import Foundation

/// Chat-completions-shaped remote providers.
///
/// Port of the `openai`, `perplexity` and `ollama` branches of `callAIRaw` in
/// `main.ts`. All three take `{ model, messages: [system, user] }`; they differ
/// only in URL, auth header and where the reply text sits in the response, so
/// one provider covers them.
///
/// The `anthropic` and `gemini` branches of `callAIRaw` are NOT ported yet —
/// their request and response shapes are different enough to need their own
/// providers. `AIService.provider(for:)` returns nil for them.
struct OpenAICompatibleProvider: AIProvider {
    let settings: AIProfile

    private var flavor: Flavor {
        Flavor(rawValue: settings.provider) ?? .openai
    }

    private enum Flavor: String {
        case openai
        case perplexity
        case ollama
    }

    // MARK: - AIProvider
    //
    /// Whether this endpoint can constrain output to a JSON schema, closing the
    /// gap with `AppleIntelligenceProvider`'s guided generation.
    ///
    /// Without it the format is a *request*: a 1.5B model asked in prose for no
    /// backticks still returned ``\`ls -u | sort -u\``` — which is exactly the
    /// class of breakage the Electron parser lived with.
    private var schemaSupport: SchemaSupport {
        switch flavor {
        case .ollama: return .ollamaFormat
        case .openai: return .openAIResponseFormat
        case .perplexity: return .none
        }
    }

    private enum SchemaSupport {
        case ollamaFormat
        case openAIResponseFormat
        case none
    }

    func suggestCommand(request: String, cwd: String?) async throws -> CommandSuggestion {
        let constrained = schemaSupport
        let text = try await complete(
            system: AIPrompts.commandPreamble()
                + (constrained == .none ? AIPrompts.strictCommandFormat() : ""),
            user: AIPrompts.commandUserPrompt(request: request, cwd: cwd),
            schema: constrained == .none ? nil : AISchemas.command
        )
        guard constrained != .none else { return try Self.parseCommand(text) }
        // A schema is a strong constraint, not a proof: some servers ignore the
        // field, so the prose parser stays as a fallback.
        if let decoded = AISchemas.decodeCommand(text) { return decoded }
        return try Self.parseCommand(text)
    }

    func answer(question: String, context: String) async throws -> String {
        let constrained = schemaSupport
        let text = try await complete(
            system: AIPrompts.assistantPreamble(),
            user: context.isEmpty ? question : "\(context)\n\n\(question)",
            schema: constrained == .none ? nil : AISchemas.answer
        )
        guard constrained != .none else { return ReplyCleaner.clean(text) }
        return AISchemas.decodeAnswer(text) ?? ReplyCleaner.clean(text)
    }


    func plan(goal: String, cwd: String) async throws -> [PlanStep] {
        let constrained = schemaSupport
        let text = try await complete(
            system: AIPrompts.planPreamble()
                + (constrained == .none ? AIPrompts.strictPlanFormat() : ""),
            user: AIPrompts.planUserPrompt(goal: goal, cwd: cwd),
            schema: constrained == .none ? nil : AISchemas.plan
        )
        guard constrained != .none else { return try Self.parsePlan(text) }
        if let steps = AISchemas.decodePlan(text) { return steps }
        return try Self.parsePlan(text)
    }

    // MARK: - JSON schemas

