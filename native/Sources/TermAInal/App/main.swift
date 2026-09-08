import AppKit

// `TermAInal --check-ai` exercises the configured provider and exits. The AI
// paths are otherwise only reachable by driving the UI, which makes them
// awkward to verify; this keeps them testable from the command line.
if CommandLine.arguments.contains("--check-ai") {
    AIDiagnostics.runAndExit()
}

// SPM builds a bare executable, so the NSApplication lifecycle is set up by hand
// rather than via @NSApplicationMain.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
