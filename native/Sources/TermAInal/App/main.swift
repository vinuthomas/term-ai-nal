import AppKit

// `TermAInal --check-ai` exercises the configured provider and exits. The AI
// paths are otherwise only reachable by driving the UI, which makes them
// awkward to verify; this keeps them testable from the command line.
if CommandLine.arguments.contains("--check-ai") {
    AIDiagnostics.runAndExit()
}

// `--check-contrast` audits the derived sidebar colours against their floors
// for every built-in theme, and exits non-zero on a violation. Theming has
// been a recurring source of unreadable output, so it is checked rather than
// eyeballed.
if CommandLine.arguments.contains("--check-contrast") {
    _ = NSApplication.shared
    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    func two(_ v: CGFloat) -> String { String(format: "%.2f", v) }

    print(pad("theme", 16) + pad("body", 8) + pad("dim", 8) + pad("cardΔ", 9) + pad("accent", 8) + "verdict")
    var allPass = true
    for theme in TerminalThemes.all {
        let palette = AssistantSidebarView.Palette(theme: theme)
        let body = palette.text.contrastRatio(against: palette.surfaceFill)
        let dim = palette.dimText.contrastRatio(against: palette.surfaceFill)
        let card = abs(palette.surfaceFill.relativeLuminance - palette.background.relativeLuminance)
        let accent = palette.failureAccent.contrastRatio(against: palette.background)
        let ok = body >= 4.5 && dim >= 4.5 && card >= 0.029 && accent >= 3.0
        allPass = allPass && ok
        print(pad(theme.key, 16) + pad(two(body), 8) + pad(two(dim), 8)
              + pad(String(format: "%.3f", card), 9) + pad(two(accent), 8)
              + (ok ? "PASS" : "FAIL"))
    }
    print("\nfloors: body >= 4.5, dim >= 4.5, cardΔ >= 0.029 luminance, accent >= 3.0")
    exit(allPass ? 0 : 1)
}

// `--check-titlebar` verifies the titlebar accessory gets a real width.
// NSTitlebarAccessoryViewController sizes its view from the frame and ignores
// Auto Layout's fittingSize, so a constraint-only container silently stayed
// 0pt wide and the button rendered invisibly.
if CommandLine.arguments.contains("--check-titlebar") {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.title = "~/code"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .visible
    window.contentView = NSView()

    // The shipped factory, not a copy of it.
    let accessory = AppDelegate.makeSidebarToggleAccessory(
        target: application,
        action: #selector(NSApplication.terminate(_:))
    )
    window.addTitlebarAccessoryViewController(accessory)
    window.center()
    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))

    let container = accessory.view
    let button = container.subviews.first
    print("accessories : \(window.titlebarAccessoryViewControllers.count)")
    print("container   : \(container.frame)")
    print("button      : \(button?.frame.debugDescription ?? "nil")")
    // The bug was a *zero* width, not a narrow one, so assert the invariant
    // rather than a magic number: the control has real width and the container
    // is wide enough to hold it.
    let buttonWidth = button?.frame.width ?? 0
    let ok = buttonWidth >= 20 && container.frame.width >= buttonWidth
    print(ok ? "\naccessory has a real width" : "\nZERO WIDTH — invisible")
    exit(ok ? 0 : 1)
}

if CommandLine.arguments.contains("--check-locale") {
    _ = NSApplication.shared
    LocaleDiagnostics.runAndExit()
}

if CommandLine.arguments.contains("--check-ctrld") {
    _ = NSApplication.shared
    SettingsStore.shared.load()
    func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    var lastTabClosed = false
    let tabs = TabController()
    tabs.onLastTabClosed = { lastTabClosed = true }
    tabs.restore(nil)
    pump(2.5)

    // A split pane must absorb its own Ctrl+D without taking the tab with it.
    tabs.activePanes?.splitActivePane(direction: .horizontal)
    pump(2.5)
    print("after split             : \(tabs.activePanes?.root.allPaneIds.count ?? 0) pane(s), \(tabs.tabs.count) tab(s)")
    tabs.activePanes?.terminals[tabs.activePaneId ?? ""]?.sendToShell("\u{04}")
    pump(3)
    print("after Ctrl+D in split   : \(tabs.activePanes?.root.allPaneIds.count ?? 0) pane(s), \(tabs.tabs.count) tab(s)")

    tabs.addTab()
    pump(2.5)
    print("tabs                    : \(tabs.tabs.count)")

    // Ctrl+D (EOF) into the frontmost shell.
    func sendEOF() {
        tabs.activePanes?.terminals[tabs.activePaneId ?? ""]?.sendToShell("\u{04}")
    }

    sendEOF(); pump(3)
    print("after Ctrl+D on tab 2   : \(tabs.tabs.count) tab(s), lastTabClosed=\(lastTabClosed)")

    sendEOF(); pump(3)
    print("after Ctrl+D on last    : \(tabs.tabs.count) tab(s), lastTabClosed=\(lastTabClosed)")
    print(lastTabClosed && tabs.tabs.isEmpty ? "\nsession ends cleanly" : "\nFAILED: last tab did not end the session")
    exit(lastTabClosed && tabs.tabs.isEmpty ? 0 : 1)
}

// SPM builds a bare executable, so the NSApplication lifecycle is set up by
// hand rather than via @NSApplicationMain.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
