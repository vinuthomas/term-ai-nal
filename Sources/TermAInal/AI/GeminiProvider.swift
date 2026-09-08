import Foundation

/// Google Gemini provider.
///
/// Port of the `gemini` branch of `callAIRaw` in `main.ts`. Gemini's
/// `generateContent` shape is different enough from chat completions
/// (`contents`/`parts` instead of `messages`, the system prompt in its own
/// `systemInstruction` field, structured output inside `generationConfig`) that
/// it cannot ride along on `OpenAICompatibleProvider`.
struct GeminiProvider: AIProvider {
    let settings: AIProfile

    // MARK: - AIProvider

    func suggestCommand(request: String, cwd: String?) async throws -> CommandSuggestion {
        let text = try await generate(
            system: AIPrompts.commandPreamble(),
            user: AIPrompts.commandUserPrompt(request: request, cwd: cwd),
            schema: AISchemas.command
        )
        // A schema is a strong constraint, not a proof — fall back to the prose
        // scrape `OpenAICompatibleProvider` uses for its unconstrained path.
        if let decoded = AISchemas.decodeCommand(text) { return decoded }
        return try OpenAICompatibleProvider.parseCommand(text)
    }

    func plan(goal: String, cwd: String) async throws -> [PlanStep] {
        let text = try await generate(
            system: AIPrompts.planPreamble(),
            user: AIPrompts.planUserPrompt(goal: goal, cwd: cwd),
            schema: AISchemas.plan
        )
        if let decoded = AISchemas.decodePlan(text) { return decoded }
        // The fallback expects the bare JSON array `callAIPlan` demanded, which
        // is what a model that ignored `responseSchema` is most likely to emit.
        return try OpenAICompatibleProvider.parsePlan(text)
    }

    func answer(question: String, context: String) async throws -> String {
        let text = try await generate(
            system: AIPrompts.assistantPreamble(),
            user: context.isEmpty ? question : "\(context)\n\n\(question)",
            schema: AISchemas.answer
        )
        return AISchemas.decodeAnswer(text) ?? ReplyCleaner.clean(text)
    }

    // MARK: - Transport

    private func generate(system: String, user: String, schema: [String: Any]) async throws -> String {
        // Read the key only at request time; never store or log it.
        let key = SettingsStore.shared.apiKey(for: settings.provider)
        guard !key.isEmpty else {
            throw AIError.notConfigured("No API key configured for \(settings.provider)")
        }

        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than the `?key=` query parameter the REST docs show: a
        // URL travels into proxy and crash logs, a header does not.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 90

        let body: [String: Any] = [
            "contents": [["parts": [["text": user]]]],
            "systemInstruction": ["parts": [["text": system]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": Self.geminiSchema(from: schema),
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard (200..<300).contains(status) else {
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String
                ?? error?["status"] as? String
                ?? "API Error"
            throw AIError.http(status: status, message: message)
        }

        return try Self.extractText(from: json)
    }

    /// Gemini's `responseSchema` is a subset of JSON Schema and rejects any
    /// request containing `additionalProperties`. The shared schemas carry it
    /// because OpenAI's strict mode requires it, so drop it on the way out —
    /// recursively, since it appears on nested objects inside `items` too.
    private static func geminiSchema(from schema: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in schema where key != "additionalProperties" {
            switch value {
            case let nested as [String: Any]:
                result[key] = geminiSchema(from: nested)
            case let array as [[String: Any]]:
                result[key] = array.map { geminiSchema(from: $0) }
            default:
                result[key] = value
            }
        }
        return result
    }

    /// A candidate can come back with no `content` at all but a `finishReason`
    /// of `SAFETY`, `RECITATION` or `MAX_TOKENS` — a 200 carrying no usable
    /// text. That is Gemini's refusal shape, and it must read as an error
    /// rather than fall through as an empty string.
    private static func extractText(from json: [String: Any]?) throws -> String {
        guard let candidate = (json?["candidates"] as? [[String: Any]])?.first else {
            // A prompt blocked before generation reports only `promptFeedback`.
            let reason = (json?["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw AIError.badResponse(reason.map { "Gemini blocked the prompt (\($0))" }
                ?? "Gemini returned no candidates")
        }

        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        // Concatenated, not `first`: Gemini is free to split one reply across
        // several parts, and taking only the first truncates the JSON object.
        let text = parts
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            let finish = candidate["finishReason"] as? String
            throw AIError.badResponse(Self.advice(forFinishReason: finish))
        }
        return text
    }

    /// Turns a `finishReason` into advice. Gemini's own codes name the policy
    /// that fired, not what the user should do about it.
    private static func advice(forFinishReason reason: String?) -> String {
        switch reason {
        case "SAFETY":
            return "Gemini declined that request on safety grounds. Try rephrasing it."
        case "RECITATION":
            return "Gemini stopped because the reply reproduced copyrighted material."
        case "MAX_TOKENS":
            return "Gemini hit its output limit before producing a usable answer. Ask about less at once."
        case "PROHIBITED_CONTENT", "BLOCKLIST", "SPII":
            return "Gemini blocked that request (\(reason ?? "")). Try rephrasing it."
        case let reason?:
            return "Gemini returned no text (finishReason: \(reason))"
        case nil:
            return "Gemini returned an empty response"
        }
    }

    private func endpoint() throws -> URL {
        // An explicit baseUrl points the provider at a proxy or gateway — and
        // at a local mock, which is the only way to exercise this path here.
        let base = settings.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let string = base.isEmpty
            ? "https://generativelanguage.googleapis.com/v1beta/models/\(resolvedModel):generateContent"
            : base
        guard let url = URL(string: string) else {
            throw AIError.notConfigured("Invalid endpoint URL: \(string)")
        }
        return url
    }

    /// A default the user overrides in Settings. Not verified against a live
    /// API from this machine — no Gemini key was available to check the ID.
    private var resolvedModel: String {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "gemini-2.5-flash" : model
    }
}
