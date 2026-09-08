import Foundation

/// Per-pane ring buffer of ANSI-stripped output, sized in KB, overflowing to a
/// spill file in the temp directory.
///
/// Port of `appendToBuffer` / `getBufferLines` / `cleanupSpillFile` in `main.ts`.
/// Exists purely to serve MCP reads — SwiftTerm keeps its own scrollback.
final class OutputBuffer {
    static let shared = OutputBuffer()

    private let queue = DispatchQueue(label: "com.termainal.outputbuffer")
    private var buffers: [String: String] = [:]
    private var spillFiles: [String: URL] = [:]

    var maxBytes: Int = 500 * 1024
    var fileSpillEnabled: Bool = true

    private init() {}

    func append(paneId: String, text: String) {
        let clean = ANSIStripper.strip(text)
        guard !clean.isEmpty else { return }

        queue.async {
            let combined = (self.buffers[paneId] ?? "") + clean
            guard combined.utf8.count > self.maxBytes else {
                self.buffers[paneId] = combined
                return
            }

            // Trim from the front, on a character boundary, down to maxBytes.
            var kept = combined
            while kept.utf8.count > self.maxBytes, !kept.isEmpty {
                kept.removeFirst()
            }
            let spilled = String(combined.prefix(combined.count - kept.count))

            if self.fileSpillEnabled, !spilled.isEmpty {
                self.appendToSpillFile(paneId: paneId, text: spilled)
            }
            self.buffers[paneId] = kept
        }
    }

    /// Returns spill-file contents concatenated with the in-memory tail,
    /// optionally limited to the last `maxLines` lines.
    func read(paneId: String, maxLines: Int? = nil) -> String {
        queue.sync {
            var full = ""
            if let spill = spillFiles[paneId], let contents = try? String(contentsOf: spill, encoding: .utf8) {
                full = contents
            }
            full += buffers[paneId] ?? ""

            guard let maxLines else { return full }
            let lines = full.components(separatedBy: "\n")
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }

    func cleanup(paneId: String) {
        queue.async {
            self.buffers.removeValue(forKey: paneId)
            if let spill = self.spillFiles.removeValue(forKey: paneId) {
                try? FileManager.default.removeItem(at: spill)
            }
        }
    }

    func cleanupAll() {
        queue.sync {
            for (_, spill) in spillFiles {
                try? FileManager.default.removeItem(at: spill)
            }
            spillFiles.removeAll()
            buffers.removeAll()
        }
    }

    private func appendToSpillFile(paneId: String, text: String) {
        let url = spillFiles[paneId] ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("term-ai-nal-buffer-\(paneId).txt")
        spillFiles[paneId] = url

        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// Strips terminal control sequences before output reaches the MCP buffer.
///
/// Extends the `ANSI_RE` regex from `main.ts`, which only covered CSI escapes:
/// with shell integration active (iTerm2's, or OSC 133 semantic prompts) a
/// stock zsh emits a stream of OSC sequences that the original regex let
/// through, so MCP readers saw `\u{1b}]1337;CurrentDir=...` mixed into the text.
/// The OSC branch below is matched first because it must consume up to its own
/// BEL or ST terminator.
///
/// Note for later: OSC 133 marks command start/end and exit status. Stripping
/// it is right for now, but parsing it is how this buffer would gain real
/// per-command boundaries instead of a flat byte stream.
enum ANSIStripper {
    private static let pattern = try! NSRegularExpression(
        pattern: "\u{1b}\\][^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\\\)"
            + "|\u{1b}\\[[0-9;?]*[A-Za-z]"
            + "|\u{1b}[()][0-9A-Za-z]"
            // Single-character escapes. `7`/`8` (DECSC/DECRC save and restore
            // cursor) were missing and leaked into MCP reads as literal
            // ESC-7/ESC-8 — Powerlevel10k emits them around every prompt.
            + "|\u{1b}[78cDEHMOSTZ=><]"
            + "|[\u{07}\u{08}\r]"
    )

    static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
