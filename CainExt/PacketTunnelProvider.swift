import Foundation
@preconcurrency import Libbox
import NetworkExtension

/// The packet tunnel: runs the selected sing-box profile inside this extension.
///
/// The start sequence (LibboxSetup → command server → startOrReloadService) follows
/// SagerNet/sing-box-for-apple's ExtensionProvider (GPL-3.0); written fresh against the Libbox
/// headers, no code copied. See NOTICE.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var commandServer: LibboxCommandServer?
    private var platform: PlatformInterface?
    private var profile: String?

    private let store = ProfileStore.shared
    private let log = TunnelLog.shared

    struct StartError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping @Sendable (Error?) -> Void) {
        log.trimIfNeeded()
        // The app passes the profile; iOS restarting the tunnel on its own passes nothing.
        guard let name = (options?["profile"] as? String) ?? store.selected else {
            completionHandler(fail("no profile selected"))
            return
        }
        Task {
            do {
                try await start(profile: name)
                log.append("tunnel on · profile \(name) · sing-box \(LibboxVersion())")
                completionHandler(nil)
            } catch {
                completionHandler(fail("start \(name): \(error.localizedDescription)"))
            }
        }
    }

    private func start(profile name: String) async throws {
        let config = try TunnelConfig.prepare(try store.load(name), logPath: log.url.path)

        let root = AppGroup.root
        let working = root.appendingPathComponent("Working", isDirectory: true)
        let temp = root.appendingPathComponent("Library/Caches", isDirectory: true)
        for dir in [working, temp] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let setup = LibboxSetupOptions()
        setup.basePath = root.path
        setup.workingPath = working.path
        setup.tempPath = temp.path
        setup.logMaxLines = 3000
        setup.crashReportSource = "NetworkExtension"
        setup.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        setup.appMarketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        // iOS kills a packet tunnel that passes ~50 MB; let sing-box shed connections first.
        setup.oomKillerEnabled = true
        var error: NSError?
        LibboxSetup(setup, &error)
        if let error { throw error }

        let platform = PlatformInterface(tunnel: self)
        guard let server = LibboxNewCommandServer(platform, platform, &error) else {
            throw error ?? StartError(message: "could not create the command server")
        }
        try server.start()
        self.platform = platform
        self.commandServer = server
        self.profile = name
        try server.startOrReloadService(config, options: LibboxOverrideOptions())
    }

    /// Re-reads the selected profile (or `name`) and reloads sing-box without dropping the tunnel.
    func reload(profile name: String? = nil) throws {
        guard let server = commandServer, let name = name ?? store.selected ?? profile else { return }
        reasserting = true
        defer { reasserting = false }
        let config = try TunnelConfig.prepare(try store.load(name), logPath: log.url.path)
        try server.startOrReloadService(config, options: LibboxOverrideOptions())
        profile = name
        log.append("reloaded · profile \(name)")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        if let server = commandServer {
            try? server.closeService()
            server.close()
        }
        commandServer = nil
        platform?.reset()
        platform = nil
        log.append("tunnel off · \(Self.describe(reason))")
    }

    /// The app sends `{"op":"reload","profile":"<name>"}` after switching profiles while on.
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: String],
              message["op"] == "reload" else { return nil }
        do {
            try reload(profile: message["profile"])
            return Data(#"{"ok":true}"#.utf8)
        } catch {
            log.append("reload failed: \(error.localizedDescription)")
            let reply = ["ok": "false", "error": error.localizedDescription]
            return try? JSONSerialization.data(withJSONObject: reply)
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }

    func writeLog(_ message: String) {
        log.append(message)
    }

    private func fail(_ message: String) -> StartError {
        log.append("start failed: \(message)")
        return StartError(message: message)
    }

    private static func describe(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .userInitiated: "stopped by the user"
        case .providerFailed: "the tunnel failed"
        case .noNetworkAvailable: "no network"
        case .unrecoverableNetworkChange: "network changed"
        case .configurationDisabled, .configurationRemoved: "VPN configuration turned off"
        case .superceded: "another VPN took over"
        case .userLogout, .userSwitch: "user changed"
        case .idleTimeout: "idle timeout"
        case .sleep: "device sleep"
        case .appUpdate: "app update"
        default: "reason \(reason.rawValue)"
        }
    }
}