    private static let commandSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": ["type": "string", "description": "The raw executable shell command, no markdown or backticks"],
            "explanation": ["type": "string", "description": "A concise explanation, at most 10 words"],
        ],
        "required": ["command", "explanation"],
        "additionalProperties": false,
    ]

    private static let planSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "steps": [
                "type": "array",
                "maxItems": AIPrompts.maxPlanSteps,
                "items": [
                    "type": "object",
                    "properties": [
                        "cmd": ["type": "string", "description": "The raw shell command, no markdown or backticks"],
                        "explanation": ["type": "string", "description": "What this step does, at most 10 words"],
                    ],
                    "required": ["cmd", "explanation"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["steps"],
        "additionalProperties": false,
    ]

    private struct SchemaCommand: Decodable {
        let command: String
        let explanation: String
    }

    private struct SchemaPlan: Decodable {
        struct Step: Decodable {
            let cmd: String
            let explanation: String
        }
        let steps: [Step]
    }

    private static func decodeCommand(_ text: String) throws -> CommandSuggestion {
        guard let data = Self.stripCodeFence(text).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SchemaCommand.self, from: data) else {
            // Fall back to the prose parser: a schema is a strong constraint,
            // not a proof, and some servers ignore the field entirely.
            return try parseCommand(text)
        }
        return CommandSuggestion(
            command: cleanCommand(decoded.command),
            explanation: decoded.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func decodePlan(_ text: String) throws -> [PlanStep] {
        guard let data = Self.stripCodeFence(text).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SchemaPlan.self, from: data) else {
            return try parsePlan(text)
        }
        let steps = decoded.steps
            .map { PlanStep(cmd: cleanCommand($0.cmd), explanation: $0.explanation.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.cmd.isEmpty }
        guard !steps.isEmpty else {
            throw AIError.badResponse("Plan response contained no steps")
        }
        return Array(steps.prefix(AIPrompts.maxPlanSteps))
    }

    /// Strips wrapping backticks a model may still put *inside* a string value.
    static func cleanCommand(_ command: String) -> String {
        var trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("`") { trimmed.removeFirst() }
        while trimmed.hasSuffix("`") { trimmed.removeLast() }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing

    /// The `COMMAND:` / `EXPLANATION:` scrape the renderer used to do.
    static func parseCommand(_ text: String) throws -> CommandSuggestion {
        var command: String?
        var explanation = ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let rest = trimmed.dropPrefixIfPresent("COMMAND:") {
                command = rest.trimmingCharacters(in: .whitespaces)
            } else if let rest = trimmed.dropPrefixIfPresent("EXPLANATION:") {
                explanation = rest.trimmingCharacters(in: .whitespaces)
            }
        }
        guard let command, !command.isEmpty else {
            throw AIError.badResponse("Response did not contain a COMMAND: line")
        }
        return CommandSuggestion(command: cleanCommand(command), explanation: explanation)
    }

    /// Equivalent of the `JSON.parse` validation in `callAIPlan`, plus a fence
    /// strip because models emit ```json despite being told not to.
    static func parsePlan(_ text: String) throws -> [PlanStep] {
        struct RawStep: Decodable {
            let cmd: String
            let explanation: String?
        }

        let json = stripCodeFence(text)
        guard let data = json.data(using: .utf8) else {
            throw AIError.badResponse("Plan response was not valid UTF-8")
        }
        let raw: [RawStep]
        do {
            raw = try JSONDecoder().decode([RawStep].self, from: data)
        } catch {
            throw AIError.badResponse("Plan response was not a JSON array of {cmd, explanation}")
        }

        let steps = raw
            .map { PlanStep(cmd: $0.cmd.trimmingCharacters(in: .whitespacesAndNewlines), explanation: $0.explanation ?? "") }
            .filter { !$0.cmd.isEmpty }
        guard !steps.isEmpty else {
            throw AIError.badResponse("Plan response contained no steps")
        }
        return Array(steps.prefix(AIPrompts.maxPlanSteps))
    }

    private static func stripCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        // Drop the opening fence line (```/```json) and the closing fence.
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        }
        if let fence = trimmed.range(of: "```", options: .backwards) {
            trimmed = String(trimmed[..<fence.lowerBound])
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transport

    private func complete(system: String, user: String, schema: [String: Any]? = nil) async throws -> String {
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if flavor != .ollama {
            // Read the key only at request time; never store or log it.
            let key = SettingsStore.shared.apiKey(for: settings.provider)
            guard !key.isEmpty else {
                throw AIError.notConfigured("No API key configured for \(settings.provider)")
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": resolvedModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if flavor == .ollama {
            body["stream"] = false
            // Harmlessly ignored by models without a thinking mode. It does not
            // reliably suppress reasoning either — qwen3 still emits its trace
            // into `content` — but it helps where the model honours it.
            body["think"] = false
        }
        if let schema {
            switch schemaSupport {
            case .ollamaFormat:
                body["format"] = schema
            case .openAIResponseFormat:
                // Unverified — needs a real key to exercise.
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": ["name": "shell_response", "strict": true, "schema": schema],
                ]
            case .none:
                break
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // A local model can spend most of a minute just loading before it
        // emits a token, and a reasoning model spends more of it thinking.
        // URLSession's 60s default was timing those out mid-generation.
        request.timeoutInterval = flavor == .ollama ? 300 : 90

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                ?? (json?["error"] as? String)
                ?? "API Error"
            throw AIError.http(status: status, message: message)
        }

        guard let text = Self.extractContent(from: json, flavor: flavor)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw AIError.badResponse("\(settings.provider) returned an empty response")
        }
        return text
    }

    private static func extractContent(from json: [String: Any]?, flavor: Flavor) -> String? {
        guard let json else { return nil }
        switch flavor {
        case .ollama:
            // Ollama's /api/chat replies with a single `message`, not `choices`.
            return (json["message"] as? [String: Any])?["content"] as? String
        case .openai, .perplexity:
            let choices = json["choices"] as? [[String: Any]]
            return (choices?.first?["message"] as? [String: Any])?["content"] as? String
        }
    }

    private func endpoint() throws -> URL {
        // An explicit baseUrl lets the OpenAI path target any OpenAI-compatible
        // server without adding a provider — same rationale as `callAIRaw`.
        let base = settings.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let string: String
        switch flavor {
        case .perplexity:
            string = "https://api.perplexity.ai/chat/completions"
        case .openai:
            string = base.isEmpty ? "https://api.openai.com/v1/chat/completions" : base
        case .ollama:
            string = (base.isEmpty ? "http://localhost:11434" : base) + "/api/chat"
        }
        guard let url = URL(string: string) else {
            throw AIError.notConfigured("Invalid endpoint URL: \(string)")
        }
        return url
    }

    /// The hardcoded defaults from `callAIRaw`.
    private var resolvedModel: String {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isEmpty else { return model }
        switch flavor {
        case .openai: return "gpt-4o"
        case .perplexity: return "llama-3.1-sonar-large-128k-online"
        case .ollama: return "llama3"
        }
    }
}

private extension String {
    /// Case-insensitive prefix strip, returning nil when the prefix is absent.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        guard let range = range(of: prefix, options: [.anchored, .caseInsensitive]) else { return nil }
        return String(self[range.upperBound...])
    }
}
