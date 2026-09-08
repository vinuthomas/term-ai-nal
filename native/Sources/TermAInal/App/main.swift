import AppKit

// SPM builds a bare executable, so the NSApplication lifecycle is set up by hand
// rather than via @NSApplicationMain.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
