import Foundation

/// A single shell command plus a short rationale — the parsed form of the
/// `COMMAND: ...\nEXPLANATION: ...` string that `callAI` in `main.ts` returned
/// as raw text for the renderer to pick apart.
struct CommandSuggestion {
    let command: String
    let explanation: String
}

/// One step of a multi-step task plan. Port of the `{cmd, explanation}` objects
/// in the JSON array `callAIPlan` in `main.ts` produced.
struct PlanStep {
    let cmd: String
    let explanation: String
}

/// The two AI entry points the app needs, matching `callAI` and `callAIPlan`.
///
/// Unlike the Electron side, failures surface as thrown errors rather than a
/// synthetic `echo "AI Error: ..."` command. `AIService.errorFallback` /
/// `errorFallbackPlan` reproduce that behaviour for call sites that still want
/// a well-formed response instead of an error path.
protocol AIProvider {
    func suggestCommand(request: String, cwd: String?) async throws -> CommandSuggestion
    func plan(goal: String, cwd: String) async throws -> [PlanStep]

    /// Free-form prose, for the assistant sidebar. Deliberately unstructured:
    /// unlike the two above there is no shape to enforce, and forcing a schema
    /// on an explanation only makes it worse.
    func answer(question: String, context: String) async throws -> String
}

