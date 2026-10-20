import Foundation
@preconcurrency import Libbox
import Network
import NetworkExtension

/// What sing-box asks of the platform: open the tun (apply NEPacketTunnelNetworkSettings and
/// hand back the utun fd), watch the default interface, list interfaces. Everything iOS can't
/// or Cain doesn't do (shell, SSH, bridges, process lookup, notifications) answers "not
/// supported".
///
/// The tun / interface-monitor logic follows SagerNet/sing-box-for-apple's
/// ExtensionPlatformInterface (GPL-3.0); written fresh against the Libbox headers. See NOTICE.
final class PlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol,
    @unchecked Sendable
{
    private unowned let tunnel: PacketTunnelProvider
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var lastPath: String?

    init(tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func reset() {
        lock.withLock {
            monitor?.cancel()
            monitor = nil
            lastPath = nil
        }
    }

    private static func unsupported(_ what: String) -> NSError {
        NSError(domain: "Cain", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(what) is not supported on iOS"])
    }

    // MARK: Tun

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else { throw Self.unsupported("openTun without options") }
        let settings = try Self.networkSettings(options)

        // Called on a Go thread that must block until the settings are applied.
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        tunnel.setTunnelNetworkSettings(settings) { error in
            outcome.error = error
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw error }

        if let fd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        guard fd != -1 else {
            throw NSError(domain: "Cain", code: 2, userInfo: [NSLocalizedDescriptionKey: "no utun file descriptor"])
        }
        ret0_.pointee = fd
    }

    private static func prefixes(_ iterator: (any LibboxRoutePrefixIteratorProtocol)?) -> [LibboxRoutePrefix] {
        var out: [LibboxRoutePrefix] = []
        while let iterator, iterator.hasNext() {
            if let next = iterator.next() { out.append(next) }
        }
        return out
    }

    private static func strings(_ iterator: (any LibboxStringIteratorProtocol)?) -> [String] {
        var out: [String] = []
        while let iterator, iterator.hasNext() {
            out.append(iterator.next())
        }
        return out
    }

    static func networkSettings(_ options: any LibboxTunOptionsProtocol) throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        guard options.getAutoRoute() else { return settings }
        settings.mtu = NSNumber(value: options.getMTU())

        if options.getDNSMode()?.value != LibboxDNSModeDisabled {
            let servers = strings(try options.getDNSServerAddress())
            if !servers.isEmpty { settings.dnsSettings = NEDNSSettings(servers: servers) }
        }

        let v4 = prefixes(options.getInet4Address())
        if !v4.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: v4.map { $0.address() }, subnetMasks: v4.map { $0.mask() })
            let routes = prefixes(options.getInet4RouteAddress())
            ipv4.includedRoutes = routes.isEmpty
                ? [NEIPv4Route.default()]
                : routes.map { NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask()) }
            ipv4.excludedRoutes = prefixes(options.getInet4RouteExcludeAddress())
                .map { NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask()) }
            settings.ipv4Settings = ipv4
        }

        let v6 = prefixes(options.getInet6Address())
        if !v6.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: v6.map { $0.address() },
                                      networkPrefixLengths: v6.map { NSNumber(value: $0.prefix()) })
            let routes = prefixes(options.getInet6RouteAddress())
            ipv6.includedRoutes = routes.isEmpty
                ? [NEIPv6Route.default()]
                : routes.map { NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix())) }
            ipv6.excludedRoutes = prefixes(options.getInet6RouteExcludeAddress())
                .map { NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix())) }
            settings.ipv6Settings = ipv6
        }

        if options.isHTTPProxyEnabled() {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxy.httpServer = server
            proxy.httpsServer = server
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            let bypass = strings(options.getHTTPProxyBypassDomain())
            if !bypass.isEmpty { proxy.exceptionList = bypass }
            let match = strings(options.getHTTPProxyMatchDomain())
            if !match.isEmpty { proxy.matchDomains = match }
            settings.proxySettings = proxy
        }
        return settings
    }

    // MARK: Interfaces

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        guard listener != nil else { return }
        nonisolated(unsafe) let target = listener!   // a gomobile proxy, safe to call from any thread
        let monitor = NWPathMonitor()
        lock.withLock { self.monitor = monitor }
        // sing-box needs the first answer before this returns.
        let first = DispatchSemaphore(value: 0)
        final class Once: @unchecked Sendable { var fired = false }
        let once = Once()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.report(path, to: target)
            if !once.fired {
                once.fired = true
                first.signal()
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.boringbox.cain.path"))
        first.wait()
    }

    private func report(_ path: NWPath, to listener: any LibboxInterfaceUpdateListenerProtocol) {
        let description = Self.describe(path)
        listener.updateNetworkPath(description)
        let changed = lock.withLock {
            defer { lastPath = description }
            return lastPath != description
        }
        guard changed else { return }
        guard path.status != .unsatisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(interface.name, interfaceIndex: Int32(interface.index),
                                        isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    private static func describe(_ path: NWPath) -> String {
        var parts = ["\(path.status)"]
        parts += path.availableInterfaces.map { "\($0.name)#\($0.index)/\($0.type)" }
        if path.supportsIPv4 { parts.append("ipv4") }
        if path.supportsIPv6 { parts.append("ipv6") }
        if path.supportsDNS { parts.append("dns") }
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("constrained") }
        return parts.joined(separator: " ")
    }

    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        reset()
    }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        guard let monitor = lock.withLock({ monitor }) else {
            throw NSError(domain: "Cain", code: 3, userInfo: [NSLocalizedDescriptionKey: "interface monitor not started"])
        }
        let path = monitor.currentPath
        let interfaces: [LibboxNetworkInterface] = path.status == .unsatisfied ? [] : path.availableInterfaces.map { it in
            let interface = LibboxNetworkInterface()
            interface.name = it.name
            interface.index = Int32(it.index)
            interface.type = switch it.type {
            case .wifi: LibboxInterfaceTypeWIFI
            case .cellular: LibboxInterfaceTypeCellular
            case .wiredEthernet: LibboxInterfaceTypeEthernet
            default: LibboxInterfaceTypeOther
            }
            return interface
        }
        return InterfaceList(interfaces)
    }

    private final class InterfaceList: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var items: [LibboxNetworkInterface]
        init(_ items: [LibboxNetworkInterface]) { self.items = items }
        func hasNext() -> Bool { !items.isEmpty }
        func next() -> LibboxNetworkInterface? { items.isEmpty ? nil : items.removeFirst() }
    }

    // MARK: Plain answers

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {}
    func useProcFS() -> Bool { false }
    func usePlatformShell() -> Bool { false }
    func usePlatformBridge() -> Bool { false }
    func clearDNSCache() {}
    func registerMyInterface(_ name: String?) {}
    func readWIFIState() -> LibboxWIFIState? { nil }
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    /// The tailnet machine name unless the profile's tailscale endpoint sets `hostname`.
    func tailscaleHostname() -> String { "cain" }

    func startNeighborMonitor(_ listener: (any LibboxNeighborUpdateListenerProtocol)?) throws {}
    func closeNeighborMonitor(_ listener: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    func send(_ notification: LibboxNotification?) throws {
        if let notification { tunnel.writeLog("sing-box: \(notification.title) \(notification.body)") }
    }

    func cancelNotification(_ identifier: String?, typeID: Int32) throws {}

    // MARK: Not supported

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                             destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw Self.unsupported("process lookup")
    }

    func checkPlatformShell() throws { throw Self.unsupported("shell") }

    func lookupUser(_ username: String?) throws -> LibboxPlatformUser { throw Self.unsupported("user lookup") }

    func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: (any LibboxStringIteratorProtocol)?,
                          term: String?, rows: Int32, cols: Int32) throws -> any LibboxShellSessionProtocol {
        throw Self.unsupported("shell")
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.unsupported("SSH")
        return ""
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.unsupported("SFTP")
        return ""
    }

    func createBridge(_ options: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw Self.unsupported("bridge")
    }

    // MARK: LibboxCommandServerHandlerProtocol

    func serviceReload() throws { try tunnel.reload() }

    func serviceStop() throws { tunnel.cancelTunnelWithError(nil) }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }

    func setSystemProxyEnabled(_ enabled: Bool) throws {}

    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws { throw Self.unsupported("SSH agent") }

    func triggerNativeCrash() throws { throw Self.unsupported("native crash") }

    func writeDebugMessage(_ message: String?) {
        if let message { tunnel.writeLog("debug: \(message)") }
    }
}
