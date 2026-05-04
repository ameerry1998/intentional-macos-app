// BlockingProfilesToIntentionsMigration.swift
//
// Spec 3 (May 2026) — One-shot migration: for each existing FocusBlock that
// still references BlockingProfile UUIDs (via the legacy local `profileIds`
// field that lived in the dashboard's daily_schedule.json before Spec 2
// stripped it at decode time), look up the named profile, find or create an
// Intention with the same name + merged blocklist, set the block's
// intentionId to that Intention.
//
// Idempotent: writes a receipt at
//   ~/Library/Application Support/Intentional/migration_profiles_to_intentions_v1.json
// If the receipt is present, the migration is a no-op.
//
// After migration, the Profiles chips UI is hidden in dashboard.html. Per D14,
// BlockingProfileManager and its data file are LEFT INTACT (cleanup is a
// future PR — this preserves rollback safety for one release).
//
// Resumable: partial-receipt writes the set of already-processed block IDs
// after every success, so a network failure on block N restarts at N+1 next
// launch instead of re-creating duplicate Intentions for blocks 1..N-1.

import Foundation

@MainActor
final class BlockingProfilesToIntentionsMigration {
    private let scheduleManager: ScheduleManager
    private let blockingProfileManager: BlockingProfileManager
    private let intentionStore: IntentionStore
    private let backend: BackendClient
    private let receiptURL: URL

    init(scheduleManager: ScheduleManager,
         blockingProfileManager: BlockingProfileManager,
         intentionStore: IntentionStore,
         backend: BackendClient,
         settingsDir: URL) {
        self.scheduleManager = scheduleManager
        self.blockingProfileManager = blockingProfileManager
        self.intentionStore = intentionStore
        self.backend = backend
        self.receiptURL = settingsDir.appendingPathComponent("migration_profiles_to_intentions_v1.json")
    }

