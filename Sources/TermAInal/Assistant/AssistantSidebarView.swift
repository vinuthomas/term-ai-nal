import AppKit

/// Callbacks out of the sidebar. Everything the user can initiate leaves the
/// view immediately; the sidebar never talks to `AIService` itself, so it stays
/// testable and the coordinator keeps sole ownership of request lifetimes.
protocol AssistantSidebarDelegate: AnyObject {
    /// User submitted a free-form question.
    func assistantSidebar(_ sidebar: AssistantSidebarView, didAsk question: String)
    /// User clicked the header's close control.
    /// User clicked "Explain the last command".
    func assistantSidebarDidRequestExplainLast(_ sidebar: AssistantSidebarView)
}

/// The right-hand AI assistant sidebar: a transcript of automatic command
/// insights and question/answer turns, plus an input row.
///
/// Deliberately passive. It renders what it is handed and reports what the user
/// did — command observation, provider calls and collapse/expand all live in the
/// coordinator. Entries are individual subviews in an `NSStackView` rather than
/// runs in one text view, because each kind carries its own accent, caption and
/// font and would otherwise need a hand-maintained attributed-string model.
final class AssistantSidebarView: NSView {
    weak var delegate: AssistantSidebarDelegate?

    /// Oldest entries are dropped past this many. A long session would
    /// otherwise accumulate views forever, and Auto Layout cost grows with
    /// them even when they are scrolled out of sight.
    private static let maxEntries = 200

    private let titleLabel = NSTextField(labelWithString: "Assistant")
    private let explainButton = NSButton()
    private let headerSeparator = NSBox()
    private let footerSeparator = NSBox()

    private let scrollView = NSScrollView()
    private let transcript = NSStackView()

    private let input = NSTextField()
    private let sendButton = NSButton()
    private let spinner = NSProgressIndicator()

    /// The rendered entries, in display order, so the cap can trim the front.
    private var entryViews: [NSView] = []

    private var theme: TerminalTheme = TerminalThemes.default

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

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        explainButton.title = "Explain Last"
        explainButton.toolTip = "Explain the last command"
        explainButton.bezelStyle = .accessoryBarAction
        explainButton.controlSize = .small
        explainButton.font = .systemFont(ofSize: 11)
        explainButton.target = self
        explainButton.action = #selector(explainLast)

        for separator in [headerSeparator, footerSeparator] {
            separator.boxType = .separator
        }

        transcript.orientation = .vertical
        transcript.alignment = .leading
        transcript.spacing = 10
        transcript.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        // Grow downward from the top so a near-empty transcript sits at the top
        // of the scroll view instead of being stretched to fill it.
        transcript.setHuggingPriority(.defaultHigh, for: .vertical)

        let clip = FlippedClipContentView()
        scrollView.contentView = clip
        scrollView.documentView = transcript
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        input.placeholderString = "Ask about this terminal…"
        input.font = .systemFont(ofSize: 12)
        // The field is single-line but tolerates long questions: it scrolls
        // horizontally rather than truncating what the user typed.
        input.usesSingleLineMode = false
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        input.target = self
        input.action = #selector(submit)

        sendButton.title = "Send"
        // Same bezel as "Explain Last". A plain push button drew no visible
        // bezel against a themed background, leaving Send as bare text.
        // Deliberately not given a Return key equivalent: as the window's
        // default button it would fire on Return while typing in the terminal.
        sendButton.bezelStyle = .accessoryBarAction
        sendButton.controlSize = .small
        sendButton.target = self
        sendButton.action = #selector(submit)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let header = NSStackView(views: [titleLabel, NSView(), explainButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)

        let footer = NSStackView(views: [input, spinner, sendButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, headerSeparator, scrollView, footerSeparator, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headerSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Pinning the stack's width to the clip view is what makes entry
            // labels wrap instead of demanding unbounded width.
            transcript.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])

