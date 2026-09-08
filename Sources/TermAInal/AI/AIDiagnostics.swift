import AppKit
import Foundation

/// Headless check of both AI profiles, run via `--check-ai`.
///
/// The Electron build could only be exercised through the renderer overlay;
/// this makes the provider layer verifiable without a window, which matters
/// because a misconfigured provider is otherwise indistinguishable from a bug.
/// Both roles are exercised because they can point at different models, and a
/// working command profile says nothing about the assistant's.
enum AIDiagnostics {
    static func runAndExit() -> Never {
        SettingsStore.shared.load()
        let settings = SettingsStore.shared.settings

        print("settings   : \(SettingsStore.shared.settingsURL.path)")
        switch AIService.appleAvailability() {
        case .available(let caveat):
            print("apple      : available" + (caveat.map { " — caveat: \($0)" } ?? ""))
        case .unavailable(let reason):
            print("apple      : unavailable — \(reason)")
        }

        let resolved = TerminalPaneView.resolveFont(
            family: settings.fontFamily,
            size: CGFloat(settings.fontSize)
        )
        print("font       : \(resolved.fontName) @ \(Int(settings.fontSize))pt"
            + (settings.fontFamily.isEmpty ? " (auto)" : " (configured)"))

        // Constructing the settings window here catches the cheap structural
        // mistakes (missing controls, index arithmetic) without needing someone
        // to open the menu.
        _ = NSApplication.shared
        let settingsController = SettingsWindowController()
        print("settings UI: constructs ok (\(settingsController.window?.contentView != nil ? "content view present" : "NO CONTENT VIEW"))")

        let semaphore = DispatchSemaphore(value: 0)
        var failures = 0

        Task {
            defer { semaphore.signal() }
            failures += await check(role: "commands", profile: settings.commandProfile) { provider in
                let suggestion = try await provider.suggestCommand(
                    request: "list files in the current directory sorted by size, largest first",
                    cwd: FileManager.default.currentDirectoryPath
                )
                print("   command    : \(suggestion.command)")
                print("   explanation: \(suggestion.explanation)")

                let steps = try await provider.plan(
                    goal: "create a new git repository and make an initial empty commit",
                    cwd: FileManager.default.currentDirectoryPath
                )
                for (index, step) in steps.enumerated() {
                    print("   \(index + 1). \(step.cmd)  — \(step.explanation)")
                }
            }

            failures += await check(role: "assistant", profile: settings.insightProfile) { provider in
                let reply = try await provider.answer(
                    question: AIPrompts.insightPrompt(
                        command: "ls /definitely-not-here-xyz",
                        exitCode: 1,
                        output: "ls: /definitely-not-here-xyz: No such file or directory"
                    ),
                    context: ""
                )
                print("   insight    : \(reply)")
            }
        }

        semaphore.wait()
        print("\nRESULT: \(failures == 0 ? "OK" : "\(failures) profile(s) failed")")
        exit(failures == 0 ? 0 : 1)
    }

    /// Returns 1 when the role could not be exercised, so the caller can sum.
    private static func check(
        role: String,
        profile: AIProfile,
        body: (AIProvider) async throws -> Void
    ) async -> Int {
        let model = profile.model.isEmpty ? "(provider default)" : profile.model
        print("\n-> \(role): \(profile.provider) / \(model)")

        if profile.provider == "ollama" {
            let models = await OllamaModels.list(baseUrl: profile.baseUrl)
            print("   ollama     : \(models.isEmpty ? "not reachable" : "\(models.count) model(s)")")
        }

        guard let provider = AIService.provider(for: profile) else {
            print("   FAILED     : no provider configured for '\(profile.provider)'")
            return 1
        }
        do {
            try await body(provider)
            return 0
        } catch {
            print("   FAILED     : \(error.localizedDescription)")
            return 1
        }
    }
}
