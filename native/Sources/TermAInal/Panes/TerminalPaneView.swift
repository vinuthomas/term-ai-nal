import AppKit
import SwiftTerm

/// One terminal pane. Subclasses SwiftTerm's `LocalProcessTerminalView` so that
/// every byte arriving from the PTY can be tapped for the MCP output buffer
/// before it reaches the emulator — the Swift equivalent of the `appendToBuffer`
/// call inside `createPty`'s `onData` handler in `main.ts`.
final class TerminalPaneView: LocalProcessTerminalView {
    let paneId: String

    /// Last directory reported by the shell via OSC 7, if it reports at all.
    ///
    /// zsh does not emit OSC 7 without shell integration, so this stays nil on a
    /// stock setup — prefer `currentCwd`, which falls back to the kernel.
    private(set) var reportedCwd: String?

    /// The pane's working directory: OSC 7 when the shell reports it, otherwise
    /// read from the child process directly.
    var currentCwd: String? {
        reportedCwd ?? ProcessCwd.lookup(pid: process.shellPid)
    }

    /// `LocalProcessTerminalView` already implements the delegate methods
    /// non-openly (it consumes them from `TerminalViewDelegate`), so the view
    /// cannot also declare conformance to `LocalProcessTerminalViewDelegate`.
    /// A separate relay object receives them and forwards here.
    private let callbackRelay = PaneProcessRelay()

    var onOutput: ((String) -> Void)?
    var onCwdChange: ((String) -> Void)?
    var onProcessExit: ((Int32?) -> Void)?

    init(paneId: String, frame: CGRect) {
        self.paneId = paneId
        super.init(frame: frame)
        processDelegate = callbackRelay
        callbackRelay.owner = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Starts the login shell. Matches the Electron spawn: `zsh --login` with a
    /// 256-colour, truecolor-capable environment.
    func start(cwd: String?) {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("COLORTERM=truecolor")
        startProcess(
            executable: Self.loginShell,
            args: ["--login"],
            environment: environment,
            currentDirectory: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    static var loginShell: String {
        // Respect the user's shell, falling back to zsh as the Electron build did.
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Writes to the PTY. Used by the AI review overlay on Execute and, later,
    /// by the MCP `send_input_to_terminal` tool.
    func sendToShell(_ text: String) {
        let bytes = Array(text.utf8)
        process.send(data: bytes[...])
    }

    func updateReportedCwd(_ directory: String) {
        // OSC 7 carries a file:// URL including the hostname — macOS's
        // /etc/zshrc `update_terminal_cwd` emits e.g.
        // file://host/Users/me — so normalise to a plain, percent-decoded
        // path before anything downstream (split inheritance, AI prompt
        // context, MCP metadata) sees it.
        let normalized = URL(string: directory)?.path
        reportedCwd = (normalized?.isEmpty == false) ? normalized : directory
        onCwdChange?(reportedCwd ?? directory)
    }

    // MARK: - Appearance

    /// Applies a theme and font. Replaces the xterm.js `theme`/`fontSize`/
    /// `fontFamily` options passed to the `Terminal` constructor in
    /// `TerminalPane.tsx`.
    func applyAppearance(theme: TerminalTheme, fontFamily: String, fontSize: Double) {
        let size = CGFloat(fontSize)
        // An unset or unresolvable family must not be fatal: the Electron build's
        // DEFAULT_FONT_FAMILY stack existed for Unicode coverage, and the system
        // mono font is the native equivalent.
        font = NSFont(name: fontFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        installColors(theme.ansi.map { color in
            let (r, g, b) = color.rgb8
            return SwiftTerm.Color(red8: r, green8: g, blue8: b)
        })

        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        caretColor = theme.cursor
        selectedTextBackgroundColor = theme.selection

        needsDisplay = true
    }

    /// Pastes a clipboard image as an inline image, returning false when the
    /// clipboard holds no image.
    ///
    /// Port of `pasteImageToTerminal`, which used xterm.js's image addon. Here
    /// the iTerm2 OSC 1337 `File=` sequence is fed straight to the emulator,
    /// which SwiftTerm renders natively. It deliberately does not go to the
    /// PTY: this is a display action, and the shell has no idea an image
    /// arrived — the same tradeoff the Electron build made.
    func pasteImageFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            return false
        }

        let payload = png.base64EncodedString()
        feed(text: "\u{1b}]1337;File=inline=1;preserveAspectRatio=1;size=\(png.count):\(payload)\u{07}\r\n")
        return true
    }

    // MARK: - Output tap

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if let text = String(bytes: slice, encoding: .utf8) {
            onOutput?(text)
        }
    }
}

/// Receives `LocalProcessTerminalViewDelegate` callbacks on behalf of
/// `TerminalPaneView`, which cannot conform to the protocol itself.
private final class PaneProcessRelay: NSObject, LocalProcessTerminalViewDelegate {
    weak var owner: TerminalPaneView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm has already pushed the new winsize to the PTY; nothing to add.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        source.window?.title = title.isEmpty ? "term-ai-nal" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        owner?.updateReportedCwd(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        owner?.onProcessExit?(exitCode)
    }
}
