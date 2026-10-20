import Foundation

/// Parsed `vpn.log.tail` params: `lines` (1–500, default 50).
struct VPNLogTailParams: Sendable, Equatable {
    var lines = 50

    init(_ params: [String: JSONValue]?) throws {
        lines = try Params.int(params ?? [:], "lines", in: 1...TunnelLog.maxTailLines) ?? lines
    }
}

/// `vpn.log.tail` {lines?} → `{count, lines: [...], note}`, oldest first. The tunnel's own log
/// (sing-box plus Cain's start/stop lines). It can name the hosts the tunnel connected to.
struct VPNLogTailCapability: Capability {
    let name = "vpn.log.tail"
    var vpn: VPNProvider = VPNDefaults.provider

    func run(_ job: Job) async throws -> JSONValue {
        try await act(VPNLogTailParams(job.params))
    }

    @MainActor private func act(_ p: VPNLogTailParams) -> JSONValue {
        let lines = vpn().log.tail(p.lines)
        return .object([
            "count": .number(Double(lines.count)),
            "lines": .array(lines.map(JSONValue.string)),
            "note": .string(lines.isEmpty ? "The VPN log is empty" : "Last \(lines.count) line(s) of the VPN log"),
        ])
    }
}
