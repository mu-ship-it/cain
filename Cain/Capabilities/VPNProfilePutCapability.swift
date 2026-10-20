import Foundation

/// Parsed `vpn.profile.put` params. Two forms:
/// - whole: `{name, config, select?}`; `config` is the sing-box config as a JSON object, or as
///   JSON text in a string.
/// - chunked, for configs too big for one job: `{name, part, parts, data, select?}`; `data` is the
///   `part`-th slice (1-based) of the JSON text cut into `parts` pieces (≤ 64). Parts may arrive
///   in any order and again (a re-leased job); the profile is saved once all parts are in.
struct VPNProfilePutParams: Sendable, Equatable {
    enum Body: Sendable, Equatable {
        case whole(String)
        case chunk(part: Int, parts: Int, data: String)
    }

    static let maxParts = 64
    static let maxChunkBytes = 256 * 1024

    let name: String
    let body: Body
    var select = false

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        guard let name = try Params.profileName(p) else {
            throw CapabilityError.badParams("'name' (string) is required")
        }
        self.name = name
        select = try Params.bool(p, "select") ?? false

        let chunked = p["part"] != nil || p["parts"] != nil || p["data"] != nil
        switch (p["config"], chunked) {
        case (.some, true):
            throw CapabilityError.badParams("Send either 'config' or 'part'/'parts'/'data', not both")
        case (.some(.string(let text)), false):
            body = .whole(text)
        case (.some(.object(let object)), false):
            body = .whole(try Self.text(of: .object(object)))
        case (.some, false):
            throw CapabilityError.badParams("'config' must be a JSON object or JSON text")
        case (.none, true):
            guard case .string(let data)? = p["data"] else { throw CapabilityError.badParams("'data' (string) is required") }
            guard data.utf8.count <= Self.maxChunkBytes else {
                throw CapabilityError.badParams("'data' is over \(Self.maxChunkBytes / 1024) KB; use more parts")
            }
            guard let parts = p["parts"]?.doubleValue, parts == parts.rounded(), (1...Double(Self.maxParts)).contains(parts) else {
                throw CapabilityError.badParams("'parts' must be a whole number from 1 to \(Self.maxParts)")
            }
            guard let part = p["part"]?.doubleValue, part == part.rounded(), (1...parts).contains(part) else {
                throw CapabilityError.badParams("'part' must be a whole number from 1 to 'parts'")
            }
            body = .chunk(part: Int(part), parts: Int(parts), data: data)
        case (.none, false):
            throw CapabilityError.badParams("'config' (the sing-box config) is required")
        }
    }

    /// JSON text for a config that arrived as an object. Whole numbers are written without a
    /// fraction (443, not 443.0): sing-box reads ports and counts as integers.
    static func text(of value: JSONValue) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: foundation(value),
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n == n.rounded() && abs(n) < 9e15 ? Int64(n) as Any : n as Any
        case .string(let s): s
        case .array(let a): a.map(foundation)
        case .object(let o): o.mapValues(foundation)
        }
    }
}

/// `vpn.profile.put` → whole form or last chunk: `{name, bytes, replaced, selected, reloaded, complete: true, note}`;
/// an earlier chunk: `{name, received, parts, complete: false, note}`.
/// Replacing the profile the running VPN uses reloads it in place. `select: true` also selects it
/// (switching a running VPN to it).
struct VPNProfilePutCapability: Capability {
    let name = "vpn.profile.put"
    var vpn: VPNProvider = VPNDefaults.provider

    func run(_ job: Job) async throws -> JSONValue {
        try await act(VPNProfilePutParams(job.params))
    }

    @MainActor private func act(_ p: VPNProfilePutParams) async throws -> JSONValue {
        let control = vpn()
        let store = control.store
        let text: String
        do {
            switch p.body {
            case .whole(let whole):
                text = whole
            case .chunk(let part, let parts, let data):
                let staged = try store.stage(p.name, part: part, of: parts, data: data)
                guard let assembled = staged.assembled else {
                    return .object([
                        "name": .string(p.name), "received": .number(Double(staged.received)),
                        "parts": .number(Double(parts)), "complete": .bool(false),
                        "note": .string("Got part \(part) of \(parts) of VPN profile \(p.name) (\(staged.received) so far)"),
                    ])
                }
                text = assembled
            }
            let replaced = try store.put(p.name, json: text)
            await control.load()
            let running = control.isOn && store.selected == p.name
            if p.select || running {
                try await control.select(p.name)
            }
            let reloaded = control.isOn && (p.select || running)
            var note = "\(replaced ? "Replaced" : "Saved") VPN profile \(p.name) (\(text.utf8.count) bytes)"
            if reloaded { note += "; the running VPN switched to it" } else if p.select { note += " and selected it" }
            return .object([
                "name": .string(p.name), "bytes": .number(Double(text.utf8.count)), "replaced": .bool(replaced),
                "selected": .bool(store.selected == p.name), "reloaded": .bool(reloaded),
                "complete": .bool(true), "note": .string(note),
            ])
        } catch {
            throw VPNErrors.map(error)
        }
    }
}
