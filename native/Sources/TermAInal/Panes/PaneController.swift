import AppKit

/// An `NSSplitView` that divides its children evenly the first time it is given
/// a real size.
///
/// `addArrangedSubview` on its own leaves every child at whatever frame it
/// already had. Because this app reuses terminal views across relayouts, those
/// frames are stale — often zero — so a fresh split came out at arbitrary and
/// sometimes invisible proportions. Divider positions can only be set once the
/// split itself has a width, which is why this happens in `layout()` rather
/// than at construction.
final class EvenSplitView: NSSplitView {
    private var hasDistributed = false

    override func layout() {
        super.layout()
        let count = arrangedSubviews.count
        guard !hasDistributed, count > 1 else { return }

        let total = isVertical ? bounds.width : bounds.height
        guard total > 1 else { return }
        hasDistributed = true

        let each = (total - dividerThickness * CGFloat(count - 1)) / CGFloat(count)
        var position: CGFloat = 0
        for index in 0..<(count - 1) {
            position += each
            setPosition(position, ofDividerAt: index)
            position += dividerThickness
        }
    }
}

/// Owns the pane tree and rebuilds the `NSSplitView` hierarchy from it.
///
/// Terminal views live in `terminals`, keyed by pane id, and are *re-parented*
/// into freshly built split views rather than recreated — the same trick the
/// Electron renderer used with its module-level `globalTerminals` map in
/// `TerminalPane.tsx`, and for the same reason: a rebuilt layout must not kill
/// a running shell.
final class PaneController {
    private(set) var root: PaneNode
    private(set) var terminals: [String: TerminalPaneView] = [:]
    /// One padded wrapper per pane. These are what get inserted into the split
    /// views; the terminal itself is inset inside its wrapper.
    private var paneContainers: [String: NSView] = [:]
    private(set) var activePaneId: String

    /// Host view the layout is mounted into.
    let containerView = NSView()

    var onActivePaneChange: ((String) -> Void)?
    /// Fires when the active pane's shell reports a new title or directory, so
    /// a tab label can follow what the pane is actually doing.
    var onTitleChange: ((String) -> Void)?
    /// Fires when the last pane in this controller has gone, so a tab holding
    /// it can close itself.
    var onEmpty: (() -> Void)?

    /// Best available label: the shell's reported title, else the working
    /// directory's last component.
    var displayTitle: String {
        guard let terminal = terminals[activePaneId] else { return "Shell" }
        if let title = terminal.reportedTitle, !title.isEmpty { return title }
        if let cwd = terminal.currentCwd {
            let name = (cwd as NSString).lastPathComponent
            return name.isEmpty ? "/" : name
        }
        return "Shell"
    }

