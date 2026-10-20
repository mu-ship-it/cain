import Foundation
import Testing
@testable import Cain

@Suite struct VPNParamsTests {
    @Test func start() throws {
        #expect(try VPNStartParams(nil).profile == nil)
        #expect(try VPNStartParams(nil).timeout == 20)
        let p = try VPNStartParams(["profile": .string(" home "), "timeout": .number(2)])
        #expect(p.profile == "home")
        #expect(p.timeout == 5)                                   // clamped
        #expect(try VPNStartParams(["timeout": .string("30")]).timeout == 30)
        #expect(try VPNStartParams(["profile": .string("")]).profile == nil)   // empty = absent
        #expect(throws: CapabilityError.self) { try VPNStartParams(["profile": .string("a/b")]) }
        #expect(throws: CapabilityError.self) { try VPNStartParams(["profile": .number(1)]) }
        #expect(throws: CapabilityError.self) { try VPNStartParams(["timeout": .string("soon")]) }
    }

    @Test func stop() throws {
        #expect(try VPNStopParams(nil).timeout == 10)
        #expect(try VPNStopParams(["timeout": .number(100)]).timeout == 30)
        #expect(throws: CapabilityError.self) { try VPNStopParams(["timeout": .bool(true)]) }
    }

    @Test func profileSet() throws {
        #expect(try VPNProfileSetParams(["name": .string("home")]).name == "home")
        #expect(throws: CapabilityError.self) { try VPNProfileSetParams(nil) }
        #expect(throws: CapabilityError.self) { try VPNProfileSetParams(["name": .string(".x")]) }
    }

    @Test func logTail() throws {
        #expect(try VPNLogTailParams(nil).lines == 50)
        #expect(try VPNLogTailParams(["lines": .number(0)]).lines == 1)
        #expect(try VPNLogTailParams(["lines": .number(9999)]).lines == 500)
    }

    @Test func profilePutWhole() throws {
        let text = try VPNProfilePutParams(["name": .string("home"), "config": .string("{}")])
        #expect(text.body == .whole("{}"))
        #expect(text.select == false)
        let object = try VPNProfilePutParams([
            "name": .string("home"), "select": .bool(true),
            "config": .object(["route": .object(["final": .string("proxy"), "auto_detect_interface": .bool(true)]),
                               "port": .number(443), "ratio": .number(0.5), "x": .null]),
        ])
        #expect(object.select)
        #expect(object.body == .whole(#"{"port":443,"ratio":0.5,"route":{"auto_detect_interface":true,"final":"proxy"},"x":null}"#))
    }

    @Test func profilePutChunk() throws {
        let p = try VPNProfilePutParams(["name": .string("big"), "part": .number(2), "parts": .number(3), "data": .string("…")])
        #expect(p.body == .chunk(part: 2, parts: 3, data: "…"))
        let bad: [[String: JSONValue]] = [
            ["name": .string("big"), "part": .number(4), "parts": .number(3), "data": .string("x")],     // part > parts
            ["name": .string("big"), "part": .number(0), "parts": .number(3), "data": .string("x")],
            ["name": .string("big"), "part": .number(1.5), "parts": .number(3), "data": .string("x")],
            ["name": .string("big"), "part": .number(1), "parts": .number(65), "data": .string("x")],    // too many parts
            ["name": .string("big"), "part": .number(1), "parts": .number(2)],                           // no data
            ["name": .string("big"), "part": .number(1), "parts": .number(2), "data": .number(1)],
            ["name": .string("big"), "part": .number(1), "parts": .number(1), "data": .string("x"), "config": .string("{}")],
            ["name": .string("big"), "part": .number(1), "parts": .number(1),
             "data": .string(String(repeating: "a", count: VPNProfilePutParams.maxChunkBytes + 1))],
        ]
        for params in bad {
            #expect(throws: CapabilityError.self) { try VPNProfilePutParams(params) }
        }
    }

    @Test func profilePutNeedsNameAndConfig() {
        #expect(throws: CapabilityError.self) { try VPNProfilePutParams(nil) }
        #expect(throws: CapabilityError.self) { try VPNProfilePutParams(["config": .string("{}")]) }
        #expect(throws: CapabilityError.self) { try VPNProfilePutParams(["name": .string("home")]) }
        #expect(throws: CapabilityError.self) { try VPNProfilePutParams(["name": .string("home"), "config": .number(1)]) }
        #expect(throws: CapabilityError.self) { try VPNProfilePutParams(["name": .string("home"), "config": .string("{}"), "select": .string("maybe")]) }
    }
}
