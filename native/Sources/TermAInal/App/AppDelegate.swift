import AppKit
import SwiftTerm

/// Application shell. Replaces `createWindow` plus the single global `keydown`
/// listener in `App.tsx`: on AppKit, shortcuts are menu-item key equivalents,
/// which get "don't fire while a text field is focused" behaviour for free
/// instead of the renderer's manual `isInputFocused` guard.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    /// Built in `applicationDidFinishLaunching`, once settings are loaded and
    /// any saved session is available to restore from.
    private var panes: PaneController!
    private var mcpServer: MCPServer?
    /// Held while the sheet is up; released when it closes.
    private var palette: AIPaletteController?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.shared.load()
        applyBufferSettings()

        // Only restore when the setting is on; otherwise drop any stale file so
        // turning the option off actually forgets the layout.
        let settings = SettingsStore.shared.settings
        if settings.restoreSession {
            panes = PaneController(restoring: SessionStore.load())
        } else {
            SessionStore.clear()
            panes = PaneController()
        }

        buildWindow()
        buildMenu()
        restartMcpServer()

        panes.onActivePaneChange = { [weak self] paneId in
            self?.mcpServer?.activePaneChanged(to: paneId)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SettingsStore.shared.settings.restoreSession {
            SessionStore.save(panes.captureSession())
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
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)

        let content = NSView()
        content.addSubview(panes.containerView)
        NSLayoutConstraint.activate([
            panes.containerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panes.containerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // Leave the transparent titlebar strip free so the window stays draggable,
            // replacing the renderer's WebkitAppRegion drag areas.
            panes.containerView.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            panes.containerView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
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
            return self.panes.root.allPanes.compactMap { node in
                guard let paneId = node.paneId else { return nil }
                return MCPPaneInfo(
                    paneId: paneId,
                    paneNumber: node.paneNumber ?? 0,
                    label: node.label,
                    cwd: self.panes.terminals[paneId]?.currentCwd ?? node.cwd
                )
            }
        }
        server.activePaneIdProvider = { [weak self] in self?.activePaneId }
        server.readBuffer = { paneId, maxLines in
            OutputBuffer.shared.read(paneId: paneId, maxLines: maxLines)
        }
        server.sendInput = { [weak self] paneId, text in
            guard let terminal = self?.panes.terminals[paneId] else { return false }
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

    private var activePaneId: String { panes.activePaneId }

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
        let shellMenuItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        addItem(to: shellMenu, "Split Right", #selector(splitRight), "t", [.command])
        addItem(to: shellMenu, "Split Down", #selector(splitDown), "t", [.command, .shift])
        addItem(to: shellMenu, "Split Left", #selector(splitLeft), "t", [.command, .option])
        addItem(to: shellMenu, "Split Up", #selector(splitUp), "t", [.command, .shift, .option])
        shellMenu.addItem(.separator())
        addItem(to: shellMenu, "Close Pane", #selector(closePane), "w", [.command])
        shellMenu.addItem(.separator())
        addItem(to: shellMenu, "Clear Screen and Scrollback", #selector(clearAll), "k", [.command])
        addItem(to: shellMenu, "Clear Screen", #selector(clearScreen), "l", [.command])
        shellMenu.addItem(.separator())
        for number in 1...9 {
            addItem(to: shellMenu, "Focus Pane \(number)", #selector(focusPane(_:)), "\(number)", [.command], tag: number)
        }
        shellMenuItem.submenu = shellMenu
        mainMenu.addItem(shellMenuItem)

        // AI menu
        let aiMenuItem = NSMenuItem()
        let aiMenu = NSMenu(title: "AI")
        addItem(to: aiMenu, "Command Palette…", #selector(openAIPalette), "p", [.command, .shift])
        addItem(to: aiMenu, "Task Planner…", #selector(openTaskPlanner), "m", [.command, .shift])
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

    @objc private func splitRight() { panes.splitActivePane(direction: .horizontal) }
    @objc private func splitDown() { panes.splitActivePane(direction: .vertical) }
    @objc private func splitLeft() { panes.splitActivePane(direction: .horizontal, before: true) }
    @objc private func splitUp() { panes.splitActivePane(direction: .vertical, before: true) }
    @objc private func closePane() { panes.closeActivePane() }

    /// Image first, then text — the Cmd+V order the Electron build used.
    @objc private func pasteIntoTerminal() {
        guard let terminal = panes.activeTerminal else { return }
        if terminal.pasteImageFromClipboard() { return }
        terminal.paste(self)
    }
    @objc private func focusPane(_ sender: NSMenuItem) { panes.focusPane(number: sender.tag) }

    /// Cmd+L: what Ctrl+L does — let the shell redraw its own prompt.
    @objc private func clearScreen() {
        panes.activeTerminal?.sendToShell("\u{0c}")
    }

    /// Cmd+K: also drop the scrollback, matching iTerm2 and the Electron build.
    @objc private func clearAll() {
        guard let terminal = panes.activeTerminal else { return }
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
        panes.applyAppearanceToAll()
        restartMcpServer()
        settingsController = nil
    }

    @objc private func openAIPalette() {
        presentPalette(mode: .command)
    }

    @objc private func openTaskPlanner() {
        presentPalette(mode: .plan)
    }

    private func presentPalette(mode: AIPaletteController.Mode) {
        let cwd = panes.activeTerminal?.currentCwd
        let controller = AIPaletteController(mode: mode, cwd: cwd) { [weak self] command in
            // Never auto-executed: this only runs after the user hits Execute in
            // the review sheet. Same invariant as the Electron overlay.
            self?.panes.activeTerminal?.sendToShell(command + "\n")
        }
        palette = controller
        controller.present(in: window)
    }
}
