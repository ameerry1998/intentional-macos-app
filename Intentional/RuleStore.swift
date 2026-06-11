// RuleStore.swift
//
// Actor-isolated store for unified `Rule` records + the shared daily
// `LeisurePool` (Rules Consolidation R2, June 2026). Mirrors IntentionStore:
//   - Pull on launch, on app foreground (didBecomeActive), every 60s.
//   - Push on user-driven create/update/delete (immediately), with
//     optimistic local apply + server reconcile (revert on failure).
//   - Offline = serve the local cache (rules.json / leisure_pool.json).
// Rules are hard-deleted on the backend (no tombstones) — pull() replaces
// the whole local set, so deletes from other devices converge within 60s.
//
// R2 is data-layer only. Enforcement wiring (WebsiteBlocker/FocusMonitor
// reading treatments, ⏳ spend metering) lands in R4/R5.

import Foundation
import AppKit

actor RuleStore {
    static let shared = RuleStore()

    private weak var backend: BackendClient?
    private weak var appDelegate: AppDelegate?

    /// All rules known to this device, keyed by id.
    private var byId: [UUID: Rule] = [:]
    /// Last-known leisure pool (today's, per server-local date). Serve-stale
    /// when offline; refreshed alongside rules on the sync rhythm.
    private var cachedPool: LeisurePool?

    private var pullTimer: Timer?

    private let fileURL: URL
    private let poolFileURL: URL
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    init(settingsDir: String? = nil) {
        let dirURL: URL
        if let settingsDir {
            dirURL = URL(fileURLWithPath: settingsDir)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dirURL = support.appendingPathComponent("Intentional", isDirectory: true)
        }
        self.fileURL = dirURL.appendingPathComponent("rules.json")
        self.poolFileURL = dirURL.appendingPathComponent("leisure_pool.json")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        loadFromDisk()
    }

    /// Inject dependencies post-init. Call from AppDelegate once refs ready.
    func wire(backend: BackendClient, appDelegate: AppDelegate) {
        self.backend = backend
        self.appDelegate = appDelegate
    }

    // MARK: - Disk

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: fileURL),
           let cached = try? Self.decoder.decode([Rule].self, from: data) {
            for r in cached { byId[r.id] = r }
        }
        if let data = try? Data(contentsOf: poolFileURL),
           let pool = try? Self.decoder.decode(LeisurePool.self, from: data) {
            cachedPool = pool
        }
    }

    private func persistToDisk() {
        let arr = Array(byId.values).sorted { $0.createdAt < $1.createdAt }
        if let data = try? Self.encoder.encode(arr) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func persistPoolToDisk() {
        guard let cachedPool, let data = try? Self.encoder.encode(cachedPool) else { return }
        try? data.write(to: poolFileURL, options: .atomic)
    }

    // MARK: - Read API

    /// All rules, oldest first (matches backend ordering).
    func all() -> [Rule] {
        byId.values.sorted { $0.createdAt < $1.createdAt }
    }

    func rule(id: UUID) -> Rule? { byId[id] }

    /// Exact-target lookup. R4 enforcement entry point: the backend
    /// normalizes site targets to bare lowercase domains, so callers should
    /// pass a normalized domain (or a bundle id for .app).
    func rule(targetKind: RuleTargetKind, target: String) -> Rule? {
        let needle = targetKind == .site ? target.lowercased() : target
        return byId.values.first { $0.targetKind == targetKind && $0.target == needle }
    }

    /// Last-known leisure pool (may be stale/yesterday's when offline).
    func pool() -> LeisurePool? { cachedPool }

    // MARK: - Sync — Pull

    /// Pull all rules from backend, replacing the local cache (rules are
    /// hard-deleted server-side, so full replace is the correct merge).
    @discardableResult
    func pull() async -> Bool {
        guard let backend else { return false }
        guard let remote = await backend.getRules() else { return false }
        byId = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        persistToDisk()
        await notifyRulesChanged()
        return true
    }

    /// Refresh today's pool from the backend. Returns the fresh pool, or the
    /// stale cache when offline (nil only if we've never seen a pool).
    @discardableResult
    func refreshPool() async -> LeisurePool? {
        guard let backend else { return cachedPool }
        guard let fresh = await backend.getLeisurePoolToday() else { return cachedPool }
        cachedPool = fresh
        persistPoolToDisk()
        await notifyPoolChanged()
        return fresh
    }

    private func notifyRulesChanged() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .rulesDidChange, object: nil)
        }
    }

    private func notifyPoolChanged() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .leisurePoolDidChange, object: nil)
        }
    }

    // MARK: - Sync rhythm

    /// Start the 60s pull timer (rules + pool). Call from AppDelegate after
    /// wire(). Also subscribes to NSApplication.didBecomeActiveNotification.
    nonisolated func startSyncTimer() {
        Task { @MainActor [weak self] in
            // Foreground refresh
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task {
                    await self?.pull()
                    await self?.refreshPool()
                }
            }
            // 60s timer
            let t = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                Task {
                    await self?.pull()
                    await self?.refreshPool()
                }
            }
            t.tolerance = 5.0
            RunLoop.main.add(t, forMode: .common)
            await self?.attachTimer(t)
        }
    }

    private func attachTimer(_ t: Timer) {
        pullTimer?.invalidate()
        pullTimer = t
    }

    // MARK: - Sync — Push (CRUD)

    /// Create + sync. The server assigns id/timestamps (and normalizes site
    /// targets), so create is server-first — no optimistic phantom row.
    /// Throws RuleError.duplicate on 409 (a rule for this target exists).
    @discardableResult
    func create(_ payload: RuleCreatePayload) async throws -> Rule {
        guard let backend else { throw BackendClient.RuleError.network("No backend") }
        let created = try await backend.createRule(payload)
        byId[created.id] = created
        persistToDisk()
        await notifyRulesChanged()
        return created
    }

    /// Update + sync. Optimistic: the local copy mutates immediately so the
    /// UI reflects the change; the server response reconciles (it normalizes
    /// targets), and any failure reverts to the pre-update snapshot.
    @discardableResult
    func update(id: UUID, payload: RuleUpdatePayload) async throws -> Rule {
        guard let backend else { throw BackendClient.RuleError.network("No backend") }

        let snapshot = byId[id]
        if var local = byId[id] {
            if let k = payload.targetKind { local.targetKind = k }
            if let t = payload.target { local.target = t }
            if let tr = payload.treatment { local.treatment = tr }
            if payload.clearSchedule == true {
                local.schedule = nil
            } else if let s = payload.schedule {
                local.schedule = s
            }
            if let e = payload.enabled { local.enabled = e }
            local.updatedAt = Date()
            byId[id] = local
            persistToDisk()
            await notifyRulesChanged()
        }

        do {
            let updated = try await backend.updateRule(id: id, payload: payload)
            byId[id] = updated  // server reconcile (normalized target, real updated_at)
            persistToDisk()
            await notifyRulesChanged()
            return updated
        } catch {
            // Revert the optimistic apply.
            if let snapshot {
                byId[id] = snapshot
            } else {
                byId.removeValue(forKey: id)
            }
            persistToDisk()
            await notifyRulesChanged()
            throw error
        }
    }

    /// Delete + sync (hard delete). Optimistic local removal; on failure the
    /// snapshot is restored and a pull reconciles with server truth (404 just
    /// means someone else already deleted it — the pull converges either way).
    @discardableResult
    func delete(id: UUID) async -> Bool {
        guard let backend else { return false }
        let snapshot = byId[id]
        byId.removeValue(forKey: id)
        persistToDisk()
        await notifyRulesChanged()

        let ok = await backend.deleteRule(id: id)
        if !ok {
            if let snapshot {
                byId[id] = snapshot
                persistToDisk()
                await notifyRulesChanged()
            }
            await pull()
        }
        return ok
    }

    // MARK: - Leisure pool mutations (R5 consumes these)

    /// Credit focused time → leisure minutes (server floors at earn_rate:1).
    /// Pass sessionId for idempotency — replays credit 0 (deduped=true).
    @discardableResult
    func earn(focusedMinutes: Int, sessionId: String? = nil) async -> LeisurePool? {
        guard let backend else { return cachedPool }
        guard let fresh = await backend.postPoolEarn(
            focusedMinutes: focusedMinutes, sessionId: sessionId
        ) else { return cachedPool }
        cachedPool = fresh
        persistPoolToDisk()
        await notifyPoolChanged()
        return fresh
    }

    /// Record leisure spend (server clamps at the available balance;
    /// spentApplied on the result says how much stuck).
    @discardableResult
    func spend(minutes: Int) async -> LeisurePool? {
        guard let backend else { return cachedPool }
        guard let fresh = await backend.postPoolSpend(minutes: minutes) else { return cachedPool }
        cachedPool = fresh
        persistPoolToDisk()
        await notifyPoolChanged()
        return fresh
    }

    /// Update pool config (base 0-240, rate 1-20, cap 0-240; server 422s
    /// outside ranges → nil here, cache untouched).
    @discardableResult
    func updatePoolConfig(baseMinutes: Int? = nil, earnRate: Int? = nil,
                          bankCap: Int? = nil) async -> LeisurePool? {
        guard let backend else { return cachedPool }
        guard let fresh = await backend.putPoolConfig(
            baseMinutes: baseMinutes, earnRate: earnRate, bankCap: bankCap
        ) else { return nil }
        cachedPool = fresh
        persistPoolToDisk()
        await notifyPoolChanged()
        return fresh
    }
}

extension Notification.Name {
    static let rulesDidChange = Notification.Name("rulesDidChange")
    static let leisurePoolDidChange = Notification.Name("leisurePoolDidChange")
}
