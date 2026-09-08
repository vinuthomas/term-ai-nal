import Foundation
import FoundationModels

// MARK: - Guided generation schemas
//
// These replace the parsing layer in `main.ts`. There, `callAI` demanded the
// exact text `COMMAND: ...\nEXPLANATION: ...` and the renderer split the string,
// while `callAIPlan` demanded a bare JSON array validated with `JSON.parse` —
// both of which broke whenever the model added a code fence or a stray
// sentence. A schema constrains decoding itself, so there is nothing left to
// parse and nothing left to validate.
//
// The `@Generable` macro would express this more tersely, but its macro plugin
// (`FoundationModelsMacros`) ships only with Xcode, not with the Command Line
// Tools this package builds against. `DynamicGenerationSchema` gives the same
// guarantee while staying buildable from the CLI — see MIGRATION.md.

enum AppleSchemas {
    /// Mirrors the two fields `callAI` asked for in prose.
    static func command() throws -> GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "ShellCommand",
            description: "A single executable shell command answering the user's request",
            properties: [
                .init(
                    name: "command",
                    description: "The raw executable shell command. No markdown, no backticks, no placeholders like <path>.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                .init(
                    name: "explanation",
                    description: "A concise explanation of the command, at most 10 words.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
            ]
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// The 10-step cap was prompt-only guidance in `callAIPlan`; here it is a
    /// schema constraint the decoder enforces.
    static func plan(maxSteps: Int) throws -> GenerationSchema {
        let step = DynamicGenerationSchema(
            name: "PlanStep",
            description: "One step of an ordered shell command plan",
            properties: [
                .init(
                    name: "cmd",
                    description: "The raw shell command for this step. No markdown, no placeholders like <path>.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                .init(
                    name: "explanation",
                    description: "What this step does, at most 10 words.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
            ]
        )
        let root = DynamicGenerationSchema(
            name: "Plan",
            description: "An ordered plan of shell commands accomplishing the user's task",
            properties: [
                .init(
                    name: "steps",
                    description: "The steps to run, in order.",
                    schema: DynamicGenerationSchema(
                        arrayOf: DynamicGenerationSchema(referenceTo: "PlanStep"),
                        minimumElements: 1,
                        maximumElements: maxSteps
                    )
                ),
            ]
        )
        return try GenerationSchema(root: root, dependencies: [step])
    }
}

/// On-device Apple Intelligence provider.
///
/// Replaces the `apple` branch of `callAIRaw` in `main.ts`, which shelled out to
/// the `fm` CLI and scraped stdout. This talks to the FoundationModels framework
/// directly, and uses guided generation so the response shape is guaranteed.
struct AppleIntelligenceProvider: AIProvider {
    let settings: AppSettings

    // MARK: - Availability

    static func availability() -> AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: describe(reason))
        @unknown default:
            return .unavailable(reason: "Apple Intelligence is unavailable for an unknown reason")
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
            schema: try AppleSchemas.command()
        )

        let command = try response.content
            .value(String.self, forProperty: "command")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw AIError.badResponse("Apple Intelligence returned an empty command")
        }
        let explanation = try response.content
            .value(String.self, forProperty: "explanation")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandSuggestion(command: command, explanation: explanation)
    }

    func plan(goal: String, cwd: String) async throws -> [PlanStep] {
        try requireAvailable()

        let session = LanguageModelSession(instructions: AIPrompts.planPreamble())
        let response = try await session.respond(
            to: AIPrompts.planUserPrompt(goal: goal, cwd: cwd),
            schema: try AppleSchemas.plan(maxSteps: AIPrompts.maxPlanSteps)
        )

        let rawSteps = try response.content.value([GeneratedContent].self, forProperty: "steps")
        let steps = try rawSteps
            .map { step in
                PlanStep(
                    cmd: try step.value(String.self, forProperty: "cmd")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    explanation: try step.value(String.self, forProperty: "explanation")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.cmd.isEmpty }

        guard !steps.isEmpty else {
            throw AIError.badResponse("Apple Intelligence returned an empty plan")
        }
        return steps
    }
}
