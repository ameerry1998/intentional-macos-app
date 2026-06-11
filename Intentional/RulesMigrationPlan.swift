// RulesMigrationPlan.swift
//
// Rules Consolidation R6 (June 2026) — PURE planning logic for the one-shot
// legacy-lists → unified-rules migration. No I/O, no network, no AppKit:
// this file (plus BlockingProfileManager.swift, AlwaysAllowedList.swift,
// Rule.swift, EnforcementCache.swift for AnyCodable) compiles standalone with
// `swiftc` so the dry-run rehearsal driver (scripts/rules-migration-dryrun/)
// exercises EXACTLY the mapping the app ships — no parallel reimplementation.
//
// Sources → treatments (spec decision #6, plan R6):
//   - BlockingProfile block rules (blocking_profiles.json) → 🚫 blocked,
//     schedule windows + enabled state preserved. Schedule blob matches what
//     the Rules page editor writes (R3): { start: "HH:MM", end: "HH:MM",
//     days: [1..7] } (ISO, Mon=1).
//   - AlwaysAllowedStore (always_allowed.json) apps + sites → ✅ allowed.
//   - Backend per-account always_blocked + distractions rows → 🚫 blocked.
//   - NOTHING auto-becomes ⏳ limited (limits are opt-in).
//
// Collision rules:
//   - Same target planned as both 🚫 and ✅ → blocked beats allowed (skip
//     logged).
//   - Same target planned twice as 🚫 (e.g. youtube.com in two profiles) →
//     the STRICTER copy wins: enabled beats disabled, always-active beats
//     scheduled (skip logged for the merged-away copy).
//   - Target already has a rule on the backend → skipped (existing rule wins;
//     the per-user receipt + server 409 both make this idempotent across the
//     two-user split-brain on the dev Mac).

import Foundation

enum RulesMigrationPlan {

    struct PlannedRule {
        let payload: RuleCreatePayload
        /// Human label for logs/receipt, e.g. `profile "Block streaming"`.
        let source: String

        var key: String {
            Self.key(kind: payload.targetKind, target: payload.target)
        }
        static func key(kind: RuleTargetKind, target: String) -> String {
            "\(kind.rawValue)|\(target)"
        }
        /// Strictness rank for blocked-vs-blocked merges:
        /// enabled+always (3) > enabled+scheduled (2) > disabled+always (1)
        /// > disabled+scheduled (0).
        var strictnessRank: Int {
            (payload.enabled ? 2 : 0) + (payload.schedule == nil ? 1 : 0)
        }
    }

    struct Skip {
        let kind: RuleTargetKind
        let target: String
        let reason: String
        let source: String
    }

    struct Output {
        var rules: [PlannedRule] = []
        var skips: [Skip] = []
        /// Informational notes (not skips) — e.g. activeDays dropped because
        /// the profile had no time window.
        var notes: [String] = []
    }

    // MARK: - Target normalization / classification

    /// Mirror of the backend's site normalization (lowercase, scheme / "www."
    /// prefix / path stripped) so client-side dedupe agrees with the server.
    static func normalizeSiteTarget(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s
    }

    /// Reverse-DNS prefixes that mark a bundle id. Domains essentially never
    /// START with these labels, while every macOS bundle id does.
    private static let bundleIdPrefixes: Set<String> = [
        "com", "org", "net", "io", "co", "app", "dev", "ai", "me", "tv",
        "us", "uk", "ca", "de", "fr", "jp", "edu", "gov", "info", "biz",
        "sh", "gg", "so", "fm", "ws", "cc", "tw", "ly", "company",
    ]

