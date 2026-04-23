//
//  EnforcementCache.swift
//  Intentional
//
//  Reads and writes the daemon-signed enforcement cache.
//  See docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md §5.5.
//

import Foundation

struct EnforcementCacheData: Codable {
    let deviceId: String
    let enforcementActive: Bool
    let constraints: [String: [String: AnyCodable]]
    let temporaryUnlockUntil: String?
    let updatedAt: String?
    let cachedAt: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case enforcementActive = "enforcement_active"
        case constraints
        case temporaryUnlockUntil = "temporary_unlock_until"
        case updatedAt = "updated_at"
        case cachedAt = "cached_at"
    }
}

/// Helper for encoding heterogeneous constraint-spec dictionaries.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Int.self)  { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([String].self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value }; return }
        if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value }; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:      try c.encode(v)
        case let v as Int:       try c.encode(v)
        case let v as Double:    try c.encode(v)
        case let v as String:    try c.encode(v)
        case let v as [String]:  try c.encode(v)
        case let v as [Any]:     try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}

final class EnforcementCache {

    private static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Intentional/enforcement_cache.json")
    }()

    private static let signatureURL: URL = {
        fileURL.deletingLastPathComponent().appendingPathComponent("enforcement_cache.sig")
    }()

    /// Write cache atomically. Signature stored alongside as a base64 text file.
    static func write(cache: EnforcementCacheData, signature: Data) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // canonical form for signing
        let json = try encoder.encode(cache)

        // Ensure parent dir exists
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Atomic write
        try json.write(to: fileURL, options: .atomic)
        try signature.base64EncodedString().data(using: .utf8)!.write(to: signatureURL, options: .atomic)
    }

    /// Read cache + signature from disk. Returns nil if either is missing.
    static func read() -> (cache: EnforcementCacheData, canonicalJSON: Data, signature: Data)? {
        guard let json = try? Data(contentsOf: fileURL),
              let sigB64 = try? Data(contentsOf: signatureURL),
              let sigString = String(data: sigB64, encoding: .utf8),
              let signature = Data(base64Encoded: sigString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }

        let decoder = JSONDecoder()
        guard let cache = try? decoder.decode(EnforcementCacheData.self, from: json) else {
            return nil
        }

        // Re-encode canonically for signature verification.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let canonical = try? encoder.encode(cache) else { return nil }

        return (cache, canonical, signature)
    }

    /// Remove cache + signature (used when we detect corruption).
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: signatureURL)
    }
}
