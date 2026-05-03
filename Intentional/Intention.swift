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
    }

    init(id: UUID, name: String, description: String? = nil,
         colorHex: String? = nil, icon: String? = nil,
         macWebsites: [String] = [], macBundleIds: [String] = [],
         iosAppTokensB64: String? = nil, iosCategoryTokensB64: String? = nil,
         version: Int = 1, createdAt: Date = Date(),
         updatedAt: Date = Date(), deletedAt: Date? = nil) {
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
