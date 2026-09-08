import Foundation
import FoundationModels

/// Reports how the on-device model sees this app's locale.
///
/// `Locale.current` is resolved from the user's preferred languages
/// *intersected with the app's own localizations*, so a bundle that declares
/// none can end up with a different locale than a bare CLI binary on the same
/// machine — which is exactly the kind of difference that makes a model call
/// fail only inside the app.
enum LocaleDiagnostics {
    static func describe(_ error: Error) -> String {
        let text = "\(error)"
        for kind in ["unsupportedLanguageOrLocale", "exceededContextWindowSize",
                     "guardrailViolation", "assetsUnavailable", "rateLimited", "refusal"] {
            if text.contains(kind) { return kind }
        }
        return String(text.prefix(90))
    }

    static func runAndExit() -> Never {
        SettingsStore.shared.load()
        let model = SystemLanguageModel.default
        print("Locale.current          : \(Locale.current.identifier)")
        print("Locale.Language         : \(Locale.current.language.minimalIdentifier)")
        print("preferredLanguages      : \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))")
        print("bundle localizations    : \(Bundle.main.localizations)")
        print("bundle preferred        : \(Bundle.main.preferredLocalizations)")
        print("developmentLocalization : \(Bundle.main.developmentLocalization ?? "none")")
        print("supportsLocale(current) : \(model.supportsLocale())")
        print("supportsLocale(en_US)   : \(model.supportsLocale(Locale(identifier: "en_US")))")
        print("supported languages     : \(model.supportedLanguages.map { $0.minimalIdentifier }.sorted().joined(separator: " "))")

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            let session = LanguageModelSession(instructions: AIPrompts.assistantPreamble())
            do {
                let reply = try await session.respond(to: "how can I list only directories?")
                print("\nplain respond           : OK -> \(reply.content.prefix(60))")
            } catch {
                print("\nplain respond           : FAILED -> \(Self.describe(error))")
            }

            // The real shipped path, which is schema-constrained.
            // Force Apple regardless of what the settings currently say.
            guard let provider = AIService.provider(for: AIProfile(provider: "apple")) else {
                print("no insight provider configured")
                return
            }
            for (label, context) in [
                ("answer, no context", ""),
                ("answer, clean ctx", "Recent terminal activity:\n\n$ ls   [exit 0]\nApplications  code  Documents"),
                ("answer, glyph ctx", "Recent terminal activity:\n\n$ ls   [exit 0]\n\u{f179} \u{f015}  ~ \u{276f} ls\nApplications  code\n%    \u{f179}"),
            ] {
                do {
                    let reply = try await provider.answer(question: "how can I list only directories?", context: context)
                    print("\(label.padding(toLength: 24, withPad: " ", startingAt: 0)): OK -> \(reply.prefix(50))")
                } catch {
                    print("\(label.padding(toLength: 24, withPad: " ", startingAt: 0)): FAILED -> \(Self.describe(error))")
                }
            }

            // How many tokens does a realistic context actually cost? Token
            // counting is 26.4+, so this is informational where available.
            if #available(macOS 26.4, *) {
                // A realistic slice of this machine's scrollback.
                let line = "\u{f179} \u{f015}  ~/code/term-ai-nal \u{276f} ls -la\n"
                    + "total 128\n"
                    + "drwxr-xr-x  14 vinu.thomas  staff   448 Sep  8 11:04 .\n"
                    + "%\u{2500}\u{2500}\u{2500}\u{2500}\u{2588}\u{2588}\n"
                let raw = String(repeating: line, count: 12)
                let cleaned = AssistantController.truncateForContext(raw)
                let probe = SystemLanguageModel()
                let before = (try? await probe.tokenCount(for: raw)) ?? -1
                let after = (try? await probe.tokenCount(for: cleaned)) ?? -1
                print("\ncontext window          : \(probe.contextSize) tokens")
                print("raw scrollback          : \(raw.count) chars -> \(before) tokens")
                print("after sanitising        : \(cleaned.count) chars -> \(after) tokens")
                if before > 0, after > 0 {
                    print("reduction               : \(Int((1 - Double(after) / Double(before)) * 100))% fewer tokens")
                }
            }
        }
        semaphore.wait()
        exit(0)
    }
}
