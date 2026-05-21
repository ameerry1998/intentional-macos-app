//
//  Entitlement.swift
//  Intentional
//
//  Subscription state returned by GET /me/entitlements.
//  Cached locally for offline resilience but backend is canonical.
//

import Foundation

struct Entitlement: Codable, Equatable {
    enum Tier: String, Codable {
        case none
        case trialing
        case active
        case pastDue = "past_due"
        case canceled
    }

    enum Plan: String, Codable {
        case monthly
        case annual
    }

    let tier: Tier
    let plan: Plan?
    let trialEndsAt: Date?
    let currentPeriodEndsAt: Date?
    let shipPuck: Bool
    let cachedAt: Date

    enum CodingKeys: String, CodingKey {
        case tier
        case plan
        case trialEndsAt = "trial_ends_at"
        case currentPeriodEndsAt = "current_period_ends_at"
        case shipPuck = "ship_puck"
        case cachedAt
    }

    var isActive: Bool {
        tier == .active || tier == .trialing
    }

    var isLapsed: Bool {
        tier == .canceled || tier == .pastDue
    }

    /// Hours since current_period_ends_at, or nil if not lapsed.
    var hoursSinceLapse: Double? {
        guard isLapsed, let ends = currentPeriodEndsAt else { return nil }
        let now = Date()
        if ends > now { return 0 }
        return now.timeIntervalSince(ends) / 3600.0
    }

    /// True if subscription is lapsed AND >24h have elapsed since the period end.
    /// Drives the lapsed banner UI (T12).
    var isHardLapsed: Bool {
        guard let h = hoursSinceLapse else { return false }
        return h >= 24
    }
}
