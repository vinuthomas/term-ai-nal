import AppKit

/// Callbacks out of the tab bar. The view owns no tab state at all — it renders
/// the titles it was handed and reports what the user clicked, so the
/// controller stays the single source of truth for which tabs exist.
protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didRequestClose index: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
}

/// The horizontal terminal tab strip that sits below the window's titlebar.
///
/// Deliberately passive, like `AssistantSidebarView`: `setTabs` replaces the
/// whole set rather than exposing insert/remove, because the controller already
/// holds the ordered tab list and reconciling two copies of it is where tab
/// bars usually go wrong.
///
/// Tabs are laid out by hand in `layout()` rather than by an `NSStackView`:
/// they divide the bar evenly until they hit `minTabWidth` and then stop
/// shrinking and scroll, which is a single width calculation here but needs
/// per-item priority juggling in a stack view.
final class TabBarView: NSView {
    weak var delegate: TabBarViewDelegate?

    /// Height of the strip. Exposed so the controller can drive its own height
    /// constraint; a hidden bar is still asked to contribute zero.
    static var preferredHeight: CGFloat { 28 }

    /// Below this a title is unreadable, so the bar scrolls instead.
    private static let minTabWidth: CGFloat = 110
    private static let maxTabWidth: CGFloat = 240

    private let scrollView = NSScrollView()
    private let tabContainer = NSView()
    private let newTabButton = NSButton()
    private let bottomSeparator = NSView()

    private var tabViews: [TabItemView] = []
    private var selectedIndex = 0
    private var theme: TerminalTheme = TerminalThemes.default
    private var palette: Palette { Palette(theme: theme) }

    // MARK: - Construction

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        wantsLayer = true

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.documentView = tabContainer
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        newTabButton.isBordered = false
        newTabButton.bezelStyle = .accessoryBar
        newTabButton.imagePosition = .imageOnly
        newTabButton.toolTip = "New Tab"
        newTabButton.target = self
        newTabButton.action = #selector(newTab)
        newTabButton.translatesAutoresizingMaskIntoConstraints = false

        bottomSeparator.wantsLayer = true
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(newTabButton)
        addSubview(bottomSeparator)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor),

            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 24),

            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: - Public API

    func setTabs(_ titles: [String], selected: Int) {
        selectedIndex = titles.isEmpty ? 0 : min(max(selected, 0), titles.count - 1)

        // A single tab is the same information the window title already carries,
        // so the strip earns its height only from two tabs up.
        isHidden = titles.count <= 1

        if titles.count != tabViews.count {
            tabViews.forEach { $0.removeFromSuperview() }
            tabViews = titles.indices.map { _ in
                let tab = TabItemView()
                tab.onSelect = { [weak self] view in self?.report(view, close: false) }
                tab.onClose = { [weak self] view in self?.report(view, close: true) }
                tabContainer.addSubview(tab)
                return tab
            }
        }

        for (index, title) in titles.enumerated() {
            tabViews[index].configure(title: title, isSelected: index == selectedIndex)
        }

        applyPalette()
        needsLayout = true
    }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        applyPalette()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let count = CGFloat(tabViews.count)
        guard count > 0 else {
            tabContainer.frame = NSRect(origin: .zero, size: NSSize(width: 0, height: bounds.height))
            return
        }

        let available = scrollView.contentSize.width
        let even = available / count
        let width = min(Self.maxTabWidth, max(Self.minTabWidth, even))
        let total = width * count
        // Scroll only once the tabs genuinely overflow; otherwise the document
        // matches the clip view so nothing rubber-bands on a short strip.
        let height = bounds.height
        tabContainer.frame = NSRect(
            x: 0, y: 0,
            width: max(total, available),
            height: height
        )

        for (index, tab) in tabViews.enumerated() {
            tab.frame = NSRect(x: width * CGFloat(index), y: 0, width: width, height: height)
        }
    }

    // MARK: - Actions

    @objc private func newTab() {
        delegate?.tabBarDidRequestNewTab(self)
    }

    /// Index is resolved at click time from the view's position, so a stale
    /// captured index cannot outlive a `setTabs` that reordered the strip.
    private func report(_ view: TabItemView, close: Bool) {
        guard let index = tabViews.firstIndex(of: view) else { return }
        if close {
            delegate?.tabBar(self, didRequestClose: index)
        } else {
            delegate?.tabBar(self, didSelect: index)
        }
    }

    // MARK: - Theming

    private func applyPalette() {
        let palette = self.palette
        layer?.backgroundColor = palette.background.cgColor
        bottomSeparator.layer?.backgroundColor = palette.separator.cgColor
        newTabButton.contentTintColor = palette.dimText
        for tab in tabViews {
            tab.apply(palette)
        }
    }

    /// Tab-strip chrome derived from the terminal theme.
    ///
    /// Every step is a guaranteed contrast floor rather than a blend fraction:
    /// a proportional shift means something different on `#002b36` than on
    /// `#282a36`, and the assistant sidebar shipped once with fixed blends that
    /// left Solarized Dark's caption text at under 2:1.
    struct Palette {
        let background: NSColor
        /// Fill behind the selected tab, lifted clear of the strip itself.
        let selectedFill: NSColor
        /// Fill behind a hovered but unselected tab.
        let hoverFill: NSColor
        let selectedText: NSColor
        let dimText: NSColor
        let accent: NSColor
        let separator: NSColor

        init(theme: TerminalTheme) {
            let isDark = theme.background.relativeLuminance < 0.5
            let strip = theme.background.shifted(towardLight: isDark, by: 0.05)
            let selected = strip.separated(from: strip, byLuminance: 0.035)
            background = strip
            selectedFill = selected
            hoverFill = strip.separated(from: strip, byLuminance: 0.015)
            separator = strip.separated(from: strip, byLuminance: 0.05)

            // 4.5:1 for both title colours: tab titles are small text, so they
            // get the body floor rather than the 3:1 large-text allowance. Each
            // is measured against the fill it actually sits on.
            selectedText = theme.foreground.ensuringContrast(atLeast: 4.5, on: selected)
            dimText = theme.foreground
                .blended(withFraction: 0.30, of: strip)?
                .ensuringContrast(atLeast: 4.5, on: strip)
                ?? theme.foreground.ensuringContrast(atLeast: 4.5, on: strip)

            // The accent edge is a non-text indicator, so 3:1 is the floor. The
            // theme's cursor colour is its own idea of "this is where you are".
            accent = theme.cursor.ensuringContrast(atLeast: 3.0, on: selected)
        }
    }
}

