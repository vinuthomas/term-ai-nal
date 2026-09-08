import AppKit

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
    private(set) var activePaneId: String

    /// Host view the layout is mounted into.
    let containerView = NSView()

    var onActivePaneChange: ((String) -> Void)?

    /// Restores `snapshot` when one is supplied and usable, otherwise starts
    /// with a single pane. Restoring happens before the first `rebuild()` so a
    /// throwaway shell is never spawned only to be killed.
    init(restoring snapshot: SessionSnapshot? = nil) {
        if let snapshot,
           let restored = PaneNode.from(snapshot.layout, newPaneId: Self.newPaneId),
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

    /// Snapshot of the current layout, with each pane's live directory.
    func captureSession() -> SessionSnapshot {
        SessionSnapshot(layout: root.snapshotNode { [weak self] paneId in
            self?.terminals[paneId]?.currentCwd
        })
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
        // Refuse to close the last pane; the window would be left empty.
        guard root.allPanes.count > 1, let current = root.findPane(paneId: activePaneId) else { return }

        let remaining = root.allPaneIds.filter { $0 != activePaneId }

        if let (parent, index) = root.findParent(of: current) {
            parent.children.remove(at: index)
        }
        root.pruneEmptyGroups()

        terminals[activePaneId]?.terminate()
        terminals[activePaneId]?.removeFromSuperview()
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
            let split = NSSplitView()
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

        if let existing = terminals[paneId] {
            existing.removeFromSuperview()
            return existing
        }

        let terminal = TerminalPaneView(paneId: paneId, frame: .zero)
        terminal.onCwdChange = { [weak node] directory in
            node?.cwd = directory
        }
        terminal.onOutput = { text in
            OutputBuffer.shared.append(paneId: paneId, text: text)
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
        return terminal
    }
}
