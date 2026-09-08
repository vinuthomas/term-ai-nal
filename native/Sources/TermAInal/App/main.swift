import AppKit

// `TermAInal --check-ai` exercises the configured provider and exits. The AI
// paths are otherwise only reachable by driving the UI, which makes them
// awkward to verify; this keeps them testable from the command line.
if CommandLine.arguments.contains("--check-ai") {
    AIDiagnostics.runAndExit()
}

// SPM builds a bare executable, so the NSApplication lifecycle is set up by hand
// rather than via @NSApplicationMain.
if CommandLine.arguments.contains("--check-contrast") {
    _ = NSApplication.shared
    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    func two(_ v: CGFloat) -> String { String(format: "%.2f", v) }

    print(pad("theme", 16) + pad("body", 8) + pad("dim", 8) + pad("cardΔ", 9) + pad("accent", 8) + "verdict")
    var allPass = true
    for theme in TerminalThemes.all {
        let p = AssistantSidebarView.Palette(theme: theme)
        let body = p.text.contrastRatio(against: p.surfaceFill)
        let dim = p.dimText.contrastRatio(against: p.surfaceFill)
        let card = abs(p.surfaceFill.relativeLuminance - p.background.relativeLuminance)
        let accent = p.failureAccent.contrastRatio(against: p.background)
        let ok = body >= 4.5 && dim >= 4.5 && card >= 0.029 && accent >= 3.0
        allPass = allPass && ok
        print(pad(theme.key, 16) + pad(two(body), 8) + pad(two(dim), 8)
              + pad(String(format: "%.3f", card), 9) + pad(two(accent), 8)
              + (ok ? "PASS" : "FAIL"))
    }
    print("\nfloors: body >= 4.5, dim >= 4.5, cardΔ >= 0.029 luminance, accent >= 3.0")
    exit(allPass ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
