/// The one list of capabilities Cain exposes. Adding a capability = one new file in this folder + one line here
/// (Bridge's pattern). See docs/VPN.md.
enum CapabilityRegistry {
    static let all: [any Capability] = [
        VPNStatusCapability(),
        VPNStartCapability(),
        VPNStopCapability(),
        VPNProfileListCapability(),
        VPNProfileSetCapability(),
        VPNProfilePutCapability(),
        VPNLogTailCapability(),
    ]
}
