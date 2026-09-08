import AppKit

/// One tab: a whole pane layout of its own.
///
/// A tab owns a `PaneController` rather than a single terminal, so splitting
/// still works *inside* a tab and none of the pane-tree behaviour had to be
/// rebuilt for this.
final class TerminalTab {
    let id: String = UUID().uuidString
    let panes: PaneController
    var title: String

    init(panes: PaneController, title: String) {
        self.panes = panes
        self.title = title
    }
}

/// Owns the tab set and slides between them.
///
/// The content area is a single horizontal strip holding every tab's view side
/// by side, offset by one viewport width per tab. Selecting a tab animates that
/// offset, so the outgoing tab travels left or right according to where the
/// incoming one sits in the order — which is the behaviour asked for, and falls
/// out of the layout rather than needing a bespoke transition per direction.
final class TabController: NSObject, TabBarViewDelegate {
    private(set) var tabs: [TerminalTab] = []
    private(set) var selectedIndex = 0

    /// Mounted by the app; holds the tab bar above the sliding strip.
    let containerView = NSView()

    private let tabBar = TabBarView()
    private let viewport = NSView()
    private let strip = NSView()
    private var stripOffset: NSLayoutConstraint!
    private var stripConstraints: [NSLayoutConstraint] = []
    private var tabBarHeight: NSLayoutConstraint!

    /// Notified when the focused pane changes for any reason — tab switch,
    /// split, close — so the MCP server and assistant stay pointed at the
    /// right shell.
    var onActivePaneChange: ((String) -> Void)?

    /// The frontmost tab's title, for the window title. Tabs carry their own
    /// labels, but the window needs to name the tab you are looking at — which
    /// is what every other terminal does and what went missing when shell
    /// titles were redirected to the tab bar.
    var onSelectedTitleChange: ((String) -> Void)?

