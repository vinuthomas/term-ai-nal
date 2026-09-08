import AppKit

/// Serialised pane layout, persisted between launches.
///
/// Port of the `session.json` handling in `main.ts` (`saveSession`,
/// `loadSession`, `clearSession`). One structural difference: the Electron
/// version stored the layout tree and a parallel `cwds` array, because pane ids
/// were reassigned on restore and could not be used as keys. Here each pane
/// carries its own directory inline, which removes the index-alignment bug
/// class that the separate array invited.
struct SessionSnapshot: Codable {
    struct Pane: Codable {
        var cwd: String?
        var label: String?
    }

    struct Tab: Codable {
        var panes: [Pane] = []
        /// Which pane is expanded in the accordion.
        var expanded: Int = 0

        init(panes: [Pane], expanded: Int) {
            self.panes = panes
            self.expanded = expanded
        }

        init(from decoder: Decoder) throws {
            // A tab written before the accordion is a nested split tree, not a
            // list. Flatten it: the tree's shape described splits that no
            // longer exist, but the panes and their directories still matter.
            if let legacy = try? LegacyNode(from: decoder) {
                panes = legacy.flattened()
                expanded = 0
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            panes = try c.decodeIfPresent([Pane].self, forKey: .panes) ?? []
            expanded = try c.decodeIfPresent(Int.self, forKey: .expanded) ?? 0
        }
    }

    var tabs: [Tab] = []
    var selected: Int = 0

    init(tabs: [Tab], selected: Int) {
        self.tabs = tabs
        self.selected = selected
    }

    /// Read-only, for sessions written before tabs existed.
    private enum LegacyKeys: String, CodingKey {
        case layout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try? c.decodeIfPresent([Tab].self, forKey: .tabs) ?? [], !decoded.isEmpty {
            tabs = decoded
            selected = try c.decodeIfPresent(Int.self, forKey: .selected) ?? 0
            return
        }
        // Pre-tabs: a single `layout` tree becomes one tab.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let node = try legacy.decode(LegacyNode.self, forKey: .layout)
        tabs = [Tab(panes: node.flattened(), expanded: 0)]
        selected = 0
    }
}

/// The old recursive split tree. Decoded only, never written — it exists so a
/// session file from a build with nested splits still restores its panes.
private struct LegacyNode: Codable {
    var type: String = "pane"
    var direction: Int?
    var children: [LegacyNode]?
    var cwd: String?
    var label: String?

    /// Depth-first, which is the order the panes appeared on screen.
    func flattened() -> [SessionSnapshot.Pane] {
        if let children, !children.isEmpty {
            return children.flatMap { $0.flattened() }
        }
        guard type == "pane" else { return [] }
        return [SessionSnapshot.Pane(cwd: cwd, label: label)]
    }
}

enum SessionStore {
    private static var sessionURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("term-ai-nal-native", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    static func save(_ snapshot: SessionSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: sessionURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)
    }

    static func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: sessionURL)
    }
}
