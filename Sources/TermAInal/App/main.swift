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

    // A second pane must absorb its own Ctrl+D without taking the tab with it.
    tabs.activePanes?.addPane()
    pump(2.5)
    print("after new pane          : \(tabs.activePanes?.paneIds.count ?? 0) pane(s), \(tabs.tabs.count) tab(s)")
    tabs.activePanes?.terminals[tabs.activePaneId ?? ""]?.sendToShell("\u{04}")
    pump(3)
    print("after Ctrl+D in pane    : \(tabs.activePanes?.paneIds.count ?? 0) pane(s), \(tabs.tabs.count) tab(s)")

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

// `--check-cloud` exercises the Anthropic and Gemini providers against
// `Scripts/mock-ai-api.py`, which must already be running. They cannot be
// reached without paid keys, so this is the only coverage their request shape
// has: auth header, schema placement, and that the reply decodes.
if CommandLine.arguments.contains("--check-cloud") {
    _ = NSApplication.shared
    func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    let mock = "http://127.0.0.1:8788/v1/mock"

    for provider in ["anthropic", "gemini"] {
        // Stash and restore any real key rather than clobbering it.
        let existing = SettingsStore.shared.apiKey(for: provider)
        SettingsStore.shared.setApiKey("mock-key-not-real", for: provider)
        defer { SettingsStore.shared.setApiKey(existing, for: provider) }

        // Empty model on purpose: this exercises each provider's *default*,
        // which is the value a new user actually gets.
        let profile = AIProfile(provider: provider, model: "", baseUrl: mock)
        guard let impl = AIService.provider(for: profile) else { print("\(provider): no provider"); continue }
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            do {
                let s = try await impl.suggestCommand(request: "list files by size", cwd: "/tmp")
                print("  \(provider.padding(toLength: 10, withPad: " ", startingAt: 0)) -> command=\(s.command.debugDescription) explanation=\(s.explanation.debugDescription)")
            } catch {
                print("  \(provider.padding(toLength: 10, withPad: " ", startingAt: 0)) -> FAILED \(error.localizedDescription)")
            }
        }
        while sem.wait(timeout: .now() + 0.1) == .timedOut { pump(0.1) }
        SettingsStore.shared.setApiKey(existing, for: provider)
    }
    exit(0)
}

// `--check-accordion` covers the pane accordion: that expanding a pane does not
// recreate the terminals (which would kill the running shells), that only the
// expanded pane's terminal is in the hierarchy, and that a session round-trips
// including the older nested-split format.
if CommandLine.arguments.contains("--check-accordion") {
    _ = NSApplication.shared
    SettingsStore.shared.load()
    func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    var failures = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let panes = PaneController()
    let host = NSView()
    host.addSubview(panes.containerView)
    NSLayoutConstraint.activate([
        panes.containerView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        panes.containerView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        panes.containerView.topAnchor.constraint(equalTo: host.topAnchor),
        panes.containerView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    pump(2)

    panes.addPane(); pump(1.5)
    panes.addPane(); pump(1.5)
    check("three panes", panes.paneIds.count == 3, "\(panes.paneIds.count)")
    check("newest is expanded", panes.expandedIndex == 2, "index \(panes.expandedIndex)")

    let firstId = panes.paneIds[0]
    let firstTerminal = panes.terminals[firstId]
    let thirdId = panes.paneIds[2]

    // Only the expanded pane's terminal should be mounted.
    let mounted = panes.containerView.subviews.compactMap { $0 as? TerminalPaneView }.map(\.paneId)
    check("only expanded terminal mounted", mounted == [thirdId], "\(mounted)")

    // Expanding runs rebuild(); terminals must survive it.
    panes.expandPane(at: 0); pump(1)
    check("expand switches active", panes.activePaneId == firstId)
    check("terminal object preserved", panes.terminals[firstId] === firstTerminal)
    check("its shell still running", firstTerminal?.process.running == true)
    let mounted2 = panes.containerView.subviews.compactMap { $0 as? TerminalPaneView }.map(\.paneId)
    check("mounted follows expansion", mounted2 == [firstId], "\(mounted2)")

    // Padding: the terminal must not touch the container edges. This has
    // regressed twice — once absent entirely, once dropped in the accordion
    // rewrite — so it is asserted rather than eyeballed.
    if let expanded = panes.terminals[panes.activePaneId] {
        let bounds = panes.containerView.bounds
        let frame = expanded.frame
        let left = frame.minX
        let right = bounds.maxX - frame.maxX
        check("terminal inset from edges", left >= 4 && right >= 4,
              "left \(Int(left)), right \(Int(right))")
        check("terminal not wider than container", frame.width <= bounds.width)
    } else {
        check("terminal inset from edges", false, "no expanded terminal")
    }

    // Headers: one per pane, stacked, non-zero height.
    let headers = panes.containerView.subviews.compactMap { $0 as? AccordionHeader }
    check("one header per pane", headers.count == 3, "\(headers.count)")
    check("headers have height", headers.allSatisfy { $0.frame.height >= 20 })
    let ys = headers.map { Int($0.frame.minY) }
    check("headers do not overlap", Set(ys).count == ys.count, "\(ys)")

    // Session round trip in the new flat format.
    let snap = panes.captureSession()
    check("captured 3 panes", snap.tabs.first?.panes.count == 3)
    check("captured expansion", snap.tabs.first?.expanded == 0)
    let restored = PaneController(restoring: snap); pump(2)
    check("restored 3 panes", restored.paneIds.count == 3, "\(restored.paneIds.count)")
    check("restored expansion", restored.expandedIndex == 0)
    check("fresh pane ids", Set(restored.paneIds).isDisjoint(with: Set(panes.paneIds)))

    // The older nested-split session format must flatten, not fail.
    let legacy = """
    {"tabs":[{"type":"group","direction":0,"children":[
      {"type":"pane","cwd":"/tmp","label":"a"},
      {"type":"group","direction":1,"children":[
        {"type":"pane","cwd":"/usr","label":"b"},
        {"type":"pane","cwd":"/var","label":"c"}]}]}],"selected":0}
    """
    if let data = legacy.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
        let cwds = decoded.tabs.first?.panes.map { $0.cwd ?? "?" } ?? []
        check("legacy tree flattens", cwds == ["/tmp", "/usr", "/var"], "\(cwds)")
    } else {
        check("legacy tree flattens", false, "decode failed")
    }

    panes.terminateAll(); restored.terminateAll()
    print(failures == 0 ? "\nall accordion checks pass" : "\n\(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

// SPM builds a bare executable, so the NSApplication lifecycle is set up by
// hand rather than via @NSApplicationMain.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
