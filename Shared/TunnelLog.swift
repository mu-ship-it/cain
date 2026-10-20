import Foundation

/// The tunnel's log: one append-only file in the App Group (`Logs/tunnel.log`). sing-box
/// writes its own log lines there (the extension points the config's `log.output` at it) and
/// the extension appends its start/stop notes. Kept as a ring buffer: once it passes `maxBytes`
/// it is cut back to the newest `keepBytes` when the tunnel starts.
struct TunnelLog: Sendable {
    static let maxBytes = 512 * 1024
    static let keepBytes = 256 * 1024
    /// `vpn.log.tail` never returns more than this many lines.
    static let maxTailLines = 500

    static let shared = TunnelLog(root: AppGroup.root)

    let root: URL
    var url: URL { root.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("tunnel.log") }

    /// Appends one line, prefixed with a UTC timestamp.
    func append(_ message: String) {
        let stamp = Date().formatted(.iso8601)
        let line = "\(stamp) [cain] \(message.replacingOccurrences(of: "\n", with: " "))\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// Cuts the file back to the newest `keepBytes` (at a line boundary) once it is over `maxBytes`.
    func trimIfNeeded(maxBytes: Int = Self.maxBytes, keepBytes: Int = Self.keepBytes) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(keepBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: url, options: .atomic)
    }

    /// The newest `count` lines (1…maxTailLines), oldest first.
    func tail(_ count: Int) -> [String] {
        let count = min(max(count, 1), Self.maxTailLines)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // Lines are short; 400 bytes a line is generous, and the whole file is at most maxBytes.
        let window = min(UInt64(count * 400), size)
        try? handle.seek(toOffset: size - window)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if window < size, !lines.isEmpty { lines.removeFirst() }   // first line may be cut mid-way
        return lines.suffix(count).map(String.init)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
