// LearnedSitesStore.swift
//
// Projects-kill B3 (June 2026): learned sites survive the Project model's
// deletion as a small LOCAL store keyed by Intention (Weekly Goal) id —
// per the spec decision "Learned sites: stays local; ported to a small store
// keyed by intentionId; data migrated from projects.legacy.json".
//
// A learned site is a host the user visited during sessions of a goal often
// enough to suggest it belongs on the goal's Allow list. `isPromoted` means
// the user accepted that suggestion (PROMOTE_LEARNED_SITE also appends the
// host to the Intention's allow_websites on the backend — see
// MainWindow.handlePromoteLearnedSite).
//
// Note: the hit-recording feeder has had no callers since the legacy
// Projects dashboard was retired; `recordHit` is kept as the API for a
// future feeder (e.g. FocusMonitor logging relevant hosts during a goal's
// sessions). Promotion still works against migrated data.

import Foundation

struct LearnedSite: Codable, Equatable, Identifiable {
    let id: UUID
    var host: String
    var hitCount: Int
    var lastSeenAt: Date
    var isPromoted: Bool
}

/// Actor-isolated JSON-backed store. Persists to
/// `<settingsDir>/learned_sites.json` as `{ "<intention uuid>": [LearnedSite] }`.
actor LearnedSitesStore {

    static let shared = LearnedSitesStore()

    static let learnedCap = 200

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let fileURL: URL
    private let receiptURL: URL
    private let legacyProjectsURL: URL

    /// Keyed by lowercased intention UUID string.
    private var sitesByIntention: [String: [LearnedSite]] = [:]

    init(settingsDir: String? = nil) {
        let dirURL: URL
        if let settingsDir = settingsDir {
            dirURL = URL(fileURLWithPath: settingsDir)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dirURL = support.appendingPathComponent("Intentional", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        self.fileURL = dirURL.appendingPathComponent("learned_sites.json")
        self.receiptURL = dirURL.appendingPathComponent("migration_learned_sites_v1.json")
        self.legacyProjectsURL = dirURL.appendingPathComponent("projects.legacy.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode([String: [LearnedSite]].self, from: data) {
            self.sitesByIntention = decoded
        }
    }

    private func key(_ intentionId: UUID) -> String { intentionId.uuidString.lowercased() }

    // MARK: - Queries

    func learned(for intentionId: UUID) -> [LearnedSite] {
        sitesByIntention[key(intentionId)] ?? []
    }

    // MARK: - Mutations

    func recordHit(intentionId: UUID, host: String) {
        let k = key(intentionId)
        var sites = sitesByIntention[k] ?? []
        let now = Date()
        if let idx = sites.firstIndex(where: { $0.host == host }) {
            sites[idx].hitCount += 1
            sites[idx].lastSeenAt = now
        } else {
            sites.append(LearnedSite(id: UUID(), host: host, hitCount: 1, lastSeenAt: now, isPromoted: false))
            Self.evictIfNeeded(&sites)
        }
        sitesByIntention[k] = sites
        persist()
    }

    /// Mark `host` promoted for the goal. Creates the entry when absent (a
    /// promote is itself the strongest signal). Returns the resulting entry.
    @discardableResult
    func promote(intentionId: UUID, host: String) -> LearnedSite {
        let k = key(intentionId)
        var sites = sitesByIntention[k] ?? []
        let result: LearnedSite
        if let idx = sites.firstIndex(where: { $0.host == host }) {
            sites[idx].isPromoted = true
            sites[idx].lastSeenAt = Date()
            result = sites[idx]
        } else {
            let entry = LearnedSite(id: UUID(), host: host, hitCount: 1, lastSeenAt: Date(), isPromoted: true)
            sites.append(entry)
            Self.evictIfNeeded(&sites)
            result = entry
        }
        sitesByIntention[k] = sites
        persist()
        return result
    }

    // MARK: - One-shot migration from projects.legacy.json

    /// Maps each legacy Project's `learned` array to the Intention with the
    /// same name (the May 2026 IntentionMigration created/merged Intentions
    /// by project name — the receipt carries no id mapping, so name is the
    /// only join key). Unmatched projects are logged and skipped. Idempotent
    /// via receipt; merge keeps the higher hitCount / promoted flag on
    /// collision so re-runs can't lose data.
    func migrateFromLegacyProjectsIfNeeded(intentionStore: IntentionStore,
                                           log: @escaping (String) -> Void = { _ in }) async {
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            return
        }
        guard let data = try? Data(contentsOf: legacyProjectsURL),
              let projects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            log("📚 LearnedSites migration: no readable projects.legacy.json — stamping receipt")
            stampReceipt(migrated: 0, skipped: 0)
            return
        }

        let iso = ISO8601DateFormatter()
        var migrated = 0
        var skipped = 0
        for project in projects {
            guard let name = project["name"] as? String,
                  let learnedRaw = project["learned"] as? [[String: Any]],
                  !learnedRaw.isEmpty else { continue }
            guard let intention = await intentionStore.active(named: name) else {
                skipped += 1
                log("📚 LearnedSites migration: no Intention named \"\(name)\" — skipping \(learnedRaw.count) learned site(s)")
                continue
            }
            let k = key(intention.id)
            var sites = sitesByIntention[k] ?? []
            for raw in learnedRaw {
                guard let host = raw["host"] as? String else { continue }
                let hitCount = raw["hitCount"] as? Int ?? 1
                let isPromoted = raw["isPromoted"] as? Bool ?? false
                let lastSeen = (raw["lastSeenAt"] as? String).flatMap { iso.date(from: $0) } ?? Date()
                if let idx = sites.firstIndex(where: { $0.host == host }) {
                    sites[idx].hitCount = max(sites[idx].hitCount, hitCount)
                    sites[idx].isPromoted = sites[idx].isPromoted || isPromoted
                } else {
                    sites.append(LearnedSite(
                        id: UUID(), host: host, hitCount: hitCount,
                        lastSeenAt: lastSeen, isPromoted: isPromoted
                    ))
                }
            }
            Self.evictIfNeeded(&sites)
            sitesByIntention[k] = sites
            migrated += learnedRaw.count
            log("📚 LearnedSites migration: \(learnedRaw.count) site(s) \"\(name)\" → intention \(intention.id.uuidString.prefix(8))")
        }
        persist()
        stampReceipt(migrated: migrated, skipped: skipped)
        log("📚 LearnedSites migration complete: \(migrated) site(s) migrated, \(skipped) project(s) unmatched")
    }

    private func stampReceipt(migrated: Int, skipped: Int) {
        let body: [String: Any] = [
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "version": 1,
            "migrated_sites": migrated,
            "skipped_projects": skipped,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])) ?? Data()
        try? data.write(to: receiptURL, options: .atomic)
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try Self.encoder.encode(sitesByIntention)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ [LearnedSitesStore] persist failed: \(error)")
        }
    }

    // MARK: - Helpers

    /// LRU-ish eviction (ported from ProjectStore): drop unpromoted entries
    /// with lowest hitCount first, tiebreak oldest lastSeenAt. Promoted kept.
    private static func evictIfNeeded(_ sites: inout [LearnedSite]) {
        guard sites.count > learnedCap else { return }
        let overflow = sites.count - learnedCap
        let victims = sites.enumerated()
            .filter { !$0.element.isPromoted }
            .sorted { a, b in
                if a.element.hitCount != b.element.hitCount { return a.element.hitCount < b.element.hitCount }
                return a.element.lastSeenAt < b.element.lastSeenAt
            }
            .prefix(overflow)
            .map { $0.offset }
        let dropSet = Set(victims)
        sites = sites.enumerated().compactMap { dropSet.contains($0.offset) ? nil : $0.element }
    }
}
