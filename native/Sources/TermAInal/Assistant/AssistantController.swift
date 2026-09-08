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
    var onCollapseRequested: (() -> Void)?

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

    func assistantSidebarDidRequestCollapse(_ sidebar: AssistantSidebarView) {
        onCollapseRequested?()
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
            \(Self.truncateForContext(record.output, limit: 1500))
            """
        }
        return "Recent terminal activity:\n\n" + described.joined(separator: "\n\n")
    }

    /// Keeps the tail rather than the head: diagnostics and error messages land
    /// at the end of output, and the on-device model's context is small.
    static func truncateForContext(_ text: String, limit: Int = 4000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…(truncated)…\n" + String(trimmed.suffix(limit))
    }
}
