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
    struct Node: Codable {
        var type: String
        /// `NSUserInterfaceLayoutOrientation.rawValue`, groups only.
        var direction: Int?
        var children: [Node]?
        var cwd: String?
        var label: String?
    }

    var layout: Node
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

// MARK: - Tree <-> snapshot

extension PaneNode {
    /// Builds a snapshot node, preferring each pane's *live* directory.
    ///
    /// The Electron build needed a `before-quit` handler that re-read every
    /// PTY's cwd because the saved session held stale values; resolving at
    /// capture time makes that unnecessary.
    func snapshotNode(cwdForPane: (String) -> String?) -> SessionSnapshot.Node {
        switch kind {
        case .pane:
            return SessionSnapshot.Node(
                type: "pane",
                direction: nil,
                children: nil,
                cwd: paneId.flatMap(cwdForPane) ?? cwd,
                label: label
            )
        case .group:
            return SessionSnapshot.Node(
                type: "group",
                direction: direction?.rawValue,
                children: children.map { $0.snapshotNode(cwdForPane: cwdForPane) },
                cwd: nil,
                label: nil
            )
        }
    }

    /// Rebuilds a tree from a snapshot, minting fresh pane ids.
    ///
    /// Pane ids are runtime handles for PTYs, so a restored session must not
    /// reuse the old ones — the equivalent of `reassignPaneIds` in `App.tsx`.
    static func from(_ node: SessionSnapshot.Node, newPaneId: () -> String) -> PaneNode? {
        if node.type == "pane" {
            let pane = PaneNode.pane(paneId: newPaneId(), cwd: node.cwd)
            pane.label = node.label
            return pane
        }

        let children = (node.children ?? []).compactMap { PaneNode.from($0, newPaneId: newPaneId) }
        guard !children.isEmpty else { return nil }
        // A group that lost all but one child collapses, rather than restoring
        // a split with nothing on one side.
        guard children.count > 1 else { return children[0] }

        let orientation = NSUserInterfaceLayoutOrientation(rawValue: node.direction ?? 0) ?? .horizontal
        return .group(direction: orientation, children: children)
    }
}
