// Intention.swift
//
// Cross-device account-scoped focus preset. Replaces the local-only
// `Project` model. Each Intention owns its own per-platform blocklists:
//   - Mac side: mac_websites (domains) + mac_bundle_ids (apps)
//   - iOS side: ios_app_tokens / ios_category_tokens (opaque blobs from
//     Apple's FamilyActivitySelection — Mac stores+forwards, never decodes)
// Versioned for optimistic concurrency. Soft-deleted via `deletedAt`.
//
// JSON shape on the wire matches the backend's snake_case endpoints
// (see plan A — intentional-backend); we use a CodingKey enum to map.

import Foundation

/// Spec 3 (May 2026): per-Intention strictness preset.
/// Direction-locked: tightening is instant; softening Standard→Soft has a 24h
/// cool-down; softening from Strict requires partner unlock.
enum StrictnessPreset: String, Codable, Equatable {
    case strict
    case standard
    case soft
}

/// Spec 3 (May 2026): a queued softening change. The server cron applies it when
/// `takesEffectAt` passes; until then the Mac shows a "scheduled" banner.
struct PendingStrictnessChange: Codable, Equatable {
    let toPreset: StrictnessPreset
    let takesEffectAt: Date

    private enum CodingKeys: String, CodingKey {
        case toPreset = "to_preset"
        case takesEffectAt = "takes_effect_at"
    }
}

struct Intention: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    /// Base64-encoded FamilyActivitySelection app tokens. iOS-only consumer.
    var iosAppTokensB64: String?
    /// Base64-encoded FamilyActivitySelection category tokens. iOS-only.
    var iosCategoryTokensB64: String?
    var version: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    /// Per-Intention strictness preset (D4). Defaults `.standard`.
    /// Direction-locked: tightening is instant; softening Standard→Soft has a 24h
    /// cool-down; softening from Strict requires partner unlock (D5).
    var strictnessPreset: StrictnessPreset

    /// If non-nil, a softening change is queued and will apply when `takesEffectAt`
    /// passes (server-side cron). Mac shows a "scheduled" banner until then.
    var pendingStrictnessChange: PendingStrictnessChange?

    /// D9 budget prep — backend column exists but no enforcement code yet.
    var weeklyBudgetHours: Double?
    var budgetEnforcement: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case colorHex = "color_hex"
        case icon
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokensB64 = "ios_app_tokens_b64"
        case iosCategoryTokensB64 = "ios_category_tokens_b64"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        // Spec 3:
        case strictnessPreset = "strictness_preset"
        case pendingStrictnessChange = "pending_strictness_change"
        case weeklyBudgetHours = "weekly_budget_hours"
        case budgetEnforcement = "budget_enforcement"
    }

    init(id: UUID, name: String, description: String? = nil,
         colorHex: String? = nil, icon: String? = nil,
         macWebsites: [String] = [], macBundleIds: [String] = [],
         iosAppTokensB64: String? = nil, iosCategoryTokensB64: String? = nil,
         version: Int = 1, createdAt: Date = Date(),
         updatedAt: Date = Date(), deletedAt: Date? = nil,
         strictnessPreset: StrictnessPreset = .standard,
         pendingStrictnessChange: PendingStrictnessChange? = nil,
         weeklyBudgetHours: Double? = nil,
         budgetEnforcement: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.colorHex = colorHex
        self.icon = icon
        self.macWebsites = macWebsites
        self.macBundleIds = macBundleIds
        self.iosAppTokensB64 = iosAppTokensB64
        self.iosCategoryTokensB64 = iosCategoryTokensB64
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.strictnessPreset = strictnessPreset
        self.pendingStrictnessChange = pendingStrictnessChange
        self.weeklyBudgetHours = weeklyBudgetHours
        self.budgetEnforcement = budgetEnforcement
    }

    /// Custom decoder so Spec 3 fields are tolerant of older payloads (no
    /// strictness_preset / pending_strictness_change / budget fields yet).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.macWebsites = try c.decodeIfPresent([String].self, forKey: .macWebsites) ?? []
        self.macBundleIds = try c.decodeIfPresent([String].self, forKey: .macBundleIds) ?? []
        self.iosAppTokensB64 = try c.decodeIfPresent(String.self, forKey: .iosAppTokensB64)
        self.iosCategoryTokensB64 = try c.decodeIfPresent(String.self, forKey: .iosCategoryTokensB64)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        // Spec 3 (May 2026): tolerate older payloads that lack these fields
        self.strictnessPreset = try c.decodeIfPresent(StrictnessPreset.self, forKey: .strictnessPreset) ?? .standard
        self.pendingStrictnessChange = try c.decodeIfPresent(PendingStrictnessChange.self, forKey: .pendingStrictnessChange)
        self.weeklyBudgetHours = try c.decodeIfPresent(Double.self, forKey: .weeklyBudgetHours)
        self.budgetEnforcement = try c.decodeIfPresent(String.self, forKey: .budgetEnforcement)
    }
}

/// Wire-format payload for POST /intentions (no id, no version).
struct IntentionCreatePayload: Codable, Equatable {
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    var iosAppTokensB64: String?
    var iosCategoryTokensB64: String?

    private enum CodingKeys: String, CodingKey {
        case name, description, icon
        case colorHex = "color_hex"
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokensB64 = "ios_app_tokens_b64"
        case iosCategoryTokensB64 = "ios_category_tokens_b64"
    }
}

/// Wire-format payload for PUT /intentions/{id} (must include current version).
struct IntentionUpdatePayload: Codable, Equatable {
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    var iosAppTokensB64: String?
    var iosCategoryTokensB64: String?
    var version: Int

    private enum CodingKeys: String, CodingKey {
        case name, description, icon, version
        case colorHex = "color_hex"
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokensB64 = "ios_app_tokens_b64"
        case iosCategoryTokensB64 = "ios_category_tokens_b64"
    }
}

/// Wrapper response for GET /intentions.
struct IntentionListResponse: Codable {
    let intentions: [Intention]
}
