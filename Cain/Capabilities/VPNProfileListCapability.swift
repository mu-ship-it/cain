import Foundation

/// `vpn.profile.list`: no params → `{count, selected, profiles: [{name, bytes, modified, selected}], note}`.
/// Names and sizes only; the configs themselves never leave the phone this way.
struct VPNProfileListCapability: Capability {
    let name = "vpn.profile.list"
    var vpn: VPNProvider = VPNDefaults.provider

    func run(_ job: Job) async throws -> JSONValue {
        await act()
    }

    @MainActor private func act() -> JSONValue {
        let store = vpn().store
        let selected = store.selected
        let profiles = store.list()
        let rows: [JSONValue] = profiles.map { info in
            .object([
                "name": .string(info.name),
                "bytes": .number(Double(info.bytes)),
                "modified": .string(ISO.string(info.modified)),
                "selected": .bool(info.name == selected),
            ])
        }
        let note = profiles.isEmpty
            ? "No VPN profiles on the phone yet"
            : "\(profiles.count) VPN profile(s); selected: \(selected ?? "none")"
        return .object([
            "count": .number(Double(profiles.count)),
            "selected": selected.map(JSONValue.string) ?? .null,
            "profiles": .array(rows),
            "note": .string(note),
        ])
    }
}
