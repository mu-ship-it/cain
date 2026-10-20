import BackgroundTasks
import Foundation
import os

/// Wires the job loop to its triggers: the foreground long poll (while the app is on screen),
/// BG app refresh (~every 15 min at iOS's discretion) and the Poll-now button.
@MainActor
final class CainRuntime {
    static let shared = CainRuntime()

    let jobLoop = JobLoop(dispatcher: JobDispatcher(CapabilityRegistry.all))
    private var poller: Task<Void, Never>?

    static let refreshID = "\(AppInfo.bundleID).refresh"
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "bg")

    /// True when the app is only hosting unit tests: then it never polls on its own, so a test's
    /// poll is the only one.
    static let hostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Foreground: one long poll, re-issued as it returns. Background: none (iOS would suspend it).
    func setForeground(_ foreground: Bool) {
        guard !Self.hostingTests else { return }
        if foreground {
            guard poller == nil else { return }
            let loop = jobLoop
            poller = Task {
                await ForegroundPoller(loop: loop) { AppStatus.shared.setConnection($0) }.run()
            }
        } else {
            poller?.cancel()
            poller = nil
            AppStatus.shared.setConnection(.idle)
            Self.scheduleRefresh()
        }
    }

    func pollNow() async {
        await jobLoop.pollOnce(trigger: "poll-now")
    }

    // MARK: BG app refresh (identifier must match BGTaskSchedulerPermittedIdentifiers)

    /// Must be called before the app finishes launching.
    static func registerBackground() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: .main) { task in
            MainActor.assumeIsolated { handle(task) }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected on the simulator (BGTaskSchedulerErrorDomain code 1, unavailable).
            log.notice("BG submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(_ task: BGTask) {
        scheduleRefresh()
        let loop = shared.jobLoop
        let work = Task { await loop.pollOnce(trigger: "bg-refresh") }
        task.expirationHandler = { work.cancel() }
        Task {
            _ = await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }
}

/// Tells the box when the tunnel goes on or off: one `vpn` event (`POST /bridge/events`) whose
/// note is the status line, "VPN on · profile home". Only while the app is running to see it.
enum VPNEvents {
    static func post(word: String, profile: String?) {
        guard let config = ConfigStore.load() else { return }
        let event = DeviceEvent(
            type: "vpn", ts: ISO.string(Date()),
            payload: .object(["state": .string(word), "profile": profile.map(JSONValue.string) ?? .null]),
            note: VPNStatusLine.text(word: word, profile: profile))
        Task.detached {
            try? await BoxClient(config: config).postEvents([event])
        }
    }
}