        let preferredWidth = widthAnchor.constraint(equalToConstant: 340)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
    }

    // MARK: - Transcript API

    func appendQuestion(_ text: String) {
        append(entry(
            label: "You",
            labelColor: palette.dimText,
            body: text,
            bodyColor: palette.text,
            accent: palette.questionAccent,
            fill: palette.raisedFill
        ))
    }

    func appendAnswer(_ text: String) {
        append(entry(
            label: "Assistant",
            labelColor: palette.dimText,
            body: text,
            bodyColor: palette.text,
            accent: palette.answerAccent,
            fill: palette.surfaceFill
        ))
    }

    func appendInsight(command: String, body: String, succeeded: Bool) {
        append(entry(
            label: succeeded ? "Insight" : "Insight · failed",
            labelColor: palette.dimText,
            body: body,
            bodyColor: palette.text,
            accent: succeeded ? palette.successAccent : palette.failureAccent,
            fill: palette.surfaceFill,
            caption: command
        ))
    }

    func appendError(_ text: String) {
        append(entry(
            label: "Problem",
            labelColor: palette.failureAccent,
            body: text,
            bodyColor: palette.text,
            accent: palette.failureAccent,
            fill: palette.surfaceFill
        ))
    }

    // MARK: - State

    func setBusy(_ busy: Bool) {
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        input.isEnabled = !busy
        sendButton.isEnabled = !busy
        explainButton.isEnabled = !busy
    }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        let palette = self.palette

        layer?.backgroundColor = palette.background.cgColor
        scrollView.backgroundColor = palette.background
        // A themed background means the scrollers must be told which way to
        // contrast; AppKit otherwise picks from the window's appearance.
        scrollView.scrollerKnobStyle = palette.isDark ? .light : .dark
        titleLabel.textColor = palette.text
        input.textColor = palette.text
        input.backgroundColor = palette.raisedFill

        // Existing entries were coloured with the old palette, so re-render.
        for view in entryViews {
            (view as? ThemedEntryView)?.apply(palette)
        }
    }

    func focusInput() {
        window?.makeFirstResponder(input)
    }

    // MARK: - Actions

    @objc private func submit() {
        let question = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        input.stringValue = ""
        delegate?.assistantSidebar(self, didAsk: question)
    }

    @objc private func explainLast() {
        delegate?.assistantSidebarDidRequestExplainLast(self)
    }

    // MARK: - Entry rendering

    private func append(_ view: NSView) {
        transcript.addView(view, in: .bottom)
        entryViews.append(view)

        while entryViews.count > Self.maxEntries {
            let stale = entryViews.removeFirst()
            transcript.removeView(stale)
        }

        // The scroll position is only meaningful once the new entry has been
        // measured, so defer the jump to after this layout pass.
        DispatchQueue.main.async { [weak self] in
            self?.scrollToBottom()
        }
    }

    private func scrollToBottom() {
        layoutSubtreeIfNeeded()
        guard let document = scrollView.documentView else { return }
        let bottom = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// One transcript row: an accent stripe, a small kind label, an optional
    /// monospaced command caption, and the wrapped body.
    private func entry(
        label: String,
        labelColor: NSColor,
        body: String,
        bodyColor: NSColor,
        accent: NSColor,
        fill: NSColor,
        caption: String? = nil
    ) -> NSView {
        let view = ThemedEntryView(
            label: label,
            body: body,
            caption: caption,
            role: .init(labelColor: labelColor, bodyColor: bodyColor, accent: accent, fill: fill)
        )
        view.apply(palette)
        return view
    }

    // MARK: - Palette

    private var palette: Palette { Palette(theme: theme) }

    /// Sidebar chrome colours, all derived from the terminal theme so the
    /// sidebar reads as part of the same window regardless of whether the
    /// theme is dark or light. Nothing here is hardcoded to a dark background.
    struct Palette {
        let isDark: Bool
        let background: NSColor
        /// Entry card fill — a slight lift out of the sidebar background.
        let surfaceFill: NSColor
        /// A stronger lift, for the input field and the user's own turns.
        let raisedFill: NSColor
        let text: NSColor
        let dimText: NSColor
        let questionAccent: NSColor
        let answerAccent: NSColor
        let successAccent: NSColor
        let failureAccent: NSColor

        init(theme: TerminalTheme) {
            let base = theme.background
            isDark = base.perceivedLuminance < 0.5

            // Every step below is a guaranteed minimum rather than a fixed
            // blend fraction, because a proportional shift means something
            // different on #002b36 than on #282a36 — and on the former it meant
            // nothing at all.
            let sidebar = base.shifted(towardLight: isDark, by: 0.05)
            background = sidebar
            surfaceFill = sidebar.separated(from: sidebar, byLuminance: 0.030)
            raisedFill = surfaceFill.separated(from: surfaceFill, byLuminance: 0.035)

            // 4.5:1 is the WCAG floor for body-size text; the labels and
            // captions are small, so they get the same floor rather than the
            // 3:1 allowed for large text.
            text = theme.foreground.ensuringContrast(atLeast: 4.5, on: surfaceFill)
            dimText = theme.foreground
                .blended(withFraction: 0.30, of: surfaceFill)?
                .ensuringContrast(atLeast: 4.5, on: surfaceFill)
                ?? text

            // ANSI slots carry the theme's own idea of these hues; bright
            // variants are used so accents survive a light background too.
            // 3:1 is the floor for a non-text indicator such as the stripe.
            let ansi = theme.ansi
            func accent(_ index: Int, fallback: NSColor) -> NSColor {
                let colour = ansi.indices.contains(index) ? ansi[index] : fallback
                return colour.ensuringContrast(atLeast: 3.0, on: sidebar)
            }
            questionAccent = theme.cursor.ensuringContrast(atLeast: 3.0, on: sidebar)
            answerAccent = accent(12, fallback: .systemBlue)
            successAccent = accent(10, fallback: .systemGreen)
            failureAccent = accent(9, fallback: .systemRed)
        }
    }
}

