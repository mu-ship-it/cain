import Foundation

/// Parsed `vpn.start` params: `profile` (optional; default the selected one), `timeout`
/// seconds to wait for the tunnel (5–60, default 20).
struct VPNStartParams: Sendable, Equatable {
    var profile: String?
    var timeout = 20

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        profile = try Params.profileName(p, "profile")
        timeout = try Params.int(p, "timeout", in: 5...60) ?? timeout
    }
}

/// `vpn.start` {profile?, timeout?} → the status (see vpn.status) once the tunnel is on.
/// Starting with a profile also selects it. Already on with that profile: nothing changes.
/// Already on with another one: switches in place.
struct VPNStartCapability: Capability {
    let name = "vpn.start"
    var vpn: VPNProvider = VPNDefaults.provider

    func run(_ job: Job) async throws -> JSONValue {
        try await act(VPNStartParams(job.params))
    }

    @MainActor private func act(_ p: VPNStartParams) async throws -> JSONValue {
        let control = vpn()
        await control.load()
        do {
            if control.isOn {
                if let profile = p.profile, profile != control.store.selected {
                    try await control.select(profile)
                    return VPNStatusLine.snapshot(control, note: "Switched the running VPN to profile \(profile)")
                }
                return VPNStatusLine.snapshot(control, note: "VPN was already on · profile \(control.store.selected ?? "?")")
            }
            try await control.start(profile: p.profile, timeout: .seconds(p.timeout))
        } catch {
            throw VPNErrors.map(error)
        }
        return VPNStatusLine.snapshot(control, note: "Turned the VPN on · profile \(control.store.selected ?? "?")")
    }
}
