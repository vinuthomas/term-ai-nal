import AppKit

/// A terminal colour scheme. Port of the `TerminalTheme` interface and the
/// `themes` record in the Electron renderer's `themes.ts`, narrowed to the four
/// built-ins the settings UI offers. The `.itermcolors` importer and the
/// `custom` theme slot are dropped by decision, so there is no runtime source of
/// themes beyond `TerminalThemes.all`.
///
/// In `themes.ts` every field but background/foreground is optional (`default`
/// sets only those two); here the palette is total, with anything a theme omits
/// filled from the standard xterm ANSI colours.
struct TerminalTheme {
    /// The value stored in `AppSettings.theme`.
    let key: String
    let displayName: String

    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor

    /// The 16 ANSI colours in wire order: black…white, then the bright eight.
    /// SwiftTerm's `installColors` requires exactly this count.
    let ansi: [NSColor]

    init(
        key: String,
        displayName: String,
        background: String,
        foreground: String,
        cursor: String? = nil,
        selection: String? = nil,
        black: String? = nil,
        red: String? = nil,
        green: String? = nil,
        yellow: String? = nil,
        blue: String? = nil,
        magenta: String? = nil,
        cyan: String? = nil,
        white: String? = nil,
        brightBlack: String? = nil,
        brightRed: String? = nil,
        brightGreen: String? = nil,
        brightYellow: String? = nil,
        brightBlue: String? = nil,
        brightMagenta: String? = nil,
        brightCyan: String? = nil,
        brightWhite: String? = nil
    ) {
        self.key = key
        self.displayName = displayName

        let fg = NSColor(hex: foreground) ?? .white
        self.background = NSColor(hex: background) ?? .black
        self.foreground = fg
        // xterm.js defaults the cursor to the foreground colour and, absent a
        // selection colour, draws a translucent wash over it.
        self.cursor = cursor.flatMap(NSColor.init(hex:)) ?? fg
        self.selection = selection.flatMap(NSColor.init(hex:)) ?? fg.withAlphaComponent(0.3)

        let names = [
            black, red, green, yellow, blue, magenta, cyan, white,
            brightBlack, brightRed, brightGreen, brightYellow,
            brightBlue, brightMagenta, brightCyan, brightWhite,
        ]
        self.ansi = zip(names, TerminalThemes.xtermANSIDefaults).map { hex, fallback in
            hex.flatMap(NSColor.init(hex:)) ?? fallback
        }
    }
}

enum TerminalThemes {
    /// The xterm palette, used wherever a theme leaves an ANSI slot unset.
    static let xtermANSIDefaults: [NSColor] = [
        "#000000", "#cd3131", "#0dbc79", "#e5e510",
        "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
        "#666666", "#f14c4c", "#23d18b", "#f5f543",
        "#3b8eea", "#d670d6", "#29b8db", "#ffffff",
    ].map { NSColor(hex: $0) ?? .black }

    static let `default` = TerminalTheme(
        key: "default",
        displayName: "Default",
        background: "#1e1e1e",
        foreground: "#ffffff"
    )

    static let dracula = TerminalTheme(
        key: "dracula",
        displayName: "Dracula",
        background: "#282a36",
        foreground: "#f8f8f2",
        cursor: "#f8f8f0",
        selection: "#44475a",
        black: "#21222c",
        red: "#ff5555",
        green: "#50fa7b",
        yellow: "#f1fa8c",
        blue: "#bd93f9",
        magenta: "#ff79c6",
        cyan: "#8be9fd",
        white: "#f8f8f2",
        brightBlack: "#6272a4",
        brightRed: "#ff6e6e",
        brightGreen: "#69ff94",
        brightYellow: "#ffffa5",
        brightBlue: "#d6acff",
        brightMagenta: "#ff92df",
        brightCyan: "#a4ffff",
        brightWhite: "#ffffff"
    )

    static let solarizedDark = TerminalTheme(
        key: "solarized-dark",
        displayName: "Solarized Dark",
        background: "#002b36",
        foreground: "#839496",
        cursor: "#839496",
        selection: "#073642",
        black: "#073642",
        red: "#dc322f",
        green: "#859900",
        yellow: "#b58900",
        blue: "#268bd2",
        magenta: "#d33682",
        cyan: "#2aa198",
        white: "#eee8d5",
        brightBlack: "#002b36",
        brightRed: "#cb4b16",
        brightGreen: "#586e75",
        brightYellow: "#657b83",
        brightBlue: "#839496",
        brightMagenta: "#6c71c4",
        brightCyan: "#93a1a1",
        brightWhite: "#fdf6e3"
    )

    static let oneDark = TerminalTheme(
        key: "one-dark",
        displayName: "One Dark",
        background: "#282c34",
        foreground: "#abb2bf",
        cursor: "#528bff",
        selection: "#3e4451",
        black: "#282c34",
        red: "#e06c75",
        green: "#98c379",
        yellow: "#e5c07b",
        blue: "#61afef",
        magenta: "#c678dd",
        cyan: "#56b6c2",
        white: "#abb2bf",
        brightBlack: "#5c6370",
        brightRed: "#e06c75",
        brightGreen: "#98c379",
        brightYellow: "#e5c07b",
        brightBlue: "#61afef",
        brightMagenta: "#c678dd",
        brightCyan: "#56b6c2",
        brightWhite: "#ffffff"
    )

    /// Stable display order for the settings picker.
    static let all: [TerminalTheme] = [`default`, dracula, solarizedDark, oneDark]

    static func theme(forKey key: String) -> TerminalTheme {
        all.first { $0.key == key } ?? `default`
    }
}

extension NSColor {
    /// Parses the `#rrggbb` form used throughout `themes.ts`. Tolerates a
    /// missing `#` and returns nil on anything else, so callers can substitute a
    /// palette default rather than trap.
    convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    /// 8-bit channels in sRGB, for handing colours to SwiftTerm's `Color`.
    var rgb8: (red: UInt16, green: UInt16, blue: UInt16) {
        let srgb = usingColorSpace(.sRGB) ?? self
        return (
            UInt16((srgb.redComponent * 255).rounded()),
            UInt16((srgb.greenComponent * 255).rounded()),
            UInt16((srgb.blueComponent * 255).rounded())
        )
    }
}
