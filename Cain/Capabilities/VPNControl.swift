import Foundation

/// What the vpn.* capabilities need from the tunnel. TunnelController in the app; a fake in tests.
@MainActor
protocol VPNControl: AnyObject {
    var store: ProfileStore { get }
    var log: TunnelLog { get }
    var statusWord: String { get }
    var isOn: Bool { get }
    var connectedSince: Date? { get }
    var lastError: String? { get }
    func load() async
    func start(profile: String?, timeout: Duration) async throws
    func stop(timeout: Duration) async throws
    func select(_ profile: String) async throws
}

extension TunnelController: VPNControl {}

/// The capabilities reach the tunnel through this, so tests can swap it.
typealias VPNProvider = @MainActor @Sendable () -> any VPNControl

enum VPNDefaults {
    static let provider: VPNProvider = { TunnelController.shared }
}

/// The one-line status everyone shows: the home screen, the activity feed, the box's `vpn`
/// events and every vpn.* result's `note`. "VPN on · profile home".
enum VPNStatusLine {
    static func text(word: String, profile: String?) -> String {
        "VPN \(word) · " + (profile.map { "profile \($0)" } ?? "no profile selected")
    }

    /// `{state, on, profile, since?, last_error?, note}`, the shape vpn.status / start / stop return.
    @MainActor
    static func snapshot(_ vpn: any VPNControl, note: String? = nil) -> JSONValue {
        let profile = vpn.store.selected
        var o: [String: JSONValue] = [
            "state": .string(vpn.statusWord),
            "on": .bool(vpn.isOn),
            "profile": profile.map(JSONValue.string) ?? .null,
            "note": .string(note ?? text(word: vpn.statusWord, profile: profile)),
        ]
        if vpn.isOn, let since = vpn.connectedSince { o["since"] = .string(ISO.string(since)) }
        if let error = vpn.lastError { o["last_error"] = .string(error) }
        return .object(o)
    }
}

/// Turns profile-store and tunnel errors into the job API's error codes.
enum VPNErrors {
    static func map(_ error: Error) -> Error {
        switch error {
        case let e as ProfileStore.Failure:
            switch e {
            case .notFound: CapabilityError.notFound(e.localizedDescription)
            case .invalidName, .notJSON, .tooLarge: CapabilityError.badParams(e.localizedDescription)
            }
        case let e as TunnelController.Failure:
            switch e {
            case .noProfile: CapabilityError.notFound(e.localizedDescription)
            case .timeout: CapabilityError(code: "timeout", message: e.localizedDescription)
            }
        default: error
        }
    }
}
