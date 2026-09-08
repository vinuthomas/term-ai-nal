import AppKit

/// Callbacks out of one accordion header. The header knows nothing about the
/// stack it lives in — no index, no sibling list — so the owner stays the single
/// source of truth for which pane is expanded, exactly as `TabBarView` leaves
/// tab ownership to its controller.
protocol AccordionHeaderDelegate: AnyObject {
    /// The header was clicked; the owner should expand this pane.
    func accordionHeaderDidActivate(_ header: AccordionHeader)
    /// The close control was clicked.
    func accordionHeaderDidRequestClose(_ header: AccordionHeader)
}

/// The title row above a pane in the vertical pane accordion: a disclosure
/// chevron, what the pane is running, its focus shortcut, and a close control.
///
/// This is chrome repeated once per pane, so it is deliberately compact — a
/// single line of 11pt text at `height` points. It is also deliberately
/// passive: `isExpanded` is a property the owner sets, never something the
/// header decides for itself, because expansion in an accordion is a
/// whole-stack decision (expanding one collapses the others).
final class AccordionHeader: NSView {
    weak var delegate: AccordionHeaderDelegate?

    /// Fixed row height for a collapsed pane; the owner lays out against this.
    static var height: CGFloat { 24 }

    /// What the pane is running, or its directory. Set frequently.
    var title: String = "" {
        didSet {
            guard title != oldValue else { return }
            titleField.stringValue = title
            // The label truncates, so the untruncated text has to be reachable.
            titleField.toolTip = title
        }
    }

    /// e.g. "⌘⌥1", or nil past the ninth pane.
    var shortcutHint: String? {
        didSet {
            guard shortcutHint != oldValue else { return }
            hintField.stringValue = shortcutHint ?? ""
            hintField.isHidden = shortcutHint == nil
        }
    }

    var isExpanded: Bool = false {
        didSet {
            guard isExpanded != oldValue else { return }
            refresh()
        }
    }

    /// Set by `PaneController` when MCP sends input to this pane while it is
    /// not the one being looked at — the only on-screen sign of that for a
    /// collapsed pane or one in a background tab. Cleared the moment the pane
    /// is expanded.
    var hasAgentActivity: Bool = false {
        didSet {
            guard hasAgentActivity != oldValue else { return }
            refresh()
        }
    }

    private let accentEdge = NSView()
    private let chevron = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let agentActivityDot = NSView()
    private let hintField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let bottomSeparator = NSView()

    private var isHovered = false
    private var theme: TerminalTheme = TerminalThemes.default
    private var palette: Palette { Palette(theme: theme) }

    // MARK: - Construction

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        wantsLayer = true

        accentEdge.wantsLayer = true
        accentEdge.translatesAutoresizingMaskIntoConstraints = false

        chevron.imageScaling = .scaleNone
        chevron.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        // Middle truncation keeps both ends of a path or command visible, which
        // is where the distinguishing part of a pane title usually lives.
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.translatesAutoresizingMaskIntoConstraints = false

        agentActivityDot.wantsLayer = true
        agentActivityDot.toolTip = "An MCP agent sent input here"
        agentActivityDot.isHidden = true
        agentActivityDot.translatesAutoresizingMaskIntoConstraints = false

        hintField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        hintField.alignment = .right
        hintField.isHidden = true
        hintField.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBar
        closeButton.imagePosition = .imageOnly
        closeButton.toolTip = "Close Pane"
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        bottomSeparator.wantsLayer = true
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(accentEdge)
        addSubview(chevron)
        addSubview(titleField)
        addSubview(agentActivityDot)
        addSubview(hintField)
        addSubview(closeButton)
        addSubview(bottomSeparator)

