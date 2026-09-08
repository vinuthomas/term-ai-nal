import AppKit

/// Draft store for keychain API keys, shared by every profile editor.
///
/// Keys are per *provider*, not per profile: if both profiles point at OpenAI
/// there is one key, and editing it in either place has to mean the same thing.
/// Nothing reaches the keychain until `commit()`, so Cancel stays a real
/// discard, and only providers the user actually touched are rewritten.
private final class APIKeyDrafts {
    private var values: [String: String] = [:]
    private var dirty: Set<String> = []

    func key(for provider: String) -> String {
        if let cached = values[provider] { return cached }
        let stored = SettingsStore.shared.apiKey(for: provider)
        values[provider] = stored
        return stored
    }

    func set(_ key: String, for provider: String) {
        guard key != self.key(for: provider) else { return }
        values[provider] = key
        dirty.insert(provider)
    }

    func commit() {
        for provider in dirty {
            SettingsStore.shared.setApiKey(values[provider] ?? "", for: provider)
        }
        dirty.removeAll()
    }
}

/// The control set for one `AIProfile`, built once and instantiated per role.
///
/// Every popup here selects by *key* and reads back the selected item's
/// `representedObject`, never an index into a parallel array. That closes a
/// whole bug class: a stored value with no matching item used to leave the
/// popup on index 0, and Save then persisted that as the user's choice.
/// `selectByKey` guarantees a matching item exists by appending one, so the
/// value the user never touched is the value that comes back out.
private final class AIProfileEditor: NSView {
    /// Only the providers that actually work. Anthropic and Gemini are not
    /// ported yet, so listing them would offer a dead end.
    private static let supportedProviders: [(key: String, title: String)] = [
        ("apple", "Apple Intelligence (on-device)"),
        ("anthropic", "Anthropic (Claude)"),
        ("openai", "OpenAI"),
        ("gemini", "Google Gemini"),
        ("perplexity", "Perplexity"),
        ("ollama", "Ollama (local)"),
    ]

    private static let appleModels: [(key: String, title: String)] = [
        ("on-device", "On-device (local, no network)"),
        ("pcc", "Private Cloud Compute (macOS 27+)"),
    ]

    private let keys: APIKeyDrafts

    private let providerPopup = NSPopUpButton()
    private let appleModelPopup = NSPopUpButton()
    private let apiKeyField = NSSecureTextField()
    private let modelCombo = NSComboBox()
    private let baseUrlField = NSTextField()
    private let refreshModelsButton = NSButton()
    private let availabilityLabel = NSTextField(wrappingLabelWithString: "")

    // Held rather than looked up by number: rows are captured as addRow(with:)
    // returns them, so visibility never depends on the row order staying put.
    private var appleModelRow: NSGridRow!
    private var statusRow: NSGridRow!
    private var apiKeyRow: NSGridRow!
    private var modelRow: NSGridRow!
    private var baseUrlRow: NSGridRow!

    /// Which provider's key the field currently shows, so a pending edit can be
    /// filed under the right provider when the popup moves.
    private var shownKeyProvider = ""

