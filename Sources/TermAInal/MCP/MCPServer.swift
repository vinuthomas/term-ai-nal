import Foundation
import Network

/// Pane metadata handed to the MCP server by the app layer.
///
/// Port of the shape produced by `buildTerminalList` in `main.ts`, minus the
/// `is_active` flag — that is derived from `activePaneIdProvider` at request time.
struct MCPPaneInfo {
    let paneId: String
    let paneNumber: Int
    let label: String?
    let cwd: String?
}

/// Hand-rolled HTTP/1.1 + SSE server exposing term-ai-nal's panes over the MCP
/// Streamable HTTP transport (single endpoint, JSON-RPC 2.0).
///
/// Port of `startMcpServer` / `stopMcpServer` / `applyMcpSettings` /
/// `handleMcpToolCall` and the SSE machinery (`makeSseId`, `sseSend`,
/// `broadcastToSseSubscribers`, `removeSseSubscriber`, `closeAllSseSubscribers`)
/// in `main.ts`. Electron used a bare `http.createServer`, so this uses bare
/// `NWListener` rather than pulling in a web framework.
///
/// Design rule carried over from the Electron build: **the server never reads UI
/// state directly.** Pane metadata, the active pane and buffer/input access all
/// arrive through the injected closures below, exactly the way the Electron main
/// process only ever received pane metadata pushed from the renderer over the
/// `mcp-set-*` IPC channels.
final class MCPServer {
    private static let serverName = "term-ai-nal"
    private static let serverVersion = "1.0.0"
    private static let protocolVersion = "2024-11-05"
    private static let heartbeatInterval: TimeInterval = 15

    // MARK: - Injected app state

    var panesProvider: (() -> [MCPPaneInfo])?
    var activePaneIdProvider: (() -> String?)?
    var readBuffer: ((String, Int?) -> String)?
    var sendInput: ((String, String) -> Bool)?

    /// Opens a new terminal. `scope` is `pane` or `tab`.
    ///
    /// The app decides the policy — how many are too many, whether the path is
    /// usable, whether focus moves — and returns the sentence the client sees.
    /// The server stays out of it, as with every other capability here.
    var openTerminal: ((_ scope: String, _ purpose: String, _ cwd: String?, _ focus: Bool) -> String)?

    /// Asks the app to show an approve/deny sheet before `send_input_to_terminal`
    /// reaches the shell. Only consulted when `requireInputConfirmation` is on.
    /// The HTTP request simply stays open until `completion` fires — nothing on
    /// `queue` blocks while it waits, so other connections and heartbeats are
    /// unaffected.
    var confirmSendInput: ((_ paneId: String, _ text: String, _ completion: @escaping (Bool) -> Void) -> Void)?

    // MARK: - Configuration

    private let port: Int
    private let features: MCPFeatures
    private let authToken: String
    private let requireInputConfirmation: Bool

    // MARK: - Mutable state, guarded by `queue`

    private let queue = DispatchQueue(label: "com.termainal.mcpserver")
    private var listener: NWListener?
    /// Subscribers watching one specific pane, keyed by pane id.
    private var paneSubscribers: [String: [SSESubscriber]] = [:]
    /// Subscribers following whichever pane is focused (`?active=true`).
    private var activeSubscribers: [SSESubscriber] = []
    private var nextSubscriberId = 0
    /// Last pane id we announced, so `pane_changed` can report the previous one
    /// without ever asking the UI for history it does not keep.
    private var lastAnnouncedActivePaneId: String?

    init(port: Int, features: MCPFeatures, authToken: String, requireInputConfirmation: Bool = false) {
        self.port = port
        self.features = features
        self.authToken = authToken
        self.requireInputConfirmation = requireInputConfirmation
    }

