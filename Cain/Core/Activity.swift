// Copied from Bridge (phonebridge ba990d1, Bridge/Core/Activity.swift); summaries are Cain's vpn.* ones.
import Foundation

/// One row of the activity feed: what the agent asked the phone to do, and how it went.
struct ActivityEntry: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable { case running, done, failed }

    let id: String          // job id
    let time: Date
    let capability: String
    let note: String
    var status: Status
    var summary: String
}

extension Job {
    /// The agent's one-line reason for this job: top-level `note`, else `params.note`
    /// (the reference server forwards params untouched but not extra top-level fields).
    var displayNote: String? {
        let raw = note ?? params?["note"]?.stringValue
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(300))
    }

    /// Every row carries a plain-words note: the agent's, or Cain's own words for the capability.
    var feedNote: String { displayNote ?? ActivitySummary.defaultNote(capability) }
}

/// One-line, human-readable result summaries for the feed. Pure, so it is unit-testable.
enum ActivitySummary {
    static func summarize(_ job: Job, _ result: JobResult) -> String {
        guard result.ok else {
            let code = result.error?.code ?? "error"
            let message = result.error?.message ?? ""
            return clip(message.isEmpty ? code : "\(code): \(message)")
        }
        // Every vpn.* result carries its own plain-words note ("VPN on · profile home").
        if let note = result.result?["note"]?.stringValue { return clip(note) }
        return "ok"
    }

    /// Cain's words for a job the agent sent without a note.
    static func defaultNote(_ capability: String) -> String {
        switch capability {
        case "vpn.status": "Box checked the VPN"
        case "vpn.start": "Box turned the VPN on"
        case "vpn.stop": "Box turned the VPN off"
        case "vpn.profile.list": "Box listed the VPN profiles"
        case "vpn.profile.set": "Box switched the VPN profile"
        case "vpn.profile.put": "Box uploaded a VPN profile"
        case "vpn.log.tail": "Box read the VPN log"
        default: "Box ran \(capability)"
        }
    }

    static func clip(_ s: String, _ max: Int = 120) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }
}
