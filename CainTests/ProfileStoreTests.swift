import Foundation
import Testing
@testable import Cain

func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cain-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let sampleConfig = #"{"log":{"level":"warn"},"outbounds":[{"type":"direct","tag":"direct"}]}"#

@Suite struct ProfileStoreTests {
    @Test func names() {
        for ok in ["home", "cn-egress", "a", "tail.net_2", String(repeating: "x", count: 64)] {
            #expect(ProfileStore.isValidName(ok), "\(ok)")
        }
        for bad in ["", ".hidden", "-x", "_x", "a/b", "../up", "a b", "名字", String(repeating: "x", count: 65)] {
            #expect(!ProfileStore.isValidName(bad), "\(bad)")
        }
    }

    @Test func putLoadListReplace() throws {
        let store = ProfileStore(root: tempRoot())
        #expect(store.list().isEmpty)
        #expect(try store.put("home", json: sampleConfig) == false)
        #expect(try store.put("home", json: sampleConfig) == true)
        try store.put("away", json: "{}")
        #expect(try store.load("home") == sampleConfig)
        #expect(store.list().map(\.name) == ["away", "home"])
        #expect(store.list().last?.bytes == sampleConfig.utf8.count)
        #expect(store.exists("home"))
        #expect(!store.exists("nope"))
    }

    @Test func rejectsBadInput() {
        let store = ProfileStore(root: tempRoot())
        #expect(throws: ProfileStore.Failure.invalidName("a/b")) { try store.put("a/b", json: "{}") }
        #expect(throws: ProfileStore.Failure.self) { try store.put("x", json: "not json") }
        #expect(throws: ProfileStore.Failure.self) { try store.put("x", json: "[1,2]") }
        let big = "{\"k\":\"" + String(repeating: "a", count: ProfileStore.maxBytes) + "\"}"
        #expect(throws: ProfileStore.Failure.tooLarge(big.utf8.count)) { try store.put("x", json: big) }
        #expect(throws: ProfileStore.Failure.notFound("ghost")) { try store.load("ghost") }
        #expect(store.list().isEmpty)
    }

    @Test func selection() throws {
        let root = tempRoot()
        let store = ProfileStore(root: root)
        #expect(store.selected == nil)
        #expect(throws: ProfileStore.Failure.notFound("home")) { try store.select("home") }
        #expect(throws: ProfileStore.Failure.invalidName("../x")) { try store.select("../x") }
        try store.put("home", json: "{}")
        try store.select("home")
        #expect(store.selected == "home")
        #expect(ProfileStore(root: root).selected == "home")   // persisted
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("home.json"))
        #expect(store.selected == nil)                         // selected but gone → none
    }

    @Test func chunksAssembleInAnyOrder() throws {
        let store = ProfileStore(root: tempRoot())
        let text = sampleConfig
        let a = String(text.prefix(20)), b = String(text.dropFirst(20).prefix(20)), c = String(text.dropFirst(40))
        #expect(try store.stage("home", part: 3, of: 3, data: c) == .init(received: 1, assembled: nil))
        #expect(try store.stage("home", part: 1, of: 3, data: a) == .init(received: 2, assembled: nil))
        #expect(try store.stage("home", part: 1, of: 3, data: a) == .init(received: 2, assembled: nil))  // re-leased job
        #expect(try store.stage("home", part: 2, of: 3, data: b) == .init(received: 3, assembled: text))
        // Staging is gone: the next upload starts fresh.
        #expect(try store.stage("home", part: 1, of: 2, data: "x").received == 1)
    }

    @Test func chunksRestartOnNewCountOrStale() throws {
        let store = ProfileStore(root: tempRoot())
        _ = try store.stage("home", part: 1, of: 3, data: "a")
        #expect(try store.stage("home", part: 2, of: 2, data: "b").received == 1)   // parts changed → over
        let later = Date().addingTimeInterval(ProfileStore.stagingMaxAge + 60)
        #expect(try store.stage("home", part: 1, of: 2, data: "a", now: later).received == 1)   // stale → over
        #expect(throws: ProfileStore.Failure.self) { try store.stage("bad/name", part: 1, of: 1, data: "{}") }
    }
}

@Suite struct TunnelLogTests {
    @Test func appendAndTail() {
        let log = TunnelLog(root: tempRoot())
        #expect(log.tail(10).isEmpty)
        for i in 1...30 { log.append("line \(i)") }
        let tail = log.tail(3)
        #expect(tail.count == 3)
        #expect(tail.last?.hasSuffix("[cain] line 30") == true)
        #expect(tail.first?.hasSuffix("[cain] line 28") == true)
        #expect(log.tail(0).count == 1)            // clamped to 1
        #expect(log.tail(10_000).count == 30)      // clamped to maxTailLines, all there are
        log.append("two\nlines")
        #expect(log.tail(1).first?.hasSuffix("two lines") == true)
    }

    @Test func trimKeepsNewestWholeLines() throws {
        let log = TunnelLog(root: tempRoot())
        for i in 1...200 { log.append("entry \(i) " + String(repeating: "x", count: 40)) }
        log.trimIfNeeded(maxBytes: 4_000, keepBytes: 2_000)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? Int)
        #expect(size <= 2_000)
        let lines = log.tail(500)
        #expect(lines.last?.contains("entry 200 ") == true)
        #expect(lines.allSatisfy { $0.contains("[cain] entry ") })   // no line cut in half
        log.trimIfNeeded(maxBytes: 4_000, keepBytes: 2_000)          // under the limit: untouched
        #expect(log.tail(500) == lines)
    }
}

@Suite struct TunnelConfigTests {
    @Test func pointsLogAtSharedFileOnly() throws {
        let out = try TunnelConfig.prepare(sampleConfig, logPath: "/group/Logs/tunnel.log")
        let o = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let log = try #require(o["log"] as? [String: Any])
        #expect(log["output"] as? String == "/group/Logs/tunnel.log")
        #expect(log["level"] as? String == "warn")       // kept
        #expect(log["timestamp"] as? Bool == true)
        #expect(log["disabled"] as? Bool == false)
        #expect((o["outbounds"] as? [[String: Any]])?.first?["tag"] as? String == "direct")
        #expect(!out.contains(#"\/"#))                    // slashes not escaped

        let bare = try TunnelConfig.prepare("{}", logPath: "/l")
        #expect(bare.contains(#""level":"info""#))
        #expect(throws: (any Error).self) { try TunnelConfig.prepare("[]", logPath: "/l") }
    }
}
