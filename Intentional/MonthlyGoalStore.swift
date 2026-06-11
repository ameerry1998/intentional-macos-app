// MonthlyGoalStore.swift
//
// Actor-isolated store for MonthlyGoal records, backed by local disk cache and
// the backend's /monthly_goals endpoints. Mirrors IntentionStore.

import Foundation
import AppKit

actor MonthlyGoalStore {
    static let shared = MonthlyGoalStore()

    private weak var backend: BackendClient?
    private weak var appDelegate: AppDelegate?
    private var byId: [UUID: MonthlyGoal] = [:]
    private var pullTimer: Timer?

    private let fileURL: URL
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Tolerant: cache is written plain-ISO8601, but accept fractional too
        // (backend wire format) so a copied/migrated payload never bricks the cache.
        d.dateDecodingStrategy = ISO8601Tolerant.decodingStrategy
        return d
    }()

    init(settingsDir: String? = nil) {
        let dirURL: URL
        if let settingsDir {
            dirURL = URL(fileURLWithPath: settingsDir)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dirURL = support.appendingPathComponent("Intentional", isDirectory: true)
        }
        self.fileURL = dirURL.appendingPathComponent("monthly_goals.json")
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
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? Self.decoder.decode([MonthlyGoal].self, from: data) else {
            return
        }
        for g in cached { byId[g.id] = g }
    }

    private func persistToDisk() {
        let arr = Array(byId.values).sorted { $0.createdAt < $1.createdAt }
        guard let data = try? Self.encoder.encode(arr) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Read API

    func active() -> [MonthlyGoal] {
        byId.values.filter { $0.deletedAt == nil }.sorted { $0.monthOf < $1.monthOf }
    }

    func goal(id: UUID) -> MonthlyGoal? { byId[id] }

    // MARK: - Sync — Pull

    @discardableResult
    func pull() async -> Bool {
        guard let backend else { return false }
        guard let remote = await backend.getMonthlyGoals(includeDeleted: true) else { return false }
        byId = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        persistToDisk()
        await notifyChanged()
        return true
    }

    private func notifyChanged() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .monthlyGoalsDidChange, object: nil)
        }
    }

    // MARK: - Sync — Push (CRUD)

    @discardableResult
    func create(_ payload: MonthlyGoalCreatePayload) async throws -> MonthlyGoal {
        guard let backend else { throw BackendClient.IntentionError.network("No backend") }
        let created = try await backend.createMonthlyGoal(payload)
        byId[created.id] = created
        persistToDisk()
        await notifyChanged()
        return created
    }

    @discardableResult
    func update(id: UUID, payload: MonthlyGoalUpdatePayload) async throws -> MonthlyGoal {
        guard let backend else { throw BackendClient.IntentionError.network("No backend") }
        do {
            let updated = try await backend.updateMonthlyGoal(id: id, payload: payload)
            byId[id] = updated
            persistToDisk()
            await notifyChanged()
            return updated
        } catch BackendClient.IntentionError.versionConflict(let serverV) {
            if let fresh = await backend.getMonthlyGoal(id: id) {
                byId[id] = fresh
                persistToDisk()
                await notifyChanged()
            }
            throw BackendClient.IntentionError.versionConflict(currentServerVersion: serverV)
        }
    }

    @discardableResult
    func delete(id: UUID) async -> Bool {
        guard let backend else { return false }
        let ok = await backend.deleteMonthlyGoal(id: id)
        if ok {
            await pull()  // refresh tombstone state
        }
        return ok
    }

    // MARK: - Sync rhythm

    nonisolated func startSyncTimer() {
        Task { @MainActor [weak self] in
            // Foreground refresh
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { await self?.pull() }
            }
            // 60s timer
            let t = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                Task { await self?.pull() }
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
}

extension Notification.Name {
    static let monthlyGoalsDidChange = Notification.Name("monthlyGoalsDidChange")
}
