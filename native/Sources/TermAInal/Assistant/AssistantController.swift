import AppKit

/// Drives the assistant sidebar: subscribes to finished commands, decides
/// whether one is worth commenting on, and routes free-form questions.
///
/// This is the first consumer of `CommandLog`, and the reason OSC 133 parsing
/// exists. "Insights after execution, not in flight" needs a command *boundary*
/// with an exit status, which a flat output buffer cannot provide — knowing a
/// command finished, and whether it failed, is exactly what the semantic prompt
/// marks carry.
final class AssistantController: NSObject, AssistantSidebarDelegate {
    let sidebar = AssistantSidebarView()

    /// Supplied by the app so the controller never reaches into the pane tree.
    var activePaneId: (() -> String?)?

    /// One request at a time. An automatic insight is dropped rather than
    /// queued when something is already running: a burst of commands must not
    /// build a backlog of stale commentary.
    private var inFlight: Task<Void, Never>?

    override init() {
        super.init()
        sidebar.delegate = self
        CommandLog.shared.onCommandFinished = { [weak self] record in
            self?.commandFinished(record)
        }
    }

    // MARK: - Automatic insights

    private func commandFinished(_ record: CommandRecord) {
        let settings = SettingsStore.shared.settings
        guard settings.assistantEnabled else { return }

        switch settings.assistantInsights {
        case "all":
            break
        case "failures":
            // `succeeded` is `exitCode == 0`, so an unreported status also reads
            // as failure. CommandLog closes a record with a nil exit code when a
            // new prompt arrives without a `D` mark, and commenting on those
            // would be noise — require a *known* non-zero exit.
            guard let exitCode = record.exitCode, exitCode != 0 else { return }
        default:
            return
        }

        guard inFlight == nil else { return }
        requestInsight(for: record)
    }

    private func requestInsight(for record: CommandRecord) {
        guard let provider = AIService.provider(for: SettingsStore.shared.settings.insightProfile) else { return }

        let prompt = AIPrompts.insightPrompt(
            command: record.command,
            exitCode: record.exitCode,
            output: Self.truncateForContext(record.output)
        )

        inFlight = Task { @MainActor [weak self] in
            defer { self?.inFlight = nil }
            do {
                let reply = try await provider.answer(question: prompt, context: "")
                // The prompt offers NOTHING as an explicit opt-out so the model
                // can decline to comment rather than padding.
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.uppercased() != "NOTHING" else { return }
                self?.sidebar.appendInsight(
                    command: record.command,
                    body: trimmed,
                    succeeded: record.succeeded
                )
            } catch {
                // Automatic insights fail quietly: an unprompted request that
                // errors should not interrupt whatever the user is doing.
                NSLog("[Assistant] insight failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - AssistantSidebarDelegate

    func assistantSidebar(_ sidebar: AssistantSidebarView, didAsk question: String) {
        sidebar.appendQuestion(question)
        ask(question, context: recentContext())
    }

    func assistantSidebarDidRequestExplainLast(_ sidebar: AssistantSidebarView) {
        guard let paneId = activePaneId?(), let record = CommandLog.shared.lastRecord(paneId: paneId) else {
            sidebar.appendError("No completed command to explain yet.")
            return
        }
        sidebar.appendQuestion("Explain: \(record.command)")
        ask(
            AIPrompts.insightPrompt(
                command: record.command,
                exitCode: record.exitCode,
                output: Self.truncateForContext(record.output)
            ),
            context: ""
        )
    }

    // MARK: - Questions

    private func ask(_ question: String, context: String) {
        guard let provider = AIService.provider(for: SettingsStore.shared.settings.insightProfile) else {
            sidebar.appendError("No AI provider configured. Open Settings to pick one.")
            return
        }
        inFlight?.cancel()
        sidebar.setBusy(true)

        inFlight = Task { @MainActor [weak self] in
            defer {
                self?.inFlight = nil
                self?.sidebar.setBusy(false)
            }
            do {
                let reply = try await provider.answer(question: question, context: context)
                self?.sidebar.appendAnswer(reply.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self?.sidebar.appendError(error.localizedDescription)
            }
        }
    }

    /// The last few commands, so a question like "why did that fail?" has
    /// something to refer to without the user restating it.
    private func recentContext() -> String {
        guard let paneId = activePaneId?() else { return "" }
        let records = CommandLog.shared.records(paneId: paneId, limit: 3)
        guard !records.isEmpty else { return "" }

        let described = records.reversed().map { record -> String in
            let status = record.exitCode.map { "exit \($0)" } ?? "still running"
            return """
            $ \(record.command)   [\(status)]
            \(Self.truncateForContext(record.output, limit: 400))
            """
        }
        return "Recent terminal activity:\n\n" + described.joined(separator: "\n\n")
    }

    /// Reduces terminal output to something a language model can actually read.
    ///
    /// Two measured reasons this matters, both specific to the on-device model.
    /// Its context window is **4096** tokens, and glyph-heavy terminal output
    /// costs roughly one token per character — 1000 characters of a
    /// Powerlevel10k prompt measured at 888 tokens — so a few thousand
    /// characters of raw scrollback fills the window on its own. And because
    /// the framework has to identify a supported language in the prompt when
    /// the user's own locale is unsupported (`en_IN` is not in the supported
    /// set), a prompt dominated by paths and private-use glyphs can fail that
    /// identification outright and be rejected as an unsupported language.
    ///
    /// Stripping the decoration fixes both at once: fewer tokens, and what
    /// remains is recognisably English.
    static func truncateForContext(_ text: String, limit: Int = 1500) -> String {
        let cleaned = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(stripDecoration)
            .filter { !$0.isEmpty && !isMostlySymbols($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count > limit else { return cleaned }
        // Keep the tail: diagnostics and error messages land at the end.
        return "…(earlier output omitted)…\n" + String(cleaned.suffix(limit))
    }

    /// Drops private-use glyphs (Nerd Font icons), box drawing and block
    /// elements, and collapses the whitespace they leave behind.
    private static func stripDecoration(_ line: some StringProtocol) -> String {
        let kept = line.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0xE000...0xF8FF: return false       // private use area
            case 0xF0000...0xFFFFD, 0x100000...0x10FFFD: return false // supplementary PUA
            case 0x2500...0x259F: return false       // box drawing, block elements
            case 0x2800...0x28FF: return false       // braille (spinners)
            case 0x276C...0x2771: return false       // prompt chevrons
            default: return !scalar.properties.isDefaultIgnorableCodePoint
            }
        }
        return String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// A line that is mostly punctuation carries no meaning for the model and
    /// costs tokens — a bare `%`, a rule of dashes, a progress bar.
    private static func isMostlySymbols(_ line: String) -> Bool {
        let letters = line.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return letters * 2 < line.unicodeScalars.count
    }
}
