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

    /// Last title the shell set via OSC 0/2.
    private(set) var reportedTitle: String?

    var onOutput: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
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
        // Bundled with the app, so this is the only entry guaranteed to
        // resolve. Everything after it is a courtesy to whatever the user
        // already installed and preferred.
        "JetBrainsMonoNL Nerd Font Mono",
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

    /// The environment handed to a pane's shell.
    ///
    /// Built from the user record and the system, and deliberately **not** from
    /// this process's own environment.
    ///
    /// The first attempt here inherited everything, which leaked the launching
    /// process's session state: started from a terminal running Claude Code,
    /// every pane carried `CLAUDE_CODE_CHILD_SESSION`, so a `claude` started
    /// inside one believed it was a nested child and stopped saving
    /// transcripts. `CLAUDE_CODE_MESSAGING_TOKEN` is a credential besides.
    ///
    /// The second attempt scrubbed a denylist of known offenders, which is the
    /// wrong shape. The same class covers Gemini CLI's `GEMINI_CLI`, Codex's
    /// `CODEX_SANDBOX` — where a stale value could persuade a tool it is
    /// already sandboxed — `TMUX`, `STY`, every host terminal's `GHOSTTY_*` /
    /// `KITTY_*` / `WEZTERM_*` / `VSCODE_*`, `TERMINFO`, `SSH_TTY`, `SHLVL`,
    /// direnv's bookkeeping, and whatever is written next year. A list that has
    /// to be complete to be correct will not stay complete.
    ///
    /// Inheriting nothing costs less than it appears to, because the child is a
    /// **login** shell: `/etc/zprofile` (via `path_helper`), `~/.zprofile` and
    /// `~/.zshrc` rebuild PATH and the user's own exports regardless. A pane
    /// therefore looks identical whether the app was opened from Finder or from
    /// a shell, which is the property that was missing.
    ///
    /// The trade-off, stated plainly: a variable placed in the GUI session with
    /// `launchctl setenv` and never exported from a shell profile will no
    /// longer reach a pane. `SSH_AUTH_SOCK` is carried over as the single
    /// exception — the agent socket comes from the login session, cannot be
    /// derived, and losing it breaks commit signing and pushes.
    static func childEnvironment() -> [String] {
        var environment: [String: String] = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": loginShell,
            // A seed only: `path_helper` in /etc/zprofile rebuilds PATH from
            // /etc/paths and /etc/paths.d, and the user's profile extends it.
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": preferredLocaleIdentifier(),
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            // Announce ourselves rather than passing on whoever launched us, so
            // shell configuration can branch on the real host terminal.
            "TERM_PROGRAM": "term-ai-nal",
            "TERM_PROGRAM_VERSION": Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        ]
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            environment["SSH_AUTH_SOCK"] = socket
        }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// The user's locale as a POSIX identifier. With no locale at all, tools
    /// like vi emit sequences that are not UTF-8 friendly.
    private static func preferredLocaleIdentifier() -> String {
        let identifier = Locale.current.identifier
            .split(separator: "@").first
            .map(String.init) ?? ""
        let normalised = identifier.replacingOccurrences(of: "-", with: "_")
        // Refuse anything that is not a plain language_REGION pair rather than
        // handing the shell a locale it cannot resolve.
        let looksPosix = normalised.count >= 5 && normalised.contains("_")
        return (looksPosix ? normalised : "en_US") + ".UTF-8"
    }

    /// The user's real login shell, from the passwd record.
    ///
    /// Taken from the user record rather than an inherited `SHELL`, which
    /// describes whichever shell happened to launch the app and was absent
    /// altogether under a GUI launch — the original cause of the
    /// `(eval):type: bad option: -t` failure.
    static var loginShell: String {
        if let record = getpwuid(getuid()), let shell = record.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/bin/zsh"
    }

    /// Writes to the PTY. Used by the AI review overlay on Execute and, later,
    /// by the MCP `send_input_to_terminal` tool.
    func sendToShell(_ text: String) {
        let bytes = Array(text.utf8)
        process.send(data: bytes[...])
    }

    func updateReportedTitle(_ title: String) {
        reportedTitle = title
        onTitleChange?(title)
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
        // Goes to the tab label rather than the window title: with tabs the
        // window name is no longer a single shell's business.
        owner?.updateReportedTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        owner?.updateReportedCwd(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        owner?.onProcessExit?(exitCode)
    }
}