    /// Restores `snapshot` when one is supplied and usable, otherwise starts
    /// with a single pane. Restoring happens before the first `rebuild()` so a
    /// throwaway shell is never spawned only to be killed.
    /// A fresh single-pane controller, optionally starting in `cwd`. Used when
    /// a new tab is opened next to an existing one.
    convenience init(startingIn cwd: String?) {
        self.init(restoring: nil)
        if let cwd {
            root.allPanes.first?.cwd = cwd
            // The pane was already built by init, so point the live shell at it
            // rather than rebuilding: cd is cheaper than a second spawn.
            terminals[activePaneId]?.sendToShell("cd \(cwd.replacingOccurrences(of: "\"", with: "\\\"")) && clear\n")
        }
    }

    init(restoring snapshot: SessionSnapshot? = nil) {
        if let snapshot,
           let first = snapshot.tabs.first,
           let restored = PaneNode.from(first, newPaneId: Self.newPaneId),
           let first = restored.allPaneIds.first {
            root = restored
            activePaneId = first
        } else {
            let firstPaneId = Self.newPaneId()
            root = .pane(paneId: firstPaneId)
            activePaneId = firstPaneId
        }
        containerView.translatesAutoresizingMaskIntoConstraints = false
        root.renumberPanes()
        rebuild()
    }

    private func notifyTitleIfActive(_ paneId: String) {
        guard paneId == activePaneId else { return }
        onTitleChange?(displayTitle)
    }

    /// Snapshot of the current layout, with each pane's live directory.
    func captureSession() -> SessionSnapshot {
        SessionSnapshot(
            tabs: [root.snapshotNode { [weak self] paneId in
                self?.terminals[paneId]?.currentCwd
            }],
            selected: 0
        )
    }

    /// Kills every shell in this controller. Called when its tab closes.
    func terminateAll() {
        for (paneId, terminal) in terminals {
            terminal.terminate()
            terminal.removeFromSuperview()
            OutputBuffer.shared.cleanup(paneId: paneId)
            CommandLog.shared.clear(paneId: paneId)
        }
        terminals.removeAll()
        paneContainers.removeAll()
    }

    static func newPaneId() -> String {
        "pane-\(UUID().uuidString.prefix(8))"
    }

    var activeTerminal: TerminalPaneView? {
        terminals[activePaneId]
    }

    // MARK: - Mutations

    /// Splits the active pane. `direction` is the axis children are laid along;
    /// `before` inserts the new pane ahead of the current one (the Cmd+Alt
    /// "split left/up" variants).
    func splitActivePane(direction: NSUserInterfaceLayoutOrientation, before: Bool = false) {
        guard let current = root.findPane(paneId: activePaneId) else { return }

        let newPaneId = Self.newPaneId()
        // Inherit the current pane's directory so a split opens where you were.
        let inheritedCwd = terminals[activePaneId]?.currentCwd ?? current.cwd
        let newPane = PaneNode.pane(paneId: newPaneId, cwd: inheritedCwd)

        let movedPane = PaneNode.pane(paneId: current.paneId!, cwd: current.cwd)
        let ordered = before ? [newPane, movedPane] : [movedPane, newPane]

        if let (parent, index) = root.findParent(of: current), parent.direction == direction {
            // Same axis: extend the existing split instead of nesting a new one.
            parent.children.remove(at: index)
            parent.children.insert(contentsOf: ordered, at: index)
        } else if root === current {
            root = .group(direction: direction, children: ordered)
        } else if let (parent, index) = root.findParent(of: current) {
            parent.children[index] = .group(direction: direction, children: ordered)
        }

        activePaneId = newPaneId
        root.renumberPanes()
        rebuild()
        onActivePaneChange?(activePaneId)
    }

    func closeActivePane() {
        // The last pane closing means the tab is done; the tab owner decides
        // whether that is allowed, since it knows how many tabs remain.
        guard root.allPanes.count > 1 else {
            onEmpty?()
            return
        }
        guard let current = root.findPane(paneId: activePaneId) else { return }

        let remaining = root.allPaneIds.filter { $0 != activePaneId }

        if let (parent, index) = root.findParent(of: current) {
            parent.children.remove(at: index)
        }
        root.pruneEmptyGroups()

        terminals[activePaneId]?.terminate()
        paneContainers[activePaneId]?.removeFromSuperview()
        paneContainers.removeValue(forKey: activePaneId)
        terminals.removeValue(forKey: activePaneId)

        activePaneId = remaining.first ?? activePaneId
        root.renumberPanes()
        rebuild()
        onActivePaneChange?(activePaneId)
    }

    func focusPane(number: Int) {
        guard let target = root.findPane(number: number), let paneId = target.paneId else { return }
        focusPane(paneId: paneId)
    }

    func focusPane(paneId: String) {
        guard let terminal = terminals[paneId] else { return }
        activePaneId = paneId
        terminal.window?.makeFirstResponder(terminal)
        onActivePaneChange?(paneId)
    }

    // MARK: - Appearance

    /// Re-reads settings and pushes appearance to every live pane. Called after
    /// the settings UI commits a change; the Electron build achieved this by
    /// re-rendering `TerminalPane` with new xterm.js options.
    func applyAppearanceToAll() {
        for terminal in terminals.values {
            applyAppearance(to: terminal)
        }
    }

    private func applyAppearance(to terminal: TerminalPaneView) {
        let settings = SettingsStore.shared.settings
        terminal.applyAppearance(
            theme: TerminalThemes.theme(forKey: settings.theme),
            fontFamily: settings.fontFamily,
            fontSize: settings.fontSize
        )
    }

    // MARK: - View construction

    /// Rebuilds the split hierarchy, reusing existing terminal views.
    func rebuild() {
        containerView.subviews.forEach { $0.removeFromSuperview() }
        let layout = buildView(for: root)
        layout.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            layout.topAnchor.constraint(equalTo: containerView.topAnchor),
            layout.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        // Drop terminals whose panes no longer exist.
        let live = Set(root.allPaneIds)
        for (paneId, view) in terminals where !live.contains(paneId) {
            view.terminate()
            view.removeFromSuperview()
            paneContainers[paneId]?.removeFromSuperview()
            paneContainers.removeValue(forKey: paneId)
            terminals.removeValue(forKey: paneId)
        }

        if let active = terminals[activePaneId] {
            DispatchQueue.main.async {
                active.window?.makeFirstResponder(active)
            }
        }
    }

    private func buildView(for node: PaneNode) -> NSView {
        switch node.kind {
        case .pane:
            return terminalView(for: node)

        case .group:
            let split = EvenSplitView()
            // A `.horizontal` group lays its children out left-to-right, which
            // AppKit expresses as a vertically-oriented divider.
            split.isVertical = (node.direction == .horizontal)
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = false
            for child in node.children {
                let childView = buildView(for: child)
                childView.translatesAutoresizingMaskIntoConstraints = true
                split.addArrangedSubview(childView)
            }
            return split
        }
    }

    private func terminalView(for node: PaneNode) -> NSView {
        guard let paneId = node.paneId else { return NSView() }

        if let existing = paneContainers[paneId] {
            existing.removeFromSuperview()
            return existing
        }

        let terminal = TerminalPaneView(paneId: paneId, frame: .zero)
        terminal.onCwdChange = { [weak self, weak node] directory in
            node?.cwd = directory
            self?.notifyTitleIfActive(paneId)
        }
        terminal.onTitleChange = { [weak self] _ in
            self?.notifyTitleIfActive(paneId)
        }
        terminal.onOutput = { text in
            OutputBuffer.shared.append(paneId: paneId, text: text)
            // Same stream, two consumers: a flat buffer for MCP reads and a
            // structured command log for the assistant.
            CommandLog.shared.ingest(paneId: paneId, text: text)
        }
        terminal.onProcessExit = { [weak self] _ in
            // The shell exited on its own (`exit`, Ctrl-D) — mirror the Electron
            // behaviour and close the pane.
            guard let self else { return }
            DispatchQueue.main.async {
                let previouslyActive = self.activePaneId
                self.activePaneId = paneId
                self.closeActivePane()
                if previouslyActive != paneId, self.terminals[previouslyActive] != nil {
                    self.focusPane(paneId: previouslyActive)
                }
            }
        }
        terminals[paneId] = terminal
        applyAppearance(to: terminal)
        terminal.start(cwd: node.cwd)

        let container = Self.padded(terminal)
        paneContainers[paneId] = container
        return container
    }

    /// Insets a terminal inside a transparent wrapper.
    ///
    /// SwiftTerm draws glyphs flush to its own bounds and offers no inset of its
    /// own, so without this the first column collides with the window edge and,
    /// in a split, with the divider. iTerm2 and Terminal.app both leave a
    /// margin. The wrapper stays transparent so the window's themed background
    /// shows through and the gap is invisible.
    private static func padded(_ terminal: NSView) -> NSView {
        let container = NSView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        return container
    }
}
