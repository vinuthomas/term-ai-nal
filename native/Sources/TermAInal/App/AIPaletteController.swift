import AppKit

/// The AI command-review sheet. Port of the command palette + review overlay and
/// the task-planner overlay in `App.tsx`.
///
/// The one invariant carried over verbatim: a generated command is *never*
/// executed on the user's behalf. Generation fills in the review area; only the
/// explicit Execute button hands anything to the shell.
final class AIPaletteController: NSObject {
    enum Mode {
        case command
        case plan
    }

    private let mode: Mode
    private let cwd: String?
    private let onExecute: (String) -> Void

    private var panel: NSPanel!
    private var parentWindow: NSWindow?

    private let input = NSTextField()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultView = NSTextView()
    private let explanationLabel = NSTextField(labelWithString: "")
    private let executeButton = NSButton()

    /// Commands currently staged for execution; a plan may hold several.
    private var stagedCommands: [String] = []

    init(mode: Mode, cwd: String?, onExecute: @escaping (String) -> Void) {
        self.mode = mode
        self.cwd = cwd
        self.onExecute = onExecute
        super.init()
    }

    // MARK: - Presentation

    func present(in parent: NSWindow) {
        parentWindow = parent
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = mode == .command ? "AI Command Palette" : "AI Task Planner"
        panel.contentView = buildContentView()
        parent.beginSheet(panel, completionHandler: nil)
        panel.makeFirstResponder(input)
    }

    private func dismiss() {
        guard let panel else { return }
        parentWindow?.endSheet(panel)
    }

    private func buildContentView() -> NSView {
        let container = NSView()

        input.placeholderString = mode == .command
            ? "Describe the command you want…"
            : "Describe the task to break into steps…"
        input.font = .systemFont(ofSize: 13)
        input.target = self
        input.action = #selector(generate)

        let generateButton = NSButton(title: "Generate", target: self, action: #selector(generate))
        generateButton.keyEquivalent = "\r"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        resultView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        resultView.isEditable = false
        resultView.drawsBackground = true
        resultView.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView()
        scroll.documentView = resultView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        explanationLabel.font = .systemFont(ofSize: 12)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.maximumNumberOfLines = 3

        executeButton.title = "Execute"
        executeButton.target = self
        executeButton.action = #selector(execute)
        executeButton.isEnabled = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))

        let inputRow = NSStackView(views: [input, generateButton, spinner])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [cancelButton, executeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [inputRow, statusLabel, scroll, explanationLabel, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            explanationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
        ])
        return container
    }

    // MARK: - Actions

    @objc private func generate() {
        let request = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }

        guard let provider = AIService.provider(for: SettingsStore.shared.settings.commandProfile) else {
            showError("No AI provider configured. Set `provider` in settings.json.")
            return
        }

        setLoading(true)
        stagedCommands = []
        executeButton.isEnabled = false

        Task { @MainActor in
            defer { setLoading(false) }
            do {
                switch mode {
                case .command:
                    let suggestion = try await provider.suggestCommand(request: request, cwd: cwd)
                    stagedCommands = [suggestion.command]
                    resultView.string = suggestion.command
                    explanationLabel.stringValue = suggestion.explanation
                case .plan:
                    let steps = try await provider.plan(goal: request, cwd: cwd ?? FileManager.default.currentDirectoryPath)
                    stagedCommands = steps.map(\.cmd)
                    resultView.string = steps.enumerated()
                        .map { "\($0.offset + 1). \($0.element.cmd)" }
                        .joined(separator: "\n")
                    explanationLabel.stringValue = steps.enumerated()
                        .map { "\($0.offset + 1). \($0.element.explanation)" }
                        .joined(separator: "  ·  ")
                }
                executeButton.isEnabled = !stagedCommands.isEmpty
                executeButton.title = stagedCommands.count > 1
                    ? "Execute \(stagedCommands.count) Steps"
                    : "Execute"
                statusLabel.stringValue = "Review before running. Nothing has been executed."
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    @objc private func execute() {
        // Steps are sent in order; the shell serialises them at its own prompt.
        for command in stagedCommands {
            onExecute(command)
        }
        dismiss()
    }

    @objc private func cancel() {
        dismiss()
    }

    private func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Generating…"
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func showError(_ message: String) {
        resultView.string = ""
        explanationLabel.stringValue = ""
        statusLabel.stringValue = "Error: \(message)"
        executeButton.isEnabled = false
    }
}
