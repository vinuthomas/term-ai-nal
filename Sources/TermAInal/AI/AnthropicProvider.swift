import Foundation

/// Anthropic Messages API provider.
///
/// Structured output uses `output_config.format` with a JSON schema, which is
/// the current mechanism. Two older patterns are deliberately *not* used:
/// forcing a tool call with `tool_choice: {type: "tool"}` — rejected with a 400
/// on current models — and prefilling an assistant turn with `{`, which is also
/// rejected. The deprecated top-level `output_format` is likewise avoided.
struct AnthropicProvider: AIProvider {
    let settings: AIProfile

    private static let defaultEndpoint = "https://api.anthropic.com/v1/messages"

    /// A default the user overrides in Settings.
    ///
    /// Not downgraded for cost: which model to pay for is the user's call, and
    /// a wrong shell flag is more expensive than a few tokens.
    private static let defaultModel = "claude-opus-5"

    /// `max_tokens` is a ceiling, not a reservation — unused headroom costs
    /// nothing — so it is set well clear of anything the schemas can produce
    /// rather than trimmed to a guess. Non-streaming is safe at this size.
    private static let maxTokens = 16_000

    // MARK: - AIProvider

    func suggestCommand(request: String, cwd: String?) async throws -> CommandSuggestion {
        let text = try await complete(
            system: AIPrompts.commandPreamble(),
            user: AIPrompts.commandUserPrompt(request: request, cwd: cwd),
            schema: AISchemas.command
        )
        guard let decoded = AISchemas.decodeCommand(text) else {
            throw AIError.badResponse("Anthropic returned a response that did not match the requested shape")
        }
        return decoded
    }

    func plan(goal: String, cwd: String) async throws -> [PlanStep] {
        let text = try await complete(
            system: AIPrompts.planPreamble(),
            user: AIPrompts.planUserPrompt(goal: goal, cwd: cwd),
            schema: AISchemas.plan
        )
        guard let steps = AISchemas.decodePlan(text) else {
            throw AIError.badResponse("Anthropic returned a plan that did not match the requested shape")
        }
        return steps
    }

    func answer(question: String, context: String) async throws -> String {
        let text = try await complete(
            system: AIPrompts.assistantPreamble(),
            user: context.isEmpty ? question : "\(context)\n\n\(question)",
            schema: AISchemas.answer
        )
        return AISchemas.decodeAnswer(text) ?? ReplyCleaner.clean(text)
    }

    // MARK: - Transport

    private func complete(system: String, user: String, schema: [String: Any]) async throws -> String {
        let key = SettingsStore.shared.apiKey(for: settings.provider)
        guard !key.isEmpty else {
            throw AIError.notConfigured("No API key configured for Anthropic")
        }

        let base = settings.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base.isEmpty ? Self.defaultEndpoint : base) else {
            throw AIError.notConfigured("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Read at request time; never stored on this type and never logged.
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "model": model.isEmpty ? Self.defaultModel : model,
            "max_tokens": Self.maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": schema,
                ],
            ],
            // `thinking` is deliberately omitted rather than disabled. Current
            // models run adaptive thinking by default, and explicitly disabling
            // it is a documented source of tool calls and reasoning tags
            // leaking into the visible text.
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "API Error"
            throw AIError.http(status: status, message: message)
        }

        // A policy decline arrives as HTTP 200 with `stop_reason: "refusal"` and
        // no usable content, so the status code alone is not enough.
        if let stop = json?["stop_reason"] as? String, stop == "refusal" {
            let category = (json?["stop_details"] as? [String: Any])?["category"] as? String
            throw AIError.badResponse(
                "Anthropic declined that request" + (category.map { " (\($0))" } ?? "") + "."
            )
        }

        guard let text = Self.firstText(in: json) else {
            throw AIError.badResponse("Anthropic returned no text content")
        }
        return text
    }

    /// The first `text` block, searched rather than indexed.
    ///
    /// With thinking on, `content[0]` is a `thinking` block, so taking the
    /// first element would read the wrong thing.
    private static func firstText(in json: [String: Any]?) -> String? {
        guard let content = json?["content"] as? [[String: Any]] else { return nil }
        for block in content where block["type"] as? String == "text" {
            if let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
