import Foundation

/// Resolves where a newly opened tab or split should start.
///
/// One preference covers both: a tab and a split are both "another shell,
/// opened from here", and having them disagree about the starting directory
/// would be arbitrary.
enum NewPaneDirectory {
    /// - Parameter inheriting: the directory of the pane the new one is being
    ///   opened from, when there is one.
    static func resolve(inheriting current: String?) -> String? {
        let settings = SettingsStore.shared.settings
        switch settings.newPaneDirectory {
        case "home":
            return NSHomeDirectory()
        case "custom":
            let path = (settings.newPaneCustomDirectory as NSString).expandingTildeInPath
            // Fall back to inheriting rather than failing to open, and rather
            // than dumping the user at `/` because a saved path moved.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return current }
            return path
        default:
            return current
        }
    }
}
