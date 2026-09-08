import Foundation
import FoundationModels

// MARK: - Generated shapes
//
// These replace the parsing layer in `main.ts`. There, `callAI` demanded the
// exact text `COMMAND: ...\nEXPLANATION: ...` and the renderer split the string,
// while `callAIPlan` demanded a bare JSON array validated with `JSON.parse` —
// both of which broke whenever the model added a code fence or a stray
// sentence. Guided generation constrains decoding itself, so there is nothing
// left to parse and nothing left to validate.

@Generable(description: "A single executable shell command answering the user's request")
struct GeneratedCommand {
    @Guide(description: "The raw executable shell command. No markdown, no backticks, no placeholders like <path>.")
    var command: String

    @Guide(description: "A concise explanation of the command, at most 10 words.")
    var explanation: String
}

@Generable(description: "One step of an ordered shell command plan")
struct GeneratedPlanStep {
    @Guide(description: "The raw shell command for this step. No markdown, no placeholders like <path>.")
    var cmd: String

    @Guide(description: "What this step does, at most 10 words.")
    var explanation: String
}

@Generable(description: "A brief prose answer for a terminal user")
struct GeneratedAnswer {
    @Guide(description: "The answer, at most three sentences. Plain prose, no markdown, no reasoning narration.")
    var answer: String
}

@Generable(description: "An ordered plan of shell commands accomplishing the user's task")
struct GeneratedPlan {
    /// The step cap was prompt-only guidance in `callAIPlan`; as a guide it is
    /// enforced by the decoder instead.
    @Guide(description: "The steps to run, in order.", .count(1...AIPrompts.maxPlanSteps))
    var steps: [GeneratedPlanStep]
}

/// On-device Apple Intelligence provider.
///
/// Replaces the `apple` branch of `callAIRaw` in `main.ts`, which shelled out to
/// the `fm` CLI and scraped stdout. This talks to the FoundationModels framework
/// directly, and uses guided generation so the response shape is guaranteed.
struct AppleIntelligenceProvider: AIProvider {
    let settings: AIProfile

    // MARK: - Availability

    static func availability() -> AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            let model = SystemLanguageModel.default
            guard model.supportsLocale() else {
                let supported = model.supportedLanguages
                    .map(\.minimalIdentifier).sorted().prefix(6).joined(separator: ", ")
                return .available(caveat: "Your region (\(Locale.current.identifier)) is not in Apple Intelligence's supported set (\(supported), …). Plainly worded questions work; anything it cannot identify a language in is rejected.")
            }
            return .available(caveat: nil)
        case .unavailable(let reason):
            return .unavailable(reason: describe(reason))
        @unknown default:
            return .unavailable(reason: "Apple Intelligence is unavailable for an unknown reason")
        }
    }

    /// Turns a generation failure into advice.
    ///
    /// The framework's own text for these is not actionable — an
    /// `unsupportedLanguageOrLocale` surfaces as "An unsupported language or
    /// locale was used", which tells the user nothing about their region being
    /// outside Apple Intelligence's supported set or what to do instead.
    static func advice(for error: Error) -> String {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return error.localizedDescription
        }
        switch generation {
        case .unsupportedLanguageOrLocale:
            let current = Locale.current.identifier
            let supported = SystemLanguageModel.default.supportsLocale()
            return supported
                ? "Apple Intelligence could not identify a supported language in that request. Try rephrasing it."
                : "Apple Intelligence does not support your region (\(current)). It can still answer plainly worded questions, but not reliably. Switch the Assistant profile to another provider in Settings, or set your Mac's language to a supported one."
        case .exceededContextWindowSize:
            return "That request was too long for the on-device model's \(SystemLanguageModel().contextSize)-token window. Ask about less at once."
        case .guardrailViolation:
            return "Apple Intelligence declined that request."
        case .assetsUnavailable:
            return "The Apple Intelligence model is not downloaded yet."
        case .rateLimited:
            return "Apple Intelligence is rate limiting requests. Try again shortly."
        case .refusal:
            return "Apple Intelligence declined to answer that."
        default:
            return generation.localizedDescription
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off in System Settings"
        case .modelNotReady:
            return "The Apple Intelligence model is still downloading"
        @unknown default:
            return "Apple Intelligence is unavailable for an unknown reason"
        }
    }

    /// Throws rather than returning, so both entry points can bail with one line.
    private func requireAvailable() throws {
        if case .unavailable(let reason) = Self.availability() {
            throw AIError.unavailable(reason)
        }
        // TODO: `settings.appleModel == "pcc"` (Private Cloud Compute) requires
        // macOS 27; the macOS 26.5 SDK exposes no way to request it, so the
        // setting is accepted and silently served on-device. Do not fake a
        // PCC-only capability here — wire it up when the API lands.
    }

    // MARK: - AIProvider

    func suggestCommand(request: String, cwd: String?) async throws -> CommandSuggestion {
        try requireAvailable()

        // Only the preamble: the format rules of `callAI` are enforced by the schema.
        let session = LanguageModelSession(instructions: AIPrompts.commandPreamble())
        let response = try await session.respond(
            to: AIPrompts.commandUserPrompt(request: request, cwd: cwd),
            generating: GeneratedCommand.self
        )

        let generated = response.content
        let command = generated.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw AIError.badResponse("Apple Intelligence returned an empty command")
        }
        return CommandSuggestion(
            command: command,
            explanation: generated.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func answer(question: String, context: String) async throws -> String {
        try requireAvailable()
        let session = LanguageModelSession(instructions: AIPrompts.assistantPreamble())
        do {
            // Schema-constrained like the other two entry points: it keeps the
            // reply to the field and leaves no room for narration around it.
            let response = try await session.respond(
                to: context.isEmpty ? question : "\(context)\n\n\(question)",
                generating: GeneratedAnswer.self
            )
            return ReplyCleaner.clean(response.content.answer)
        } catch {
            throw AIError.unavailable(Self.advice(for: error))
        }
    }

    func plan(goal: String, cwd: String) async throws -> [PlanStep] {
        try requireAvailable()

        let session = LanguageModelSession(instructions: AIPrompts.planPreamble())
        let response = try await session.respond(
            to: AIPrompts.planUserPrompt(goal: goal, cwd: cwd),
            generating: GeneratedPlan.self
        )

        let steps = response.content.steps
            .map {
                PlanStep(
                    cmd: $0.cmd.trimmingCharacters(in: .whitespacesAndNewlines),
                    explanation: $0.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.cmd.isEmpty }

        guard !steps.isEmpty else {
            throw AIError.badResponse("Apple Intelligence returned an empty plan")
        }
        return steps
    }
}
