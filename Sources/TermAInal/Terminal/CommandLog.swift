import Foundation

/// One shell command as the terminal reported it: the text that was typed, the
/// directory it ran in, its output, its exit status and how long it took.
///
/// This is the structured unit that replaces the flat byte stream for
/// per-command purposes. `OutputBuffer` stays as-is and keeps serving raw MCP
/// reads; nothing here is subtracted from it.
struct CommandRecord: Identifiable {
    let id: UUID
    let paneId: String
    var command: String
    var cwd: String?
    var output: String
    var exitCode: Int32?
    var startedAt: Date
    var finishedAt: Date?

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var succeeded: Bool { exitCode == 0 }
}

/// Turns each pane's raw PTY text into `CommandRecord`s by parsing OSC 133
/// semantic prompt marks.
///
/// `ANSIStripper` throws these marks away, which is right for MCP text but
/// discards the only reliable command boundaries the terminal has. The shell on
/// this machine already emits them unconfigured, so parsing costs nothing at
/// the shell end.
///
/// Feed every chunk through `ingest` in arrival order. Reads happen on the main
/// thread while `ingest` runs on SwiftTerm's PTY queue, so all state lives
/// behind one serial queue in the same spirit as `OutputBuffer`.
final class CommandLog {
    static let shared = CommandLog()

    /// Fired once per completed command, always on the main queue.
    var onCommandFinished: ((CommandRecord) -> Void)?

    /// Retained records per pane; oldest are dropped past this.
    var maxRecordsPerPane: Int = 200

    /// Per-record output cap. A `yes` loop must not be able to exhaust memory,
    /// so the tail past this is counted and discarded rather than kept.
    var maxOutputBytes: Int = 256 * 1024

    private let queue = DispatchQueue(label: "com.termainal.commandlog")
    private var panes: [String: PaneState] = [:]

    private init() {}

    // MARK: - Ingest

    func ingest(paneId: String, text: String) {
        guard !text.isEmpty else { return }
        queue.async {
            var state = self.panes[paneId] ?? PaneState()
            self.scan(paneId: paneId, text: text, into: &state)
            self.panes[paneId] = state
        }
    }

    // MARK: - Reads

    /// Most recent first.
    func records(paneId: String, limit: Int) -> [CommandRecord] {
        guard limit > 0 else { return [] }
        return queue.sync {
            guard let state = panes[paneId] else { return [] }
            return Array(state.records.suffix(limit).reversed())
        }
    }

    func lastRecord(paneId: String) -> CommandRecord? {
        queue.sync { panes[paneId]?.records.last }
    }

    func clear(paneId: String) {
        queue.async { self.panes.removeValue(forKey: paneId) }
    }

    // MARK: - Per-pane state

    /// Where the parser is between prompt marks. `A` opens a prompt, `B` ends it
    /// and begins the echoed command line, `C` starts execution, `D` ends it.
    private enum Phase {
        case idle
        case prompt
        case command
        case output
    }

    private struct PaneState {
        var phase: Phase = .idle
        /// Text held back because a sequence was cut mid-way by a chunk boundary.
        var carry: String = ""
        /// Raw echo of the typed line, captured between the B and C marks.
        var commandEcho: String = ""
        var cwd: String?
        var open: CommandRecord?
        /// Bytes of output already dropped for exceeding `maxOutputBytes`.
        var droppedOutputBytes: Int = 0
        var records: [CommandRecord] = []
    }

    // MARK: - Scanner

    /// A stray `ESC ]` that never terminates would otherwise grow `carry`
    /// without bound; past this it is treated as ordinary text.
    private static let maxCarryBytes = 4096

    private func scan(paneId: String, text: String, into state: inout PaneState) {
        let work = state.carry + text
        state.carry = ""

        var plain = ""
        var i = work.startIndex

        while i < work.endIndex {
            guard work[i] == "\u{1b}" else {
                plain.append(work[i])
                i = work.index(after: i)
                continue
            }

            let next = work.index(after: i)
            guard next < work.endIndex else {
                // A lone trailing ESC is unresolvable until the next chunk.
                state.carry = String(work[i...])
                break
            }

            guard work[next] == "]" else {
                // Not an OSC, so it carries no semantics here — but it still
                // has to arrive at `ANSIStripper` whole, or half of a split CSI
                // leaks into a record as text.
                guard let end = escapeEnd(in: work, from: next) else {
                    state.carry = String(work[i...])
                    if state.carry.utf8.count > Self.maxCarryBytes {
                        plain.append(state.carry)
                        state.carry = ""
                    }
                    break
                }
                plain.append(contentsOf: work[i..<end])
                i = end
                continue
            }

            guard let end = oscTerminator(in: work, from: next) else {
                let tail = String(work[i...])
                if tail.utf8.count > Self.maxCarryBytes {
                    plain.append(tail)
                } else {
                    state.carry = tail
                }
                break
            }

            let body = String(work[work.index(after: next)..<end.bodyEnd])
            append(plain, paneId: paneId, to: &state)
            plain = ""
            handle(osc: body, paneId: paneId, state: &state)
            i = end.next
        }

        append(plain, paneId: paneId, to: &state)
    }

    /// Locates the end of a non-OSC escape sequence starting at `intro` (the
    /// character after ESC), or nil if the chunk ended before it completed.
    private func escapeEnd(in text: String, from intro: String.Index) -> String.Index? {
        if text[intro] == "[" {
            var i = text.index(after: intro)
            while i < text.endIndex {
                if text[i].isNumber || ";?<>=!".contains(text[i]) {
                    i = text.index(after: i)
                    continue
                }
                return text.index(after: i)
            }
            return nil
        }

        // Charset designators take one more byte; everything else is a
        // two-character sequence we can consume as it stands.
        if text[intro] == "(" || text[intro] == ")" {
            let arg = text.index(after: intro)
            return arg < text.endIndex ? text.index(after: arg) : nil
        }
        return text.index(after: intro)
    }

