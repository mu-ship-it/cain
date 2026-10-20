import Foundation
import Testing
@testable import Cain

/// Stands in for TunnelController: no NetworkExtension, a real ProfileStore and TunnelLog in a temp dir.
@MainActor
final class FakeVPN: VPNControl {
    let store: ProfileStore
    let log: TunnelLog
    var statusWord = "off"
    var connectedSince: Date?
    var lastError: String?
    var startError: Error?
    private(set) var calls: [String] = []

    var isOn: Bool { statusWord == "on" }

    init(root: URL = tempRoot()) {
        store = ProfileStore(root: root)
        log = TunnelLog(root: root)
    }

    func load() async {}

    func start(profile: String?, timeout: Duration) async throws {
        calls.append("start \(profile ?? "-") \(timeout)")
        if let profile { try store.select(profile) }
        guard store.selected != nil else { throw TunnelController.Failure.noProfile }
        if let startError { throw startError }
        statusWord = "on"
        connectedSince = Date(timeIntervalSince1970: 1_792_108_800)
    }

    func stop(timeout: Duration) async throws {
        calls.append("stop")
        statusWord = "off"
    }

    func select(_ profile: String) async throws {
        calls.append("select \(profile)")
        try store.select(profile)
    }
}

@MainActor
private func dispatch(_ fake: FakeVPN, _ capability: String, _ params: [String: JSONValue]? = nil,
                      note: String? = nil) async -> JobResult {
    let provider: VPNProvider = { fake }
    let dispatcher = JobDispatcher([
        VPNStatusCapability(vpn: provider), VPNStartCapability(vpn: provider), VPNStopCapability(vpn: provider),
        VPNProfileListCapability(vpn: provider), VPNProfileSetCapability(vpn: provider),
        VPNProfilePutCapability(vpn: provider), VPNLogTailCapability(vpn: provider),
    ])
    return await dispatcher.dispatch(Job(id: "j1", capability: capability, params: params, note: note))
}