    // MARK: - Lifecycle

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw MCPServerError.invalidPort(port)
        }

        let params = NWParameters.tcp
        // Loopback only — this server is never exposed off-device.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("[MCP] Server running at http://127.0.0.1:\(nwPort.rawValue)/mcp")
            case .failed(let error):
                NSLog("[MCP] Server error: \(error)")
            default:
                break
            }
        }

        queue.sync { self.listener = listener }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            closeAllSubscribersLocked()
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Fan-out from the app

    /// Port of `broadcastToSseSubscribers`.
    func broadcast(paneId: String, text: String) {
        queue.async {
            self.deliverLocked(event: "output", data: .string(text), toPane: paneId)
        }
    }

    /// Port of the `mcp-set-active-pane` IPC handler's `pane_changed` notification.
    func activePaneChanged(to paneId: String) {
        queue.async {
            let previous = self.lastAnnouncedActivePaneId
            self.lastAnnouncedActivePaneId = paneId
            guard previous != paneId, !self.activeSubscribers.isEmpty else { return }
            let payload: JSONValue = .object([
                "previous_terminal_id": previous.map { JSONValue.string($0) } ?? .null,
                "terminal_id": .string(paneId),
            ])
            self.activeSubscribers = self.activeSubscribers.filter {
                $0.send(event: "pane_changed", data: payload)
            }
        }
    }

    /// Port of `removeAllSseSubscribersForTerminal` — tells watchers the pane is gone.
    func paneClosed(paneId: String) {
        queue.async {
            let subs = self.paneSubscribers.removeValue(forKey: paneId) ?? []
            for sub in subs {
                _ = sub.send(event: "closed", data: .string("Terminal \(paneId) was closed."))
                sub.close()
            }
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let session = HTTPSession(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.queue.async { self?.dropSubscribersLocked(for: connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        readMore(session)
    }

    /// A request can arrive split across several TCP reads, so keep accumulating
    /// until the request line, headers and any `Content-Length` body are complete.
    private func readMore(_ session: HTTPSession) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                session.buffer.append(data)
                switch HTTPRequest.parse(session.buffer) {
                case .incomplete:
                    if session.buffer.count > 1024 * 1024 {
                        self.respond(session.connection, status: 400, json: .object(["error": .string("Request too large")]))
                        return
                    }
                    self.readMore(session)
                case .malformed:
                    self.respond(session.connection, status: 400, json: .object(["error": .string("Bad request")]))
                case .complete(let request):
                    self.route(request, on: session.connection)
                }
                return
            }
            if isComplete || error != nil {
                session.connection.cancel()
            }
        }
    }

    // MARK: - Routing
    //
    // Every connection is started on `queue`, so parsing, routing and registry
    // mutation below already run serialized on it — no extra locking needed.

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        if request.method == "OPTIONS" {
            // No CORS headers are sent (see respondRaw), so this satisfies
            // nothing a browser needs — a web page was never a legitimate MCP
            // client. Answered only so a stray preflight gets a clean 204
            // instead of falling through to 404.
            respondRaw(connection, status: 204, headers: [:], body: Data(), keepAlive: false)
            return
        }

        guard isAuthorized(request) else {
            MCPAuditLog.record("auth_failed path=\(request.path)")
            respond(connection, status: 401, json: .object(["error": .string("Unauthorized")]))
            return
        }

        if request.method == "GET", request.path == "/" || request.path == "/mcp" {
            respond(connection, status: 200, json: serverInfo())
            return
        }

        if request.method == "POST", request.path == "/mcp" {
            handleJSONRPC(request, on: connection)
            return
        }

        if request.method == "GET", request.path == "/mcp/stream" {
            handleStream(request, on: connection)
            return
        }

        respond(connection, status: 404, json: .object(["error": .string("Not found")]))
    }

    /// Every route but `OPTIONS` requires `Authorization: Bearer <token>`.
    ///
    /// Loopback binding alone is not enough: without this, any process on the
    /// machine — including JavaScript in a browser tab, since responses used
    /// to carry `Access-Control-Allow-Origin: *` — could call
    /// `send_input_to_terminal` with zero interaction from the user. A shared
    /// secret the real MCP client has to be configured with closes that off.
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"] else { return false }
        return header == "Bearer \(authToken)"
    }

    private func serverInfo() -> JSONValue {
        .object([
            "name": .string(Self.serverName),
            "version": .string(Self.serverVersion),
            "description": .string("MCP server for term-ai-nal terminal emulator. Query terminal panel output."),
            "tools": .array(MCPTool.all.map { .string($0.name) }),
            "endpoint": .string("http://localhost:\(port)/mcp"),
        ])
    }

    // MARK: - JSON-RPC

    private func handleJSONRPC(_ request: HTTPRequest, on connection: NWConnection) {
        guard let root = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            respond(connection, status: 400, json: .object([
                "jsonrpc": .string("2.0"),
                "id": .null,
                "error": .object(["code": .number(-32700), "message": .string("Parse error")]),
            ]))
            return
        }

        let id = JSONValue(any: root["id"] ?? NSNull())
        let method = root["method"] as? String ?? ""
        let params = root["params"] as? [String: Any] ?? [:]

        func result(_ value: JSONValue) {
            respond(connection, status: 200, json: .object([
                "jsonrpc": .string("2.0"), "id": id, "result": value,
            ]))
        }
        // JSON-RPC errors still ride a 200, as in the Electron implementation.
        func rpcError(_ code: Int, _ message: String) {
            respond(connection, status: 200, json: .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object(["code": .number(Double(code)), "message": .string(message)]),
            ]))
        }

        switch method {
        case "initialize":
            result(.object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string(Self.serverName),
                    "version": .string(Self.serverVersion),
                ]),
            ]))

        case "notifications/initialized":
            respondRaw(connection, status: 204, headers: [:], body: Data(), keepAlive: false)

        case "tools/list":
            let enabled = MCPTool.all.filter { features.isEnabled($0.featureKey) }
            result(.object(["tools": .array(enabled.map { $0.manifest })]))

        case "tools/call":
            guard let name = params["name"] as? String, !name.isEmpty else {
                rpcError(-32602, "Missing tool name")
                return
            }
            guard let tool = MCPTool.all.first(where: { $0.name == name }) else {
                MCPAuditLog.record("unknown_tool name=\(name)")
                rpcError(-32602, "Unknown tool: \(name)")
                return
            }
            guard features.isEnabled(tool.featureKey) else {
                MCPAuditLog.record("disabled_tool name=\(name)")
                rpcError(-32602, "Tool '\(name)' is disabled.")
                return
            }
            let args = params["arguments"] as? [String: Any] ?? [:]

            if name == "send_input_to_terminal", requireInputConfirmation, let confirmSendInput {
                handleSendInputWithConfirmation(args, confirmSendInput: confirmSendInput) { text in
                    result(.object(["content": .array([.object([
                        "type": .string("text"), "text": .string(text),
                    ])])]))
                }
                return
            }

            logToolCall(name, args)
            let text = handleToolCallLocked(tool.name, args)
            result(.object(["content": .array([.object([
                "type": .string("text"), "text": .string(text),
            ])])]))

        default:
            rpcError(-32601, "Method not found: \(method)")
        }
    }

    /// Port of `handleMcpToolCall`. Every branch returns human-readable text —
    /// including errors — so clients never have to special-case a failure.
    private func handleToolCallLocked(_ name: String, _ args: [String: Any]) -> String {
        let panes = panesProvider?() ?? []
        let activeId = activePaneIdProvider?()

        func lines() -> Int? {
            if let n = args["lines"] as? NSNumber { return n.intValue }
            if let s = args["lines"] as? String { return Int(s) }
            return nil
        }
        // Panes absent from `panesProvider` are the equivalent of Electron's
        // `mcpHiddenPanes` — they simply do not exist as far as MCP is concerned.
        func visible(_ id: String) -> Bool { panes.contains { $0.paneId == id } }

        switch name {
        case "list_terminals":
            let list = JSONValue.array(panes.map { pane in
                .object([
                    "id": .string(pane.paneId),
                    "label": .string(pane.label ?? pane.paneId),
                    "cwd": .string(pane.cwd ?? ""),
                    "is_active": .bool(pane.paneId == activeId),
                ])
            })
            return list.serialized(prettyPrinted: true)

        case "get_terminal_output":
            guard let id = args["terminal_id"] as? String, !id.isEmpty else {
                return "Error: Missing required argument 'terminal_id'."
            }
            guard visible(id) else {
                return "Error: Terminal '\(id)' not found. Use list_terminals to see available terminals."
            }
            let output = readBuffer?(id, lines()) ?? ""
            return output.isEmpty ? "(no output buffered yet)" : output

        case "get_active_terminal_output":
            guard let activeId else { return "Error: No active terminal." }
            guard visible(activeId) else { return "Error: The active terminal is not visible to MCP." }
            let output = readBuffer?(activeId, lines()) ?? ""
            return output.isEmpty ? "(no output buffered yet)" : output

        case "send_input_to_terminal":
            guard let id = args["terminal_id"] as? String, !id.isEmpty else {
                return "Error: Missing required argument 'terminal_id'."
            }
            guard let text = args["text"] else { return "Error: Missing required argument 'text'." }
            guard let string = text as? String else {
                return "Error: Argument 'text' must be a string."
            }
            guard visible(id), sendInput?(id, string) == true else {
                return "Error: Terminal '\(id)' not found. Use list_terminals to see available terminals."
            }
            return "Sent \(string.count) characters to terminal '\(id)'."

        case "open_terminal":
            guard let purpose = (args["purpose"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !purpose.isEmpty else {
                return "Error: Missing required argument 'purpose'."
            }
            let scope = (args["scope"] as? String) ?? "pane"
            guard scope == "pane" || scope == "tab" else {
                return "Error: Argument 'scope' must be \"pane\" or \"tab\"."
            }
            let cwd = (args["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // JSONSerialization gives NSNumber for JSON booleans, and `as Bool`
            // matches any NSNumber through ObjC bridging — the same trap that
            // once turned the JSON-RPC id 1 into true.
            let focus: Bool
            if let number = args["focus"] as? NSNumber, CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                focus = number.boolValue
            } else {
                focus = false
            }
            guard let open = openTerminal else {
                return "Error: Opening terminals is not available."
            }
            return open(scope, purpose, cwd, focus)

        case "watch_terminal":
            let id = (args["terminal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? activeId
            guard let id else { return "Error: No terminal_id provided and no active terminal." }
            guard visible(id) else {
                return "Error: Terminal '\(id)' not found. Use list_terminals to see available terminals."
            }
            let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
            let suffix = (args["include_history"] as? Bool) == false ? "&history=false" : ""
            return """
            Connect to this SSE endpoint to stream live output from terminal '\(id)':
            http://127.0.0.1:\(port)/mcp/stream?terminal_id=\(escaped)\(suffix)

            Events:
              connected — sent immediately with terminal metadata
              output    — new text chunk from the terminal
              heartbeat — sent every 15 s to keep the connection alive
              closed    — terminal was closed
            """

        case "watch_active_terminal":
            let suffix = (args["include_history"] as? Bool) == false ? "&history=false" : ""
            return """
            Connect to this SSE endpoint to stream live output from the active terminal (switches automatically when the user changes panes):
            http://127.0.0.1:\(port)/mcp/stream?active=true\(suffix)

            Events:
              connected    — sent immediately
              output       — new text chunk
              pane_changed — active terminal changed (includes new terminal_id)
              heartbeat    — sent every 15 s
              closed       — terminal was closed
            """

        default:
            return "Error: Unknown tool '\(name)'."
        }
    }

    /// Validates args the same way the synchronous `send_input_to_terminal`
    /// branch above does, then asks the app to show an approve/deny sheet
    /// before anything reaches the shell. `completion` carries the same
    /// human-readable text the synchronous path would have returned, and
    /// fires back on `queue` — nothing blocks while the sheet is up.
    private func handleSendInputWithConfirmation(
        _ args: [String: Any],
        confirmSendInput: @escaping (String, String, @escaping (Bool) -> Void) -> Void,
        completion: @escaping (String) -> Void
    ) {
        guard let id = args["terminal_id"] as? String, !id.isEmpty else {
            completion("Error: Missing required argument 'terminal_id'.")
            return
        }
        guard let text = args["text"] else {
            completion("Error: Missing required argument 'text'.")
            return
        }
        guard let string = text as? String else {
            completion("Error: Argument 'text' must be a string.")
            return
        }
        let panes = panesProvider?() ?? []
        guard panes.contains(where: { $0.paneId == id }) else {
            completion("Error: Terminal '\(id)' not found. Use list_terminals to see available terminals.")
            return
        }

        MCPAuditLog.record("tool=send_input_to_terminal pane=\(id) text=\(Self.auditEscape(string)) awaiting_confirmation=true")
        confirmSendInput(id, string) { [weak self] approved in
            guard let self else { return }
            self.queue.async {
                guard approved else {
                    MCPAuditLog.record("tool=send_input_to_terminal pane=\(id) denied=true")
                    completion("Denied by user.")
                    return
                }
                guard self.sendInput?(id, string) == true else {
                    completion("Error: Terminal '\(id)' not found. Use list_terminals to see available terminals.")
                    return
                }
                MCPAuditLog.record("tool=send_input_to_terminal pane=\(id) approved=true")
                completion("Sent \(string.count) characters to terminal '\(id)'.")
            }
        }
    }

    /// One line per tool call. `send_input_to_terminal` and `open_terminal`
    /// carry their payload — that is the whole point of an audit log — the
    /// read-only tools just note what was asked, since their output already
    /// lives in `OutputBuffer`.
    private func logToolCall(_ name: String, _ args: [String: Any]) {
        var parts = ["tool=\(name)"]
        if let id = args["terminal_id"] as? String, !id.isEmpty {
            parts.append("pane=\(id)")
        }
        if name == "send_input_to_terminal", let text = args["text"] as? String {
            parts.append("text=\(Self.auditEscape(text))")
        }
        if name == "open_terminal", let purpose = args["purpose"] as? String {
            parts.append("purpose=\(Self.auditEscape(purpose))")
        }
        MCPAuditLog.record(parts.joined(separator: " "))
    }

    private static func auditEscape(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: - SSE

    private func handleStream(_ request: HTTPRequest, on connection: NWConnection) {
        let terminalId = request.query["terminal_id"] ?? ""
        let watchActive = request.query["active"] == "true"
        let includeHistory = request.query["history"] != "false"

        if !watchActive, terminalId.isEmpty {
            respond(connection, status: 400, json: .object(["error": .string("Provide terminal_id or active=true")]))
            return
        }

        let panes = panesProvider?() ?? []
        if !terminalId.isEmpty, !panes.contains(where: { $0.paneId == terminalId }) {
            respond(connection, status: 404, json: .object(["error": .string("Terminal '\(terminalId)' not found.")]))
            return
        }

        respondRaw(connection, status: 200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        ], body: Data(), keepAlive: true)

        nextSubscriberId += 1
        let subscriber = SSESubscriber(id: "sse-\(nextSubscriberId)", connection: connection)

        if watchActive {
            let activeId = activePaneIdProvider?()
            lastAnnouncedActivePaneId = activeId
            activeSubscribers.append(subscriber)
            _ = subscriber.send(event: "connected", data: .object([
                "watching": .string("active"),
                "active_terminal_id": activeId.map { JSONValue.string($0) } ?? .null,
            ]))
            if includeHistory, let activeId, panes.contains(where: { $0.paneId == activeId }) {
                let history = readBuffer?(activeId, nil) ?? ""
                if !history.isEmpty { _ = subscriber.send(event: "output", data: .string(history)) }
            }
        } else {
            paneSubscribers[terminalId, default: []].append(subscriber)
            _ = subscriber.send(event: "connected", data: .object(["terminal_id": .string(terminalId)]))
            if includeHistory {
                let history = readBuffer?(terminalId, nil) ?? ""
                if !history.isEmpty { _ = subscriber.send(event: "output", data: .string(history)) }
            }
        }

        startHeartbeat(for: subscriber)
    }

    /// Keeps proxies and long-lived agent clients from timing the stream out.
    private func startHeartbeat(for subscriber: SSESubscriber) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !subscriber.send(event: "heartbeat", data: .string("ping")) {
                self.removeLocked(subscriber)
            }
        }
        subscriber.heartbeat = timer
        timer.resume()
    }

    private func deliverLocked(event: String, data: JSONValue, toPane paneId: String) {
        if var subs = paneSubscribers[paneId] {
            subs = subs.filter { $0.send(event: event, data: data) }
            if subs.isEmpty { paneSubscribers.removeValue(forKey: paneId) } else { paneSubscribers[paneId] = subs }
        }
        if paneId == activePaneIdProvider?() {
            activeSubscribers = activeSubscribers.filter { $0.send(event: event, data: data) }
        }
    }

    /// Port of `removeSseSubscriber`.
    private func removeLocked(_ subscriber: SSESubscriber) {
        activeSubscribers.removeAll { $0.id == subscriber.id }
        for (paneId, subs) in paneSubscribers {
            let kept = subs.filter { $0.id != subscriber.id }
            if kept.isEmpty { paneSubscribers.removeValue(forKey: paneId) } else { paneSubscribers[paneId] = kept }
        }
        subscriber.close()
    }

    private func dropSubscribersLocked(for connection: NWConnection) {
        for sub in activeSubscribers where sub.connection === connection { sub.close() }
        activeSubscribers.removeAll { $0.connection === connection }
        for (paneId, subs) in paneSubscribers {
            for sub in subs where sub.connection === connection { sub.close() }
            let kept = subs.filter { $0.connection !== connection }
            if kept.isEmpty { paneSubscribers.removeValue(forKey: paneId) } else { paneSubscribers[paneId] = kept }
        }
    }

    /// Port of `closeAllSseSubscribers`.
    private func closeAllSubscribersLocked() {
        for (_, subs) in paneSubscribers { subs.forEach { $0.close() } }
        paneSubscribers.removeAll()
        activeSubscribers.forEach { $0.close() }
        activeSubscribers.removeAll()
    }

    // MARK: - HTTP responses

    private func respond(_ connection: NWConnection, status: Int, json: JSONValue) {
        let body = Data(json.serialized().utf8)
        respondRaw(connection, status: status, headers: ["Content-Type": "application/json"], body: body, keepAlive: false)
    }

    private func respondRaw(
        _ connection: NWConnection,
        status: Int,
        headers: [String: String],
        body: Data,
        keepAlive: Bool
    ) {
        // Deliberately no Access-Control-Allow-* headers: an MCP client is a
        // local agent process, never a browser tab, and CORS is the mechanism
        // that would let one read this response.
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        if keepAlive {
            // SSE bodies are open-ended, so no Content-Length.
            head += "\r\n"
        } else {
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        }

        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in
            if !keepAlive { connection.cancel() }
        })
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default: return "Error"
        }
    }
}

