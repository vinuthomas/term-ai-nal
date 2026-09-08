import AppKit
import SwiftTerm

/// Application shell. Replaces `createWindow` plus the single global `keydown`
/// listener in `App.tsx`: on AppKit, shortcuts are menu-item key equivalents,
/// which get "don't fire while a text field is focused" behaviour for free
/// instead of the renderer's manual `isInputFocused` guard.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private let tabs = TabController()

    /// The pane layout of the frontmost tab. Menu actions operate on this;
    /// background tabs keep running but are not the target of a shortcut.
    private var panes: PaneController? { tabs.activePanes }
    private var mcpServer: MCPServer?
    private var settingsController: SettingsWindowController?
    /// Rebuilt on each opening by `menuNeedsUpdate` to list only tabs/panes
    /// that currently exist, rather than a fixed bank of nine.
    private let selectTabMenu = NSMenu(title: "Select Tab")
    private let focusPaneMenu = NSMenu(title: "Focus Pane")
    /// Kept so its pressed state can follow the sidebar.
    private var sidebarToggle: NSButton?

    private let assistant = AssistantController()
    private let mainSplit = NSSplitView()
    /// Distinguishes "the user collapsed the sidebar" from "the window is too
    /// narrow to show it", so widening the window does not resurrect a sidebar
    /// the user deliberately closed.
    private var userCollapsedSidebar = false
    /// Ceiling on terminals an agent can open. Each is a live shell.
    private static let maxAgentTerminals = 24

    /// Below this the sidebar would leave too little room for the terminal.
    private static let sidebarMinimumWindowWidth: CGFloat = 900

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.shared.load()
        applyBufferSettings()

        // Only restore when the setting is on; otherwise drop any stale file so
        // turning the option off actually forgets the layout.
        let settings = SettingsStore.shared.settings
        tabs.onActivePaneChange = { [weak self] paneId in
            self?.mcpServer?.activePaneChanged(to: paneId)
        }
        if settings.restoreSession {
            tabs.restore(SessionStore.load())
        } else {
            SessionStore.clear()
            tabs.restore(nil)
        }

        buildWindow()
        buildMenu()
        restartMcpServer()
        tabs.refreshSelectedTitle()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remember a dragged sidebar width.
        if sidebarVisible {
            var settings = SettingsStore.shared.settings
            let width = assistant.sidebar.frame.width
            if width > 100 {
                settings.assistantSidebarWidth = Double(width)
                SettingsStore.shared.save(settings)
            }
        }
        if SettingsStore.shared.settings.restoreSession {
            SessionStore.save(tabs.captureSession())
        }
        mcpServer?.stop()
        OutputBuffer.shared.cleanupAll()
    }

    // MARK: - Window

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "term-ai-nal"
        // The AppKit equivalent of Electron's titleBarStyle: 'hiddenInset'.
        window.titlebarAppearsTransparent = true
        // Shown, unlike a plain hidden-inset window: the title is how you tell
        // what a window is without switching to it, and it names the frontmost
        // tab. The titlebar strip stays transparent so the tab bar sits under
        // it and the window remains draggable there.
        window.titleVisibility = .visible
        applyWindowBackground()

        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.addArrangedSubview(tabs.containerView)
        mainSplit.addArrangedSubview(assistant.sidebar)
        // The terminal absorbs window resizing; the sidebar keeps its width.
        mainSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        assistant.activePaneId = { [weak self] in self?.tabs.activePaneId }
        tabs.onSelectedTitleChange = { [weak self] title in
            self?.window.title = title
        }
        // Ending the last session closes the window, which quits the app —
        // the same thing Terminal.app and iTerm2 do when the last shell exits.
        tabs.onLastTabClosed = { [weak self] in
            self?.window.performClose(nil)
        }

        let settings = SettingsStore.shared.settings
        let launchTheme = TerminalThemes.theme(forKey: settings.theme)
        assistant.sidebar.applyTheme(launchTheme)
        tabs.applyTheme(launchTheme)
        // Start collapsed unless the assistant is on and there is room for it.
        userCollapsedSidebar = !settings.assistantEnabled
        assistant.sidebar.isHidden = true

        let content = NSView()
        content.addSubview(mainSplit)
        NSLayoutConstraint.activate([
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // Leave the transparent titlebar strip free so the window stays draggable,
            // replacing the renderer's WebkitAppRegion drag areas.
            mainSplit.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            mainSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.delegate = self
        installSidebarToggle()
        window.center()
        window.makeKeyAndOrderFront(nil)

        if settings.assistantEnabled {
            setSidebarVisible(true, byUser: false)
        }
    }

    /// Puts a permanent assistant toggle in the titlebar.
    ///
    /// The sidebar could be closed from its own header but only reopened from
    /// the menu or a shortcut, which is not a way back — you have to already
    /// know the feature exists to find either. The titlebar rather than the tab
    /// bar because the tab bar hides itself at one tab, which is most of the
    /// time, so a control there would vanish exactly when it was wanted.
    private func installSidebarToggle() {
        let accessory = Self.makeSidebarToggleAccessory(
            target: self,
            action: #selector(toggleAssistant)
        )
        sidebarToggle = accessory.view.subviews.first as? NSButton
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// Builds the titlebar accessory.
    ///
    /// The container is given an explicit frame. `NSTitlebarAccessoryViewController`
    /// sizes its view from the frame and ignores Auto Layout's `fittingSize`, so
    /// with constraints alone the container stayed 0pt wide and the control was
    /// laid out at zero width — present in the hierarchy and invisible.
    static func makeSidebarToggleAccessory(target: AnyObject, action: Selector) -> NSTitlebarAccessoryViewController {
        let button = NSButton(title: "", target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.setButtonType(.pushOnPushOff)
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Assistant")
        button.imagePosition = .imageOnly
        button.toolTip = "Show or hide the assistant (\u{2318}\u{21E7}A)"

        let height: CGFloat = 28
        let trailingInset: CGFloat = 10
        let width = max(button.intrinsicContentSize.width, 34)
        button.frame = NSRect(
            x: 0,
            y: ((height - button.intrinsicContentSize.height) / 2).rounded(),
            width: width,
            height: button.intrinsicContentSize.height
        )

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width + trailingInset, height: height))
        container.addSubview(button)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        return accessory
    }

    // MARK: - Assistant sidebar    // MARK: - Assistant sidebar

    private var sidebarVisible: Bool { !assistant.sidebar.isHidden }

    /// `byUser` records intent: an automatic collapse because the window got
    /// narrow must be reversible, an explicit one must not be undone silently.
    private func setSidebarVisible(_ visible: Bool, byUser: Bool) {
        if byUser { userCollapsedSidebar = !visible }
        guard visible != sidebarVisible else { return }

        if visible {
            guard window.frame.width >= Self.sidebarMinimumWindowWidth else { return }
            assistant.sidebar.isHidden = false
            let width = CGFloat(SettingsStore.shared.settings.assistantSidebarWidth)
            mainSplit.setPosition(window.frame.width - width, ofDividerAt: 0)
            assistant.sidebar.focusInput()
        } else {
            assistant.sidebar.isHidden = true
        }
        mainSplit.adjustSubviews()
        sidebarToggle?.state = sidebarVisible ? .on : .off
    }

    @objc private func toggleAssistant() {
        setSidebarVisible(!sidebarVisible, byUser: true)
    }

    func windowDidResize(_ notification: Notification) {
        // The slide offset is a multiple of the viewport width, so it must be
        // recomputed rather than stored.
        tabs.viewportResized()

        // Hide when there is no room; bring it back only if the user did not
        // close it themselves.
        if window.frame.width < Self.sidebarMinimumWindowWidth {
            if sidebarVisible { setSidebarVisible(false, byUser: false) }
        } else if !sidebarVisible, !userCollapsedSidebar,
                  SettingsStore.shared.settings.assistantEnabled {
            setSidebarVisible(true, byUser: false)
        }
    }

    /// Matches the window's background to the active theme so the per-pane
    /// padding reads as margin rather than as a border.
    private func applyWindowBackground() {
        let theme = TerminalThemes.theme(forKey: SettingsStore.shared.settings.theme)
        window.backgroundColor = theme.background
        // Standard controls draw their bezels, scrollers and text-field
        // backgrounds from the window's appearance, not from whatever colour we
        // painted behind them. Without this a dark theme under a light system
        // appearance gives light bezels on a dark ground and vice versa.
        window.appearance = NSAppearance(named: theme.background.isDarkForControls ? .darkAqua : .aqua)
    }

    private func applyBufferSettings() {
        let settings = SettingsStore.shared.settings
        OutputBuffer.shared.maxBytes = max(1024, settings.mcpBufferSizeKB * 1024)
        OutputBuffer.shared.fileSpillEnabled = settings.mcpFileBufferEnabled
    }

    // MARK: - MCP

    /// Stops any running server and starts a fresh one if enabled.
    ///
    /// `MCPServer` is immutable per port, so a port or feature change means a
    /// new instance — this is what `applyMcpSettings` did in `main.ts`.
    private func restartMcpServer() {
        mcpServer?.stop()
        mcpServer = nil

        let settings = SettingsStore.shared.settings
        guard settings.mcpEnabled else { return }

        let server = MCPServer(
            port: settings.mcpPort,
            features: settings.mcpFeatures,
            // A plain file, not the keychain (see mcpAuthTokenURL) — and
            // this whole call only runs when mcpEnabled is on, which is
            // off by default, so it's not touched by a user who hasn't
            // opted in either way.
            authToken: SettingsStore.shared.mcpAuthToken,
            requireInputConfirmation: settings.mcpRequireConfirmationForInput
        )

        // Metadata is injected, never read from the UI directly — the same
        // separation the Electron build enforced with its `mcp-set-*` IPC push.
        server.panesProvider = { [weak self] in
            guard let self else { return [] }
            // Every tab, not just the visible one: a shell in a background tab
            // is still live and an agent may be driving it. Numbering runs
            // across all of them regardless of the restriction below, so a
            // pane's number does not change depending on the setting.
            var infos: [MCPPaneInfo] = []
            var number = 1
            for tab in self.tabs.tabs {
                for pane in tab.panes.panes {
                    infos.append(MCPPaneInfo(
                        paneId: pane.paneId,
                        paneNumber: number,
                        label: pane.label ?? tab.title,
                        cwd: tab.panes.terminals[pane.paneId]?.currentCwd ?? pane.cwd
                    ))
                    number += 1
                }
            }
            guard SettingsStore.shared.settings.mcpRestrictToVisiblePane else { return infos }
            // Every other tool already gates on membership in this list (see
            // `visible(_:)` in MCPServer), so filtering it here is the whole
            // mechanism — nothing else needs to know the restriction exists.
            guard let activeId = self.tabs.activePaneId else { return [] }
            return infos.filter { $0.paneId == activeId }
        }
        server.activePaneIdProvider = { [weak self] in self?.tabs.activePaneId }
        server.readBuffer = { paneId, maxLines in
            OutputBuffer.shared.read(paneId: paneId, maxLines: maxLines)
        }
        // The app owns the policy: how many terminals are too many, whether a
        // path is usable, and whether the user's view moves. The server only
        // parses the request and relays this sentence back.
        server.openTerminal = { [weak self] scope, purpose, cwd, focus in
            guard let self else { return "Error: The window is not available." }

            // First tool that changes the window's structure rather than
            // reading it or typing into it, so it needs a ceiling: a looping
            // agent would otherwise spawn shells until the machine complained.
            let paneCount = self.tabs.tabs.reduce(0) { $0 + $1.panes.paneIds.count }
            guard paneCount < Self.maxAgentTerminals else {
                return "Error: \(Self.maxAgentTerminals) terminals are already open. Close some before opening more."
            }

            // A path that does not resolve falls back to the app's preference
            // rather than failing the call or dumping the shell at /.
            var directory: String?
            if let cwd {
                let expanded = (cwd as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    directory = expanded
                }
            }
            let ignoredPath = cwd != nil && directory == nil

            var result = ""
            let work = {
                let label = String(purpose.prefix(60))
                if scope == "tab" {
                    let paneId = self.tabs.addLabelledTab(purpose: label, cwd: directory, focus: focus)
                    result = "Opened tab \"\(label)\" with terminal '\(paneId)'."
                } else if let panes = self.tabs.activePanes {
                    let paneId = panes.addPane(purpose: label, cwd: directory, focus: focus)
                    result = "Opened pane \"\(label)\" as terminal '\(paneId)' in the current tab."
                } else {
                    result = "Error: No tab to add a pane to."
                }
            }
            // Requests arrive on the server's queue; view work is main-only.
            if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }

            if result.hasPrefix("Error") { return result }
            if ignoredPath { result += " The requested directory did not exist, so the default was used." }
            if !focus { result += " It is not visible; pass focus=true or let the user expand it." }
            return result + " Send input with send_input_to_terminal."
        }

        server.sendInput = { [weak self] paneId, text in
            guard let self,
                  let tab = self.tabs.tabs.first(where: { $0.panes.terminals[paneId] != nil }),
                  let terminal = tab.panes.terminals[paneId]
            else { return false }
            DispatchQueue.main.async {
                terminal.sendToShell(text)
                // The only on-screen sign an agent typed anywhere, since a
                // background tab's pane gives no other indication at all.
                tab.panes.flagAgentActivity(paneId: paneId)
            }
            return true
        }

        server.confirmSendInput = { [weak self] paneId, text, completion in
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                let label = self.tabs.tabs
                    .flatMap { $0.panes.panes }
                    .first { $0.paneId == paneId }?
                    .label ?? paneId
                self.presentInputConfirmation(paneLabel: label, text: text, completion: completion)
            }
        }

        do {
            try server.start()
            mcpServer = server
        } catch {
            NSLog("[MCP] failed to start on port \(settings.mcpPort): \(error)")
        }
    }

    /// Approve/deny sheet for `send_input_to_terminal`, shown only when
    /// `mcpRequireConfirmationForInput` is on. `completion` runs exactly
    /// once, whether the user clicks a button or the 60s timeout below ends
    /// the sheet on their behalf — a dialog nobody notices should not hang an
    /// agent (or the MCP request behind it) for the rest of the session.
    private func presentInputConfirmation(paneLabel: String, text: String, completion: @escaping (Bool) -> Void) {
        guard let window else {
            completion(false)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Allow agent input to \"\(paneLabel)\"?"
        let preview = text.count > 400 ? String(text.prefix(400)) + "…" : text
        alert.informativeText = "An MCP client wants to send this to the terminal:\n\n\(preview)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak window, weak alert] in
            guard let window, let alertWindow = alert?.window, window.sheets.contains(alertWindow) else { return }
            window.endSheet(alertWindow, returnCode: .alertSecondButtonReturn)
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About term-ai-nal", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide term-ai-nal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit term-ai-nal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — the standard responder-chain selectors, which SwiftTerm's
        // TerminalView implements, so Cmd+C/V/A need no custom handling.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        addItem(to: editMenu, "Paste", #selector(pasteIntoTerminal), "v", [.command])
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu — the split/close/focus shortcuts from App.tsx plus the
        // assistant sidebar toggle (there is no other menu it belongs under
        // now that AI only had that one item).
        // Cmd+T is New Tab and Cmd+1..9 select tabs, which is what every other
        // macOS terminal does. The Electron build bound Cmd+T to split-right
        // and the digits to panes; those move to Cmd+D and Cmd+Alt+digit.
        //
        // "Select Tab" and "Focus Pane" list only tabs/panes that currently
        // exist (rebuilt by menuNeedsUpdate just before each opens), rather
        // than a fixed bank of nine — the key equivalents still work up to
        // whatever exists, since TabController/PaneController already bounds-
        // check the index.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        addItem(to: viewMenu, "New Tab", #selector(newTab), "t", [.command])
        addItem(to: viewMenu, "Close Tab", #selector(closeTab), "w", [.command, .shift])
        viewMenu.addItem(.separator())
        addItem(to: viewMenu, "Next Tab", #selector(nextTab), "]", [.command, .shift])
        addItem(to: viewMenu, "Previous Tab", #selector(previousTab), "[", [.command, .shift])
        let selectTabItem = NSMenuItem(title: "Select Tab", action: nil, keyEquivalent: "")
        selectTabMenu.delegate = self
        selectTabItem.submenu = selectTabMenu
        viewMenu.addItem(selectTabItem)
        viewMenu.addItem(.separator())
        addItem(to: viewMenu, "New Pane", #selector(addPane), "d", [.command])
        addItem(to: viewMenu, "Close Pane", #selector(closePane), "w", [.command])
        let focusPaneItem = NSMenuItem(title: "Focus Pane", action: nil, keyEquivalent: "")
        focusPaneMenu.delegate = self
        focusPaneItem.submenu = focusPaneMenu
        viewMenu.addItem(focusPaneItem)
        viewMenu.addItem(.separator())
        addItem(to: viewMenu, "Clear Screen and Scrollback", #selector(clearAll), "k", [.command])
        addItem(to: viewMenu, "Clear Screen", #selector(clearScreen), "l", [.command])
        viewMenu.addItem(.separator())
        addItem(to: viewMenu, "Toggle Assistant Sidebar", #selector(toggleAssistant), "a", [.command, .shift])
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Help menu — registered as NSApp.helpMenu so macOS also surfaces its
        // items (and their key equivalents) in the built-in Help search field.
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "term-ai-nal Help", action: #selector(openHelp), keyEquivalent: "")
        helpMenu.addItem(.separator())
        let versionItem = NSMenuItem(title: "Version \(Self.appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        helpMenu.addItem(versionItem)
        helpMenu.addItem(withTitle: "Acknowledgments & Licenses…", action: #selector(openLicenses), keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    private func addItem(
        to menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags,
        tag: Int = 0
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.tag = tag
        menu.addItem(item)
    }

    // MARK: - NSMenuDelegate

    /// Rebuilds `selectTabMenu`/`focusPaneMenu` right before they open, so
    /// each lists exactly the tabs or panes that exist right now — a
    /// checkmark on the current one — instead of a fixed Tab/Pane 1...9.
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu {
        case selectTabMenu:
            menu.items = tabs.tabs.enumerated().map { index, tab in
                let item = NSMenuItem(title: tab.title, action: #selector(selectTab(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
                item.keyEquivalentModifierMask = [.command]
                item.target = self
                item.tag = index + 1
                item.state = index == tabs.selectedIndex ? .on : .off
                return item
            }
        case focusPaneMenu:
            let paneCount = panes?.panes.count ?? 0
            let expandedIndex = panes?.expandedIndex ?? -1
            menu.items = (paneCount > 0 ? Array(1...paneCount) : []).map { number in
                let item = NSMenuItem(title: "Pane \(number)", action: #selector(focusPane(_:)), keyEquivalent: number < 10 ? "\(number)" : "")
                item.keyEquivalentModifierMask = [.command, .option]
                item.target = self
                item.tag = number
                item.state = number - 1 == expandedIndex ? .on : .off
                return item
            }
        default:
            break
        }
    }

    // MARK: - Actions

    // Tabs
    @objc private func newTab() {
        tabs.addTab(cwd: NewPaneDirectory.resolve(inheriting: panes?.activeTerminal?.currentCwd))
    }
    @objc private func closeTab() { tabs.closeSelectedTab() }
    @objc private func nextTab() { tabs.selectNextTab() }
    @objc private func previousTab() { tabs.selectPreviousTab() }
    @objc private func selectTab(_ sender: NSMenuItem) { tabs.selectTab(at: sender.tag - 1) }

    // Panes, within the frontmost tab
    @objc private func addPane() { panes?.addPane() }
    @objc private func closePane() { panes?.closeActivePane() }
    @objc private func focusPane(_ sender: NSMenuItem) { panes?.focusPane(number: sender.tag) }

    // Help — shortcuts moved here once they were tucked into submenus above,
    // plus the version and license notices a normal macOS app surfaces.
    @objc private func openHelp() {
        let alert = NSAlert()
        alert.messageText = "term-ai-nal Help"
        alert.informativeText = """
        Keyboard shortcuts

        ⌘T New Tab · ⌘⇧W Close Tab · ⌘⇧] / ⌘⇧[ Next / Previous Tab · ⌘1–9 Select Tab
        ⌘D New Pane · ⌘W Close Pane · ⌘⌥1–9 Focus Pane
        ⌘K Clear Screen and Scrollback · ⌘L Clear Screen
        ⌘⇧A Toggle Assistant Sidebar · ⌘, Settings
        ⌘C / ⌘V / ⌘A Copy / Paste / Select All
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openLicenses() {
        let alert = NSAlert()
        alert.messageText = "Acknowledgments & Licenses"
        alert.informativeText = """
        term-ai-nal \(Self.appVersion) — MIT licensed.

        Built on SwiftTerm (github.com/migueldeicaza/SwiftTerm), MIT licensed.

        Bundles JetBrainsMonoNL Nerd Font Mono: JetBrains Mono under the SIL \
        Open Font License 1.1, with Nerd Fonts icon glyphs under a mix of \
        licenses, including Font Awesome under CC BY 4.0. Full notice in \
        Fonts/NOTICE.md inside the app's Resources.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reveal Notices in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn, let resources = Bundle.main.resourceURL {
            NSWorkspace.shared.activateFileViewerSelecting([resources])
        }
    }

    /// Image first, then text — the Cmd+V order the Electron build used.
    @objc private func pasteIntoTerminal() {
        guard let terminal = panes?.activeTerminal else { return }
        if terminal.pasteImageFromClipboard() { return }
        terminal.paste(self)
    }

    /// Cmd+L: what Ctrl+L does — let the shell redraw its own prompt.
    @objc private func clearScreen() {
        panes?.activeTerminal?.sendToShell("\u{0c}")
    }

    /// Cmd+K: also drop the scrollback, matching iTerm2 and the Electron build.
    @objc private func clearAll() {
        guard let terminal = panes?.activeTerminal else { return }
        terminal.terminal.clearScrollback()
        terminal.sendToShell("\u{0c}")
    }

    @objc private func openSettings() {
        if let existing = settingsController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController()
        controller.onSave = { [weak self] _ in
            self?.applyChangedSettings()
        }
        // A rotated token is a credential change; it takes effect immediately
        // rather than waiting for Save, or "Regenerate" would silently lie
        // about having revoked the old one.
        controller.onRegenerateToken = { [weak self] in
            self?.restartMcpServer()
        }
        settingsController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Re-applies everything that reads settings at runtime. Font and theme go
    /// straight to the live panes; the MCP server has to be rebuilt because its
    /// port and feature set are fixed at construction.
    private func applyChangedSettings() {
        applyBufferSettings()
        applyWindowBackground()
        let settings = SettingsStore.shared.settings
        let theme = TerminalThemes.theme(forKey: settings.theme)
        tabs.applyTheme(theme)
        assistant.sidebar.applyTheme(theme)
        if !settings.assistantEnabled {
            setSidebarVisible(false, byUser: true)
        }
        restartMcpServer()
        settingsController = nil
    }
}
