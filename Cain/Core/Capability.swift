// Copied from Bridge (phonebridge ba990d1, Bridge/Core/Capability.swift), trimmed to what Cain uses.
import Foundation

/// Every phone feature the box can call is one small type conforming to this.
protocol Capability: Sendable {
    /// Dotted name used in `Job.capability`, e.g. `vpn.status`.
    var name: String { get }
    func run(_ job: Job) async throws -> JSONValue
}

/// Throw this from a capability to give the box a machine-readable error code.
struct CapabilityError: Error, LocalizedError, Sendable, Equatable {
    let code: String
    let message: String

    var errorDescription: String? { message }

    static func badParams(_ message: String) -> CapabilityError {
        CapabilityError(code: "bad_params", message: message)
    }

    static func unavailable(_ message: String) -> CapabilityError {
        CapabilityError(code: "unavailable", message: message)
    }

    static func notFound(_ message: String) -> CapabilityError {
        CapabilityError(code: "not_found", message: message)
    }
}

/// Routes jobs to capabilities by name and always produces a result (never throws).
struct JobDispatcher: Sendable {
    private let capabilities: [String: any Capability]

    init(_ capabilities: [any Capability]) {
        self.capabilities = Dictionary(capabilities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var names: [String] { capabilities.keys.sorted() }

    func dispatch(_ job: Job, now: @Sendable () -> Date = { Date() }) async -> JobResult {
        let started = ISO.string(now())
        guard let capability = capabilities[job.capability] else {
            return JobResult(jobId: job.id, ok: false,
                             error: JobError(code: "unknown_capability", message: "No capability named '\(job.capability)'. Available: \(names.joined(separator: ", "))"),
                             startedAt: started, finishedAt: ISO.string(now()))
        }
        do {
            let value = try await capability.run(job)
            return JobResult(jobId: job.id, ok: true, result: value, startedAt: started, finishedAt: ISO.string(now()))
        } catch let error as CapabilityError {
            return JobResult(jobId: job.id, ok: false, error: JobError(code: error.code, message: error.message),
                             startedAt: started, finishedAt: ISO.string(now()))
        } catch is CancellationError {
            return JobResult(jobId: job.id, ok: false, error: JobError(code: "cancelled", message: "Job was cancelled (app suspended?)"),
                             startedAt: started, finishedAt: ISO.string(now()))
        } catch {
            return JobResult(jobId: job.id, ok: false, error: JobError(code: "failed", message: error.localizedDescription),
                             startedAt: started, finishedAt: ISO.string(now()))
        }
    }
}

/// Small shared helpers for validating `job.params`.
enum Params {
    /// Optional bool; present-but-invalid is `bad_params`.
    static func bool(_ p: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = p[key], value != .null else { return nil }
        guard let b = value.boolValue else { throw CapabilityError.badParams("'\(key)' must be a boolean") }
        return b
    }

    /// Optional integer clamped to `range`; present-but-invalid is `bad_params`.
    static func int(_ p: [String: JSONValue], _ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = p[key], value != .null else { return nil }
        guard let n = value.doubleValue, n.isFinite else { throw CapabilityError.badParams("'\(key)' must be a number") }
        return min(max(Int(n), range.lowerBound), range.upperBound)
    }

    /// Optional string, trimmed; empty counts as absent.
    static func string(_ p: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = p[key], value != .null else { return nil }
        guard case .string(let s) = value else { throw CapabilityError.badParams("'\(key)' must be a string") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Optional profile name: present-but-invalid is `bad_params`. (Cain's own helper.)
    static func profileName(_ p: [String: JSONValue], _ key: String = "name") throws -> String? {
        guard let name = try string(p, key) else { return nil }
        guard ProfileStore.isValidName(name) else {
            throw CapabilityError.badParams(ProfileStore.Failure.invalidName(name).localizedDescription)
        }
        return name
    }
}
