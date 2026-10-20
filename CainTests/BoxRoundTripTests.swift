import Foundation
import Testing
@testable import Cain

/// The real TunnelController in the simulator, which has no VPN service: what docs/VPN.md says
/// the box sees before Cain runs on a phone.
#if targetEnvironment(simulator)
@MainActor @Suite struct SimulatorTunnelTests {
    @Test func statusIsNotSetUpAndStartFails() async throws {
        let status = await JobDispatcher(CapabilityRegistry.all).dispatch(Job(id: "s1", capability: "vpn.status"))
        #expect(status.ok)
        #expect(status.result?["state"] == .string("not set up"))

        let name = "sim-\(UUID().uuidString.prefix(8))"
        try ProfileStore.shared.put(name, json: "{}")
        defer { try? FileManager.default.removeItem(at: ProfileStore.shared.directory.appendingPathComponent(name + ".json")) }
        let start = await JobDispatcher(CapabilityRegistry.all).dispatch(
            Job(id: "s2", capability: "vpn.start", params: ["profile": .string(name), "timeout": .number(5)]))
        #expect(!start.ok)
        #expect(start.error?.code == "failed")
        #expect(!(start.error?.message.isEmpty ?? true))
    }
}
#endif

/// One real poll against a running box, opt-in: `TEST_RUNNER_CAIN_E2E_BOX=http://localhost:8787`
/// (Bridge's tools/mock_box.py, token `devtoken`), with jobs queued for it beforehand. Checks the
/// jobs ran here; the box side prints the results.
@MainActor @Suite struct BoxRoundTripTests {
    nonisolated static let box = ProcessInfo.processInfo.environment["CAIN_E2E_BOX"]

    @Test(.enabled(if: box != nil, "set TEST_RUNNER_CAIN_E2E_BOX to run against a box"))
    func pollRunsQueuedJobs() async throws {
        try ConfigStore.save(url: try #require(Self.box), token: "devtoken", deviceId: "cain-e2e")
        let before = Set(AppStatus.shared.activity.map(\.id))
        let ran = await CainRuntime.shared.jobLoop.pollOnce(trigger: "e2e")
        #expect(ran)
        let fresh = AppStatus.shared.activity.filter { !before.contains($0.id) }
        #expect(!fresh.isEmpty)
        for entry in fresh {
            #expect(!entry.note.isEmpty)
            #expect(entry.status != .running)
        }
        #expect(AppStatus.shared.lastPollMessage.hasPrefix("OK via e2e"))
    }
}
