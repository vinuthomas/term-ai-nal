import Foundation

/// One pane in a tab's accordion.
///
/// Replaces the recursive `PaneNode` tree. Panes inside a tab are now a flat,
/// ordered list — a nested tree of groups and directions existed to describe
/// arbitrary splits, and once panes stack in one direction with one expanded
/// there is nothing left for it to describe. Roughly 120 lines of tree
/// manipulation and its `EvenSplitView` companion went with it.
final class TerminalPaneModel {
    let paneId: String
    /// Where the shell starts. Updated as it reports its directory, so a
    /// restored session lands where the pane was left.
    var cwd: String?
    /// User-assigned name, surfaced over MCP. Nothing sets it yet.
    var label: String?

    init(paneId: String, cwd: String? = nil, label: String? = nil) {
        self.paneId = paneId
        self.cwd = cwd
        self.label = label
    }
}
