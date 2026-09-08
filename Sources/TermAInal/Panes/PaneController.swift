import AppKit

/// Owns a tab's panes and lays them out as a vertical accordion.
///
/// Panes are a flat, ordered list: one is expanded and shows its terminal, the
/// rest collapse to just their header. This replaced a recursive tree of split
/// groups and four split directions — that structure existed to describe
/// arbitrary nested splits, and with panes stacked in one direction there is
/// nothing for it to describe.
///
/// Terminal views live in `terminals`, keyed by pane id, and are *re-parented*
/// when the layout is rebuilt rather than recreated. That is not an
/// optimisation: recreating them kills the running shells.
final class PaneController: NSObject, AccordionHeaderDelegate {
    private(set) var panes: [TerminalPaneModel] = []
    private(set) var terminals: [String: TerminalPaneView] = [:]
    private(set) var expandedIndex: Int = 0

    /// Host view the accordion is mounted into.
    ///
    /// A subclass so the accordion reflows when the window resizes: rows are
    /// laid out by frame, so nothing reflows on its own the way Auto Layout
    /// would.
    let containerView = AccordionContainerView()

    var onActivePaneChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    /// Fires when the last pane has gone, so the owning tab can close itself.
    var onEmpty: (() -> Void)?

    private var headers: [String: AccordionHeader] = [:]

    // MARK: - Identity

    static func newPaneId() -> String {
        "pane-\(UUID().uuidString.prefix(8))"
    }

    var activePaneId: String {
        panes.indices.contains(expandedIndex) ? panes[expandedIndex].paneId : (panes.first?.paneId ?? "")
    }

    var activeTerminal: TerminalPaneView? { terminals[activePaneId] }

    var paneIds: [String] { panes.map(\.paneId) }

    /// The fuller form, for a window title: a whole path with home abbreviated,
    /// or whatever a program named itself.
    var windowTitle: String {
        guard let terminal = terminals[activePaneId] else { return "term-ai-nal" }
        if let title = terminal.reportedTitle, !title.isEmpty { return title }
        if let cwd = terminal.currentCwd { return Self.abbreviatingHome(cwd) }
        return "term-ai-nal"
    }

