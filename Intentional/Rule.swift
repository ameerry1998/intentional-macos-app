// Rule.swift
//
// Unified blocking/limits/allow rule + shared daily leisure pool
// (Rules Consolidation R2, June 2026).
//
// Mirrors intentional-backend `rules` + `leisure_pool` tables (migration 028,
// branch feat/rules-table, commit 5603ab5 — the wire format there is
// authoritative and decoded verbatim here):
//
//   Rule = { id, target_kind: "site"|"app", target, treatment:
//            "blocked"|"limited"|"allowed", schedule: object|null,
//            enabled, created_at, updated_at }
//   Pool = { pool_date, base_minutes, earned_minutes, spent_minutes,
//            bank_minutes, earn_rate, bank_cap, available_minutes }
//
// Decoding is tolerant by design:
//   - Unknown fields are ignored (Codable default).
//   - A single malformed rule is skipped, not the whole list
//     (RuleListResponse uses a lossy element decode).
//   - Timestamps parse with or without fractional seconds (Supabase emits
//     fractional seconds; JSONDecoder's plain .iso8601 strategy chokes on
//     them, so Rule parses date strings itself).
//   - Missing optionals get sensible defaults.

import Foundation

enum RuleTargetKind: String, Codable, Equatable {
    case site
    case app
}

enum RuleTreatment: String, Codable, Equatable {
    /// 🚫 Never usable (optionally only within schedule windows).
    case blocked
    /// ⏳ Usable against the shared daily leisure pool.
    case limited
    /// ✅ Never blocked, never swept.
    case allowed
}

struct Rule: Codable, Identifiable {
    let id: UUID
    var targetKind: RuleTargetKind
    /// site: bare lowercase domain (server normalizes scheme/path/www.);
    /// app: bundle id, whitespace-stripped, case kept.
    var target: String
    var treatment: RuleTreatment
    /// Opaque schedule blob (client-defined shape; nil = always in effect).
    var schedule: [String: AnyCodable]?
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, target, treatment, schedule, enabled
        case targetKind = "target_kind"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: UUID, targetKind: RuleTargetKind, target: String,
         treatment: RuleTreatment, schedule: [String: AnyCodable]? = nil,
         enabled: Bool = true, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.targetKind = targetKind
        self.target = target
        self.treatment = treatment
        self.schedule = schedule
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.targetKind = try c.decode(RuleTargetKind.self, forKey: .targetKind)
        self.target = try c.decode(String.self, forKey: .target)
        self.treatment = try c.decode(RuleTreatment.self, forKey: .treatment)
        self.schedule = try c.decodeIfPresent([String: AnyCodable].self, forKey: .schedule)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // Timestamps arrive as ISO8601 strings, possibly with fractional
        // seconds (Supabase) — parse manually so we don't depend on the
        // decoder's dateDecodingStrategy.
        self.createdAt = Self.parseDate(try c.decodeIfPresent(String.self, forKey: .createdAt)) ?? Date()
        self.updatedAt = Self.parseDate(try c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(targetKind, forKey: .targetKind)
        try c.encode(target, forKey: .target)
        try c.encode(treatment, forKey: .treatment)
        try c.encodeIfPresent(schedule, forKey: .schedule)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(Self.isoString(createdAt), forKey: .createdAt)
        try c.encode(Self.isoString(updatedAt), forKey: .updatedAt)
    }

    // MARK: - Date helpers (fractional-second tolerant)

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// ISO8601DateFormatter+.withFractionalSeconds is picky about 6-digit
    /// microseconds on some macOS versions; Supabase emits exactly that.
    private static let isoMicroseconds: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxxxx"
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFractional.date(from: s)
            ?? isoPlain.date(from: s)
            ?? isoMicroseconds.date(from: s)
            // Supabase sometimes emits "2026-06-10T21:19:53.123456" (no zone).
            ?? isoFractional.date(from: s + "Z")
            ?? isoPlain.date(from: s + "Z")
            ?? isoMicroseconds.date(from: s + "+00:00")
    }

    static func isoString(_ d: Date) -> String {
        isoPlain.string(from: d)
    }
}

/// Wrapper for GET /rules → {"rules": [...]}. Lossy: a single rule that fails
/// to decode is skipped; the rest of the list survives.
struct RuleListResponse: Decodable {
    let rules: [Rule]

    private enum CodingKeys: String, CodingKey { case rules }

    /// Always succeeds and always consumes its element, so a bad rule
    /// advances the unkeyed container instead of wedging it.
    private struct FailableRule: Decodable {
        let value: Rule?
        init(from decoder: Decoder) throws {
            value = try? Rule(from: decoder)
        }
    }

    init(rules: [Rule]) { self.rules = rules }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var arr = try c.nestedUnkeyedContainer(forKey: .rules)
        var out: [Rule] = []
        while !arr.isAtEnd {
            if let rule = try arr.decode(FailableRule.self).value {
                out.append(rule)
            }
        }
        self.rules = out
    }
}