// MARK: - Tab item

/// One tab: title, an accent edge when selected, and a close control that only
/// appears on hover or selection — a close box on every tab at all times reads
/// as clutter and invites misclicks.
private final class TabItemView: NSView {
    var onSelect: ((TabItemView) -> Void)?
    var onClose: ((TabItemView) -> Void)?

    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let accentEdge = NSView()

    private var isSelected = false
    private var isHovered = false
    private var palette: TabBarView.Palette?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true

        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        titleField.alignment = .center
        // Middle truncation keeps both ends of a path or command visible, which
        // is where the distinguishing part of a tab title usually lives.
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBar
        closeButton.imagePosition = .imageOnly
        closeButton.toolTip = "Close Tab"
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        if let symbol = closeButton.image {
            closeButton.image = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            )
        }

        accentEdge.wantsLayer = true
        accentEdge.isHidden = true
        accentEdge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleField)
        addSubview(closeButton)
        addSubview(accentEdge)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            accentEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentEdge.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentEdge.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(title: String, isSelected: Bool) {
        titleField.stringValue = title
        titleField.toolTip = title
        self.isSelected = isSelected
        refresh()
    }

    func apply(_ palette: TabBarView.Palette) {
        self.palette = palette
        refresh()
    }

    private func refresh() {
        guard let palette else { return }
        let fill: NSColor
        if isSelected {
            fill = palette.selectedFill
        } else if isHovered {
            fill = palette.hoverFill
        } else {
            fill = palette.background
        }
        layer?.backgroundColor = fill.cgColor
        accentEdge.layer?.backgroundColor = palette.accent.cgColor
        accentEdge.isHidden = !isSelected
        titleField.textColor = isSelected ? palette.selectedText : palette.dimText
        closeButton.contentTintColor = isSelected ? palette.selectedText : palette.dimText
        closeButton.isHidden = !(isSelected || isHovered)
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refresh()
    }

    // MARK: - Clicks

    // The close button is an `NSButton` subview and swallows its own clicks, so
    // selecting on `mouseDown` here cannot double-fire with a close.
    override func mouseDown(with event: NSEvent) {
        onSelect?(self)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onClose?(self)
    }

    @objc private func close() {
        onClose?(self)
    }
}

// MARK: - Colour helpers

private extension NSColor {
    /// Nudges a colour towards white or black. On a dark theme surfaces lift
    /// towards white, on a light theme they sink towards black, so the same
    /// layering reads correctly either way.
    func shifted(towardLight: Bool, by amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: towardLight ? .white : .black) ?? self
    }

    /// Pushes this colour away from `background` until it reaches `ratio`.
    /// A fixed blend cannot work across themes — Solarized Dark's foreground is
    /// deliberately low-contrast against its own background to begin with — so
    /// the target is a floor, walked towards rather than assumed.
    func ensuringContrast(atLeast ratio: CGFloat, on background: NSColor) -> NSColor {
        guard contrastRatio(against: background) < ratio else { return self }

        let towardLight = background.relativeLuminance < 0.5
        var amount: CGFloat = 0.05
        while amount <= 1.0 {
            let candidate = shifted(towardLight: towardLight, by: amount)
            if candidate.contrastRatio(against: background) >= ratio { return candidate }
            amount += 0.05
        }
        // Unreachable target, e.g. a mid-grey background: take the extreme.
        return towardLight ? .white : .black
    }

    /// Lifts this colour away from `other` until their luminance differs enough
    /// to read as a distinct surface. On near-black backgrounds a proportional
    /// blend produces almost no visible step at all.
    func separated(from other: NSColor, byLuminance delta: CGFloat) -> NSColor {
        let towardLight = other.relativeLuminance < 0.5
        var amount: CGFloat = 0
        var candidate = self
        while amount <= 1.0 {
            candidate = shifted(towardLight: towardLight, by: amount)
            if abs(candidate.relativeLuminance - other.relativeLuminance) >= delta { return candidate }
            amount += 0.02
        }
        return candidate
    }
}
