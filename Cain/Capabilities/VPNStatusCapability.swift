import Foundation

/// `vpn.status`: no params → `{state, on, profile, since?, last_error?, note}`.
/// `state` is `on`, `off`, `connecting`, `reconnecting`, `disconnecting` or `not set up` (never started on this phone).
struct VPNStatusCapability: Capability {
    let name = "vpn.status"
    var vpn: VPNProvider = VPNDefaults.provider

    func run(_ job: Job) async throws -> JSONValue {
        try await act()
    }

    @MainActor private func act() async throws -> JSONValue {
        let control = vpn()
        await control.load()
        return VPNStatusLine.snapshot(control)
    }
}
