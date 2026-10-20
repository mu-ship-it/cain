// Copied from Bridge (phonebridge ba990d1, Bridge/Core/AppStatus.swift), trimmed: polls + activity feed.
import Foundation
import Observation

/// What the home screen shows about the box connection. Small, persisted in UserDefaults (no secrets).
@MainActor @Observable
final class AppStatus {
    static let shared = AppStatus()

    private(set) var lastPoll: Date?
    private(set) var lastPollMessage = "Never polled"
    private(set) var unsentResults = 0
    private(set) var connection: ConnectionState = .idle
    /// Newest first, max `activityLimit`, persisted so it survives relaunch.
    private(set) var activity: [ActivityEntry] = []

    private let defaults = UserDefaults.standard
    static let activityLimit = 100

    private init() {
        lastPoll = defaults.object(forKey: "status.lastPoll") as? Date
        lastPollMessage = defaults.string(forKey: "status.lastPollMessage") ?? lastPollMessage
        if let data = defaults.data(forKey: "status.activity"),
           let saved = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            // Anything still "running" was cut off by a relaunch; the server re-offers it after the lease.
            activity = saved.map { e in
                guard e.status == .running else { return e }
                var e = e
                e.status = .failed
                e.summary = "interrupted (app was suspended or quit)"
                return e
            }
        }
    }

    func recordPoll(success: Bool, message: String, unsent: Int) {
        if success {
            lastPoll = Date()
            defaults.set(lastPoll, forKey: "status.lastPoll")
        }
        lastPollMessage = success ? message : "Error: \(message)"
        unsentResults = unsent
        defaults.set(lastPollMessage, forKey: "status.lastPollMessage")
    }

    func setConnection(_ state: ConnectionState) { connection = state }

    func jobStarted(_ job: Job) {
        activity.removeAll { $0.id == job.id } // a re-leased job replaces its earlier row
        activity.insert(ActivityEntry(id: job.id, time: Date(), capability: job.capability, note: job.feedNote,
                                      status: .running, summary: ""), at: 0)
        saveActivity()
    }

    func jobFinished(_ job: Job, _ result: JobResult) {
        let summary = ActivitySummary.summarize(job, result)
        let status: ActivityEntry.Status = result.ok ? .done : .failed
        if let i = activity.firstIndex(where: { $0.id == job.id }) {
            activity[i].status = status
            activity[i].summary = summary
        } else {
            activity.insert(ActivityEntry(id: job.id, time: Date(), capability: job.capability, note: job.feedNote,
                                          status: status, summary: summary), at: 0)
        }
        saveActivity()
    }

    /// Clears finished rows; a job still running keeps its row so its result has somewhere to land.
    func clearActivity() {
        activity.removeAll { $0.status != .running }
        saveActivity()
    }

    private func saveActivity() {
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
        if let data = try? JSONEncoder().encode(activity) { defaults.set(data, forKey: "status.activity") }
    }
}
