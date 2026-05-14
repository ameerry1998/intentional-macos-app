// IntentTextMigration.swift
//
// One-shot migration: for each Intention with empty `intentText` and non-empty
// `description`, copy `description` into `intentText` so the per-goal AI
// scoring text seeds from the existing free-text field.
//
// Idempotent via receipt at:
//   ~/Library/Application Support/Intentional/migration_intent_text_v1.json
//
// Best-effort — individual failures don't block the receipt being stamped.

import Foundation

enum IntentTextMigration {
    private static var receiptURL: URL {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Intentional", isDirectory: true)
        return dir.appendingPathComponent("migration_intent_text_v1.json")
    }

    /// True iff the migration has already run.
    static var isCompleted: Bool {
        FileManager.default.fileExists(atPath: receiptURL.path)
    }

    /// Run the migration. No-op if receipt is present.
    @discardableResult
    static func runIfNeeded(intentionStore: IntentionStore, log: ((String) -> Void)? = nil) async -> Bool {
        if isCompleted {
            log?("🔁 IntentTextMigration: receipt present, skipping")
            return false
        }
        let all = await intentionStore.active()
        log?("🔁 IntentTextMigration: \(all.count) intentions to inspect")
        var copied = 0
        for i in all {
            let intentText = (i.intentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let description = (i.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard intentText.isEmpty, !description.isEmpty else { continue }
            // Build a payload that copies description into intent_text and preserves everything else.
            let payload = IntentionUpdatePayload(
                name: i.name,
                description: i.description,
                colorHex: i.colorHex,
                icon: i.icon,
                macWebsites: i.macWebsites,
                macBundleIds: i.macBundleIds,
                iosAppTokensB64: i.iosAppTokensB64,
                iosCategoryTokensB64: i.iosCategoryTokensB64,
                version: i.version,
                outcome: i.outcome,
                status: i.status,
                weeklyTargetHours: i.weeklyTargetHours,
                intentText: i.description,           // <-- copy
                aiScoringEnabled: i.aiScoringEnabled,
                allowWebsites: i.allowWebsites,
                allowBundleIds: i.allowBundleIds,
                monthlyGoalId: i.monthlyGoalId,
                weekOf: i.weekOf
            )
            do {
                _ = try await intentionStore.update(id: i.id, payload: payload)
                copied += 1
            } catch {
                log?("🔁 IntentTextMigration: update failed for \(i.id) (\(error.localizedDescription))")
                // best effort — continue
            }
        }
        let receipt: [String: Any] = [
            "ran_at": ISO8601DateFormatter().string(from: Date()),
            "version": 1,
            "copied": copied,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted]) {
            try? data.write(to: receiptURL, options: .atomic)
        }
        log?("🔁 IntentTextMigration: complete, copied \(copied) intent_text fields")
        return true
    }
}