enum MCPServerError: Error {
    case invalidPort(Int)
}

// MARK: - Subscribers

/// One live SSE connection. Port of the `SseSubscriber` interface in `main.ts`.
private final class SSESubscriber {
    let id: String
    let connection: NWConnection
    var heartbeat: DispatchSourceTimer?
    private var isClosed = false

    init(id: String, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }

    /// Port of `sseSend` — returns false if the connection is gone, which is the
    /// caller's signal to evict this subscriber.
    func send(event: String, data: JSONValue) -> Bool {
        guard !isClosed, connection.state == .ready else { return false }
        let frame = "event: \(event)\ndata: \(data.serialized())\n\n"
        connection.send(content: Data(frame.utf8), completion: .idempotent)
        return true
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        heartbeat?.cancel()
        heartbeat = nil
        connection.cancel()
    }
}

// MARK: - Tool manifest

/// Port of the `MCP_TOOLS` manifest plus the `featureMap` gate in `main.ts`.
private struct MCPTool {
    let name: String
    let description: String
    let properties: JSONValue
    let required: [String]
    /// Which `mcpFeatures` flag gates this tool. `watch_*` deliberately share a
    /// gate with their non-streaming counterpart, as in the Electron version.
    let featureKey: MCPFeatureKey

    var manifest: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": properties,
                "required": .array(required.map { .string($0) }),
            ]),
        ])
    }

    private static func stringProp(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func numberProp(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }
    private static func boolProp(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static let all: [MCPTool] = [
        MCPTool(
            name: "list_terminals",
            description: "List all open terminal panels with their ID, label, and current working directory.",
            properties: .object([:]),
            required: [],
            featureKey: .listTerminals
        ),
        MCPTool(
            name: "open_terminal",
            description: """
                Open another terminal to drive. Prefer scope="pane".

                A pane is a row in the current tab's accordion, for shells belonging to the                 same piece of work — a build, its test run, its logs. A tab is for genuinely                 separate work the user would switch to rather than group: another repository,                 an unrelated task. When in doubt, open a pane: it keeps related shells                 together and is easy to promote later, whereas a stray tab is clutter the                 user has to close.

                Note that only the expanded pane in a tab is visible. A pane groups shells;                 it does not put two of them on screen at once. If the user needs to watch                 this terminal, pass focus=true — otherwise it opens without disturbing them.

                'purpose' is required and becomes the terminal's label, shown on the pane                 header and in list_terminals. Say what the terminal is for, not what you are                 about to type.
                """,
            properties: .object([
                "purpose": stringProp("What this terminal is for, e.g. \"integration test logs\". Becomes its label."),
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array([.string("pane"), .string("tab")]),
                    "description": .string("\"pane\" (default) adds a row to the current tab; \"tab\" starts a separate one."),
                ]),
                "cwd": stringProp("Directory to start in. Defaults to the app's new-terminal preference."),
                "focus": .object([
                    "type": .string("boolean"),
                    "description": .string("Show it immediately. Defaults to false so the user is not interrupted."),
                ]),
            ]),
            required: ["purpose"],
            featureKey: .openTerminal
        ),
        MCPTool(
            name: "get_terminal_output",
            description: "Get the buffered text output of a specific terminal panel.",
            properties: .object([
                "terminal_id": stringProp("The terminal panel ID (from list_terminals)"),
                "lines": numberProp("Maximum number of tail lines to return (default: all buffered output)"),
            ]),
            required: ["terminal_id"],
            featureKey: .getTerminalOutput
        ),
        MCPTool(
            name: "get_active_terminal_output",
            description: "Get the buffered text output of the currently active (focused) terminal panel.",
            properties: .object([
                "lines": numberProp("Maximum number of tail lines to return (default: all buffered output)"),
            ]),
            required: [],
            featureKey: .getActiveTerminalOutput
        ),
        MCPTool(
            name: "send_input_to_terminal",
            description: "Send a text string (e.g. a command followed by \\n) to a specific terminal panel.",
            properties: .object([
                "terminal_id": stringProp("The terminal panel ID (from list_terminals)"),
                "text": stringProp("Text to send to the terminal (append \\n to execute as a command)"),
            ]),
            required: ["terminal_id", "text"],
            featureKey: .sendInputToTerminal
        ),
        MCPTool(
            name: "watch_terminal",
            description: "Stream live output from a specific terminal panel over SSE. Connect to GET /mcp/stream?terminal_id=<id> to receive real-time output events. Each SSE event has type \"output\" with the new text chunk, \"connected\" on start, \"heartbeat\" every 15 s, and \"closed\" when the terminal closes.",
            properties: .object([
                "terminal_id": stringProp("The terminal panel ID to watch (from list_terminals). Omit to watch the active terminal."),
                "include_history": boolProp("If true, send buffered history immediately after connecting (default: true)."),
            ]),
            required: [],
            featureKey: .getTerminalOutput
        ),
        MCPTool(
            name: "watch_active_terminal",
            description: "Stream live output from whichever terminal is currently focused, switching automatically when the user changes panes. Connect to GET /mcp/stream?active=true. Events: \"output\", \"connected\", \"pane_changed\", \"heartbeat\", \"closed\".",
            properties: .object([
                "include_history": boolProp("If true, send buffered history of the current active terminal immediately after connecting (default: true)."),
            ]),
            required: [],
            featureKey: .getActiveTerminalOutput
        ),
    ]
}

