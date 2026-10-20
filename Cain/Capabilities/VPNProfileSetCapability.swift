import Foundation

/// Parsed `vpn.profile.set` params: `name` (required, an existing profile).
struct VPNProfileSetParams: Sendable, Equatable {
    let name: String

    init(_ params: [String: JSONValue]?) throws {
        guard let name = try Params.profileName(params ?? [:]) else {
            throw CapabilityError.badParams("'name' (string) is required")
        }
        self.name = name
    }
}

/// `vpn.profile.set` {name} → `{selected, reloaded, note}`. Selects the profile the tunnel runs.
/// While the VPN is on, it switches in place (`reloaded: true`); while off, the next start uses it.
struct VPNProfileSetCapability: Capability {
    let name = "vpn.profile.set"
    var vpn: VPNProvider = VPNDefaults.provider

    func run(_ job: Job) async throws -> JSONValue {
        try await act(VPNProfileSetParams(job.params))
    }

    @MainActor private func act(_ p: VPNProfileSetParams) async throws -> JSONValue {
        let control = vpn()
        await control.load()
        do {
            try await control.select(p.name)
        } catch {
            throw VPNErrors.map(error)
        }
        let note = control.isOn
            ? "Switched the running VPN to profile \(p.name)"
            : "Selected profile \(p.name); the VPN is off and will use it next time"
        return .object(["selected": .string(p.name), "reloaded": .bool(control.isOn), "note": .string(note)])
    }
}
