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
    let settings: AppSettings

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
    // Unlike AppleIntelligenceProvider, there is no schema enforcement here, so
    // these keep the original strict-format prompts and the matching parsers:
    // the response shape is a request, not a guarantee.

    func suggestCommand(request: String, cwd: String?) async throws -> CommandSuggestion {
        let text = try await complete(
            system: AIPrompts.commandPreamble() + AIPrompts.strictCommandFormat(),
            user: AIPrompts.commandUserPrompt(request: request, cwd: cwd)
        )
        return try Self.parseCommand(text)
    }

    func plan(goal: String, cwd: String) async throws -> [PlanStep] {
        let text = try await complete(
            system: AIPrompts.planPreamble() + AIPrompts.strictPlanFormat(),
            user: AIPrompts.planUserPrompt(goal: goal, cwd: cwd)
        )
        return try Self.parsePlan(text)
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
        return CommandSuggestion(command: command, explanation: explanation)
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

    private func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if flavor != .ollama {
            // Read the key only at request time; never store or log it.
            let key = SettingsStore.shared.apiKey
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
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
