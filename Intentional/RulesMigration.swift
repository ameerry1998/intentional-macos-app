// RulesMigration.swift
//
// Rules Consolidation R6 (June 2026) — one-shot runner that moves the legacy
// list systems into the unified `rules` table (backend) via RuleStore.
//
// Receipt: migration_rules_v1.json (same pattern as IntentionMigration):
//   - {"completed_at": ...} → done, run() is a no-op forever.
//   - {"partial_processed": [keys...]} → a previous run created SOME rules
//     and hit a failure; next launch resumes from where it stopped (created
//     targets are also protected by the server's 409-on-duplicate).
//
// Safety order (zero-data-loss mandate):
//   1. BACKUP first — copy blocking_profiles.json / always_allowed.json /
//      block_rule_snoozes.json to a timestamped backup dir BEFORE any
//      mutation.
//   2. Create all planned rules on the backend (retry once per rule; on a
//      second failure persist partial state and stop — originals untouched).
//   3. ONLY after every create landed: rename originals to *.legacy.json,
//      write fresh EMPTY stores (prevents BlockingProfileManager /
//      AlwaysAllowedStore from re-seeding their defaults on next launch —
//      which would resurrect ghost copies of just-migrated rules), and
//      re-evaluate enforcement.
//   4. Backend always_blocked / distractions rows are NOT deleted — they
//      retire with their endpoints in a later slice.
//
// Dry-run: run(dryRun: true) plans + logs, POSTs nothing, renames nothing.
// Trigger in-app via env INTENTIONAL_RULES_MIGRATION_DRY_RUN=1, or rehearse
// fully outside the app with scripts/rules-migration-dryrun/ (compiles this
// repo's planner against COPIES of the real files).

import Foundation

@MainActor
final class RulesMigration {

    private let settingsDir: URL
    private let ruleStore: RuleStore
    private let backend: BackendClient
    private weak var blockingProfileManager: BlockingProfileManager?
    private weak var alwaysAllowedStore: AlwaysAllowedStore?
    private weak var appDelegate: AppDelegate?

    private let receiptURL: URL
    private var profilesURL: URL { settingsDir.appendingPathComponent("blocking_profiles.json") }
    private var alwaysAllowedURL: URL { settingsDir.appendingPathComponent("always_allowed.json") }
    private var snoozesURL: URL { settingsDir.appendingPathComponent("block_rule_snoozes.json") }

    init(settingsDir: URL,
         ruleStore: RuleStore,
         backend: BackendClient,
         blockingProfileManager: BlockingProfileManager?,
         alwaysAllowedStore: AlwaysAllowedStore?,
         appDelegate: AppDelegate?) {
        self.settingsDir = settingsDir
        self.ruleStore = ruleStore
        self.backend = backend
        self.blockingProfileManager = blockingProfileManager
        self.alwaysAllowedStore = alwaysAllowedStore
        self.appDelegate = appDelegate
        self.receiptURL = settingsDir.appendingPathComponent("migration_rules_v1.json")
    }

