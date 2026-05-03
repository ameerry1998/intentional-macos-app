// IntentionMigration.swift
//
// One-time migration from the local-only `Project` model
// (in `projects.json`) to backend-resident `Intention` rows.
//
// Resolves blocklists by reading the project's own `allowed`/`blocked`
// HostItems AND any referenced `BlockingProfileManager` profiles, merging
// them via set-union into the new Intention's `mac_websites` /
// `mac_bundle_ids` lists. Profiles themselves are NOT migrated — they
// stay in their own UI surface.
//
// Idempotent: writes a receipt to `migration_intentions_v1.json`. If the
// receipt is present, migration is a no-op.
//
// Merge-by-name: if the backend already has an active Intention with the
// same name (e.g. iOS migrated first), the local project is merged INTO
// that Intention (set-union of mac_websites / mac_bundle_ids).
//
// On partial failure (e.g. POST fails for project N), the receipt is NOT
// stamped; the migration resumes from project N+1 on next launch.

import Foundation

@MainActor
final class IntentionMigration {

    private let projectStore: ProjectStore?
    private let blockingProfileManager: BlockingProfileManager?
    private let intentionStore: IntentionStore
    private let backend: BackendClient
    private let receiptURL: URL
    private let projectsLegacyURL: URL
    private let projectsCurrentURL: URL

    init(projectStore: ProjectStore?,
         blockingProfileManager: BlockingProfileManager?,
         intentionStore: IntentionStore,
         backend: BackendClient,
         settingsDir: URL) {
        self.projectStore = projectStore
        self.blockingProfileManager = blockingProfileManager
        self.intentionStore = intentionStore
        self.backend = backend
        self.receiptURL = settingsDir.appendingPathComponent("migration_intentions_v1.json")
        self.projectsLegacyURL = settingsDir.appendingPathComponent("projects.legacy.json")
        self.projectsCurrentURL = settingsDir.appendingPathComponent("projects.json")
    }

    var isCompleted: Bool {
        // Stamped means full success. A partial-progress receipt (with
        // partial_processed) is NOT considered completed; we still resume.
        guard let data = try? Data(contentsOf: receiptURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["completed_at"] is String else {
            return false
        }
        return true
    }

    /// Run the migration. Safe to call repeatedly — early-returns if complete.
    func run(log: @escaping (String) -> Void = { _ in }) async {
        if isCompleted {
            log("🔁 IntentionMigration: receipt present, skipping")
            return
        }
        guard let projectStore else {
            log("🔁 IntentionMigration: no projectStore, nothing to do")
            await stampReceipt()
            return
        }

        // Hydrate IntentionStore so merge-by-name has fresh data.
        await intentionStore.pull()

        let projects = await projectStore.list()
        log("🔁 IntentionMigration: \(projects.count) projects to consider")

        if projects.isEmpty {
            await stampReceipt()
            log("🔁 IntentionMigration: nothing to migrate, stamping receipt")
            return
        }

        // Resume support: if receipt has partial state, skip already-processed.
        let alreadyProcessed = loadPartialReceipt()
        var processed: [UUID] = Array(alreadyProcessed)
        let pending = projects.filter { !alreadyProcessed.contains($0.id) }

        for project in pending {
            let merged = mergedBlocklist(for: project)
            let payload = IntentionCreatePayload(
                name: project.name,
                description: project.intention.isEmpty ? nil : project.intention,
                colorHex: project.accent,
                icon: nil,
                macWebsites: merged.domains,
                macBundleIds: merged.appBundleIds,
                iosAppTokensB64: nil,
                iosCategoryTokensB64: nil
            )

            // Merge-by-name: if backend already has this Intention, push our blocklist
            // up via PUT (set-union with existing). Otherwise create.
            if let existing = await intentionStore.active(named: project.name) {
                let unionDomains = Set(existing.macWebsites).union(merged.domains).sorted()
                let unionApps = Set(existing.macBundleIds).union(merged.appBundleIds).sorted()
                let updatePayload = IntentionUpdatePayload(
                    name: existing.name,
                    description: existing.description ?? payload.description,
                    colorHex: existing.colorHex ?? payload.colorHex,
                    icon: existing.icon,
                    macWebsites: unionDomains,
                    macBundleIds: unionApps,
                    iosAppTokensB64: existing.iosAppTokensB64,
                    iosCategoryTokensB64: existing.iosCategoryTokensB64,
                    version: existing.version
                )
                do {
                    _ = try await intentionStore.update(id: existing.id, payload: updatePayload)
                    log("🔁 IntentionMigration: merged \(project.name) → existing intention \(existing.id)")
                } catch {
                    log("🔁 IntentionMigration: merge failed for \(project.name) (\(error.localizedDescription))")
                    persistPartialReceipt(processed)
                    return
                }
            } else {
                do {
                    _ = try await intentionStore.create(payload)
                    log("🔁 IntentionMigration: created intention for \(project.name)")
                } catch {
                    log("🔁 IntentionMigration: create failed for \(project.name) (\(error.localizedDescription))")
                    persistPartialReceipt(processed)
                    return
                }
            }
            processed.append(project.id)
        }

        // All done — rename projects.json + stamp receipt.
        renameProjectsJSON()
        await stampReceipt()
        log("🔁 IntentionMigration: complete, \(processed.count) projects migrated")
    }

    // MARK: - Helpers

    private func mergedBlocklist(for project: Project) -> MergedBlockList {
        let mgr = blockingProfileManager
        let profileMerge = mgr?.mergedBlockList(profileIds: project.blocklistIds)
            ?? MergedBlockList(domains: [], appBundleIds: [])

        // Add project's own allowed/blocked HostItems (treat as additional domains/bundles).
        var domains = Set(profileMerge.domains)
        var apps = Set(profileMerge.appBundleIds)
        for h in project.blocked {
            switch h.kind {
            case .domain: domains.insert(h.value)
            case .appBundleId: apps.insert(h.value)
            }
        }
        return MergedBlockList(
            domains: domains.sorted(),
            appBundleIds: apps.sorted()
        )
    }

    private func renameProjectsJSON() {
        guard FileManager.default.fileExists(atPath: projectsCurrentURL.path) else { return }
        // Remove any existing legacy file from a prior run before moving.
        try? FileManager.default.removeItem(at: projectsLegacyURL)
        try? FileManager.default.moveItem(at: projectsCurrentURL, to: projectsLegacyURL)
    }

    private func stampReceipt() async {
        let body: [String: Any] = [
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "version": 1,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])) ?? Data()
        try? data.write(to: receiptURL, options: .atomic)
    }

    private func loadPartialReceipt() -> Set<UUID> {
        guard let data = try? Data(contentsOf: receiptURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["partial_processed"] as? [String] else {
            return []
        }
        return Set(arr.compactMap(UUID.init(uuidString:)))
    }

    private func persistPartialReceipt(_ processed: [UUID]) {
        let body: [String: Any] = [
            "partial_processed": processed.map { $0.uuidString },
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])) ?? Data()
        try? data.write(to: receiptURL, options: .atomic)
    }
}
