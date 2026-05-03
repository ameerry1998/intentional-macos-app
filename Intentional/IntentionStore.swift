// IntentionStore.swift
//
// Actor-isolated store for `Intention` records, backed by a local
// write-through cache (`intentions.json`). Sync rhythm mirrors
// `BedtimeConfigSync` and `PartnerSyncService`:
//   - Pull on init, on app foreground (didBecomeActive), every 60s.
//   - Push on user-driven create/update/delete (immediately).
// Tombstones (deleted_at != nil) are kept in cache so session-history
// UIs can still resolve names like "Coding (deleted)".
//
// Why an actor: writes happen from MainActor (dashboard bridge), pulls
// happen from background tasks. Actor isolation gives us safe shared
// state without a lock.

import Foundation
import AppKit

actor IntentionStore {
    static let shared = IntentionStore()

    private weak var backend: BackendClient?
    private weak var appDelegate: AppDelegate?

    /// All intentions known to this device, keyed by id. Includes tombstones.
    private var byId: [UUID: Intention] = [:]

    private let fileURL: URL
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

    private var pullTimer: Timer?

    init(settingsDir: String? = nil) {
        let dirURL: URL
        if let settingsDir {
            dirURL = URL(fileURLWithPath: settingsDir)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dirURL = support.appendingPathComponent("Intentional", isDirectory: true)
        }
        self.fileURL = dirURL.appendingPathComponent("intentions.json")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        loadFromDisk()
    }

    /// Inject dependencies post-init. Call from `AppDelegate` once both refs are ready.
    func wire(backend: BackendClient, appDelegate: AppDelegate) {
        self.backend = backend
        self.appDelegate = appDelegate
    }

    // MARK: - Disk

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? Self.decoder.decode([Intention].self, from: data) else {
            return
        }
        for i in cached { byId[i.id] = i }
    }

    private func persistToDisk() {
        let arr = Array(byId.values).sorted { $0.createdAt < $1.createdAt }
        guard let data = try? Self.encoder.encode(arr) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Read API

    func active() -> [Intention] {
        return byId.values.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    func intention(id: UUID) -> Intention? {
        return byId[id]
    }

    /// Case-insensitive name lookup, ignoring tombstones. Used by migration.
    func active(named name: String) -> Intention? {
        let lower = name.lowercased()
        return byId.values.first { $0.deletedAt == nil && $0.name.lowercased() == lower }
    }

    // MARK: - Sync — Pull

    /// Pull all intentions from backend, replacing the local cache. Tombstones
    /// included (we send `include_deleted=true`) so we can render history.
    @discardableResult
    func pull() async -> Bool {
        guard let backend else { return false }
        guard let remote = await backend.getIntentions(includeDeleted: true) else {
            return false
        }
        byId = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        persistToDisk()
        await notifyChanged()
        return true
    }

    private func notifyChanged() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .intentionsDidChange, object: nil)
        }
    }

    // MARK: - Sync rhythm

    /// Start the 60s pull timer. Call from AppDelegate after wire().
    /// Also subscribes to `NSApplication.didBecomeActiveNotification`.
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

    // MARK: - Sync — Push (CRUD)

    /// Create + sync. Returns the server-assigned intention.
    @discardableResult
    func create(_ payload: IntentionCreatePayload) async throws -> Intention {
        guard let backend else { throw BackendClient.IntentionError.network("No backend") }
        let created = try await backend.createIntention(payload)
        byId[created.id] = created
        persistToDisk()
        await notifyChanged()
        return created
    }

    /// Update + sync. Throws .versionConflict on 409 — caller should refetch and retry.
    @discardableResult
    func update(id: UUID, payload: IntentionUpdatePayload) async throws -> Intention {
        guard let backend else { throw BackendClient.IntentionError.network("No backend") }
        do {
            let updated = try await backend.updateIntention(id: id, payload: payload)
            byId[id] = updated
            persistToDisk()
            await notifyChanged()
            return updated
        } catch BackendClient.IntentionError.versionConflict(let serverV) {
            // On 409, refetch the latest from server and notify UI.
            if let fresh = await backend.getIntention(id: id) {
                byId[id] = fresh
                persistToDisk()
                await notifyChanged()
            }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .intentionVersionConflict,
                    object: nil,
                    userInfo: ["intentionId": id, "serverVersion": serverV ?? -1]
                )
            }
            throw BackendClient.IntentionError.versionConflict(currentServerVersion: serverV)
        }
    }

    /// Delete + sync (soft delete on backend; tombstone retained locally).
    @discardableResult
    func delete(id: UUID) async -> Bool {
        guard let backend else { return false }
        let ok = await backend.deleteIntention(id: id)
        if ok {
            // Pull to refresh tombstone state with deleted_at.
            await pull()
        }
        return ok
    }
}

extension Notification.Name {
    static let intentionsDidChange = Notification.Name("intentionsDidChange")
    static let intentionVersionConflict = Notification.Name("intentionVersionConflict")
}
