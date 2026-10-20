import Foundation

/// Chunked uploads for `vpn.profile.put`: parts wait in `Staging/<name>/` until all are in.
extension ProfileStore {
    struct Staged: Sendable, Equatable {
        let received: Int
        /// The whole text once every part is in (the staging folder is then removed).
        let assembled: String?
    }

    /// Staging older than this is dropped, so a half-sent upload can't linger.
    static let stagingMaxAge: TimeInterval = 24 * 3600

    private func stagingDirectory(_ name: String) -> URL {
        root.appendingPathComponent("Staging", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Stores part `part` (1-based) of `parts`. A different `parts` count from an earlier part, or
    /// staging older than a day, starts over. Sending the same part again replaces it.
    func stage(_ name: String, part: Int, of parts: Int, data: String, now: Date = Date()) throws -> Staged {
        guard Self.isValidName(name) else { throw Failure.invalidName(name) }
        let fm = FileManager.default
        let dir = stagingDirectory(name)
        let countFile = dir.appendingPathComponent("parts")

        let existing = (try? String(contentsOf: countFile, encoding: .utf8)).flatMap { Int($0) }
        let created = (try? fm.attributesOfItem(atPath: countFile.path)[.creationDate] as? Date) ?? now
        if existing != parts || now.timeIntervalSince(created) > Self.stagingMaxAge {
            try? fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: countFile.path) {
            try Data(String(parts).utf8).write(to: countFile, options: .atomic)
        }
        try Data(data.utf8).write(to: dir.appendingPathComponent("part-\(part)"), options: .atomic)

        let present = (1...parts).filter { fm.fileExists(atPath: dir.appendingPathComponent("part-\($0)").path) }
        guard present.count == parts else { return Staged(received: present.count, assembled: nil) }
        var whole = Data()
        for index in 1...parts {
            whole.append(try Data(contentsOf: dir.appendingPathComponent("part-\(index)")))
        }
        try? fm.removeItem(at: dir)
        return Staged(received: parts, assembled: String(decoding: whole, as: UTF8.self))
    }
}