    /// Backend `app_identifier` columns are free text (bundle id OR domain,
    /// no kind discriminator — research §2.1). Classify by shape:
    /// reverse-DNS first label → app; anything else → site.
    static func classifyIdentifier(_ raw: String) -> RuleTargetKind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("://") || s.contains("/") { return .site }
        let labels = s.lowercased().split(separator: ".")
        guard labels.count >= 2 else { return .site }
        if let first = labels.first, bundleIdPrefixes.contains(String(first)) {
            return .app
        }
        return .site
    }

    // MARK: - Schedule conversion (profile window → R3 blob)

    /// `{ start: "HH:MM", end: "HH:MM", days: [1..7] }` — exactly the shape
    /// the Rules page editor writes and EnforcementResolver.scheduleActive
    /// reads. nil when the profile has no time window (matches legacy
    /// semantics: BlockingProfile.isCurrentlyActive ignores activeDays when
    /// startHour/endHour are unset).
    static func scheduleBlob(for profile: BlockingProfile) -> [String: AnyCodable]? {
        guard let sh = profile.startHour, let eh = profile.endHour else { return nil }
        let sm = profile.startMinute ?? 0
        let em = profile.endMinute ?? 0
        var days = profile.activeDays.filter { (1...7).contains($0) }.sorted()
        if days.isEmpty { days = [1, 2, 3, 4, 5, 6, 7] }
        return [
            "start": AnyCodable(String(format: "%02d:%02d", sh, sm)),
            "end": AnyCodable(String(format: "%02d:%02d", eh, em)),
            "days": AnyCodable(days),
        ]
    }

    // MARK: - The plan

    static func build(profiles: [BlockingProfile],
                      alwaysAllowed: AlwaysAllowedList?,
                      backendAlwaysBlocked: [String],
                      backendDistractions: [String],
                      existingRuleKeys: Set<String>) -> Output {
        var out = Output()
        // key → planned blocked rule (insertion order preserved separately)
        var blockedByKey: [String: PlannedRule] = [:]
        var blockedOrder: [String] = []

        func planBlocked(_ candidate: PlannedRule) {
            let key = candidate.key
            if let existing = blockedByKey[key] {
                // Stricter copy wins; merged-away copy is logged.
                if candidate.strictnessRank > existing.strictnessRank {
                    blockedByKey[key] = candidate
                    out.skips.append(Skip(kind: existing.payload.targetKind,
                                          target: existing.payload.target,
                                          reason: "duplicate 🚫 target — stricter copy from \(candidate.source) wins",
                                          source: existing.source))
                } else {
                    out.skips.append(Skip(kind: candidate.payload.targetKind,
                                          target: candidate.payload.target,
                                          reason: "duplicate 🚫 target — already planned from \(existing.source)",
                                          source: candidate.source))
                }
                return
            }
            blockedByKey[key] = candidate
            blockedOrder.append(key)
        }

        // 1. BlockingProfile block rules → 🚫 (schedules + enabled preserved).
        for profile in profiles {
            let schedule = scheduleBlob(for: profile)
            let source = "profile \"\(profile.name)\""
            if schedule == nil, profile.startHour == nil, profile.activeDays.count < 7 {
                out.notes.append("\(source): activeDays \(profile.activeDays.sorted()) dropped — profile had no time window, and legacy enforcement ignored days without hours")
            }
            for domain in profile.blockedDomains {
                let target = normalizeSiteTarget(domain)
                guard !target.isEmpty else { continue }
                planBlocked(PlannedRule(
                    payload: RuleCreatePayload(targetKind: .site, target: target,
                                               treatment: .blocked, schedule: schedule,
                                               enabled: profile.enabled),
                    source: source))
            }
            for bid in profile.blockedAppBundleIds {
                let target = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else { continue }
                planBlocked(PlannedRule(
                    payload: RuleCreatePayload(targetKind: .app, target: target,
                                               treatment: .blocked, schedule: schedule,
                                               enabled: profile.enabled),
                    source: source))
            }
        }

        // 2. Backend always_blocked + distractions rows → 🚫 (enabled, always).
        //    Neither table was ever enforced on the Mac (research §2.4), but
        //    the user explicitly wrote these targets down as distractions —
        //    they become real 🚫 rules now. NOTHING auto-becomes ⏳.
        for (rows, label) in [(backendAlwaysBlocked, "backend always_blocked"),
                              (backendDistractions, "backend distractions")] {
            for raw in rows {
                let kind = classifyIdentifier(raw)
                let target = kind == .site
                    ? normalizeSiteTarget(raw)
                    : raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else { continue }
                planBlocked(PlannedRule(
                    payload: RuleCreatePayload(targetKind: kind, target: target,
                                               treatment: .blocked, schedule: nil,
                                               enabled: true),
                    source: label))
            }
        }

        // 3. AlwaysAllowedStore → ✅. Blocked beats allowed on collision.
        var allowed: [PlannedRule] = []
        if let aa = alwaysAllowed {
            for bid in aa.bundleIds.sorted() {
                let target = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else { continue }
                allowed.append(PlannedRule(
                    payload: RuleCreatePayload(targetKind: .app, target: target,
                                               treatment: .allowed, schedule: nil,
                                               enabled: true),
                    source: "always_allowed apps"))
            }
            for domain in aa.domains.sorted() {
                let target = normalizeSiteTarget(domain)
                guard !target.isEmpty else { continue }
                allowed.append(PlannedRule(
                    payload: RuleCreatePayload(targetKind: .site, target: target,
                                               treatment: .allowed, schedule: nil,
                                               enabled: true),
                    source: "always_allowed sites"))
            }
        }

        // Assemble: blocked first (insertion order), then allowed minus
        // collisions, then drop anything that already exists on the backend.
        var assembled: [PlannedRule] = blockedOrder.compactMap { blockedByKey[$0] }
        for candidate in allowed {
            if blockedByKey[candidate.key] != nil {
                out.skips.append(Skip(kind: candidate.payload.targetKind,
                                      target: candidate.payload.target,
                                      reason: "🚫 beats ✅ — target is also planned as blocked",
                                      source: candidate.source))
                continue
            }
            assembled.append(candidate)
        }
        for candidate in assembled {
            if existingRuleKeys.contains(candidate.key) {
                out.skips.append(Skip(kind: candidate.payload.targetKind,
                                      target: candidate.payload.target,
                                      reason: "a rule for this target already exists on the backend",
                                      source: candidate.source))
            } else {
                out.rules.append(candidate)
            }
        }
        return out
    }

    // MARK: - Pretty-print (shared by dry-run driver + in-app dry-run log)

    static func describe(_ output: Output) -> String {
        var lines: [String] = []
        lines.append("Planned rules: \(output.rules.count)")
        for r in output.rules {
            let sched: String
            if let s = r.payload.schedule,
               let start = s["start"]?.value as? String,
               let end = s["end"]?.value as? String {
                let days = (s["days"]?.value as? [Int]) ?? []
                sched = " sched=\(start)-\(end) days=\(days)"
            } else {
                sched = ""
            }
            let glyph = r.payload.treatment == .blocked ? "🚫" : (r.payload.treatment == .allowed ? "✅" : "⏳")
            lines.append("  \(glyph) \(r.payload.targetKind.rawValue) \(r.payload.target) enabled=\(r.payload.enabled)\(sched)  ← \(r.source)")
        }
        lines.append("Skips: \(output.skips.count)")
        for s in output.skips {
            lines.append("  ⤫ \(s.kind.rawValue) \(s.target) (\(s.source)) — \(s.reason)")
        }
        for n in output.notes {
            lines.append("  ℹ︎ \(n)")
        }
        return lines.joined(separator: "\n")
    }
}
