import Foundation

/// sing-box JSON configs by name, in the App Group: `Profiles/<name>.json`, plus the name of
/// the selected one in `selected-profile`. The app writes; the extension reads the selected
/// profile when it starts (also when iOS restarts the tunnel on its own, without the app).
struct ProfileStore: Sendable {
    struct Info: Sendable, Equatable {
        let name: String
        let bytes: Int
        let modified: Date
    }

    enum Failure: LocalizedError, Equatable {
        case invalidName(String)
        case notFound(String)
        case notJSON(String)
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                "Profile name \"\(name)\" is not allowed. Use 1–64 letters, digits, dot, dash or underscore, starting with a letter or digit."
            case .notFound(let name): "There is no profile called \"\(name)\"."
            case .notJSON(let why): "The profile is not a sing-box JSON object: \(why)"
            case .tooLarge(let bytes):
                "The profile is \(bytes) bytes; the limit is \(ProfileStore.maxBytes) bytes."
            }
        }
    }

    /// sing-box configs with inline rule sets can get big; remote rule sets keep them small.
    static let maxBytes = 1_048_576

    static let shared = ProfileStore(root: AppGroup.root)

    let root: URL
    var directory: URL { root.appendingPathComponent("Profiles", isDirectory: true) }
    private var selectedFile: URL { root.appendingPathComponent("selected-profile") }

    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let alnum = CharacterSet.alphanumerics
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
            && first.isASCII && alnum.contains(first)
    }

    private func file(_ name: String) throws -> URL {
        guard Self.isValidName(name) else { throw Failure.invalidName(name) }
        return directory.appendingPathComponent(name + ".json")
    }

    /// Checks the text is one JSON object within the size limit. sing-box itself validates the
    /// schema when the tunnel starts.
    static func validate(_ json: String) throws {
        let data = Data(json.utf8)
        guard data.count <= maxBytes else { throw Failure.tooLarge(data.count) }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure.notJSON(error.localizedDescription)
        }
        guard parsed is [String: Any] else { throw Failure.notJSON("the top level is not an object") }
    }

    /// Saves (or replaces) a profile. Returns true when it replaced an existing one.
    @discardableResult
    func put(_ name: String, json: String) throws -> Bool {
        let url = try file(name)
        try Self.validate(json)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try Data(json.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return existed
    }

    func load(_ name: String) throws -> String {
        let url = try file(name)
        guard let data = try? Data(contentsOf: url) else { throw Failure.notFound(name) }
        return String(decoding: data, as: UTF8.self)
    }

    func exists(_ name: String) -> Bool {
        guard let url = try? file(name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// All profiles, by name.
    func list() -> [Info] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard Self.isValidName(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Info(name: name, bytes: values?.fileSize ?? 0,
                        modified: values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.name < $1.name }
    }

    /// The profile the tunnel runs, or nil when none is selected (or it was removed).
    var selected: String? {
        guard let data = try? Data(contentsOf: selectedFile) else { return nil }
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return exists(name) ? name : nil
    }

    func select(_ name: String) throws {
        guard exists(name) else {
            _ = try file(name)          // invalid names fail as such, not as "not found"
            throw Failure.notFound(name)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(name.utf8).write(to: selectedFile, options: .atomic)
    }
}