    var isCompleted: Bool {
        guard let data = try? Data(contentsOf: receiptURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["completed_at"] is String else { return false }
        return true
    }

    /// Run the migration. Safe to call repeatedly — early-returns when the
    /// receipt is stamped. `dryRun` plans + logs only (no POSTs, no renames).
    func run(dryRun: Bool = false, log: @escaping (String) -> Void = { _ in }) async {
        if isCompleted && !dryRun {
            log("📐 RulesMigration: receipt present, skipping")
            return
        }

        // ── Gather sources ────────────────────────────────────────────────
        let profiles = blockingProfileManager?.profiles ?? []
        let alwaysAllowed = alwaysAllowedStore?.list

        // Backend taxonomy rows. nil = unreachable → abort WITHOUT stamping
        // (we must not stamp a receipt that silently dropped backend rows).
        guard let backendBlocked = await backend.getAppListForMigration(path: "/always_blocked"),
              let backendDistractions = await backend.getAppListForMigration(path: "/distractions") else {
            log("📐 RulesMigration: backend unreachable for always_blocked/distractions — will retry next launch")
            return
        }

        // Existing rules (collision source). A failed pull is tolerable: the
        // server still 409s duplicates and we treat 409 as a logged skip.
        _ = await ruleStore.pull()
        let existingKeys = Set(await ruleStore.all().map {
            RulesMigrationPlan.PlannedRule.key(kind: $0.targetKind, target: $0.target)
        })

        let plan = RulesMigrationPlan.build(profiles: profiles,
                                            alwaysAllowed: alwaysAllowed,
                                            backendAlwaysBlocked: backendBlocked,
                                            backendDistractions: backendDistractions,
                                            existingRuleKeys: existingKeys)

        log("📐 RulesMigration plan — sources: \(profiles.count) profiles, " +
            "\(alwaysAllowed.map { $0.bundleIds.count + $0.domains.count } ?? 0) always-allowed entries, " +
            "\(backendBlocked.count) backend always_blocked, \(backendDistractions.count) backend distractions; " +
            "\(existingKeys.count) rules already on backend")
        for line in RulesMigrationPlan.describe(plan).split(separator: "\n") {
            log("📐   \(line)")
        }

        if dryRun {
            log("📐 RulesMigration: DRY RUN — nothing created, nothing renamed")
            return
        }

        if plan.rules.isEmpty {
            log("📐 RulesMigration: nothing to create — renaming legacy stores + stamping receipt")
            backUpOriginals(log: log)
            retireLegacyStores(log: log)
            stampReceipt(created: 0, skipped: plan.skips.count)
            return
        }

        // ── 1. Backup BEFORE any mutation ─────────────────────────────────
        backUpOriginals(log: log)

        // ── 2. Create rules (resume-aware, retry-once, 409 = skip) ────────
        let alreadyProcessed = loadPartialReceipt()
        var processed = alreadyProcessed
        var created = 0
        var skippedDuplicates = 0

        for planned in plan.rules {
            if alreadyProcessed.contains(planned.key) {
                log("📐   resume: \(planned.key) already processed in a previous run")
                continue
            }
            do {
                _ = try await createWithOneRetry(planned.payload, log: log)
                created += 1
                log("📐   ✓ created \(planned.key) (\(planned.source))")
            } catch BackendClient.RuleError.duplicate {
                skippedDuplicates += 1
                log("📐   ⤫ \(planned.key) already exists on backend (409) — existing rule wins")
            } catch {
                log("📐   ✗ create failed twice for \(planned.key): \(error.localizedDescription) — persisting partial state, resuming next launch")
                persistPartialReceipt(processed)
                return
            }
            processed.insert(planned.key)
            persistPartialReceipt(processed)
        }

        // ── 3. Retire originals (rename → .legacy.json, write empty stores) ─
        retireLegacyStores(log: log)

        stampReceipt(created: created, skipped: plan.skips.count + skippedDuplicates)
        log("📐 RulesMigration: COMPLETE — \(created) rules created, \(plan.skips.count + skippedDuplicates) skips (see receipt)")
    }

    // MARK: - Steps

    private func createWithOneRetry(_ payload: RuleCreatePayload,
                                    log: @escaping (String) -> Void) async throws -> Rule {
        do {
            return try await ruleStore.create(payload)
        } catch BackendClient.RuleError.duplicate {
            throw BackendClient.RuleError.duplicate
        } catch {
            log("📐   retrying \(payload.targetKind.rawValue)|\(payload.target) after: \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 700_000_000)
            return try await ruleStore.create(payload)
        }
    }

    private func backUpOriginals(log: @escaping (String) -> Void) {
        let fm = FileManager.default
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        let backupDir = settingsDir.appendingPathComponent("migration_backup_rules_v1_\(stamp)", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        var copies = 0
        for url in [profilesURL, alwaysAllowedURL, snoozesURL] where fm.fileExists(atPath: url.path) {
            let dest = backupDir.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: url, to: dest)
                copies += 1
            } catch {
                log("📐   ⚠️ backup copy failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        log("📐 RulesMigration: backed up \(copies) file(s) → \(backupDir.lastPathComponent)/")
    }

    private func retireLegacyStores(log: @escaping (String) -> Void) {
        let fm = FileManager.default

        // Rename originals → *.legacy.json (idempotent: clear stale legacy first).
        for url in [profilesURL, alwaysAllowedURL] where fm.fileExists(atPath: url.path) {
            let legacy = url.deletingPathExtension().appendingPathExtension("legacy.json")
            try? fm.removeItem(at: legacy)
            try? fm.moveItem(at: url, to: legacy)
            log("📐   renamed \(url.lastPathComponent) → \(legacy.lastPathComponent)")
        }

        // Write fresh EMPTY stores so the live in-memory state matches the
        // Rules page AND neither store re-seeds its defaults on next launch
        // (BlockingProfileManager seeds "Distracting Apps & Sites" and
        // AlwaysAllowedStore seeds 8 apps + 4 domains when their file is
        // missing — that would resurrect ghost copies of migrated rules).
        blockingProfileManager?.removeAllProfilesForMigration()
        alwaysAllowedStore?.replace(AlwaysAllowedList(bundleIds: [], domains: []))

        // Drop the (now-ownerless) standalone enforcement the profiles fed;
        // the migrated 🚫 rules cover the same targets via RuleStore.
        appDelegate?.applyAlwaysActiveProfiles()
        BlockRuleEnforcer.shared.reevaluateNow()
        log("📐   legacy stores emptied; enforcement re-evaluated (rules layer owns these targets now)")
    }

    // MARK: - Receipt

    private func stampReceipt(created: Int, skipped: Int) {
        let body: [String: Any] = [
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "version": 1,
            "created": created,
            "skipped": skipped,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? data.write(to: receiptURL, options: .atomic)
    }

    private func loadPartialReceipt() -> Set<String> {
        guard let data = try? Data(contentsOf: receiptURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["partial_processed"] as? [String] else { return [] }
        return Set(arr)
    }

    private func persistPartialReceipt(_ processed: Set<String>) {
        let body: [String: Any] = [
            "partial_processed": Array(processed).sorted(),
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? data.write(to: receiptURL, options: .atomic)
    }
}