private enum MCPFeatureKey {
    case listTerminals
    case getTerminalOutput
    case getActiveTerminalOutput
    case sendInputToTerminal
    case openTerminal
}

private extension MCPFeatures {
    func isEnabled(_ key: MCPFeatureKey) -> Bool {
        switch key {
        case .listTerminals: return listTerminals
        case .getTerminalOutput: return getTerminalOutput
        case .getActiveTerminalOutput: return getActiveTerminalOutput
        case .sendInputToTerminal: return sendInputToTerminal
        case .openTerminal: return openTerminal
        }
    }
}

// MARK: - Minimal HTTP/1.1 parsing

/// Accumulates bytes for one connection until a full request has arrived.
private final class HTTPSession {
    let connection: NWConnection
    var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    enum ParseResult {
        case incomplete
        case malformed
        case complete(HTTPRequest)
    }

    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return .incomplete }

        guard let headerText = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .malformed
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .malformed }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let expected = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = data.count - data.distance(from: data.startIndex, to: bodyStart)
        guard available >= expected else { return .incomplete }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: expected)]

        let (path, query) = splitTarget(target)
        return .complete(HTTPRequest(
            method: method.uppercased(),
            path: path,
            query: query,
            headers: headers,
            body: Data(body)
        ))
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[target.startIndex..<mark])
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first?.percentDecoded else { continue }
            query[key] = kv.count > 1 ? (kv[1].percentDecoded ?? "") : ""
        }
        return (path, query)
    }
}

private extension Substring {
    var percentDecoded: String? {
        replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

// MARK: - JSON

/// A tiny JSON tree, so responses can be composed literally and serialized
/// deterministically without a Codable type per payload shape.
enum JSONValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        // JSONSerialization returns NSNumber for both numbers and booleans, and
        // `as Bool` matches *any* NSNumber through ObjC bridging — which turned
        // the JSON-RPC id `1` into `true`. Check the CoreFoundation type first.
        case let value as NSNumber:
            if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as Bool: self = .bool(value)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    private var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map { $0.foundationValue }
        case .object(let values): return values.mapValues { $0.foundationValue }
        }
    }

    func serialized(prettyPrinted: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if prettyPrinted { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: options),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}