    /// The compact form, for a tab label: the last path component only.
    var displayTitle: String {
        let title = windowTitle
        guard title.contains("/") else { return title }
        let name = (title as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    private static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The title shown on one pane's header, independent of which is expanded.
    private func headerTitle(for pane: TerminalPaneModel) -> String {
        if let label = pane.label, !label.isEmpty { return label }
        guard let terminal = terminals[pane.paneId] else { return "shell" }
        if let title = terminal.reportedTitle, !title.isEmpty { return title }
        if let cwd = terminal.currentCwd { return Self.abbreviatingHome(cwd) }
        return "shell"
    }

    // MARK: - Init

    /// A fresh single-pane controller whose shell starts in `cwd`.
    convenience init(startingIn cwd: String?) {
        self.init(restoring: SessionSnapshot(
            tabs: [SessionSnapshot.Tab(panes: [SessionSnapshot.Pane(cwd: cwd, label: nil)], expanded: 0)],
            selected: 0
        ))
    }

    init(restoring snapshot: SessionSnapshot? = nil) {
        super.init()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.onLayout = { [weak self] in self?.layoutAccordion() }

        if let tab = snapshot?.tabs.first, !tab.panes.isEmpty {
            panes = tab.panes.map { TerminalPaneModel(paneId: Self.newPaneId(), cwd: $0.cwd, label: $0.label) }
            expandedIndex = min(max(0, tab.expanded), panes.count - 1)
        } else {
            panes = [TerminalPaneModel(paneId: Self.newPaneId())]
            expandedIndex = 0
        }
        rebuild()
    }

    // MARK: - Mutations

    /// Adds a pane below the expanded one and expands it.
    func addPane() {
        let inherited = NewPaneDirectory.resolve(
            inheriting: activeTerminal?.currentCwd ?? panes[safe: expandedIndex]?.cwd
        )
        let insertAt = min(expandedIndex + 1, panes.count)
        panes.insert(TerminalPaneModel(paneId: Self.newPaneId(), cwd: inherited), at: insertAt)
        expandedIndex = insertAt
        rebuild()
        onActivePaneChange?(activePaneId)
        onTitleChange?(displayTitle)
    }

    func closeActivePane() {
        // The last pane closing means the tab is done; the owner decides
        // whether that is allowed, since it knows how many tabs remain.
        guard panes.count > 1 else {
            onEmpty?()
            return
        }
        close(paneId: activePaneId)
    }

    private func close(paneId: String) {
        guard let index = panes.firstIndex(where: { $0.paneId == paneId }) else { return }
        guard panes.count > 1 else {
            onEmpty?()
            return
        }

        panes.remove(at: index)
        teardown(paneId: paneId)
        // Keep the selection where the eye is: the pane that took its place,
        // or the last one if it was the tail.
        expandedIndex = min(index, panes.count - 1)
        rebuild()
        onActivePaneChange?(activePaneId)
        onTitleChange?(displayTitle)
    }

    private func teardown(paneId: String) {
        terminals[paneId]?.terminate()
        terminals[paneId]?.removeFromSuperview()
        terminals.removeValue(forKey: paneId)
        headers[paneId]?.removeFromSuperview()
        headers.removeValue(forKey: paneId)
        OutputBuffer.shared.cleanup(paneId: paneId)
        CommandLog.shared.clear(paneId: paneId)
    }

    func expandPane(at index: Int) {
        guard panes.indices.contains(index), index != expandedIndex else {
            focusExpanded()
            return
        }
        expandedIndex = index
        rebuild()
        onActivePaneChange?(activePaneId)
        onTitleChange?(displayTitle)
    }

    /// `Cmd+Alt+1`…`9`.
    func focusPane(number: Int) {
        expandPane(at: number - 1)
    }

    func focusPane(paneId: String) {
        guard let index = panes.firstIndex(where: { $0.paneId == paneId }) else { return }
        expandPane(at: index)
    }

    // MARK: - Layout

    /// Rebuilds the stack, reusing terminal views and headers.
    ///
    /// Every collapsed pane contributes only its header height; the expanded one
    /// takes whatever is left. Frame-based rather than Auto Layout because the
    /// arithmetic is one expression and the views are reparented constantly.
    func rebuild() {
        containerView.subviews.forEach { $0.removeFromSuperview() }

        for (index, pane) in panes.enumerated() {
            let header = self.header(for: pane, index: index)
            header.isExpanded = index == expandedIndex
            header.title = headerTitle(for: pane)
            header.shortcutHint = index < 9 ? "\u{2318}\u{2325}\(index + 1)" : nil
            containerView.addSubview(header)

            let terminal = self.terminal(for: pane)
            if index == expandedIndex {
                containerView.addSubview(terminal)
            } else {
                terminal.removeFromSuperview()
            }
        }

        // Drop terminals whose panes are gone.
        let live = Set(paneIds)
        for paneId in terminals.keys where !live.contains(paneId) {
            teardown(paneId: paneId)
        }

        containerView.needsLayout = true
        layoutAccordion()
        focusExpanded()
    }

    /// The terminal is inset inside its row rather than filling it.
    ///
    /// SwiftTerm draws glyphs flush to its own bounds and offers no inset, so
    /// without this the first column collides with the window edge. The older
    /// split layout achieved the same thing with a padded wrapper view per
    /// pane; laying rows out by frame makes it an inset instead, which is why
    /// it went missing in that rewrite. `--check-accordion` asserts it now.
    static let terminalInset = NSSize(width: 8, height: 6)

    /// Gap between accordion rows.
    ///
    /// Rows are inset horizontally by the same amount as the terminal and
    /// separated vertically, so the stack reads as panels sitting *in* the
    /// tab's content area. Spanning the full width made an expanded header
    /// indistinguishable from the tab bar directly above it and a collapsed one
    /// look like a status bar — edge-to-edge is what chrome does.
    static let rowGap: CGFloat = 4

    /// Called by the host on resize, and after any rebuild.
    func layoutAccordion() {
        let bounds = containerView.bounds
        guard bounds.height > 0 else { return }

        let headerHeight = AccordionHeader.height
        // A single pane needs no header at all — one row of chrome describing
        // the only thing on screen is pure noise.
        let showHeaders = panes.count > 1
        let inset = Self.terminalInset
        let gap = Self.rowGap
        let chrome = showHeaders
            ? (headerHeight + gap) * CGFloat(panes.count) + gap
            : 0
        let terminalHeight = max(0, bounds.height - chrome)

        var y = bounds.maxY
        for (index, pane) in panes.enumerated() {
            if showHeaders {
                y -= gap + headerHeight
                headers[pane.paneId]?.isHidden = false
                headers[pane.paneId]?.frame = NSRect(
                    x: inset.width,
                    y: y,
                    width: max(0, bounds.width - inset.width * 2),
                    height: headerHeight
                )
            } else {
                headers[pane.paneId]?.isHidden = true
            }
            if index == expandedIndex, let terminal = terminals[pane.paneId] {
                // The row still consumes the full height; only the terminal
                // inside it is inset, so the stacking arithmetic is unaffected.
                y -= terminalHeight
                // With headers shown the row gaps already separate things, so
                // the terminal only needs its own vertical inset when it is
                // alone in the tab.
                let vertical = showHeaders ? 0 : inset.height
                terminal.frame = NSRect(
                    x: inset.width,
                    y: y + vertical,
                    width: max(0, bounds.width - inset.width * 2),
                    height: max(0, terminalHeight - vertical * 2)
                )
            }
        }
    }

    private func focusExpanded() {
        guard let terminal = activeTerminal else { return }
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    private func header(for pane: TerminalPaneModel, index: Int) -> AccordionHeader {
        if let existing = headers[pane.paneId] {
            existing.removeFromSuperview()
            return existing
        }
        let header = AccordionHeader(frame: .zero)
        header.delegate = self
        // The initializer paints with the default theme, so a new header has to
        // be told the current one or it arrives mismatched.
        header.applyTheme(TerminalThemes.theme(forKey: SettingsStore.shared.settings.theme))
        headers[pane.paneId] = header
        return header
    }

    private func terminal(for pane: TerminalPaneModel) -> TerminalPaneView {
        if let existing = terminals[pane.paneId] {
            existing.removeFromSuperview()
            return existing
        }

        let paneId = pane.paneId
        let terminal = TerminalPaneView(paneId: paneId, frame: .zero)
        terminal.onCwdChange = { [weak self, weak pane] directory in
            pane?.cwd = directory
            self?.paneTitleChanged(paneId)
        }
        terminal.onTitleChange = { [weak self] _ in
            self?.paneTitleChanged(paneId)
        }
        terminal.onOutput = { text in
            OutputBuffer.shared.append(paneId: paneId, text: text)
            CommandLog.shared.ingest(paneId: paneId, text: text)
        }
        terminal.onProcessExit = { [weak self] _ in
            // The shell exited on its own (`exit`, Ctrl-D).
            DispatchQueue.main.async { self?.close(paneId: paneId) }
        }
        terminals[paneId] = terminal
        applyAppearance(to: terminal)
        terminal.start(cwd: pane.cwd)
        return terminal
    }

    private func paneTitleChanged(_ paneId: String) {
        if let pane = panes.first(where: { $0.paneId == paneId }) {
            headers[paneId]?.title = headerTitle(for: pane)
        }
        if paneId == activePaneId { onTitleChange?(displayTitle) }
    }

    // MARK: - Appearance

    func applyAppearanceToAll() {
        let theme = TerminalThemes.theme(forKey: SettingsStore.shared.settings.theme)
        for terminal in terminals.values { applyAppearance(to: terminal) }
        for header in headers.values { header.applyTheme(theme) }
    }

    private func applyAppearance(to terminal: TerminalPaneView) {
        let settings = SettingsStore.shared.settings
        terminal.applyAppearance(
            theme: TerminalThemes.theme(forKey: settings.theme),
            fontFamily: settings.fontFamily,
            fontSize: settings.fontSize
        )
    }

    // MARK: - Session

    func captureSession() -> SessionSnapshot {
        SessionSnapshot(
            tabs: [SessionSnapshot.Tab(
                panes: panes.map {
                    SessionSnapshot.Pane(cwd: terminals[$0.paneId]?.currentCwd ?? $0.cwd, label: $0.label)
                },
                expanded: expandedIndex
            )],
            selected: 0
        )
    }

    /// Kills every shell here. Called when the owning tab closes.
    func terminateAll() {
        for paneId in Array(terminals.keys) { teardown(paneId: paneId) }
        panes.removeAll()
    }

    // MARK: - AccordionHeaderDelegate

    func accordionHeaderDidActivate(_ header: AccordionHeader) {
        guard let paneId = headers.first(where: { $0.value === header })?.key else { return }
        focusPane(paneId: paneId)
    }

    func accordionHeaderDidRequestClose(_ header: AccordionHeader) {
        guard let paneId = headers.first(where: { $0.value === header })?.key else { return }
        close(paneId: paneId)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}


/// The accordion's host view, which reports its own relayout.
///
/// Rows are positioned by frame — the heights are one expression (every
/// collapsed pane contributes its header, the expanded one takes the rest) and
/// the views are reparented on every rebuild, which Auto Layout handles poorly.
/// The cost is that resizing has to be observed rather than inherited.
final class AccordionContainerView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
