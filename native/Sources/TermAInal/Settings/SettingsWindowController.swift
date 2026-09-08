import AppKit

/// The preferences window. Port of `Settings.tsx`, which was a three-tab React
/// form (AI / Terminal / MCP) writing the whole settings object back at once.
///
/// The same edit-a-copy-then-save model is kept: controls mutate `draft`, and
/// nothing is persisted until Save, so Cancel is a genuine discard.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Called with the saved settings so the app can re-apply appearance and
    /// restart the MCP server if its configuration moved.
    var onSave: ((AppSettings) -> Void)?

    private var draft: AppSettings
    private var apiKey: String

    // AI tab
    private let providerPopup = NSPopUpButton()
    private let appleModelPopup = NSPopUpButton()
    private let apiKeyField = NSSecureTextField()
    private let modelCombo = NSComboBox()
    private let baseUrlField = NSTextField()
    private let refreshModelsButton = NSButton()
    private let availabilityLabel = NSTextField(wrappingLabelWithString: "")
    private let assistantEnabledCheckbox = NSButton()
    private let assistantInsightsPopup = NSPopUpButton()
    private var aiGrid: NSGridView!

    // Terminal tab
    private let fontCombo = NSComboBox()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let themePopup = NSPopUpButton()
    private let restoreSessionCheckbox = NSButton()

    // MCP tab
    private let mcpEnabledCheckbox = NSButton()
    private let mcpPortField = NSTextField()
    private let mcpBufferField = NSTextField()
    private let mcpFileBufferCheckbox = NSButton()
    private let featureListTerminals = NSButton()
    private let featureGetOutput = NSButton()
    private let featureGetActiveOutput = NSButton()
    private let featureSendInput = NSButton()
    private let mcpUrlLabel = NSTextField(labelWithString: "")

    /// Only the providers that actually work. Anthropic and Gemini are not
    /// ported yet, so listing them would offer a dead end.
    private static let supportedProviders: [(key: String, title: String)] = [
        ("apple", "Apple Intelligence (on-device)"),
        ("openai", "OpenAI"),
        ("perplexity", "Perplexity"),
        ("ollama", "Ollama (local)"),
    ]

    /// Supported providers, plus the stored one when it is not among them.
    ///
    /// Without the extra entry a config carrying `anthropic` or `gemini` — both
    /// unported, and both reachable via the one-time Electron import — would
    /// find no matching item, leave the popup on index 0, and get silently
    /// rewritten to Apple on Save.
    private var providers: [(key: String, title: String)] {
        var list = Self.supportedProviders
        if !list.contains(where: { $0.key == draft.provider }) {
            list.append((draft.provider, "\(draft.provider) (not ported)"))
        }
        return list
    }

    /// Sentinel for "no explicit family", kept distinct from an empty combo
    /// value: an editable NSComboBox does not reliably preserve an empty
    /// string, and letting it fall through to the first listed family meant
    /// opening Settings and saving silently replaced the automatic font.
    private static let automaticFont = "Automatic (best Unicode coverage)"

    /// Index-aligned with the Insights popup's items.
    private static let insightModes = ["off", "failures", "all"]

    init() {
        draft = SettingsStore.shared.settings
        apiKey = SettingsStore.shared.apiKey

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContentView()
        window.center()
        syncFromDraft()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Layout

    private func buildContentView() -> NSView {
        let tabView = NSTabView()
        tabView.addTabViewItem(tab("AI", buildAITab()))
        tabView.addTabViewItem(tab("Terminal", buildTerminalTab()))
        tabView.addTabViewItem(tab("MCP", buildMCPTab()))

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [tabView, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tabView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        return container
    }

    private func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = label
        item.view = view
        return item
    }

    /// Builds a two-column label/control form. NSGridView is used because rows
    /// can be hidden individually, which is how provider-specific fields
    /// appear and disappear.
    private func form(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    private func wrap(_ grid: NSGridView) -> NSView {
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])
        return container
    }

    private func buildAITab() -> NSView {
        for provider in providers {
            providerPopup.addItem(withTitle: provider.title)
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        appleModelPopup.addItem(withTitle: "On-device (local, no network)")
        appleModelPopup.addItem(withTitle: "Private Cloud Compute (macOS 27+)")

        modelCombo.isEditable = true
        modelCombo.completes = true

        refreshModelsButton.title = "Reload"
        refreshModelsButton.target = self
        refreshModelsButton.action = #selector(reloadOllamaModels)

        let modelRow = NSStackView(views: [modelCombo, refreshModelsButton])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8
        modelCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        baseUrlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        availabilityLabel.font = .systemFont(ofSize: 11)
        availabilityLabel.textColor = .secondaryLabelColor
        availabilityLabel.preferredMaxLayoutWidth = 340

        assistantEnabledCheckbox.setButtonType(.switch)
        assistantEnabledCheckbox.title = "Show the assistant sidebar"

        assistantInsightsPopup.addItem(withTitle: "Never")
        assistantInsightsPopup.addItem(withTitle: "After a command fails")
        assistantInsightsPopup.addItem(withTitle: "After every command")

        // Appended last on purpose: updateProviderVisibility() addresses grid
        // rows 1-5 by index, so new rows must go after them.
        aiGrid = form([
            ("Provider", providerPopup),
            ("Apple Model", appleModelPopup),
            ("Status", availabilityLabel),
            ("API Key", apiKeyField),
            ("Model", modelRow),
            ("Base URL", baseUrlField),
            ("Assistant", assistantEnabledCheckbox),
            ("Insights", assistantInsightsPopup),
        ])
        return wrap(aiGrid)
    }

    private func buildTerminalTab() -> NSView {
        // Only monospaced families, since a proportional font in a terminal
        // grid is never what anyone wants.
        fontCombo.isEditable = true
        fontCombo.addItem(withObjectValue: Self.automaticFont)
        for family in Self.monospacedFontFamilies() {
            fontCombo.addItem(withObjectValue: family)
        }
        fontCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        fontSizeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        fontSizeStepper.minValue = 8
        fontSizeStepper.maxValue = 32
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped)

        let sizeRow = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 4

        for theme in TerminalThemes.all {
            themePopup.addItem(withTitle: theme.displayName)
        }

        restoreSessionCheckbox.setButtonType(.switch)
        restoreSessionCheckbox.title = "Restore panes and directories on launch"

        let hint = NSTextField(labelWithString: "Leave the font blank for the system monospaced font.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        return wrap(form([
            ("Font", fontCombo),
            ("Size", sizeRow),
            ("Theme", themePopup),
            ("", restoreSessionCheckbox),
            ("", hint),
        ]))
    }

    private func buildMCPTab() -> NSView {
        mcpEnabledCheckbox.setButtonType(.switch)
        mcpEnabledCheckbox.title = "Enable MCP server"
        mcpEnabledCheckbox.target = self
        mcpEnabledCheckbox.action = #selector(mcpEnabledChanged)

        mcpPortField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        mcpBufferField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        mcpFileBufferCheckbox.setButtonType(.switch)
        mcpFileBufferCheckbox.title = "Spill overflow to a temp file (otherwise drop it)"

        for (button, title) in [
            (featureListTerminals, "list_terminals"),
            (featureGetOutput, "get_terminal_output"),
            (featureGetActiveOutput, "get_active_terminal_output"),
            (featureSendInput, "send_input_to_terminal"),
        ] {
            button.setButtonType(.switch)
            button.title = title
        }

        let features = NSStackView(views: [
            featureListTerminals, featureGetOutput, featureGetActiveOutput, featureSendInput,
        ])
        features.orientation = .vertical
        features.alignment = .leading
        features.spacing = 4

        mcpUrlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        mcpUrlLabel.textColor = .secondaryLabelColor

        let note = NSTextField(wrappingLabelWithString:
            "Changing the port or toggling the server restarts it on Save.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 340

        return wrap(form([
            ("", mcpEnabledCheckbox),
            ("Port", mcpPortField),
            ("Buffer (KB)", mcpBufferField),
            ("", mcpFileBufferCheckbox),
            ("Tools", features),
            ("Endpoint", mcpUrlLabel),
            ("", note),
        ]))
    }

    private static func monospacedFontFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
    }

    // MARK: - Draft <-> controls

    private func syncFromDraft() {
        if let index = providers.firstIndex(where: { $0.key == draft.provider }) {
            providerPopup.selectItem(at: index)
        }
        appleModelPopup.selectItem(at: draft.appleModel == "pcc" ? 1 : 0)
        apiKeyField.stringValue = apiKey
        modelCombo.stringValue = draft.model
        baseUrlField.stringValue = draft.baseUrl

        fontCombo.stringValue = draft.fontFamily.isEmpty ? Self.automaticFont : draft.fontFamily
        fontSizeField.stringValue = String(Int(draft.fontSize))
        fontSizeStepper.doubleValue = draft.fontSize
        if let index = TerminalThemes.all.firstIndex(where: { $0.key == draft.theme }) {
            themePopup.selectItem(at: index)
        }
        restoreSessionCheckbox.state = draft.restoreSession ? .on : .off

        mcpEnabledCheckbox.state = draft.mcpEnabled ? .on : .off
        mcpPortField.stringValue = String(draft.mcpPort)
        mcpBufferField.stringValue = String(draft.mcpBufferSizeKB)
        mcpFileBufferCheckbox.state = draft.mcpFileBufferEnabled ? .on : .off
        featureListTerminals.state = draft.mcpFeatures.listTerminals ? .on : .off
        featureGetOutput.state = draft.mcpFeatures.getTerminalOutput ? .on : .off
        featureGetActiveOutput.state = draft.mcpFeatures.getActiveTerminalOutput ? .on : .off
        featureSendInput.state = draft.mcpFeatures.sendInputToTerminal ? .on : .off

        assistantEnabledCheckbox.state = draft.assistantEnabled ? .on : .off
        assistantInsightsPopup.selectItem(at: Self.insightModes.firstIndex(of: draft.assistantInsights) ?? 1)

        updateProviderVisibility()
        updateMcpUrl()
        updateAvailability()
    }

    private func collectIntoDraft() {
        let candidates = providers
        let providerIndex = providerPopup.indexOfSelectedItem
        if candidates.indices.contains(providerIndex) {
            draft.provider = candidates[providerIndex].key
        }
        draft.appleModel = appleModelPopup.indexOfSelectedItem == 1 ? "pcc" : "on-device"
        draft.model = modelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.baseUrl = baseUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = apiKeyField.stringValue

        let chosenFont = fontCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unresolvable family is stored as automatic rather than kept as a
        // name that silently falls back on every launch.
        draft.fontFamily = (chosenFont == Self.automaticFont || NSFont(name: chosenFont, size: 12) == nil)
            ? ""
            : chosenFont
        draft.fontSize = Double(fontSizeField.stringValue).map { min(max($0, 8), 32) } ?? draft.fontSize
        let themeIndex = themePopup.indexOfSelectedItem
        if TerminalThemes.all.indices.contains(themeIndex) {
            draft.theme = TerminalThemes.all[themeIndex].key
        }
        draft.restoreSession = restoreSessionCheckbox.state == .on
        draft.assistantEnabled = assistantEnabledCheckbox.state == .on
        let insightIndex = assistantInsightsPopup.indexOfSelectedItem
        if Self.insightModes.indices.contains(insightIndex) {
            draft.assistantInsights = Self.insightModes[insightIndex]
        }

        draft.mcpEnabled = mcpEnabledCheckbox.state == .on
        // Reject a nonsense port rather than letting the listener fail silently.
        if let port = Int(mcpPortField.stringValue), (1024...65535).contains(port) {
            draft.mcpPort = port
        }
        if let kb = Int(mcpBufferField.stringValue), kb > 0 {
            draft.mcpBufferSizeKB = kb
        }
        draft.mcpFileBufferEnabled = mcpFileBufferCheckbox.state == .on
        draft.mcpFeatures = MCPFeatures(
            listTerminals: featureListTerminals.state == .on,
            getTerminalOutput: featureGetOutput.state == .on,
            getActiveTerminalOutput: featureGetActiveOutput.state == .on,
            sendInputToTerminal: featureSendInput.state == .on
        )
    }

    private func updateProviderVisibility() {
        let candidates = providers
        let provider = candidates[min(max(0, providerPopup.indexOfSelectedItem), candidates.count - 1)].key
        let isApple = provider == "apple"
        let isOllama = provider == "ollama"

        // Row order matches buildAITab().
        aiGrid.row(at: 1).isHidden = !isApple            // Apple Model
        aiGrid.row(at: 2).isHidden = !isApple            // Status
        aiGrid.row(at: 3).isHidden = isApple || isOllama // API Key
        aiGrid.row(at: 4).isHidden = isApple             // Model
        aiGrid.row(at: 5).isHidden = !(provider == "openai" || isOllama) // Base URL

        refreshModelsButton.isHidden = !isOllama
        if isOllama { reloadOllamaModels() }
    }

    private func updateAvailability() {
        switch AIService.appleAvailability() {
        case .available:
            availabilityLabel.stringValue = "Available on this Mac."
            availabilityLabel.textColor = .systemGreen
        case .unavailable(let reason):
            availabilityLabel.stringValue = reason
            availabilityLabel.textColor = .systemOrange
        }
    }

    private func updateMcpUrl() {
        let port = Int(mcpPortField.stringValue) ?? draft.mcpPort
        mcpUrlLabel.stringValue = mcpEnabledCheckbox.state == .on
            ? "http://127.0.0.1:\(port)/mcp"
            : "disabled"
    }

    // MARK: - Actions

    @objc private func providerChanged() {
        updateProviderVisibility()
        updateAvailability()
    }

    @objc private func mcpEnabledChanged() {
        updateMcpUrl()
    }

    @objc private func fontSizeStepped() {
        fontSizeField.stringValue = String(Int(fontSizeStepper.doubleValue))
    }

    @objc private func reloadOllamaModels() {
        let baseUrl = baseUrlField.stringValue
        let current = modelCombo.stringValue
        refreshModelsButton.isEnabled = false

        Task { @MainActor in
            let models = await OllamaModels.list(baseUrl: baseUrl)
            refreshModelsButton.isEnabled = true
            modelCombo.removeAllItems()
            modelCombo.addItems(withObjectValues: models)
            // Keep whatever the user typed; only the suggestion list changed.
            modelCombo.stringValue = current
            modelCombo.placeholderString = models.isEmpty
                ? "Ollama not reachable — start it to list models"
                : "llama3"
        }
    }

    @objc private func save() {
        collectIntoDraft()
        SettingsStore.shared.apiKey = apiKey
        SettingsStore.shared.save(draft)
        onSave?(draft)
        close()
    }

    @objc private func cancel() {
        close()
    }
}