    var isCompleted: Bool {
        guard let data = try? Data(contentsOf: receiptURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let completed = json["completed_at"] as? String, !completed.isEmpty else {
            return false
        }
        return true
    }

    func run(log: @escaping (String) -> Void = { _ in }) async {
        guard !isCompleted else {
            log("🔁 BlockingProfilesToIntentions: receipt present, skipping")
            return
        }

        // Hydrate Intentions cache so name-based merge sees fresh data.
        await intentionStore.pull()

        // The schedule's blocks may have a sidecar `profileIds` populated by
        // the dashboard JSON file before the redesign. Read the on-disk schedule
        // to find them (ScheduleManager's in-memory model already drops the
        // field after Spec 2's BackendClient round-trip).
        let blocksWithProfiles = await loadLegacyProfileBindings()
        log("🔁 BlockingProfilesToIntentions: \(blocksWithProfiles.count) blocks with legacy profileIds to migrate")

        if blocksWithProfiles.isEmpty {
            await stampReceipt(processedIds: [])
            log("🔁 BlockingProfilesToIntentions: nothing to migrate, stamping receipt")
            return
        }

        let alreadyProcessed = loadPartialReceipt()
        let pending = blocksWithProfiles.filter { !alreadyProcessed.contains($0.blockId) }

        var processedIds = Array(alreadyProcessed)

        for binding in pending {
            // For each profileId on this block, find or merge into an Intention
            // with the same name. If the block had multiple profiles, we union
            // their blocklists into ONE Intention named after the profile that
            // was sorted alphabetically first.
            let profiles = binding.profileIds.compactMap { id -> BlockingProfile? in
                blockingProfileManager.profiles.first(where: { $0.id == id })
            }
            guard let primary = profiles.sorted(by: { $0.name < $1.name }).first else {
                log("🔁 BlockingProfilesToIntentions: skipping block \(binding.blockId) — no resolvable profiles")
                processedIds.append(binding.blockId)
                continue
            }

            let mergedDomains = profiles.flatMap { $0.blockedDomains }.sorted().reduce(into: [String]()) { acc, d in
                if acc.last != d { acc.append(d) }
            }
            let mergedApps = profiles.flatMap { $0.blockedAppBundleIds }.sorted().reduce(into: [String]()) { acc, b in
                if acc.last != b { acc.append(b) }
            }

            let intention: Intention
            if let existing = await intentionStore.active(named: primary.name) {
                // Set-union with existing
                let unionDomains = Set(existing.macWebsites).union(mergedDomains).sorted()
                let unionApps = Set(existing.macBundleIds).union(mergedApps).sorted()
                let payload = IntentionUpdatePayload(
                    name: existing.name,
                    description: existing.description,
                    colorHex: existing.colorHex,
                    icon: existing.icon,
                    macWebsites: unionDomains,
                    macBundleIds: unionApps,
                    iosAppTokensB64: existing.iosAppTokensB64,
                    iosCategoryTokensB64: existing.iosCategoryTokensB64,
                    version: existing.version
                )
                do {
                    intention = try await intentionStore.update(id: existing.id, payload: payload)
                } catch {
                    log("🔁 BlockingProfilesToIntentions: merge failed for '\(primary.name)' (\(error.localizedDescription))")
                    persistPartialReceipt(processedIds)
                    return
                }
            } else {
                let payload = IntentionCreatePayload(
                    name: primary.name,
                    description: nil,
                    colorHex: nil,
                    icon: nil,
                    macWebsites: mergedDomains,
                    macBundleIds: mergedApps,
                    iosAppTokensB64: nil,
                    iosCategoryTokensB64: nil
                )
                do {
                    intention = try await intentionStore.create(payload)
                } catch {
                    log("🔁 BlockingProfilesToIntentions: create failed for '\(primary.name)' (\(error.localizedDescription))")
                    persistPartialReceipt(processedIds)
                    return
                }
            }

            // Now bind the block to this Intention.
            await scheduleManager.setBlockIntention(blockId: binding.blockId, intentionId: intention.id)
            processedIds.append(binding.blockId)
        }

        await stampReceipt(processedIds: processedIds)
        log("🔁 BlockingProfilesToIntentions: complete (\(processedIds.count) blocks processed)")
    }

    // MARK: - Helpers

    private struct LegacyBinding {
        let blockId: String
        let profileIds: [UUID]
    }

    /// Read legacy schedule JSON (pre-Spec-2) which may still contain `profileIds`
    /// on each block. After Spec 2 the field is dropped at decode time, so we read
    /// the raw JSON instead of using the typed model.
    private func loadLegacyProfileBindings() async -> [LegacyBinding] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Intentional", isDirectory: true)
        let candidates = [
            dir.appendingPathComponent("daily_schedule.json"),
            dir.appendingPathComponent("daily_schedule.legacy.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = root["blocks"] as? [[String: Any]] else { continue }
            var out: [LegacyBinding] = []
            for b in blocks {
                guard let id = b["id"] as? String,
                      let pids = b["profileIds"] as? [String], !pids.isEmpty else { continue }
                let uuids = pids.compactMap { UUID(uuidString: $0) }
                if !uuids.isEmpty { out.append(LegacyBinding(blockId: id, profileIds: uuids)) }
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    private func stampReceipt(processedIds: [String]) async {
        let body: [String: Any] = [
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "version": 1,
            "block_ids_processed": processedIds,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])) ?? Data()
        try? data.write(to: receiptURL, options: .atomic)
    }

    private func loadPartialReceipt() -> Set<String> {
        guard let data = try? Data(contentsOf: receiptURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["partial_processed"] as? [String] else { return [] }
        return Set(arr)
    }

    private func persistPartialReceipt(_ processed: [String]) {
        let body: [String: Any] = [
            "partial_processed": processed,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])) ?? Data()
        try? data.write(to: receiptURL, options: .atomic)
    }
}
