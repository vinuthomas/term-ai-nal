import Foundation

/// Per-tool MCP toggles — port of the nested `mcpFeatures` object in
/// `defaultSettings` (`main.ts`). Gates `handleMcpToolCall` dispatch.
struct MCPFeatures: Codable {
    var listTerminals: Bool = true
    var getTerminalOutput: Bool = true
    var getActiveTerminalOutput: Bool = true
    var sendInputToTerminal: Bool = true

    init(
        listTerminals: Bool = true,
        getTerminalOutput: Bool = true,
        getActiveTerminalOutput: Bool = true,
        sendInputToTerminal: Bool = true
    ) {
        self.listTerminals = listTerminals
        self.getTerminalOutput = getTerminalOutput
        self.getActiveTerminalOutput = getActiveTerminalOutput
        self.sendInputToTerminal = sendInputToTerminal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MCPFeatures()
        listTerminals = try c.decodeIfPresent(Bool.self, forKey: .listTerminals) ?? d.listTerminals
        getTerminalOutput = try c.decodeIfPresent(Bool.self, forKey: .getTerminalOutput) ?? d.getTerminalOutput
        getActiveTerminalOutput = try c.decodeIfPresent(Bool.self, forKey: .getActiveTerminalOutput) ?? d.getActiveTerminalOutput
        sendInputToTerminal = try c.decodeIfPresent(Bool.self, forKey: .sendInputToTerminal) ?? d.sendInputToTerminal
    }
}

/// Port of the `defaultSettings` object in `main.ts` — the single source of
/// truth for every persisted setting key.
///
/// `apiKey` is absent by design: it moves out of the settings file and into the
/// keychain (see `KeychainStore`), replacing Electron's `safeStorage` hex blob.
struct AppSettings: Codable {
    var provider: String = "openai"
    var model: String = "gpt-4o"
    /// Ollama or any custom endpoint; empty means use the provider default.
    var baseUrl: String = ""
    /// `on-device` (local 3B) or `pcc` (Private Cloud Compute).
    var appleModel: String = "on-device"
    var fontSize: Double = 14
    /// Empty means auto-detect a Unicode-capable font stack.
    var fontFamily: String = ""
    var theme: String = "default"
    var restoreSession: Bool = false

    // iTerm theme import (`parseItermTheme`) is dropped by decision, so the
    // `customTheme` / `customThemeName` keys are intentionally omitted. Built-in
    // themes only — see TerminalThemes.

    var mcpEnabled: Bool = true
    var mcpPort: Int = 57320
    /// Per-terminal in-memory buffer size; overflow spills to a temp file.
    var mcpBufferSizeKB: Int = 500
    /// When false, overflow is dropped instead of spilled.
    var mcpFileBufferEnabled: Bool = true
    var mcpFeatures: MCPFeatures = MCPFeatures()

    static var defaults: AppSettings { AppSettings() }

    init() {}

    /// Every key falls back to its default so a settings file written by an
    /// older build still loads and picks up newly added keys. This is the
    /// equivalent of the `{ ...defaultSettings, ...data }` spread in
    /// `loadSettings()`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? d.baseUrl
        appleModel = try c.decodeIfPresent(String.self, forKey: .appleModel) ?? d.appleModel
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        restoreSession = try c.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? d.restoreSession
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? d.mcpEnabled
        mcpPort = try c.decodeIfPresent(Int.self, forKey: .mcpPort) ?? d.mcpPort
        mcpBufferSizeKB = try c.decodeIfPresent(Int.self, forKey: .mcpBufferSizeKB) ?? d.mcpBufferSizeKB
        mcpFileBufferEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpFileBufferEnabled) ?? d.mcpFileBufferEnabled
        mcpFeatures = try c.decodeIfPresent(MCPFeatures.self, forKey: .mcpFeatures) ?? d.mcpFeatures
    }
}

/// Port of `loadSettings` / `saveSettings` in `main.ts`, including the 0o600
/// file mode. The settings directory stands in for Electron's
/// `app.getPath('userData')`.
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var settings: AppSettings = .defaults

    private init() {}

    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// Deliberately *not* `term-ai-nal/`.
    ///
    /// That directory is the live Electron app's `userData`, holding its own
    /// `settings.json` and `session.json`. `save()` writes only the keys this
    /// struct knows about, so sharing the file would silently strip `apiKey`,
    /// `customTheme` and `customThemeName` and break the shipping app. The two
    /// stay separate until Electron is retired.
    var settingsURL: URL {
        let dir = supportDirectory.appendingPathComponent("term-ai-nal-native", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    /// The Electron app's settings file. Read once, never written.
    private var electronSettingsURL: URL {
        supportDirectory
            .appendingPathComponent("term-ai-nal", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Any failure — missing file, unreadable, malformed JSON — yields defaults
    /// rather than throwing, so a corrupt file can never block startup.
    ///
    /// On first run the Electron config is imported so provider, model, theme
    /// and MCP preferences carry over. Tolerant decoding drops the keys this
    /// build does not have (`customTheme`, `apiKey`) without complaint; the
    /// original file is left untouched.
    func load() {
        if let decoded = decode(from: settingsURL) {
            settings = decoded
            return
        }
        if let imported = decode(from: electronSettingsURL) {
            settings = imported
            save(imported)
            return
        }
        settings = .defaults
    }

    private func decode(from url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    @discardableResult
    func save(_ newSettings: AppSettings) -> Bool {
        settings = newSettings
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(newSettings) else { return false }

        let url = settingsURL
        do {
            try data.write(to: url, options: .atomic)
            // An atomic write replaces the inode, so the mode has to be
            // reapplied every time rather than set once at creation.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Lives in the keychain, not `settings.json`.
    var apiKey: String {
        get { KeychainStore.get(account: "apiKey") ?? "" }
        set { KeychainStore.set(newValue, account: "apiKey") }
    }
}