    var activePaneId: String? { selectedTab?.panes.activePaneId }
    var selectedTab: TerminalTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }
    var activePanes: PaneController? { selectedTab?.panes }

    /// Every pane in every tab. MCP exposes them all: a pane in a background
    /// tab is still a live shell an agent may be driving.
    var allPanes: [(paneId: String, controller: PaneController)] {
        tabs.flatMap { tab in
            tab.panes.root.allPaneIds.map { ($0, tab.panes) }
        }
    }

    override init() {
        super.init()
        buildLayout()
    }

    // MARK: - Layout

    private func buildLayout() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        viewport.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        // Tabs waiting off-screen must not paint over the visible one.
        viewport.clipsToBounds = true

        tabBar.delegate = self
        containerView.addSubview(tabBar)
        containerView.addSubview(viewport)
        viewport.addSubview(strip)

        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        stripOffset = strip.leadingAnchor.constraint(equalTo: viewport.leadingAnchor)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: containerView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tabBarHeight,

            viewport.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            viewport.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            viewport.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            strip.topAnchor.constraint(equalTo: viewport.topAnchor),
            strip.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            stripOffset,
        ])
    }

    /// Recomputes the strip's contents and constraints from `tabs`.
    private func rebuildStrip() {
        NSLayoutConstraint.deactivate(stripConstraints)
        stripConstraints = []
        strip.subviews.forEach { $0.removeFromSuperview() }

        var previous: NSView?
        for tab in tabs {
            let view = tab.panes.containerView
            view.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(view)
            stripConstraints += [
                view.topAnchor.constraint(equalTo: strip.topAnchor),
                view.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
                // Each tab is exactly one viewport wide, which is what makes
                // the offset arithmetic below a simple multiple.
                view.widthAnchor.constraint(equalTo: viewport.widthAnchor),
                view.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? strip.leadingAnchor),
            ]
            previous = view
        }
        if let last = previous {
            stripConstraints.append(last.trailingAnchor.constraint(equalTo: strip.trailingAnchor))
        }
        NSLayoutConstraint.activate(stripConstraints)

        tabBar.setTabs(tabs.map(\.title), selected: selectedIndex)
        // A single tab needs no chrome; the bar collapses rather than showing
        // one lonely tab across the whole width.
        tabBarHeight.constant = tabs.count > 1 ? TabBarView.preferredHeight : 0
        tabBar.isHidden = tabs.count <= 1
        updateOffset(animated: false)
    }

    /// Offsets the strip so the selected tab fills the viewport.
    private func updateOffset(animated: Bool) {
        containerView.layoutSubtreeIfNeeded()
        let width = viewport.bounds.width
        guard width > 0 else { return }
        let target = -CGFloat(selectedIndex) * width

        guard animated else {
            stripOffset.constant = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            stripOffset.constant = target
            containerView.layoutSubtreeIfNeeded()
        }
    }

    /// The viewport width changes with the window, so the offset is a function
    /// of it and has to be recomputed rather than stored.
    func viewportResized() {
        updateOffset(animated: false)
    }

    // MARK: - Tabs

    @discardableResult
    func addTab(restoring snapshot: SessionSnapshot.Node? = nil, cwd: String? = nil) -> TerminalTab {
        let controller: PaneController
        if let snapshot {
            controller = PaneController(restoring: SessionSnapshot(tabs: [snapshot], selected: 0))
        } else {
            controller = PaneController(startingIn: cwd)
        }

        let tab = TerminalTab(panes: controller, title: controller.displayTitle)
        wire(tab)
        tabs.append(tab)
        selectedIndex = tabs.count - 1
        rebuildStrip()
        focusSelected()
        return tab
    }

    private func wire(_ tab: TerminalTab) {
        tab.panes.onActivePaneChange = { [weak self] paneId in
            guard let self, self.selectedTab === tab else { return }
            self.onActivePaneChange?(paneId)
        }
        tab.panes.onTitleChange = { [weak self, weak tab] title in
            guard let self, let tab else { return }
            tab.title = tab.panes.displayTitle
            _ = title
            self.tabBar.setTabs(self.tabs.map(\.title), selected: self.selectedIndex)
            if self.selectedTab === tab { self.notifySelectedTitle() }
        }
        tab.panes.onEmpty = { [weak self, weak tab] in
            guard let self, let tab, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTab(at: index)
        }
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        tabBar.setTabs(tabs.map(\.title), selected: selectedIndex)
        updateOffset(animated: true)
        focusSelected()
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (selectedIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (selectedIndex - 1 + tabs.count) % tabs.count)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        // Never leave the window empty; the app quits from the menu, not by
        // closing the last tab out from under itself.
        guard tabs.count > 1 else { return }

        let tab = tabs.remove(at: index)
        tab.panes.terminateAll()
        tab.panes.containerView.removeFromSuperview()

        selectedIndex = min(selectedIndex, tabs.count - 1)
        rebuildStrip()
        focusSelected()
    }

    func closeSelectedTab() {
        closeTab(at: selectedIndex)
    }

    /// Re-emits the current title. Needed because tabs are restored before the
    /// window exists, so the first notification would otherwise be dropped.
    func refreshSelectedTitle() {
        notifySelectedTitle()
    }

    private func notifySelectedTitle() {
        // The window gets the fuller path; the tab keeps its compact label.
        onSelectedTitleChange?(selectedTab?.panes.windowTitle ?? "term-ai-nal")
    }

    private func focusSelected() {
        guard let tab = selectedTab else { return }
        tab.panes.focusPane(paneId: tab.panes.activePaneId)
        onActivePaneChange?(tab.panes.activePaneId)
        notifySelectedTitle()
    }

    // MARK: - Session

    func captureSession() -> SessionSnapshot {
        SessionSnapshot(
            tabs: tabs.map { $0.panes.captureSession().tabs.first ?? SessionSnapshot.Node(type: "pane") },
            selected: selectedIndex
        )
    }

    func restore(_ snapshot: SessionSnapshot?) {
        let nodes = snapshot?.tabs ?? []
        if nodes.isEmpty {
            addTab()
        } else {
            for node in nodes { addTab(restoring: node) }
            selectedIndex = min(max(0, snapshot?.selected ?? 0), tabs.count - 1)
            rebuildStrip()
            focusSelected()
        }
    }

    func applyTheme(_ theme: TerminalTheme) {
        tabBar.applyTheme(theme)
        for tab in tabs { tab.panes.applyAppearanceToAll() }
    }

    // MARK: - TabBarViewDelegate

    func tabBar(_ bar: TabBarView, didSelect index: Int) {
        selectTab(at: index)
    }

    func tabBar(_ bar: TabBarView, didRequestClose index: Int) {
        closeTab(at: index)
    }

    func tabBarDidRequestNewTab(_ bar: TabBarView) {
        addTab(cwd: activePanes?.activeTerminal?.currentCwd)
    }
}