@MainActor @Suite struct VPNCapabilityTests {
    @Test func registryHasTheSeven() {
        #expect(JobDispatcher(CapabilityRegistry.all).names == [
            "vpn.log.tail", "vpn.profile.list", "vpn.profile.put", "vpn.profile.set",
            "vpn.start", "vpn.status", "vpn.stop",
        ])
    }

    @Test func statusLine() {
        #expect(VPNStatusLine.text(word: "on", profile: "home") == "VPN on · profile home")
        #expect(VPNStatusLine.text(word: "off", profile: nil) == "VPN off · no profile selected")
    }

    @Test func statusStartStop() async throws {
        let fake = FakeVPN()
        try fake.store.put("home", json: sampleConfig)

        var r = await dispatch(fake, "vpn.status")
        #expect(r.ok)
        #expect(r.result?["state"] == .string("off"))
        #expect(r.result?["note"] == .string("VPN off · no profile selected"))

        r = await dispatch(fake, "vpn.start")
        #expect(r.error?.code == "not_found")              // nothing selected yet

        r = await dispatch(fake, "vpn.start", ["profile": .string("home"), "timeout": .number(99)])
        #expect(r.ok)
        #expect(fake.calls.last == "start home 60.0 seconds")   // timeout clamped to 60
        #expect(r.result?["on"] == .bool(true))
        #expect(r.result?["profile"] == .string("home"))
        #expect(r.result?["since"] != nil)
        #expect(r.result?["note"] == .string("Turned the VPN on · profile home"))

        r = await dispatch(fake, "vpn.start")
        #expect(r.result?["note"] == .string("VPN was already on · profile home"))

        r = await dispatch(fake, "vpn.status")
        #expect(r.result?["note"] == .string("VPN on · profile home"))

        r = await dispatch(fake, "vpn.stop")
        #expect(r.result?["on"] == .bool(false))
        #expect(r.result?["note"] == .string("Turned the VPN off"))
        r = await dispatch(fake, "vpn.stop")
        #expect(r.result?["note"] == .string("VPN was already off"))
    }

    @Test func startWhileOnSwitchesProfile() async throws {
        let fake = FakeVPN()
        try fake.store.put("home", json: "{}")
        try fake.store.put("away", json: "{}")
        _ = await dispatch(fake, "vpn.start", ["profile": .string("home")])
        let r = await dispatch(fake, "vpn.start", ["profile": .string("away")])
        #expect(fake.calls.last == "select away")
        #expect(r.result?["note"] == .string("Switched the running VPN to profile away"))
    }

    @Test func startFailureKeepsMessage() async throws {
        let fake = FakeVPN()
        try fake.store.put("home", json: "{}")
        fake.startError = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "start failed: bad outbound"])
        let r = await dispatch(fake, "vpn.start", ["profile": .string("home")])
        #expect(r.error == JobError(code: "failed", message: "start failed: bad outbound"))
        fake.startError = TunnelController.Failure.timeout("connecting")
        #expect(await dispatch(fake, "vpn.start").error?.code == "timeout")
    }

    @Test func profileSetAndList() async throws {
        let fake = FakeVPN()
        var r = await dispatch(fake, "vpn.profile.list")
        #expect(r.result?["count"] == .number(0))
        #expect(r.result?["note"] == .string("No VPN profiles on the phone yet"))

        try fake.store.put("home", json: sampleConfig)
        try fake.store.put("away", json: "{}")
        #expect(await dispatch(fake, "vpn.profile.set", ["name": .string("ghost")]).error?.code == "not_found")
        #expect(await dispatch(fake, "vpn.profile.set", ["name": .string("../x")]).error?.code == "bad_params")
        #expect(await dispatch(fake, "vpn.profile.set").error?.code == "bad_params")

        r = await dispatch(fake, "vpn.profile.set", ["name": .string("home")])
        #expect(r.result?["reloaded"] == .bool(false))
        #expect(r.result?["note"] == .string("Selected profile home; the VPN is off and will use it next time"))

        r = await dispatch(fake, "vpn.profile.list")
        #expect(r.result?["count"] == .number(2))
        #expect(r.result?["selected"] == .string("home"))
        let rows = try #require(r.result?["profiles"]?.arrayValue)
        #expect(rows.map { $0["name"] } == [.string("away"), .string("home")])
        #expect(rows.last?["selected"] == .bool(true))
        #expect(rows.last?["bytes"] == .number(Double(sampleConfig.utf8.count)))
        #expect(r.result?["note"] == .string("2 VPN profile(s); selected: home"))

        _ = await dispatch(fake, "vpn.start")
        r = await dispatch(fake, "vpn.profile.set", ["name": .string("away")])
        #expect(r.result?["reloaded"] == .bool(true))
    }

    @Test func profilePutWhole() async throws {
        let fake = FakeVPN()
        var r = await dispatch(fake, "vpn.profile.put", ["name": .string("home"), "config": .string(sampleConfig)])
        #expect(r.ok)
        #expect(r.result?["replaced"] == .bool(false))
        #expect(r.result?["selected"] == .bool(false))
        #expect(r.result?["note"] == .string("Saved VPN profile home (\(sampleConfig.utf8.count) bytes)"))
        #expect(try fake.store.load("home") == sampleConfig)

        // As an object, with select: written back as JSON text, whole numbers stay integers.
        let object: JSONValue = .object(["inbounds": .array([.object(["type": .string("tun"), "mtu": .number(9000)])])])
        r = await dispatch(fake, "vpn.profile.put", ["name": .string("home"), "config": object, "select": .bool(true)])
        #expect(r.result?["replaced"] == .bool(true))
        #expect(r.result?["selected"] == .bool(true))
        #expect(r.result?["note"] == .string("Replaced VPN profile home (40 bytes) and selected it"))
        #expect(try fake.store.load("home") == #"{"inbounds":[{"mtu":9000,"type":"tun"}]}"#)

        // Replacing the running profile reloads it.
        _ = await dispatch(fake, "vpn.start")
        r = await dispatch(fake, "vpn.profile.put", ["name": .string("home"), "config": .string("{}")])
        #expect(r.result?["reloaded"] == .bool(true))
        #expect(fake.calls.last == "select home")

        #expect(await dispatch(fake, "vpn.profile.put", ["name": .string("x"), "config": .string("nope")]).error?.code == "bad_params")
    }

    @Test func profilePutChunked() async throws {
        let fake = FakeVPN()
        let text = sampleConfig
        let half = text.count / 2
        var r = await dispatch(fake, "vpn.profile.put", [
            "name": .string("big"), "part": .number(2), "parts": .number(2), "data": .string(String(text.dropFirst(half))),
        ])
        #expect(r.result?["complete"] == .bool(false))
        #expect(r.result?["received"] == .number(1))
        #expect(r.result?["note"] == .string("Got part 2 of 2 of VPN profile big (1 so far)"))
        #expect(!fake.store.exists("big"))
        r = await dispatch(fake, "vpn.profile.put", [
            "name": .string("big"), "part": .number(1), "parts": .number(2), "data": .string(String(text.prefix(half))),
        ])
        #expect(r.result?["complete"] == .bool(true))
        #expect(try fake.store.load("big") == text)

        // Halves that don't make JSON: rejected when the last part lands, nothing saved.
        _ = await dispatch(fake, "vpn.profile.put", ["name": .string("junk"), "part": .number(1), "parts": .number(2), "data": .string("{")])
        r = await dispatch(fake, "vpn.profile.put", ["name": .string("junk"), "part": .number(2), "parts": .number(2), "data": .string("x")])
        #expect(r.error?.code == "bad_params")
        #expect(!fake.store.exists("junk"))
    }

    @Test func logTail() async throws {
        let fake = FakeVPN()
        #expect(await dispatch(fake, "vpn.log.tail").result?["note"] == .string("The VPN log is empty"))
        for i in 1...80 { fake.log.append("l\(i)") }
        var r = await dispatch(fake, "vpn.log.tail")
        #expect(r.result?["count"] == .number(50))
        r = await dispatch(fake, "vpn.log.tail", ["lines": .number(2)])
        #expect(r.result?["lines"]?.arrayValue?.count == 2)
        #expect(r.result?["note"] == .string("Last 2 line(s) of the VPN log"))
        #expect(await dispatch(fake, "vpn.log.tail", ["lines": .string("lots")]).error?.code == "bad_params")
    }

    @Test func everyJobHasAPlainWordsNote() async throws {
        let fake = FakeVPN()
        for name in JobDispatcher(CapabilityRegistry.all).names {
            let job = Job(id: "j", capability: name)
            #expect(!job.feedNote.isEmpty)
            #expect(job.feedNote != "Box ran \(name)", "\(name) has no default note")
        }
        #expect(Job(id: "j", capability: "vpn.stop", params: ["note": .string("Leaving China, tailnet only")]).feedNote
            == "Leaving China, tailnet only")
        // The feed summary is the result's own note.
        let r = await dispatch(fake, "vpn.status")
        #expect(ActivitySummary.summarize(Job(id: "j1", capability: "vpn.status"), r) == "VPN off · no profile selected")
        let failed = await dispatch(fake, "vpn.profile.set", ["name": .string("ghost")])
        #expect(ActivitySummary.summarize(Job(id: "j1", capability: "vpn.profile.set"), failed)
            == "not_found: There is no profile called \"ghost\".")
    }
}