// MARK: - Entry view

/// A transcript row that can be recoloured in place when the theme changes.
private final class ThemedEntryView: NSView {
    struct Role {
        let labelColor: NSColor
        let bodyColor: NSColor
        let accent: NSColor
        let fill: NSColor
    }

    private let role: Role
    private let stripe = NSView()
    private let card = NSView()
    private let labelField: NSTextField
    private let captionField: NSTextField?
    private let bodyField: NSTextField

    init(label: String, body: String, caption: String?, role: Role) {
        self.role = role
        labelField = NSTextField(labelWithString: label)
        bodyField = NSTextField(wrappingLabelWithString: body)
        captionField = caption.map { NSTextField(wrappingLabelWithString: $0) }
        super.init(frame: .zero)

        labelField.font = .systemFont(ofSize: 10, weight: .semibold)

        bodyField.font = .systemFont(ofSize: 12)
        bodyField.isSelectable = true

        captionField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        captionField?.isSelectable = true
        // Commands are the one place truncation is worse than a long row.
        captionField?.maximumNumberOfLines = 3

        card.wantsLayer = true
        card.layer?.cornerRadius = 5
        stripe.wantsLayer = true
        stripe.layer?.cornerRadius = 1.5

        let text = NSStackView(views: [labelField] + [captionField, bodyField].compactMap { $0 })
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(text)

        for subview in [stripe, card] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripe.topAnchor.constraint(equalTo: topAnchor),
            stripe.bottomAnchor.constraint(equalTo: bottomAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 3),

            card.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            text.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func apply(_ palette: AssistantSidebarView.Palette) {
        card.layer?.backgroundColor = role.fill.cgColor
        stripe.layer?.backgroundColor = role.accent.cgColor
        labelField.textColor = role.labelColor
        bodyField.textColor = role.bodyColor
        captionField?.textColor = palette.dimText
    }
}

// MARK: - Helpers

/// A flipped clip view so the transcript stack starts at the top and the
/// newest entry lands at the bottom, matching how the scroll offset is set.
private final class FlippedClipContentView: NSClipView {
    override var isFlipped: Bool { true }
}

private extension NSColor {
    /// Rec. 709 luma, used only to decide whether a theme is dark.
    var perceivedLuminance: CGFloat {
        let srgb = usingColorSpace(.sRGB) ?? self
        return 0.2126 * srgb.redComponent
            + 0.7152 * srgb.greenComponent
            + 0.0722 * srgb.blueComponent
    }

    /// Nudges a colour towards white or black by `amount`. Used to build the
    /// sidebar's greys out of the theme background: on a dark theme surfaces
    /// lift towards white, on a light theme they sink towards black, so the
    /// same layering reads correctly either way.
    func shifted(towardLight: Bool, by amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: towardLight ? .white : .black) ?? self
    }

    /// Pushes this colour away from `background` until it reaches `ratio`.
    ///
    /// Fixed blend fractions cannot work across themes: Solarized Dark's
    /// foreground (#839496 on #002b36) is deliberately low-contrast to begin
    /// with, so blending it 42% further toward the background — which is what
    /// the caption and label colour used to do — left roughly 1.8:1 and the
    /// labels were effectively invisible. Enforcing a floor instead adapts to
    /// whatever the theme provides.
    func ensuringContrast(atLeast ratio: CGFloat, on background: NSColor) -> NSColor {
        guard contrastRatio(against: background) < ratio else { return self }

        // Move towards whichever extreme is further from the background.
        let towardLight = background.relativeLuminance < 0.5
        var candidate = self
        var amount: CGFloat = 0.05
        while amount <= 1.0 {
            candidate = shifted(towardLight: towardLight, by: amount)
            if candidate.contrastRatio(against: background) >= ratio { return candidate }
            amount += 0.05
        }
        // Unreachable target (a mid-grey background): take the extreme.
        return towardLight ? .white : .black
    }

    /// Lifts this colour away from `other` until their luminance differs enough
    /// to read as a distinct surface. On near-black backgrounds a proportional
    /// blend produces almost no visible step, which is why the entry cards were
    /// indistinguishable from the sidebar behind them.
    func separated(from other: NSColor, byLuminance delta: CGFloat) -> NSColor {
        let towardLight = other.relativeLuminance < 0.5
        var candidate = self
        var amount: CGFloat = 0
        while amount <= 1.0 {
            candidate = shifted(towardLight: towardLight, by: amount)
            if abs(candidate.relativeLuminance - other.relativeLuminance) >= delta { return candidate }
            amount += 0.02
        }
        return candidate
    }
}
