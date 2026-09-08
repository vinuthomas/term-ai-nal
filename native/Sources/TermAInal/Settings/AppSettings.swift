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

/// One AI configuration. Two of these are held, so command generation and the
/// assistant can use different models.
///
/// The split exists because the two tasks have genuinely different needs, and
/// measurement bore that out: Apple's on-device 3B produced a wrong `ls` flag
/// but a correct diagnosis of a failing command, while a coder-tuned local model
/// was the reverse trade — accurate syntax at the cost of memory. Property names
/// match what the providers already read, so provider bodies are unaffected.
struct AIProfile: Codable, Equatable {
    var provider: String = "openai"
    var model: String = "gpt-4o"
    /// Ollama or any custom endpoint; empty means use the provider default.
    var baseUrl: String = ""
    /// `on-device` (local 3B) or `pcc` (Private Cloud Compute).
    var appleModel: String = "on-device"

    init(provider: String = "openai", model: String = "gpt-4o", baseUrl: String = "", appleModel: String = "on-device") {
        self.provider = provider
        self.model = model
        self.baseUrl = baseUrl
        self.appleModel = appleModel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AIProfile()
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? d.baseUrl
        appleModel = try c.decodeIfPresent(String.self, forKey: .appleModel) ?? d.appleModel
    }
}

/// Port of the `defaultSettings` object in `main.ts` — the single source of
/// truth for every persisted setting key.
///
/// `apiKey` is absent by design: it moves out of the settings file and into the
/// keychain (see `KeychainStore`), replacing Electron's `safeStorage` hex blob.
struct AppSettings: Codable {
    /// Generating shell commands: the palette (Cmd+Shift+P) and the task
    /// planner (Cmd+Shift+M). Accuracy of syntax matters most here.
    var commandProfile: AIProfile = AIProfile()
    /// The assistant sidebar's insights and questions. Explanation quality and
    /// low cost matter more than command syntax.
    var insightProfile: AIProfile = AIProfile()

    var fontSize: Double = 14
    /// Empty means auto-detect a Unicode-capable font stack.
    var fontFamily: String = ""
    var theme: String = "default"
    var restoreSession: Bool = false
    /// Where a new tab or split starts: `inherit` (the current pane's
    /// directory), `home`, or `custom`.
    var newPaneDirectory: String = "inherit"
    /// Used only when `newPaneDirectory` is `custom`.
    var newPaneCustomDirectory: String = ""

    // iTerm theme import (`parseItermTheme`) is dropped by decision, so the
    // `customTheme` / `customThemeName` keys are intentionally omitted. Built-in
    // themes only — see TerminalThemes.

    // Assistant sidebar
    var assistantEnabled: Bool = true
    /// `off`, `failures` or `all`. Defaults to failures: an observation after
    /// every successful command is mostly noise, and on metered or on-device
    /// models it is also a steady cost for little gain.
    var assistantInsights: String = "failures"
    var assistantSidebarWidth: Double = 340

    var mcpEnabled: Bool = true
    var mcpPort: Int = 57320
    /// Per-terminal in-memory buffer size; overflow spills to a temp file.
    var mcpBufferSizeKB: Int = 500
    /// When false, overflow is dropped instead of spilled.
    var mcpFileBufferEnabled: Bool = true
    var mcpFeatures: MCPFeatures = MCPFeatures()

    /// Only for reading a pre-split settings file; never encoded.
    private enum LegacyAIKeys: String, CodingKey {
        case provider, model, baseUrl, appleModel
    }

    static var defaults: AppSettings { AppSettings() }

    init() {}

    /// Every key falls back to its default so a settings file written by an
    /// older build still loads and picks up newly added keys. This is the
    /// equivalent of the `{ ...defaultSettings, ...data }` spread in
    /// `loadSettings()`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        // A file from before the split carries flat provider keys. Both roles
        // inherit them, so an upgrade changes nothing until the user chooses to
        // differ — surprising someone by silently moving one role to another
        // model would be worse than leaving them identical.
        let legacy = try? decoder.container(keyedBy: LegacyAIKeys.self)
        let inherited = AIProfile(
            provider: (try? legacy?.decodeIfPresent(String.self, forKey: .provider)) as? String ?? d.commandProfile.provider,
            model: (try? legacy?.decodeIfPresent(String.self, forKey: .model)) as? String ?? d.commandProfile.model,
            baseUrl: (try? legacy?.decodeIfPresent(String.self, forKey: .baseUrl)) as? String ?? d.commandProfile.baseUrl,
            appleModel: (try? legacy?.decodeIfPresent(String.self, forKey: .appleModel)) as? String ?? d.commandProfile.appleModel
        )
        commandProfile = try c.decodeIfPresent(AIProfile.self, forKey: .commandProfile) ?? inherited
        insightProfile = try c.decodeIfPresent(AIProfile.self, forKey: .insightProfile) ?? inherited
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        restoreSession = try c.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? d.restoreSession
        newPaneDirectory = try c.decodeIfPresent(String.self, forKey: .newPaneDirectory) ?? d.newPaneDirectory
        newPaneCustomDirectory = try c.decodeIfPresent(String.self, forKey: .newPaneCustomDirectory) ?? d.newPaneCustomDirectory
        assistantEnabled = try c.decodeIfPresent(Bool.self, forKey: .assistantEnabled) ?? d.assistantEnabled
        assistantInsights = try c.decodeIfPresent(String.self, forKey: .assistantInsights) ?? d.assistantInsights
        assistantSidebarWidth = try c.decodeIfPresent(Double.self, forKey: .assistantSidebarWidth) ?? d.assistantSidebarWidth
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

    /// API keys live in the keychain, keyed by *provider* rather than by role.
    ///
    /// A key belongs to a service, not to a task: with two profiles that may
    /// both point at OpenAI, storing per-role would mean entering the same key
    /// twice and having them drift.
    func apiKey(for provider: String) -> String {
        if let key = KeychainStore.get(account: "apiKey.\(provider)"), !key.isEmpty {
            return key
        }
        // Pre-split builds stored a single unqualified key. Read it through so
        // an upgrade does not appear to lose it.
        return KeychainStore.get(account: "apiKey") ?? ""
    }

    func setApiKey(_ key: String, for provider: String) {
        KeychainStore.set(key, account: "apiKey.\(provider)")
    }
}
