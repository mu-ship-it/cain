import Foundation

/// What the extension changes in a profile before handing it to sing-box: the log goes to the
/// shared tunnel log file (with timestamps), so the app and `vpn.log.tail` can read it. Every
/// other field is passed through untouched.
enum TunnelConfig {
    static func prepare(_ json: String, logPath: String) throws -> String {
        guard var root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ProfileStore.Failure.notJSON("the top level is not an object")
        }
        var log = root["log"] as? [String: Any] ?? [:]
        log["output"] = logPath
        log["timestamp"] = true
        if log["level"] == nil { log["level"] = "info" }
        log["disabled"] = false
        root["log"] = log
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
