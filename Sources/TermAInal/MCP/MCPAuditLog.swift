import Foundation

/// Append-only local record of MCP tool calls, so a user can answer "what did
/// an agent actually do through MCP" without reading Console.app logs.
///
/// Deliberately a flat text file rather than structured storage: this is
/// meant to be opened and read by a human occasionally, not queried. Nothing
/// here is transmitted anywhere — it lives next to `settings.json`, mode
/// 0600 like everything else in that directory.
enum MCPAuditLog {
    /// Past this size the file is trimmed to its newest half rather than left
    /// to grow forever. A busy agent session logging every tool call could
    /// otherwise run unbounded, same reasoning as `mcpBufferSizeKB` for pane
    /// output.
    private static let maxBytes = 1 * 1024 * 1024
    private static let queue = DispatchQueue(label: "com.termainal.mcpauditlog")
    private static let iso = ISO8601DateFormatter()

    /// Records one line if `mcpAuditLogEnabled` is on; otherwise a no-op, so
    /// call sites never need to check the setting themselves.
    static func record(_ line: String) {
        guard SettingsStore.shared.settings.mcpAuditLogEnabled else { return }
        let stamped = "\(iso.string(from: Date())) \(line)\n"
        queue.async {
            appendLocked(stamped)
        }
    }

    private static func appendLocked(_ line: String) {
        let url = SettingsStore.shared.settings.mcpAuditLogEnabled
            ? SettingsStore.shared.mcpAuditLogURL
            : nil
        guard let url, let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        trimIfNeededLocked(url)
    }

    /// Keeps only the tail of the file once it crosses `maxBytes`, so a log
    /// nobody ever reads cannot become the largest file in the settings
    /// directory. Cuts at a line boundary rather than a byte offset so the
    /// result is still readable text.
    private static func trimIfNeededLocked(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > maxBytes,
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        let target = contents.count / 2
        let tail = contents.suffix(contents.count - target)
        guard let firstNewline = tail.firstIndex(of: "\n") else { return }
        let trimmed = String(tail[tail.index(after: firstNewline)...])
        try? trimmed.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
