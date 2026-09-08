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
        startProcess(
            executable: Self.loginShell,
            args: ["--login"],
            environment: Self.childEnvironment(),
            currentDirectory: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// Preference order copied from `DEFAULT_FONT_FAMILY` in `TerminalPane.tsx`.
    ///
    /// Nerd Font variants come first because prompts like Powerlevel10k draw
    /// their separators and icons from the Unicode private use area. The system
    /// monospaced font contains none of them, so falling straight back to it
    /// renders those glyphs as replacement boxes — which is exactly what
    /// dropping this stack during the port caused.
    private static let fontFallbacks = [
        // Nerd Font variants — best Unicode plus icon coverage.
        "MesloLGS NF", "Hack Nerd Font Mono", "FiraCode Nerd Font Mono",
        "JetBrainsMono Nerd Font Mono", "CaskaydiaCove Nerd Font Mono",
        "SauceCodePro Nerd Font Mono",
        // Cross-platform developer fonts.
        "Fira Code", "JetBrains Mono", "Cascadia Code", "Cascadia Mono",
        // macOS system fonts.
        "Menlo", "Monaco", "SF Mono",
    ]

    /// Resolves an explicit family, else the first installed fallback, else the
    /// system monospaced font. `NSFont(name:)` accepts family names, returning
    /// the regular face.
    static func resolveFont(family: String, size: CGFloat) -> NSFont {
        let requested = family.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requested.isEmpty, let font = NSFont(name: requested, size: size) {
            return font
        }
        for candidate in fontFallbacks {
            if let font = NSFont(name: candidate, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The child shell inherits the app's full environment.
    ///
    /// `Terminal.getEnvironmentVariables` deliberately returns a minimal set —
    /// TERM, COLORTERM, LANG and a few of USER/HOME/LOGNAME, with PATH
    /// explicitly excluded — which is not what a terminal emulator should hand
    /// its shell. The Electron build spawned with `{...process.env}`, and iTerm2
    /// and Terminal.app inherit likewise; anything less makes the user's shell
    /// startup behave differently here than everywhere else.
    ///
    /// Concretely, a missing `SHELL` made zsh startup scripts take a bash code
    /// path and emit `(eval):type: bad option: -t`, which then tripped
    /// Powerlevel10k's instant-prompt console-output warning. `SHELL` is set
    /// explicitly because a GUI launch via launchd may not provide one.
    static func childEnvironment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["SHELL"] = loginShell
        // Only a fallback: an inherited locale is the user's own choice, but
        // without any locale tools like vi emit non-UTF-8 sequences.
        if environment["LANG"] == nil, environment["LC_ALL"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment.map { "\($0.key)=\($0.value)" }
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
        font = Self.resolveFont(family: fontFamily, size: CGFloat(fontSize))

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
