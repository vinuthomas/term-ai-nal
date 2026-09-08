import AppKit

/// Direct port of the `LayoutNode` tree in the Electron renderer (`App.tsx`).
/// A node is either a `group` (a split with a direction and children) or a
/// `pane` (a leaf that owns one terminal).
final class PaneNode {
    enum Kind {
        case group
        case pane
    }

    let id: String = UUID().uuidString
    var kind: Kind

    // group
    var direction: NSUserInterfaceLayoutOrientation?
    var children: [PaneNode] = []

    // pane
    var paneId: String?
    var cwd: String?
    var paneNumber: Int?
    var label: String?

    private init(kind: Kind) {
        self.kind = kind
    }

    static func pane(paneId: String, cwd: String? = nil, paneNumber: Int? = nil) -> PaneNode {
        let node = PaneNode(kind: .pane)
        node.paneId = paneId
        node.cwd = cwd
        node.paneNumber = paneNumber
        return node
    }

    static func group(direction: NSUserInterfaceLayoutOrientation, children: [PaneNode]) -> PaneNode {
        let node = PaneNode(kind: .group)
        node.direction = direction
        node.children = children
        return node
    }
}

// MARK: - Tree helpers
//
// These mirror the pure helper functions at the top of `App.tsx`
// (findNodeByPaneId, collectPaneIds, getMaxPaneNumber, reassignPaneIds).

extension PaneNode {
    /// All pane ids in depth-first order — the order pane numbers are assigned in.
    var allPaneIds: [String] {
        switch kind {
        case .pane:
            return paneId.map { [$0] } ?? []
        case .group:
            return children.flatMap(\.allPaneIds)
        }
    }

    var allPanes: [PaneNode] {
        switch kind {
        case .pane:
            return [self]
        case .group:
            return children.flatMap(\.allPanes)
        }
    }

    func findPane(paneId target: String) -> PaneNode? {
        allPanes.first { $0.paneId == target }
    }

    func findPane(number: Int) -> PaneNode? {
        allPanes.first { $0.paneNumber == number }
    }

    /// Locates the parent group holding `node`, plus the index within it.
    func findParent(of node: PaneNode) -> (parent: PaneNode, index: Int)? {
        guard kind == .group else { return nil }
        if let index = children.firstIndex(where: { $0 === node }) {
            return (self, index)
        }
        for child in children {
            if let hit = child.findParent(of: node) { return hit }
        }
        return nil
    }

    /// Renumbers panes depth-first so `Cmd+1`…`Cmd+9` stay stable after a
    /// split or close, matching `reassignPaneIds`.
    func renumberPanes() {
        var next = 1
        for pane in allPanes {
            pane.paneNumber = next
            next += 1
        }
    }

    /// Collapses groups left holding a single child after a pane is removed.
    func pruneEmptyGroups() {
        guard kind == .group else { return }
        for child in children { child.pruneEmptyGroups() }
        children.removeAll { $0.kind == .group && $0.children.isEmpty }

        // A group with one child is redundant: absorb that child in place.
        if children.count == 1, let only = children.first {
            kind = only.kind
            direction = only.direction
            children = only.children
            paneId = only.paneId
            cwd = only.cwd
            paneNumber = only.paneNumber
            label = only.label
        }
    }
}
