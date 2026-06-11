// GoalSessionHistory.swift
//
// Projects-kill B2 (June 2026): the backend (`focus_sessions` table) is the
// permanent record of a Weekly Goal's session history — including the
// focus_score the Mac sends on stop. The goal detail panel pulls
// `GET /intentions/{id}/sessions` on open; this file holds the wire model
// and a small local cache (`session_history.json`) so the panel renders
// instantly / offline (pull-on-open + cache-fallback, same pattern as
// IntentionStore's intentions.json).

import Foundation

/// One row of `GET /intentions/{id}/sessions`.
struct GoalSession: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: Int?
    let focusScore: Double?
    let triggeredBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case focusScore = "focus_score"
        case triggeredBy = "triggered_by"
    }
}

/// Local cache: `{ "<intention uuid>": [GoalSession] }` at
/// `~/Library/Application Support/Intentional/session_history.json`.
/// Whole-file read/write under a lock — payloads are ≤20 sessions per goal.
enum GoalSessionHistoryCache {

    private static let lock = NSLock()

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Intentional", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session_history.json")
    }

    /// Dates persisted as fractional ISO8601 — matches the backend wire format
    /// so cached and live payloads decode identically.
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = Self.parseISO(s) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: dec.codingPath, debugDescription: "Bad date: \(s)"))
        }
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Self.isoFractional.string(from: date))
        }
        return e
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Backend sends fractional seconds ("2026-06-11T02:26:19.603741+00:00");
    /// accept plain seconds too for robustness.
    static func parseISO(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    static func load(intentionId: UUID) -> [GoalSession]? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? decoder().decode([String: [GoalSession]].self, from: data) else {
            return nil
        }
        return all[intentionId.uuidString.lowercased()]
    }

    static func save(intentionId: UUID, sessions: [GoalSession]) {
        lock.lock(); defer { lock.unlock() }
        var all: [String: [GoalSession]] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? decoder().decode([String: [GoalSession]].self, from: data) {
            all = existing
        }
        all[intentionId.uuidString.lowercased()] = sessions
        if let data = try? encoder().encode(all) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Decoder for the live backend payload (same date strategy as the cache).
    static func wireDecoder() -> JSONDecoder { decoder() }

    /// Encoder for pushing sessions to the dashboard (snake_case keys + ISO
    /// dates via GoalSession.CodingKeys — same shape as the backend payload).
    static func wireEncoder() -> JSONEncoder { encoder() }
}
