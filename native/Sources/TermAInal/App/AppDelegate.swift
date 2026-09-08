import AppKit
import SwiftTerm

/// Application shell. Replaces `createWindow` plus the single global `keydown`
/// listener in `App.tsx`: on AppKit, shortcuts are menu-item key equivalents,
/// which get "don't fire while a text field is focused" behaviour for free
/// instead of the renderer's manual `isInputFocused` guard.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let tabs = TabController()

    /// The pane layout of the frontmost tab. Menu actions operate on this;
    /// background tabs keep running but are not the target of a shortcut.
    private var panes: PaneController? { tabs.activePanes }
    private var mcpServer: MCPServer?
    /// Held while the sheet is up; released when it closes.
    private var palette: AIPaletteController?
    private var settingsController: SettingsWindowController?
    /// Kept so its pressed state can follow the sidebar.
    private var sidebarToggle: NSButton?

    private let assistant = AssistantController()
    private let mainSplit = NSSplitView()
    /// Distinguishes "the user collapsed the sidebar" from "the window is too
    /// narrow to show it", so widening the window does not resurrect a sidebar
    /// the user deliberately closed.
    private var userCollapsedSidebar = false
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
        assistant.onCollapseRequested = { [weak self] in self?.setSidebarVisible(false, byUser: true) }

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

        let server = MCPServer(port: settings.mcpPort, features: settings.mcpFeatures)

        // Metadata is injected, never read from the UI directly — the same
        // separation the Electron build enforced with its `mcp-set-*` IPC push.
        server.panesProvider = { [weak self] in
            guard let self else { return [] }
            // Every tab, not just the visible one: a shell in a background tab
            // is still live and an agent may be driving it.
            var infos: [MCPPaneInfo] = []
            var number = 1
            for tab in self.tabs.tabs {
                for node in tab.panes.root.allPanes {
                    guard let paneId = node.paneId else { continue }
                    infos.append(MCPPaneInfo(
                        paneId: paneId,
                        paneNumber: number,
                        label: node.label ?? tab.title,
                        cwd: tab.panes.terminals[paneId]?.currentCwd ?? node.cwd
                    ))
                    number += 1
                }
            }
            return infos
        }
        server.activePaneIdProvider = { [weak self] in self?.tabs.activePaneId }
        server.readBuffer = { paneId, maxLines in
            OutputBuffer.shared.read(paneId: paneId, maxLines: maxLines)
        }
        server.sendInput = { [weak self] paneId, text in
            guard let self,
                  let terminal = self.tabs.tabs.compactMap({ $0.panes.terminals[paneId] }).first
            else { return false }
            DispatchQueue.main.async { terminal.sendToShell(text) }
            return true
        }

        do {
            try server.start()
            mcpServer = server
        } catch {
            NSLog("[MCP] failed to start on port \(settings.mcpPort): \(error)")
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

        // Shell menu — the split/close/focus shortcuts from App.tsx
        // Cmd+T is New Tab and Cmd+1..9 select tabs, which is what every other
        // macOS terminal does. The Electron build bound Cmd+T to split-right
        // and the digits to panes; those move to Cmd+D and Cmd+Alt+digit.
        let shellMenuItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        addItem(to: shellMenu, "New Tab", #selector(newTab), "t", [.command])
        addItem(to: shellMenu, "Close Tab", #selector(closeTab), "w", [.command, .shift])
        shellMenu.addItem(.separator())
        addItem(to: shellMenu, "Next Tab", #selector(nextTab), "]", [.command, .shift])
        addItem(to: shellMenu, "Previous Tab", #selector(previousTab), "[", [.command, .shift])
        for number in 1...9 {
            addItem(to: shellMenu, "Tab \(number)", #selector(selectTab(_:)), "\(number)", [.command], tag: number)
        }
        shellMenu.addItem(.separator())
        addItem(to: shellMenu, "Split Right", #selector(splitRight), "d", [.command])
        addItem(to: shellMenu, "Split Down", #selector(splitDown), "d", [.command, .shift])
        addItem(to: shellMenu, "Split Left", #selector(splitLeft), "d", [.command, .option])
        addItem(to: shellMenu, "Split Up", #selector(splitUp), "d", [.command, .shift, .option])
        addItem(to: shellMenu, "Close Pane", #selector(closePane), "w", [.command])
        for number in 1...9 {
            addItem(to: shellMenu, "Focus Pane \(number)", #selector(focusPane(_:)), "\(number)", [.command, .option], tag: number)
        }
        shellMenu.addItem(.separator())
        addItem(to: shellMenu, "Clear Screen and Scrollback", #selector(clearAll), "k", [.command])
        addItem(to: shellMenu, "Clear Screen", #selector(clearScreen), "l", [.command])
        shellMenuItem.submenu = shellMenu
        mainMenu.addItem(shellMenuItem)

        // AI menu
        let aiMenuItem = NSMenuItem()
        let aiMenu = NSMenu(title: "AI")
        addItem(to: aiMenu, "Command Palette…", #selector(openAIPalette), "p", [.command, .shift])
        aiMenu.addItem(.separator())
        addItem(to: aiMenu, "Toggle Assistant Sidebar", #selector(toggleAssistant), "a", [.command, .shift])
        aiMenuItem.submenu = aiMenu
        mainMenu.addItem(aiMenuItem)

        NSApp.mainMenu = mainMenu
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

    // MARK: - Actions

    // Tabs
    @objc private func newTab() {
        tabs.addTab(cwd: NewPaneDirectory.resolve(inheriting: panes?.activeTerminal?.currentCwd))
    }
    @objc private func closeTab() { tabs.closeSelectedTab() }
    @objc private func nextTab() { tabs.selectNextTab() }
    @objc private func previousTab() { tabs.selectPreviousTab() }
    @objc private func selectTab(_ sender: NSMenuItem) { tabs.selectTab(at: sender.tag - 1) }

    // Splits, within the frontmost tab
    @objc private func splitRight() { panes?.splitActivePane(direction: .horizontal) }
    @objc private func splitDown() { panes?.splitActivePane(direction: .vertical) }
    @objc private func splitLeft() { panes?.splitActivePane(direction: .horizontal, before: true) }
    @objc private func splitUp() { panes?.splitActivePane(direction: .vertical, before: true) }
    @objc private func closePane() { panes?.closeActivePane() }
    @objc private func focusPane(_ sender: NSMenuItem) { panes?.focusPane(number: sender.tag) }

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

    @objc private func openAIPalette() {
        let cwd = panes?.activeTerminal?.currentCwd
        let controller = AIPaletteController(cwd: cwd) { [weak self] command in
            // Never auto-executed: this only runs after the user hits Execute in
            // the review sheet. Same invariant as the Electron overlay.
            self?.panes?.activeTerminal?.sendToShell(command + "\n")
        }
        palette = controller
        controller.present(in: window)
    }
}
