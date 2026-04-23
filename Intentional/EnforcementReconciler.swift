//
//  EnforcementReconciler.swift
//  Intentional
//
//  Orchestrates enforcement: Phase A (blocking, local cache verify + correction),
//  Phase B (async, backend fetch + re-sign cache), heartbeat, post-unlock refresh.
//
//  Callers:
//    - AppDelegate step 15b — reconciler.runBlockingPhaseA()
//    - AppDelegate async after 15b — reconciler.runPhaseB()
//    - Heartbeat every 5 min — reconciler.refreshIfDue()
//    - BackendClient.verifyUnlock success — reconciler.refresh()
//
//  See docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md §5.
//

import Foundation
import AppKit

struct EnforcementSnapshot {
    let enforcementActive: Bool
    let constraints: [String: [String: Any]]
    let temporaryUnlockUntil: String?
    let asOf: Date
    let source: Source

    enum Source: String { case cache, backend, defaults, empty }
}

final class EnforcementReconciler {

    weak var appDelegate: AppDelegate?
    private let backendClient: BackendClient
    private let daemonClient: EnforcementDaemonClient
    private(set) var current: EnforcementSnapshot?

    private let settingsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Intentional/onboarding_settings.json")
    }()

    private let reconcileInterval: TimeInterval = 5 * 60
    private var lastReconcile: Date?

    init(appDelegate: AppDelegate, backendClient: BackendClient, daemonClient: EnforcementDaemonClient) {
        self.appDelegate = appDelegate
        self.backendClient = backendClient
        self.daemonClient = daemonClient
    }

    // MARK: Phase A — blocking, local cache verify

    /// Must complete before ContentSafetyMonitor starts so CS sees verified state.
    func runBlockingPhaseA() async {
        appDelegate?.postLog("🛡️ Enforcement Phase A: verifying cache…")

        // Try daemon-signed cache first.
        if daemonClient.daemonAvailable,
           let triple = EnforcementCache.read() {
            let ok = await daemonClient.verify(payload: triple.canonicalJSON, signature: triple.signature)
            if ok {
                let snapshot = EnforcementSnapshot(
                    enforcementActive: triple.cache.enforcementActive,
                    constraints: triple.cache.constraints.mapValues { dict in
                        dict.mapValues { $0.value }
                    },
                    temporaryUnlockUntil: triple.cache.temporaryUnlockUntil,
                    asOf: Date(),
                    source: .cache
                )
                current = snapshot
                applyCorrections(snapshot, logPrefix: "Phase A cache-hit")
                return
            } else {
                appDelegate?.postLog("🛡️ Enforcement Phase A: cache signature INVALID — TAMPER")
                EnforcementCache.clear()
                fallbackMaxStrictness(reason: "invalid cache signature")
                return
            }
        }

        // No cache (or daemon unavailable). Could be first run OR tamper (cache deleted).
        // Backend answers this in Phase B.
        appDelegate?.postLog("🛡️ Enforcement Phase A: no cache — awaiting backend response in Phase B")
        current = EnforcementSnapshot(
            enforcementActive: false, constraints: [:], temporaryUnlockUntil: nil,
            asOf: Date(), source: .empty
        )
    }

    // MARK: Phase B — async, backend fetch

    func runPhaseB() async {
        appDelegate?.postLog("🛡️ Enforcement Phase B: fetching backend state…")
        guard let result = await backendClient.fetchEnforcement() else {
            // Backend unreachable. If we have no cache AND this device has ever been onboarded,
            // fall back to max-strictness. Fresh install offline → stay empty (no enforcement).
            if current?.source == .empty {
                let settings = (try? Data(contentsOf: settingsURL))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let hasConsent = (settings["consentStatus"] as? String) == "confirmed"
                if hasConsent {
                    fallbackMaxStrictness(reason: "backend unreachable, onboarded device, no cache")
                }
            }
            return
        }

        let snapshot = EnforcementSnapshot(
            enforcementActive: result.enforcementActive,
            constraints: result.constraints,
            temporaryUnlockUntil: result.temporaryUnlockUntil,
            asOf: Date(),
            source: .backend
        )
        current = snapshot
        lastReconcile = Date()

        // Sign + write cache if daemon is available.
        if daemonClient.daemonAvailable {
            let cacheData = EnforcementCacheData(
                deviceId: result.deviceId,
                enforcementActive: result.enforcementActive,
                constraints: result.constraints.mapValues { inner in
                    inner.mapValues { AnyCodable($0) }
                },
                temporaryUnlockUntil: result.temporaryUnlockUntil,
                updatedAt: result.updatedAt,
                cachedAt: ISO8601DateFormatter().string(from: Date())
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let canonical = try? encoder.encode(cacheData),
               let signature = await daemonClient.sign(canonical) {
                try? EnforcementCache.write(cache: cacheData, signature: signature)
                appDelegate?.postLog("🛡️ Enforcement: cache re-signed (\(result.constraints.count) constraints)")
            }
        } else {
            appDelegate?.postLog("🛡️ Enforcement: daemon unavailable — cache not signed (degraded mode)")
        }

        applyCorrections(snapshot, logPrefix: "Phase B backend-synced")
        pushStateToDashboard()
    }

    // MARK: Refresh hooks

    func refreshIfDue() async {
        if let last = lastReconcile, Date().timeIntervalSince(last) < reconcileInterval {
            return
        }
        await runPhaseB()
    }

    func refresh() async {
        await runPhaseB()
    }

    // MARK: Corrections

    /// Maps enforcement blob keys (snake_case, backend-canonical) to the corresponding
    /// keypath in `onboarding_settings.json` (camelCase, client-canonical). Without this
    /// translation, the reconciler looks up non-existent paths and silently fails to
    /// correct the file even though runtime services get the right signal.
    private static let enforcementToSettingsKeyPath: [String: String] = [
        "content_safety.enabled":           "contentSafety.enabled",
        "platforms.youtube.enabled":        "platforms.youtube.enabled",
        "platforms.youtube.threshold":      "platforms.youtube.threshold",
        "platforms.youtube.block_shorts":   "platforms.youtube.blockShorts",
        "platforms.youtube.block_reels":    "platforms.youtube.blockReels",
        "platforms.instagram.enabled":      "platforms.instagram.enabled",
        "platforms.instagram.threshold":    "platforms.instagram.threshold",
        "platforms.instagram.block_reels":  "platforms.instagram.blockReels",
        "platforms.facebook.enabled":       "platforms.facebook.enabled",
        "platforms.facebook.block_watch":   "platforms.facebook.blockWatch",
        "platforms.facebook.block_reels":   "platforms.facebook.blockReels",
        "platforms.facebook.block_gaming":  "platforms.facebook.blockGaming",
        "platforms.facebook.block_sponsored":  "platforms.facebook.blockSponsored",
        "platforms.facebook.block_suggested":  "platforms.facebook.blockSuggested",
        "distracting_sites":                "distractingSites",
    ]

    private static func settingsPath(for enforcementKey: String) -> String {
        return enforcementToSettingsKeyPath[enforcementKey] ?? enforcementKey
    }

    private func applyCorrections(_ snapshot: EnforcementSnapshot, logPrefix: String) {
        guard snapshot.enforcementActive, !snapshot.constraints.isEmpty else { return }

        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            appDelegate?.postLog("⚠️ \(logPrefix): cannot read onboarding_settings.json")
            return
        }

        var violations: [(String, Any)] = []  // (key, correction) — enforcement key (snake_case)

        for (key, spec) in snapshot.constraints {
            let constraint = ConstraintEvaluator.parse(spec)
            let localPath = Self.settingsPath(for: key)
            let current = getValue(forKeyPath: localPath, in: settings)
            let result = ConstraintEvaluator.evaluate(key: key, constraint: constraint, currentValue: current)
            switch result {
            case .satisfied:
                continue
            case .violated(let correction):
                settings = setValue(correction, forKeyPath: localPath, in: settings)
                violations.append((key, correction))
            case .cannotAutoCorrect:
                appDelegate?.postLog("⚠️ \(logPrefix): unknown constraint for \(key)")
                Task {
                    await appDelegate?.backendClient?.reportContentSafetyTamper(
                        eventType: "unknown_constraint_type",
                        detail: key
                    )
                }
            }
        }

        if violations.isEmpty { return }

        appDelegate?.postLog("🛡️ \(logPrefix): \(violations.count) violations corrected")

        if let new = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
            try? new.write(to: settingsURL, options: .atomic)
        }

        // Notify runtime services of changes they care about.
        for (key, _) in violations {
            if key == "content_safety.enabled" {
                appDelegate?.contentSafetyMonitor?.onSettingsChanged(enabled: true)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.appDelegate?.tamperOverlayController?.show(violations: violations)
        }
        Task {
            let detail = violations.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
            await appDelegate?.backendClient?.reportContentSafetyTamper(
                eventType: "enforcement_mismatch",
                detail: detail
            )
        }
    }

    private func fallbackMaxStrictness(reason: String) {
        appDelegate?.postLog("🛡️ Enforcement: FAIL-CLOSED fallback — \(reason)")
        let defaults: [String: [String: Any]] = [
            "content_safety.enabled": ["type": "must_be_true"],
        ]
        let snapshot = EnforcementSnapshot(
            enforcementActive: true,
            constraints: defaults,
            temporaryUnlockUntil: nil,
            asOf: Date(),
            source: .defaults
        )
        current = snapshot
        applyCorrections(snapshot, logPrefix: "fallback-max-strictness")
    }

    // MARK: Dashboard bridge

    func pushStateToDashboard() {
        guard let snapshot = current else { return }
        let payload: [String: Any] = [
            "enforcement_active": snapshot.enforcementActive,
            "constraints": snapshot.constraints,
            "temporary_unlock_until": snapshot.temporaryUnlockUntil as Any,
            "source": snapshot.source.rawValue,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        appDelegate?.mainWindowController?.callJS("window._enforcementState && window._enforcementState(\(json))")
    }

    // MARK: KeyPath helpers

    private func getValue(forKeyPath path: String, in dict: [String: Any]) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        var current: Any? = dict
        for part in parts {
            guard let sub = current as? [String: Any] else { return nil }
            current = sub[part]
        }
        return current
    }

    private func setValue(_ value: Any, forKeyPath path: String, in dict: [String: Any]) -> [String: Any] {
        var parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return dict }
        var result = dict
        if parts.count == 1 {
            result[parts[0]] = value
            return result
        }
        let first = parts.removeFirst()
        let sub = (result[first] as? [String: Any]) ?? [:]
        result[first] = setValue(value, forKeyPath: parts.joined(separator: "."), in: sub)
        return result
    }
}