/// Wire-format payload for POST /rules (server assigns id + timestamps).
struct RuleCreatePayload: Codable {
    var targetKind: RuleTargetKind
    var target: String
    var treatment: RuleTreatment
    var schedule: [String: AnyCodable]?
    var enabled: Bool = true

    private enum CodingKeys: String, CodingKey {
        case target, treatment, schedule, enabled
        case targetKind = "target_kind"
    }
}

/// Wire-format payload for PUT /rules/{id}. Partial: nil fields are omitted
/// from the JSON (synthesized Codable uses encodeIfPresent) and keep their
/// server-side value. A bare `"schedule": null` is treated as omitted by the
/// backend — set `clearSchedule = true` to null out a schedule.
struct RuleUpdatePayload: Codable {
    var targetKind: RuleTargetKind?
    var target: String?
    var treatment: RuleTreatment?
    var schedule: [String: AnyCodable]?
    var clearSchedule: Bool?
    var enabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case target, treatment, schedule, enabled
        case targetKind = "target_kind"
        case clearSchedule = "clear_schedule"
    }

    init(targetKind: RuleTargetKind? = nil, target: String? = nil,
         treatment: RuleTreatment? = nil, schedule: [String: AnyCodable]? = nil,
         clearSchedule: Bool? = nil, enabled: Bool? = nil) {
        self.targetKind = targetKind
        self.target = target
        self.treatment = treatment
        self.schedule = schedule
        self.clearSchedule = clearSchedule
        self.enabled = enabled
    }
}

// MARK: - Leisure pool

/// Shared daily leisure pool (spec decisions #1-#4: one pool, base + earned,
/// daily reset with capped bank rollover). `available = max(0, base + earned
/// + bank - spent)` — server-computed; we trust the wire value when present.
struct LeisurePool: Codable {
    /// "YYYY-MM-DD" — SERVER-local date (currently UTC on Railway).
    var poolDate: String
    var baseMinutes: Int
    var earnedMinutes: Int
    var spentMinutes: Int
    var bankMinutes: Int
    var earnRate: Int
    var bankCap: Int
    var availableMinutes: Int

    // Extras carried on POST /earn and /spend responses only.
    var creditedMinutes: Int?
    var deduped: Bool?
    var spentApplied: Int?

    private enum CodingKeys: String, CodingKey {
        case poolDate = "pool_date"
        case baseMinutes = "base_minutes"
        case earnedMinutes = "earned_minutes"
        case spentMinutes = "spent_minutes"
        case bankMinutes = "bank_minutes"
        case earnRate = "earn_rate"
        case bankCap = "bank_cap"
        case availableMinutes = "available_minutes"
        case creditedMinutes = "credited_minutes"
        case deduped
        case spentApplied = "spent_applied"
    }

    init(poolDate: String, baseMinutes: Int = 15, earnedMinutes: Int = 0,
         spentMinutes: Int = 0, bankMinutes: Int = 0, earnRate: Int = 5,
         bankCap: Int = 60, availableMinutes: Int? = nil,
         creditedMinutes: Int? = nil, deduped: Bool? = nil, spentApplied: Int? = nil) {
        self.poolDate = poolDate
        self.baseMinutes = baseMinutes
        self.earnedMinutes = earnedMinutes
        self.spentMinutes = spentMinutes
        self.bankMinutes = bankMinutes
        self.earnRate = earnRate
        self.bankCap = bankCap
        self.availableMinutes = availableMinutes
            ?? max(0, baseMinutes + earnedMinutes + bankMinutes - spentMinutes)
        self.creditedMinutes = creditedMinutes
        self.deduped = deduped
        self.spentApplied = spentApplied
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.poolDate = try c.decodeIfPresent(String.self, forKey: .poolDate) ?? ""
        self.baseMinutes = try c.decodeIfPresent(Int.self, forKey: .baseMinutes) ?? 15
        self.earnedMinutes = try c.decodeIfPresent(Int.self, forKey: .earnedMinutes) ?? 0
        self.spentMinutes = try c.decodeIfPresent(Int.self, forKey: .spentMinutes) ?? 0
        self.bankMinutes = try c.decodeIfPresent(Int.self, forKey: .bankMinutes) ?? 0
        self.earnRate = try c.decodeIfPresent(Int.self, forKey: .earnRate) ?? 5
        self.bankCap = try c.decodeIfPresent(Int.self, forKey: .bankCap) ?? 60
        self.availableMinutes = try c.decodeIfPresent(Int.self, forKey: .availableMinutes)
            ?? max(0, baseMinutes + earnedMinutes + bankMinutes - spentMinutes)
        self.creditedMinutes = try c.decodeIfPresent(Int.self, forKey: .creditedMinutes)
        self.deduped = try c.decodeIfPresent(Bool.self, forKey: .deduped)
        self.spentApplied = try c.decodeIfPresent(Int.self, forKey: .spentApplied)
    }
}
