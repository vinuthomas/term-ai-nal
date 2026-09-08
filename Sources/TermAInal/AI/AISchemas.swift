import Foundation

/// The JSON schemas and decoders every schema-capable provider shares.
///
/// Each provider carries these to its API by a different mechanism — Ollama's
/// `format`, OpenAI's `response_format`, Anthropic's `output_config.format`,
/// Gemini's `responseSchema` — but the shape being demanded must be identical,
/// or the same request would return differently shaped answers depending on
/// which provider the user happened to pick. Defining them once is what keeps
/// that honest.
///
/// Apple's provider is the exception: `@Generable` derives its schema from the
/// Swift type, so it cannot share these dictionaries.
enum AISchemas {
    static let command: [String: Any] = [
        "type": "object",
        "properties": [
            "command": ["type": "string", "description": "The raw executable shell command, no markdown or backticks"],
            "explanation": ["type": "string", "description": "A concise explanation, at most 10 words"],
        ],
        "required": ["command", "explanation"],
        "additionalProperties": false,
    ]

    static let plan: [String: Any] = [
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

    static let answer: [String: Any] = [
        "type": "object",
        "properties": [
            "answer": [
                "type": "string",
                "description": "The answer, at most three sentences. Plain prose, no markdown, no reasoning narration.",
            ],
        ],
        "required": ["answer"],
        "additionalProperties": false,
    ]

    // MARK: - Decoding

    private struct DecodedCommand: Decodable {
        let command: String
        let explanation: String
    }

    private struct DecodedPlan: Decodable {
        struct Step: Decodable {
            let cmd: String
            let explanation: String
        }
        let steps: [Step]
    }

    private struct DecodedAnswer: Decodable {
        let answer: String
    }

    /// A schema is a strong constraint, not a proof: some servers ignore the
    /// field, and a model can still wrap the object in a code fence. Each
    /// decoder therefore strips a fence first and returns nil rather than
    /// throwing, so a caller can fall back to a prose parser.
    static func decodeCommand(_ text: String) -> CommandSuggestion? {
        guard let decoded: DecodedCommand = decode(text) else { return nil }
        return CommandSuggestion(
            command: cleanCommand(decoded.command),
            explanation: decoded.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func decodePlan(_ text: String) -> [PlanStep]? {
        guard let decoded: DecodedPlan = decode(text) else { return nil }
        let steps = decoded.steps
            .map {
                PlanStep(
                    cmd: cleanCommand($0.cmd),
                    explanation: $0.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.cmd.isEmpty }
        guard !steps.isEmpty else { return nil }
        return Array(steps.prefix(AIPrompts.maxPlanSteps))
    }

    static func decodeAnswer(_ text: String) -> String? {
        guard let decoded: DecodedAnswer = decode(text) else { return nil }
        return ReplyCleaner.clean(decoded.answer)
    }

    private static func decode<T: Decodable>(_ text: String) -> T? {
        guard let data = stripCodeFence(text).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Models emit ```json despite being told not to.
    static func stripCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        }
        if let fence = trimmed.range(of: "```", options: .backwards) {
            trimmed = String(trimmed[..<fence.lowerBound])
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips wrapping backticks a model may put *inside* a string value —
    /// observed from a 1.5B model asked in prose for none.
    static func cleanCommand(_ command: String) -> String {
        var trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("`") { trimmed.removeFirst() }
        while trimmed.hasSuffix("`") { trimmed.removeLast() }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