/// Cleans prose replies from models that narrate their reasoning.
///
/// Reasoning models are a bad fit for this app but users will point it at them
/// anyway — qwen3 in particular emits its full chain of thought, and Ollama's
/// `think: false` does not reliably suppress it. Schema-constrained output is
/// the real defence (see `answer` on both providers); this handles the tagged
/// variants a schema cannot catch because the tags land *inside* the field.
enum ReplyCleaner {
    static func clean(_ text: String) -> String {
        var result = text

        // <think>…</think>, <thinking>…</thinking>, and an unclosed opener.
        for tag in ["think", "thinking", "reasoning"] {
            while let open = result.range(of: "<\(tag)>", options: .caseInsensitive) {
                if let close = result.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<result.endIndex) {
                    result.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    // Unclosed: everything after the opener is reasoning.
                    result.removeSubrange(open.lowerBound..<result.endIndex)
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppleIntelligenceAvailability {
    case available
    case unavailable(reason: String)
}

enum AIError: LocalizedError {
    case notConfigured(String)
    case unavailable(String)
    case badResponse(String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let detail): return detail
        case .unavailable(let detail): return detail
        case .badResponse(let detail): return detail
        case .http(let status, let message): return "API Error (\(status)): \(message)"
        }
    }
}

/// Provider dispatch — the Swift counterpart of the single `if/else` chain in
/// `callAIRaw` in `main.ts`.
enum AIService {
    static func provider(for settings: AppSettings) -> AIProvider? {
        switch settings.provider {
        case "apple":
            return AppleIntelligenceProvider(settings: settings)
        case "openai", "perplexity", "ollama":
            return OpenAICompatibleProvider(settings: settings)
        case "anthropic", "gemini":
            // TODO: port the `anthropic` and `gemini` branches of `callAIRaw`.
            // Both use a bespoke request/response shape, so they do not fit
            // OpenAICompatibleProvider and need providers of their own.
            return nil
        default:
            return nil
        }
    }

    static func appleAvailability() -> AppleIntelligenceAvailability {
        AppleIntelligenceProvider.availability()
    }

    // MARK: - Shared prompt context

    /// The OS/arch/shell block both system prompts in `main.ts` injected via
    /// `os.platform()` / `os.release()` / `os.arch()`.
    static var systemInfo: String {
        let info = ProcessInfo.processInfo.operatingSystemVersion
        let release = "\(info.majorVersion).\(info.minorVersion).\(info.patchVersion)"
        return "OS: darwin \(release) (\(machineArchitecture))\nShell: \(shell)"
    }

    static var shell: String { "zsh" }

    private static var machineArchitecture: String {
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return "arm64" }
        return withUnsafeBytes(of: &sysinfo.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: - Error fallbacks
    //
    // `callAI` / `callAIPlan` never propagated failures: they returned a
    // well-formed response whose command echoes the error, so the renderer had
    // no failure branch. Kept here for call sites that want that same shape.

    /// Matches the `[^a-zA-Z0-9 _.:-]` strip in `main.ts` — the message is
    /// interpolated into a shell string, so anything else must go.
    static func sanitize(_ message: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.:-")
        let cleaned = String(message.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "Unknown error" : cleaned
    }

    static func errorFallback(_ error: Error) -> CommandSuggestion {
        CommandSuggestion(
            command: "echo \"AI Error: \(sanitize(error.localizedDescription))\"",
            explanation: "AI service request failed"
        )
    }

    static func errorFallbackPlan(_ error: Error) -> [PlanStep] {
        [PlanStep(
            cmd: "echo \"AI Error: \(sanitize(error.localizedDescription))\"",
            explanation: "AI service request failed"
        )]
    }
}

/// The two system prompts from `main.ts`, verbatim in intent.
///
/// `AppleIntelligenceProvider` uses only the preamble portions: schema-constrained
/// generation makes the formatting rules (rules 1–4 of `callAI`, rules 1–3 of
/// `callAIPlan`) unnecessary, so those live in `strictFormat*` and are appended
/// only by providers that must parse free text.
extension AIPrompts {
    /// The sidebar assistant's brief. Kept terse on purpose — long, hedged
    /// answers are worse than short ones when the reader is mid-task at a
    /// prompt, and the small local and on-device models this app targets
    /// degrade badly when asked to be expansive.
    static func assistantPreamble() -> String {
        """
        You are a terminal assistant embedded in a macOS terminal, running on \(AIService.systemInfo).
        You are shown what the user ran and what it printed, and you comment on it or answer questions.

        RULES:
        1. Be brief. Two or three sentences unless asked for more.
        2. No markdown headers, no bullet lists, no code fences. Plain prose, with commands inline.
        3. If a command failed, say what went wrong and the single most likely fix.
        4. Never invent output the user did not show you.
        5. If the context is insufficient, say so in one sentence instead of guessing.
        """
    }

    /// Frames a finished command for an unprompted observation.
    static func insightPrompt(command: String, exitCode: Int32?, output: String) -> String {
        let status = exitCode.map { $0 == 0 ? "succeeded (exit 0)" : "failed (exit \($0))" } ?? "finished"
        // The opt-out is only offered for a command that worked. A small model
        // reaches for an escape hatch readily — offered one on a real failure,
        // qwen3:4b answered NOTHING for `ls` on a path that does not exist,
        // which is the single case the feature exists to cover.
        let failed = (exitCode ?? 0) != 0
        let closing = failed
            ? "In two sentences or fewer, give the likely cause and the single most likely fix. Answer directly; do not decline."
            : "In two sentences or fewer, tell the user the single most useful thing about this result. If nothing is worth saying, reply exactly: NOTHING."
        return """
        The user ran this command, which \(status):

        $ \(command)

        Output:
        \(output.isEmpty ? "(no output)" : output)

        \(closing)
        """
    }
}

enum AIPrompts {
    static func commandPreamble() -> String {
        """
        You are an expert terminal assistant running on \(AIService.systemInfo).
        Your goal is to convert natural language instructions into a SINGLE executable \(AIService.shell) command.

        CONTEXT: The user's prompt may include [Current Directory: /path/to/dir] - use this to generate contextually relevant commands with correct relative/absolute paths.

        CRITICAL RULES:
        - DO NOT provide multiple command options.
        - The explanation must be a single, short sentence of at most 10 words.
        - NEVER use generic placeholders like <path>, <file>, <ip-address>, <url>, etc.
        - If specific values are needed (paths, IPs, URLs, filenames), ask for them in a follow-up question inside the explanation instead of providing a generic command.
        - Use the current directory context when generating commands - prefer relative paths when appropriate.
        - Example: if the user says "connect to server" and no IP is given, the command is `echo "Please specify: What is the server IP address or hostname?"` and the explanation is "Need specific server address to connect".
        """
    }

    static func strictCommandFormat() -> String {
        """

        Return your response in this EXACT format, with no markdown and no backticks:
        COMMAND: <raw executable command>
        EXPLANATION: <concise explanation, MAX 10 WORDS>
        """
    }

    static func planPreamble() -> String {
        """
        You are an expert terminal assistant on \(AIService.systemInfo).
        The user wants to accomplish a multi-step task. Break it into an ordered list of concrete shell commands.

        CRITICAL RULES:
        - Each step has a raw \(AIService.shell) command and a short (max 10 words) description of what it does.
        - Use at most 10 steps.
        - NEVER use generic placeholders like <path> or <value>. If a value is unknown, use a realistic example or ask for it with a command like `echo 'Specify: ...'`.
        - Use the current directory context when generating paths.
        """
    }

    static func strictPlanFormat() -> String {
        """

        Return ONLY a JSON array. No prose, no markdown, no code fences. Each item must be an object with exactly two string fields, "cmd" and "explanation".
        Example valid response: [{"cmd":"mkdir my-project","explanation":"Create project directory"},{"cmd":"cd my-project","explanation":"Enter project directory"}]
        """
    }

    /// The renderer passed the cwd inline in the user prompt as
    /// `[Current Directory: ...]`; keep that so prompts stay comparable.
    static func commandUserPrompt(request: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return request }
        return "[Current Directory: \(cwd)]\n\(request)"
    }

    static func planUserPrompt(goal: String, cwd: String) -> String {
        "Current directory: \(cwd)\nTask: \(goal)"
    }

    static let maxPlanSteps = 10
}
