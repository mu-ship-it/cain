import Foundation

/// Parsed `vpn.stop` params: `timeout` seconds to wait for the tunnel to close (3–30, default 10).
struct VPNStopParams: Sendable, Equatable {
    var timeout = 10

    init(_ params: [String: JSONValue]?) throws {
        timeout = try Params.int(params ?? [:], "timeout", in: 3...30) ?? timeout
    }
}

/// `vpn.stop` {timeout?} → the status (see vpn.status) once the tunnel is off. Already off: no change.
struct VPNStopCapability: Capability {
    let name = "vpn.stop"
    var vpn: VPNProvider = VPNDefaults.provider

    func run(_ job: Job) async throws -> JSONValue {
        try await act(VPNStopParams(job.params))
    }

    @MainActor private func act(_ p: VPNStopParams) async throws -> JSONValue {
        let control = vpn()
        await control.load()
        if ["off", "not set up"].contains(control.statusWord) {
            return VPNStatusLine.snapshot(control, note: "VPN was already off")
        }
        do {
            try await control.stop(timeout: .seconds(p.timeout))
        } catch {
            throw VPNErrors.map(error)
        }
        return VPNStatusLine.snapshot(control, note: "Turned the VPN off")
    }
}
