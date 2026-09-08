import AppKit
import Foundation

/// Headless check of the configured AI provider, run via `--check-ai`.
///
/// The Electron build could only be exercised through the renderer overlay;
/// this makes the provider layer verifiable without a window, which matters
/// because a misconfigured provider is otherwise indistinguishable from a bug.
enum AIDiagnostics {
    static func runAndExit() -> Never {
        SettingsStore.shared.load()
        let settings = SettingsStore.shared.settings

        print("settings   : \(SettingsStore.shared.settingsURL.path)")
        print("provider   : \(settings.provider)")
        print("model      : \(settings.model.isEmpty ? "(provider default)" : settings.model)")
        print("baseUrl    : \(settings.baseUrl.isEmpty ? "(provider default)" : settings.baseUrl)")

        switch AIService.appleAvailability() {
        case .available:
            print("apple      : available")
        case .unavailable(let reason):
            print("apple      : unavailable — \(reason)")
        }

        // Constructing the settings window here catches the cheap structural
        // mistakes (NSGridView row indices, missing controls) without needing
        // someone to open the menu.
        _ = NSApplication.shared
        let settingsController = SettingsWindowController()
        print("settings UI: constructs ok (\(settingsController.window?.contentView != nil ? "content view present" : "NO CONTENT VIEW"))")

        let resolved = TerminalPaneView.resolveFont(
            family: settings.fontFamily,
            size: CGFloat(settings.fontSize)
        )
        print("font       : \(resolved.fontName) @ \(Int(settings.fontSize))pt"
            + (settings.fontFamily.isEmpty ? " (auto)" : " (configured)"))

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            if settings.provider == "ollama" {
                let models = await OllamaModels.list(baseUrl: settings.baseUrl)
                print("ollama     : \(models.isEmpty ? "not reachable" : "\(models.count) model(s): \(models.joined(separator: ", "))")")
            }

            guard let provider = AIService.provider(for: settings) else {
                print("\nRESULT: no provider configured for '\(settings.provider)'")
                exitCode = 1
                semaphore.signal()
                return
            }

            do {
                print("\n-> suggestCommand")
                let suggestion = try await provider.suggestCommand(
                    request: "list files in the current directory sorted by size, largest first",
                    cwd: FileManager.default.currentDirectoryPath
                )
                print("   command    : \(suggestion.command)")
                print("   explanation: \(suggestion.explanation)")

                print("\n-> plan")
                let steps = try await provider.plan(
                    goal: "create a new git repository and make an initial empty commit",
                    cwd: FileManager.default.currentDirectoryPath
                )
                for (index, step) in steps.enumerated() {
                    print("   \(index + 1). \(step.cmd)  — \(step.explanation)")
                }
                print("\nRESULT: OK")
            } catch {
                print("\nRESULT: FAILED — \(error.localizedDescription)")
                exitCode = 1
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(exitCode)
    }
}