    init(title: String, hint: String, keys: APIKeyDrafts) {
        self.keys = keys
        super.init(frame: .zero)
        build(title: title, hint: hint)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Layout

    private func build(title: String, hint: String) {
        for provider in Self.supportedProviders {
            addItem(to: providerPopup, key: provider.key, title: provider.title)
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        for model in Self.appleModels {
            addItem(to: appleModelPopup, key: model.key, title: model.title)
        }

        modelCombo.isEditable = true
        modelCombo.completes = true
        modelCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        refreshModelsButton.title = "Reload"
        refreshModelsButton.bezelStyle = .rounded
        refreshModelsButton.target = self
        refreshModelsButton.action = #selector(reloadOllamaModels)

        let modelStack = NSStackView(views: [modelCombo, refreshModelsButton])
        modelStack.orientation = .horizontal
        modelStack.spacing = 8

        baseUrlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        availabilityLabel.font = .systemFont(ofSize: 11)
        availabilityLabel.textColor = .secondaryLabelColor
        availabilityLabel.preferredMaxLayoutWidth = 320

        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)

        let hintLabel = NSTextField(wrappingLabelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 480

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        appleModelRow = addRow(to: grid, "Apple Model", appleModelPopup)
        statusRow = addRow(to: grid, "Status", availabilityLabel)
        apiKeyRow = addRow(to: grid, "API Key", apiKeyField)
        modelRow = addRow(to: grid, "Model", modelStack)
        baseUrlRow = addRow(to: grid, "Base URL", baseUrlField)
        // Provider drives the rest, so it sits above them.
        _ = grid.insertRow(at: 0, with: [NSTextField(labelWithString: "Provider"), providerPopup])

        let stack = NSStackView(views: [heading, hintLabel, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func addRow(to grid: NSGridView, _ label: String, _ control: NSView) -> NSGridRow {
        grid.addRow(with: [NSTextField(labelWithString: label), control])
    }

    // MARK: - Key-addressed popups

    private func addItem(to popup: NSPopUpButton, key: String, title: String) {
        popup.addItem(withTitle: title)
        popup.lastItem?.representedObject = key
    }

    /// Selects `key`, adding an item for it when nothing matches — an unknown
    /// stored value must survive a round trip, not collapse onto index 0.
    private func selectByKey(_ popup: NSPopUpButton, _ key: String, unsupportedTitle: (String) -> String) {
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == key }) {
            popup.select(item)
            return
        }
        addItem(to: popup, key: key, title: unsupportedTitle(key))
        popup.selectItem(at: popup.numberOfItems - 1)
    }

    private func selectedKey(_ popup: NSPopUpButton) -> String {
        popup.selectedItem?.representedObject as? String ?? ""
    }

    private var provider: String { selectedKey(providerPopup) }

    // MARK: - Draft <-> controls

    func load(_ profile: AIProfile) {
        // Anthropic and Gemini are unported yet reachable via the one-time
        // Electron import, so they arrive here as stored-but-unlisted values.
        selectByKey(providerPopup, profile.provider) { "\($0) (not ported)" }
        selectByKey(appleModelPopup, profile.appleModel) { "\($0) (unknown)" }
        modelCombo.stringValue = profile.model
        baseUrlField.stringValue = profile.baseUrl
        showKey(for: provider)
        updateVisibility()
        updateAvailability()
    }

    func commit() -> AIProfile {
        keys.set(apiKeyField.stringValue, for: shownKeyProvider)
        return AIProfile(
            provider: provider,
            model: modelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            baseUrl: baseUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            appleModel: selectedKey(appleModelPopup)
        )
    }

    private func showKey(for provider: String) {
        shownKeyProvider = provider
        apiKeyField.stringValue = keys.key(for: provider)
    }

    private func updateVisibility() {
        let isApple = provider == "apple"
        let isOllama = provider == "ollama"

        appleModelRow.isHidden = !isApple
        statusRow.isHidden = !isApple
        apiKeyRow.isHidden = isApple || isOllama
        modelRow.isHidden = isApple
        // Every provider whose endpoint can be overridden — for a proxy or a
        // gateway. Perplexity is absent because its provider hardcodes the URL,
        // and Apple has no endpoint at all.
        baseUrlRow.isHidden = !["openai", "ollama", "anthropic", "gemini"].contains(provider)

        refreshModelsButton.isHidden = !isOllama
        if isOllama { reloadOllamaModels() }
    }

    private func updateAvailability() {
        switch AIService.appleAvailability() {
        case .available(let caveat):
            availabilityLabel.stringValue = caveat ?? "Available on this Mac."
            availabilityLabel.textColor = caveat == nil ? .systemGreen : .systemOrange
        case .unavailable(let reason):
            availabilityLabel.stringValue = reason
            availabilityLabel.textColor = .systemOrange
        }
    }

    // MARK: - Actions

    @objc private func providerChanged() {
        // File the visible key under the provider it was typed for before the
        // field is repointed, otherwise switching providers discards the edit.
        keys.set(apiKeyField.stringValue, for: shownKeyProvider)
        showKey(for: provider)
        updateVisibility()
        updateAvailability()
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
}

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
    private let apiKeys = APIKeyDrafts()

    // AI tab
    private let profileSwitcher = NSSegmentedControl(
        labels: ["Commands", "Assistant"], trackingMode: .selectOne, target: nil, action: nil
    )
    private var commandEditor: AIProfileEditor!
    private var insightEditor: AIProfileEditor!
    private let assistantEnabledCheckbox = NSButton()
    private let assistantInsightsPopup = NSPopUpButton()

    // Terminal tab
    private let fontCombo = NSComboBox()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let themePopup = NSPopUpButton()
    private let restoreSessionCheckbox = NSButton()
    private let newPanePopup = NSPopUpButton()
    private let newPaneCustomField = NSTextField()
    private let newPaneChooseButton = NSButton()
    private var terminalGrid: NSGridView!

    // MCP tab
    private let mcpEnabledCheckbox = NSButton()
    private let mcpPortField = NSTextField()
    private let mcpBufferField = NSTextField()
    private let mcpFileBufferCheckbox = NSButton()
    private let featureListTerminals = NSButton()
    private let featureGetOutput = NSButton()
    private let featureGetActiveOutput = NSButton()
    private let featureSendInput = NSButton()
    private let featureOpenTerminal = NSButton()
    private let mcpUrlLabel = NSTextField(labelWithString: "")

    /// Sentinel for "no explicit family", kept distinct from an empty combo
    /// value: an editable NSComboBox does not reliably preserve an empty
    /// string, and letting it fall through to the first listed family meant
    /// opening Settings and saving silently replaced the automatic font.
    private static let automaticFont = "Automatic (best Unicode coverage)"

    /// Index-aligned with the Insights popup's items.
    private static let insightModes = ["off", "failures", "all"]

    /// Index-aligned with the "New tab or split opens in" popup.
    private static let newPaneModes = ["inherit", "home", "custom"]

    init() {
        draft = SettingsStore.shared.settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
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

    private func wrap(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])
        return container
    }

    /// The two profiles get one editor each, shown one at a time — stacking both
    /// control sets would not fit, and the choice is rarely made twice at once.
    private func buildAITab() -> NSView {
        commandEditor = AIProfileEditor(
            title: "Commands",
            hint: "Used by the command palette. Pick the model whose shell syntax you trust most — a wrong flag is worse than a slow answer.",
            keys: apiKeys
        )
        insightEditor = AIProfileEditor(
            title: "Assistant",
            hint: "Used by the sidebar's insights and questions. Apple's on-device model suits this well: free, no memory cost, and good at explaining — even though it is weaker at writing commands.",
            keys: apiKeys
        )

        profileSwitcher.target = self
        profileSwitcher.action = #selector(profileSwitched)
        profileSwitcher.selectedSegment = 0

        assistantEnabledCheckbox.setButtonType(.switch)
        assistantEnabledCheckbox.title = "Show the assistant sidebar"

        assistantInsightsPopup.addItem(withTitle: "Never")
        assistantInsightsPopup.addItem(withTitle: "After a command fails")
        assistantInsightsPopup.addItem(withTitle: "After every command")

        let editors = NSView()
        for editor in [commandEditor!, insightEditor!] {
            editor.translatesAutoresizingMaskIntoConstraints = false
            editors.addSubview(editor)
            NSLayoutConstraint.activate([
                editor.leadingAnchor.constraint(equalTo: editors.leadingAnchor),
                editor.trailingAnchor.constraint(lessThanOrEqualTo: editors.trailingAnchor),
                editor.topAnchor.constraint(equalTo: editors.topAnchor),
                editor.bottomAnchor.constraint(lessThanOrEqualTo: editors.bottomAnchor),
            ])
        }

        let separator = NSBox()
        separator.boxType = .separator

        let sidebarForm = form([
            ("Sidebar", assistantEnabledCheckbox),
            ("Insights", assistantInsightsPopup),
        ])

        let stack = NSStackView(views: [profileSwitcher, editors, separator, sidebarForm])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return wrap(stack)
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

        newPanePopup.addItem(withTitle: "The current tab's folder")
        newPanePopup.addItem(withTitle: "Home folder")
        newPanePopup.addItem(withTitle: "A specific folder…")
        newPanePopup.target = self
        newPanePopup.action = #selector(newPaneModeChanged)

        newPaneCustomField.placeholderString = "~/code"
        newPaneCustomField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        newPaneChooseButton.title = "Choose…"
        newPaneChooseButton.target = self
        newPaneChooseButton.action = #selector(chooseNewPaneDirectory)
        let customRow = NSStackView(views: [newPaneCustomField, newPaneChooseButton])
        customRow.orientation = .horizontal
        customRow.spacing = 8

        // One preference for both: a tab and a split are each "another shell,
        // opened from here", and having them disagree would be arbitrary.
        terminalGrid = form([
            ("Font", fontCombo),
            ("Size", sizeRow),
            ("Theme", themePopup),
            ("New shells open in", newPanePopup),
            ("Folder", customRow),
            ("", restoreSessionCheckbox),
            ("", hint),
        ])
        return wrap(terminalGrid)
    }

    /// The custom-folder row is only meaningful for the custom mode.
    private func updateNewPaneVisibility() {
        let mode = Self.newPaneModes[min(max(0, newPanePopup.indexOfSelectedItem), Self.newPaneModes.count - 1)]
        terminalGrid.row(at: 4).isHidden = mode != "custom"
    }

    @objc private func newPaneModeChanged() {
        updateNewPaneVisibility()
    }

    @objc private func chooseNewPaneDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (newPaneCustomField.stringValue as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newPaneCustomField.stringValue = Self.abbreviatingHome(url.path)
    }

    /// Stored the way a user would type it, so the field stays readable.
    private static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
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
            (featureOpenTerminal, "open_terminal"),
        ] {
            button.setButtonType(.switch)
            button.title = title
        }

        let features = NSStackView(views: [
            featureListTerminals, featureGetOutput, featureGetActiveOutput, featureSendInput,
            featureOpenTerminal,
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
        commandEditor.load(draft.commandProfile)
        insightEditor.load(draft.insightProfile)
        updateProfileVisibility()

        fontCombo.stringValue = draft.fontFamily.isEmpty ? Self.automaticFont : draft.fontFamily
        fontSizeField.stringValue = String(Int(draft.fontSize))
        fontSizeStepper.doubleValue = draft.fontSize
        if let index = TerminalThemes.all.firstIndex(where: { $0.key == draft.theme }) {
            themePopup.selectItem(at: index)
        }
        restoreSessionCheckbox.state = draft.restoreSession ? .on : .off
        newPanePopup.selectItem(at: Self.newPaneModes.firstIndex(of: draft.newPaneDirectory) ?? 0)
        newPaneCustomField.stringValue = draft.newPaneCustomDirectory
        updateNewPaneVisibility()

        mcpEnabledCheckbox.state = draft.mcpEnabled ? .on : .off
        mcpPortField.stringValue = String(draft.mcpPort)
        mcpBufferField.stringValue = String(draft.mcpBufferSizeKB)
        mcpFileBufferCheckbox.state = draft.mcpFileBufferEnabled ? .on : .off
        featureListTerminals.state = draft.mcpFeatures.listTerminals ? .on : .off
        featureGetOutput.state = draft.mcpFeatures.getTerminalOutput ? .on : .off
        featureGetActiveOutput.state = draft.mcpFeatures.getActiveTerminalOutput ? .on : .off
        featureSendInput.state = draft.mcpFeatures.sendInputToTerminal ? .on : .off
        featureOpenTerminal.state = draft.mcpFeatures.openTerminal ? .on : .off

        assistantEnabledCheckbox.state = draft.assistantEnabled ? .on : .off
        assistantInsightsPopup.selectItem(at: Self.insightModes.firstIndex(of: draft.assistantInsights) ?? 1)

        updateMcpUrl()
    }

    private func collectIntoDraft() {
        draft.commandProfile = commandEditor.commit()
        draft.insightProfile = insightEditor.commit()

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
        let paneModeIndex = newPanePopup.indexOfSelectedItem
        if Self.newPaneModes.indices.contains(paneModeIndex) {
            draft.newPaneDirectory = Self.newPaneModes[paneModeIndex]
        }
        draft.newPaneCustomDirectory = newPaneCustomField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            sendInputToTerminal: featureSendInput.state == .on,
            openTerminal: featureOpenTerminal.state == .on
        )
    }

    private func updateProfileVisibility() {
        let showCommands = profileSwitcher.selectedSegment == 0
        commandEditor.isHidden = !showCommands
        insightEditor.isHidden = showCommands
    }

    private func updateMcpUrl() {
        let port = Int(mcpPortField.stringValue) ?? draft.mcpPort
        mcpUrlLabel.stringValue = mcpEnabledCheckbox.state == .on
            ? "http://127.0.0.1:\(port)/mcp"
            : "disabled"
    }

    // MARK: - Actions

    @objc private func profileSwitched() {
        updateProfileVisibility()
    }

    @objc private func mcpEnabledChanged() {
        updateMcpUrl()
    }

    @objc private func fontSizeStepped() {
        fontSizeField.stringValue = String(Int(fontSizeStepper.doubleValue))
    }

    @objc private func save() {
        collectIntoDraft()
        apiKeys.commit()
        SettingsStore.shared.save(draft)
        onSave?(draft)
        close()
    }

    @objc private func cancel() {
        close()
    }
}
