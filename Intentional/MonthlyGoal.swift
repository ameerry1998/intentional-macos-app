// MonthlyGoal.swift
//
// Cross-device account-scoped monthly goal. Companion to Intention (weekly
// goal). Weekly goals link to one monthly goal (nullable FK).
//
// Server: monthly_goals table (migration 026). Sibling-shared via account_id.

import Foundation

struct MonthlyGoal: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var outcome: String?
    var colorHex: String?
    /// ISO date (first-of-month), e.g. `2026-05-01`.
    var monthOf: String
    var status: GoalStatus
    var version: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, title, outcome, version, status
        case colorHex = "color_hex"
        case monthOf = "month_of"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    init(id: UUID, title: String, outcome: String? = nil, colorHex: String? = nil,
         monthOf: String, status: GoalStatus = .planned, version: Int = 1,
         createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.title = title; self.outcome = outcome
        self.colorHex = colorHex; self.monthOf = monthOf; self.status = status
        self.version = version; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        self.colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        self.monthOf = try c.decode(String.self, forKey: .monthOf)
        self.status = try c.decodeIfPresent(GoalStatus.self, forKey: .status) ?? .planned
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

struct MonthlyGoalCreatePayload: Codable, Equatable {
    var title: String
    var outcome: String?
    var colorHex: String?
    var monthOf: String  // YYYY-MM-01
    var status: GoalStatus = .planned

    private enum CodingKeys: String, CodingKey {
        case title, outcome, status
        case colorHex = "color_hex"
        case monthOf = "month_of"
    }
}

struct MonthlyGoalUpdatePayload: Codable, Equatable {
    var title: String
    var outcome: String?
    var colorHex: String?
    var monthOf: String
    var status: GoalStatus
    var version: Int

    private enum CodingKeys: String, CodingKey {
        case title, outcome, status, version
        case colorHex = "color_hex"
        case monthOf = "month_of"
    }
}

struct MonthlyGoalListResponse: Codable {
    let monthlyGoals: [MonthlyGoal]
    private enum CodingKeys: String, CodingKey { case monthlyGoals = "monthly_goals" }
}