        // The close control is only *hidden*, never removed, so the title and
        // hint keep their widths on hover — text that reflows under the cursor
        // reads as a glitch.
        NSLayoutConstraint.activate([
            // Inset inside the rounded corners, or the clip eats its ends and
            // it reads as a rendering artefact instead of an indicator.
            accentEdge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            accentEdge.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            accentEdge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            accentEdge.widthAnchor.constraint(equalToConstant: 3),

            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),

            titleField.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: agentActivityDot.leadingAnchor, constant: -6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            agentActivityDot.trailingAnchor.constraint(equalTo: hintField.leadingAnchor, constant: -6),
            agentActivityDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            agentActivityDot.widthAnchor.constraint(equalToConstant: 6),
            agentActivityDot.heightAnchor.constraint(equalToConstant: 6),

            hintField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            hintField.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])

        // The title yields before the hint does: a shortcut is fixed-width and
        // its whole value is the information, whereas a title still reads
        // truncated.
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintField.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    // MARK: - Public API

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        refresh()
    }

    // MARK: - Appearance

    private func refresh() {
        let palette = self.palette

        // Expanded is carried by three cues, not just the chevron: a lifted
        // fill, the leading accent edge, and full-strength text.
        let fill = isExpanded ? palette.expandedFill : (isHovered ? palette.hoverFill : palette.collapsedFill)
        layer?.backgroundColor = fill.cgColor
        // Rounded and outlined so a row reads as a panel rather than a bar.
        // Full-width, square rows were indistinguishable from the tab bar above
        // and looked like a status bar below.
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = (isExpanded ? palette.accent : palette.separator).cgColor
        accentEdge.layer?.backgroundColor = palette.accent.cgColor
        accentEdge.layer?.cornerRadius = 1.5
        accentEdge.isHidden = !isExpanded
        // Redundant now the rows are separated panels with their own outline.
        bottomSeparator.isHidden = true

        let symbol = isExpanded ? "chevron.down" : "chevron.right"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isExpanded ? "Expanded" : "Collapsed")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))

        let text = isExpanded ? palette.expandedText : palette.collapsedText
        chevron.contentTintColor = text
        titleField.textColor = text
        hintField.textColor = isExpanded ? palette.expandedHint : palette.collapsedHint
        closeButton.contentTintColor = text

        agentActivityDot.layer?.cornerRadius = 3
        agentActivityDot.layer?.backgroundColor = palette.accent.cgColor
        // Expanding a pane clears the flag, so there is never anything to
        // show once it is the one on screen — showing it anyway would read
        // as "still happening" rather than "happened while you were away".
        agentActivityDot.isHidden = !hasAgentActivity || isExpanded

        // Shown on hover or when expanded: a close box on every row at all
        // times is noise on a stack of panes, and invites misclicks.
        closeButton.isHidden = !(isExpanded || isHovered)
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

    // The whole row activates. `closeButton` is an `NSButton` subview and
    // swallows its own clicks before they reach here, so a close can never also
    // fire an activate.
    override func mouseDown(with event: NSEvent) {
        delegate?.accordionHeaderDidActivate(self)
    }

    @objc private func close() {
        delegate?.accordionHeaderDidRequestClose(self)
    }
}

// MARK: - Palette

extension AccordionHeader {
    /// Header chrome derived from the terminal theme.
    ///
    /// Every step is a guaranteed contrast floor rather than a blend fraction:
    /// a proportional shift means something different on `#002b36` than on
    /// `#282a36`, and this app already shipped fixed blends once that left
    /// Solarized Dark's caption text under 2:1 against its 4.5:1 requirement.
    struct Palette {
        /// Fill behind a collapsed row.
        let collapsedFill: NSColor
        /// Fill behind a hovered but collapsed row.
        let hoverFill: NSColor
        /// Fill behind the expanded row, lifted clear of the collapsed ones.
        let expandedFill: NSColor
        let collapsedText: NSColor
        let expandedText: NSColor
        let collapsedHint: NSColor
        let expandedHint: NSColor
        let accent: NSColor
        let separator: NSColor

        init(theme: TerminalTheme) {
            let isDark = theme.background.relativeLuminance < 0.5
            let base = theme.background.shifted(towardLight: isDark, by: 0.05)
            let expanded = base.separated(from: base, byLuminance: 0.035)

            collapsedFill = base
            hoverFill = base.separated(from: base, byLuminance: 0.015)
            expandedFill = expanded
            separator = base.separated(from: base, byLuminance: 0.05)

            // 4.5:1 for the titles and 4.5:1 for the hints — both are small
            // text, so neither qualifies for the 3:1 large-text allowance. Each
            // is measured against the fill it actually sits on, which is why
            // there are two of each.
            collapsedText = theme.foreground.ensuringContrast(atLeast: 4.5, on: base)
            expandedText = theme.foreground.ensuringContrast(atLeast: 4.5, on: expanded)
            // The hint reads dimmer where the theme has the headroom for it,
            // but the floor wins: on a low-contrast theme it lands back at the
            // same strength as the title rather than below the floor.
            collapsedHint = theme.foreground.dimmed(towards: base, floor: 4.5)
            expandedHint = theme.foreground.dimmed(towards: expanded, floor: 4.5)

            // The accent edge is a non-text indicator, so 3:1 is the floor. The
            // theme's cursor colour is its own idea of "this is where you are".
            accent = theme.cursor.ensuringContrast(atLeast: 3.0, on: expanded)
        }
    }
}

// MARK: - Colour helpers

// Local copies: the equivalents in `TabBarView` and `AssistantSidebarView` are
// file-private, and hoisting them into `TerminalTheme.swift` would widen a file
// that is being rewritten alongside this one.
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

    /// A visually secondary version of this colour that still clears `floor`
    /// against `background`. The dimming is an aesthetic preference, the floor
    /// is not, so the result is re-raised if the blend undershot.
    func dimmed(towards background: NSColor, floor: CGFloat) -> NSColor {
        let dim = blended(withFraction: 0.30, of: background) ?? self
        return dim.ensuringContrast(atLeast: floor, on: background)
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