    /// Locates the ST closing an OSC that starts at `open` (the `]`), returning
    /// where its payload ends and where scanning resumes. ST is BEL or `ESC \`.
    private func oscTerminator(
        in text: String,
        from open: String.Index
    ) -> (bodyEnd: String.Index, next: String.Index)? {
        var i = text.index(after: open)
        while i < text.endIndex {
            if text[i] == "\u{07}" {
                return (i, text.index(after: i))
            }
            if text[i] == "\u{1b}" {
                let after = text.index(after: i)
                // An ESC not followed by `\` is a malformed OSC; give up on it
                // and let the outer scanner re-examine from there.
                guard after < text.endIndex else { return nil }
                return text[after] == "\\" ? (i, text.index(after: after)) : (i, i)
            }
            i = text.index(after: i)
        }
        return nil
    }

    // MARK: - Marks

    private func handle(osc body: String, paneId: String, state: inout PaneState) {
        let parts = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let code = parts.first else { return }

        switch code {
        case "133":
            guard parts.count > 1, let mark = parts[1].first else { return }
            switch mark {
            case "A":
                // A prompt without an intervening D means the previous command
                // never reported a status — close it out rather than leak it.
                finish(exitCode: nil, paneId: paneId, state: &state)
                state.phase = .prompt
                state.commandEcho = ""
            case "B":
                state.phase = .command
                state.commandEcho = ""
            case "C":
                start(paneId: paneId, state: &state)
            case "D":
                // `D;<code>` or a bare `D`; extra parameters (`aid=…`) are ignored.
                let status = parts.count > 2 ? Int32(parts[2]) : nil
                finish(exitCode: status, paneId: paneId, state: &state)
            default:
                break
            }

        case "1337":
            guard parts.count > 1 else { return }
            let rest = parts.dropFirst().joined(separator: ";")
            guard rest.hasPrefix("CurrentDir=") else { return }
            let path = String(rest.dropFirst("CurrentDir=".count))
            state.cwd = path
            state.open?.cwd = path

        default:
            break
        }
    }

    private func append(_ plain: String, paneId: String, to state: inout PaneState) {
        guard !plain.isEmpty else { return }

        switch state.phase {
        case .command:
            state.commandEcho += plain
        case .output:
            guard state.open != nil else { return }
            let room = maxOutputBytes - state.open!.output.utf8.count
            guard room > 0 else {
                state.droppedOutputBytes += plain.utf8.count
                return
            }
            let clean = ANSIStripper.strip(plain)
            guard !clean.isEmpty else { return }
            if clean.utf8.count <= room {
                state.open!.output += clean
            } else {
                var head = clean
                while head.utf8.count > room, !head.isEmpty { head.removeLast() }
                state.droppedOutputBytes += clean.utf8.count - head.utf8.count
                state.open!.output += head
            }
        case .idle, .prompt:
            break
        }
    }

    private func start(paneId: String, state: inout PaneState) {
        state.phase = .output
        // Return at a bare prompt produces no command and so no record; output
        // between here and D is discarded because `open` stays nil.
        let command = Self.settledCommandLine(from: state.commandEcho)
        state.commandEcho = ""
        state.droppedOutputBytes = 0
        guard !command.isEmpty else {
            state.open = nil
            return
        }
        state.open = CommandRecord(
            id: UUID(),
            paneId: paneId,
            command: command,
            cwd: state.cwd,
            output: "",
            exitCode: nil,
            startedAt: Date(),
            finishedAt: nil
        )
    }

    /// Drops zsh's end-of-line marker from the tail of captured output.
    ///
    /// With `PROMPT_SP` on (the default) zsh writes `%` padded with spaces and a
    /// carriage return before drawing the next prompt, to show whether the last
    /// line was incomplete. Observed on this machine, that lands *before* the
    /// `D` mark, so it falls inside the command's own output window. Harmless on
    /// screen, but every consumer of a record would otherwise carry it — and
    /// these records are fed to a model, where it is pure wasted context.
    static func trimPromptArtefacts(_ output: String) -> String {
        var lines = output.components(separatedBy: "\n")
        while let last = lines.last {
            let stripped = last.trimmingCharacters(in: .whitespaces)
            // Only an isolated marker, never a line that merely ends in `%`.
            if stripped.isEmpty || stripped == "%" || stripped == "#" {
                lines.removeLast()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    private func finish(exitCode: Int32?, paneId: String, state: inout PaneState) {
        state.phase = .idle
        guard var record = state.open else { return }
        state.open = nil

        record.exitCode = exitCode
        record.finishedAt = Date()
        record.output = Self.trimPromptArtefacts(record.output)
        if state.droppedOutputBytes > 0 {
            record.output += "\n[\(state.droppedOutputBytes) bytes of output dropped]"
            state.droppedOutputBytes = 0
        }

        state.records.append(record)
        if state.records.count > maxRecordsPerPane {
            state.records.removeFirst(state.records.count - maxRecordsPerPane)
        }

        let callback = onCommandFinished
        DispatchQueue.main.async { callback?(record) }
    }

    /// The B…C region is the shell's own echo of the line being edited, so it
    /// carries cursor movement, redraws and autosuggestion leftovers. Once the
    /// control sequences are gone the last non-empty line is what the user
    /// finally submitted; everything before it is superseded redraw.
    private static func settledCommandLine(from echo: String) -> String {
        let clean = ANSIStripper.strip(echo)
        for line in clean.components(separatedBy: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
