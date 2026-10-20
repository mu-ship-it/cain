import Foundation
import NetworkExtension

/// Owns Cain's one VPN configuration (an NETunnelProviderManager pointing at CainExt):
/// creates and saves it on first use, starts and stops the tunnel, follows its status, and asks
/// the running extension to reload when the profile changes.
@MainActor
final class TunnelController: ObservableObject {
    static let shared = TunnelController()

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var connectedSince: Date?
    @Published private(set) var lastError: String?

    let store = ProfileStore.shared
    let log = TunnelLog.shared

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    static let tunnelBundleID =
        Bundle.main.object(forInfoDictionaryKey: "CainTunnelBundleID") as? String ?? "dev.boringbox.cain.ext"

    enum Failure: LocalizedError {
        case noProfile
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .noProfile: "No profile is selected. Upload one with vpn.profile.put, then pick it with vpn.profile.set."
            case .timeout(let state): "The tunnel did not finish in time; it is \(state)."
            }
        }
    }

    var isOn: Bool { status == .connected }
    var isBusy: Bool { [.connecting, .disconnecting, .reasserting].contains(status) }

    /// "on", "off", "connecting"…; what vpn.status and the status feed report.
    var statusWord: String { Self.word(for: status) }

    static func word(for status: NEVPNStatus) -> String {
        switch status {
        case .invalid: "not set up"
        case .disconnected: "off"
        case .connecting: "connecting"
        case .connected: "on"
        case .reasserting: "reconnecting"
        case .disconnecting: "disconnecting"
        @unknown default: "unknown"
        }
    }

    /// Loads the existing configuration, if any, and starts following its status.
    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            let ours = all.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundleID
            }
            if let ours { adopt(ours) } else { status = .invalid }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The manager, created and saved the first time (iOS asks the user to allow the VPN once).
    private func ensureManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }
        await load()
        if let manager { return manager }
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = "sing-box"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "该隐 Cain"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()   // required before the first start
        adopt(manager)
        return manager
    }

    private func adopt(_ manager: NETunnelProviderManager) {
        self.manager = manager
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        let previous = status
        status = manager?.connection.status ?? .invalid
        connectedSince = manager?.connection.connectedDate
        // Tell the box about real transitions, not about the first look after launch.
        if status != previous, previous != .invalid, [.connected, .disconnected].contains(status) {
            VPNEvents.post(word: statusWord, profile: store.selected)
        }
    }

    /// Starts the tunnel with `profile` (or the selected one). Returns once it is on, or throws.
    func start(profile: String? = nil, timeout: Duration = .seconds(20)) async throws {
        if let profile { try store.select(profile) }
        guard let name = store.selected else { throw Failure.noProfile }
        _ = try store.load(name)
        let manager = try await ensureManager()
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        lastError = nil
        try manager.connection.startVPNTunnel(options: ["profile": name as NSString])
        try await wait(until: [.connected], timeout: timeout)
    }

    func stop(timeout: Duration = .seconds(10)) async throws {
        guard let manager, status != .disconnected, status != .invalid else { return }
        manager.connection.stopVPNTunnel()
        try await wait(until: [.disconnected, .invalid], timeout: timeout)
    }

    /// Selects `profile`; when the tunnel is on, the extension reloads into it in place.
    func select(_ profile: String) async throws {
        try store.select(profile)
        guard isOn, let session = manager?.connection as? NETunnelProviderSession else { return }
        let message = try JSONSerialization.data(withJSONObject: ["op": "reload", "profile": profile])
        let reply: Data? = try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if let reply, let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
           let failure = object["error"] as? String {
            throw NSError(domain: "Cain", code: 4, userInfo: [NSLocalizedDescriptionKey: failure])
        }
    }

    private func wait(until wanted: Set<NEVPNStatus>, timeout: Duration) async throws {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            refresh()
            if wanted.contains(status) { return }
            // A start that fails goes connecting → disconnected; the extension logs why.
            if wanted.contains(.connected), status == .disconnected, ContinuousClock.now - started > .seconds(1) {
                let why = log.tail(5).last(where: { $0.contains("start failed") }) ?? "the tunnel stopped while starting"
                lastError = why
                throw NSError(domain: "Cain", code: 5, userInfo: [NSLocalizedDescriptionKey: why])
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.timeout(statusWord)
    }
}
