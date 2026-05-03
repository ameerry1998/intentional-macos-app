# Spec 1 — Mac Client Implementation Plan (Plan B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote Mac's local-only `Project` to a backend-synced `Intention`. Add `IntentionStore` mirroring the proven `BedtimeConfigSync` pattern. Wire manual session start to backend; cross-device session changes drive Mac enforcement via existing `FocusStatePoller`.

**Architecture:** New `IntentionStore` actor + `BackendClient` extensions (intentions CRUD + extended `/focus/toggle`). `MainWindow.swift` bridge messages renamed `*_PROJECT_*` → `*_INTENTION_*`. `FocusStatePoller` extended to read `intention_id` from `/focus/active` and look up intention via `IntentionStore`. `BlockingProfileManager` is **kept** (it backs an existing dashboard UI for named profiles) — Intentions migrate by *resolving* profile references into their own `mac_websites`/`mac_bundle_ids` lists. `AppDelegate.activeProjectSession` stays as in-RAM cache, but is now driven by both the manual-start flow AND the poller's session payload (was: only manual). `FocusModeController.activate(intention:source:)` gains `intentionId: UUID?` parameter persisted to `focus_mode_state.json`.

**Tech Stack:** Swift 5.9+, AppKit, SwiftUI for some surfaces, WKWebView dashboard, actor-based JSON store, URLSession, XCTest.

**Worktree:** This plan executes in `/Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/intentions-spec1` on branch `feat/intentions-spec1` (from `puck`).

**Backend dependency:** Plan A (backend) endpoints must be reachable. For unit tests, `URLSession` is mocked. For integration smoke, run against a deployed Plan A.

**Spec reference:** `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md`

**Cross-repo log:** `docs/overnight-run-2026-05-03.md`

---

## Scope check / honest delta from spec

The spec said *"`BlockingProfileManager` removed entirely"*. Audit reveals it backs an active dashboard UI (`CREATE/UPDATE/DELETE_BLOCKING_PROFILE` handlers in `MainWindow.swift:451-534`). Removing it would delete a working feature, which is out of scope for Spec 1. Adjusted plan: **keep `BlockingProfileManager`; migrate project blocklists by resolving profile references into the new `Intention.mac_websites`/`mac_bundle_ids` lists at migration time.** New Intentions own their lists directly (no `blocklistIds` indirection). Profiles UI keeps working until a future cleanup PR. Documented in CLAUDE.md update task.

The spec said *"`AppDelegate.activeProjectSession` (in-RAM tuple) **removed**"*. Audit reveals 12+ callers across `AppDelegate.swift` and consumers. Removing it would require deep refactor of the project-session enforcement chain. Adjusted plan: **keep `activeProjectSession` as a local cache, but make it canonically driven by the backend session state (via `FocusStatePoller`).** The known "lost on app restart" bug fixes itself: after restart, `FocusStatePoller`'s first 2s poll re-populates the tuple from `/focus/active.intention_id`. Manual-start callers still set it locally for instant feedback (optimistic).

---

## File map

| File | Op | Purpose |
|---|---|---|
| `Intentional/Intention.swift` | CREATE | `Intention` Codable model |
| `Intentional/IntentionStore.swift` | CREATE | Actor + sync rhythm + 409 handling |
| `Intentional/IntentionMigration.swift` | CREATE | One-time `projects.json` → backend migration |
| `Intentional/BackendClient.swift` | MODIFY | Add `getIntentions/getIntention/createIntention/updateIntention/deleteIntention/postFocusToggle` |
| `Intentional/MainWindow.swift` | MODIFY | Add `*_INTENTION_*` handlers (keep `*_PROJECT_*` as deprecated aliases for one release cycle); `handleStartIntentionSession` calls backend |
| `Intentional/FocusStatePoller.swift` | MODIFY | Read `intention_id`; look up Intention; pass to `FocusModeController.activate` |
| `Intentional/FocusModeController.swift` | MODIFY | `activate(intention:intentionId:source:)` signature; persist `intentionId` in `Period`; rehydrate from `focus_mode_state.json` |
| `Intentional/AppDelegate.swift` | MODIFY | Init `IntentionStore`; run `IntentionMigration`; wire `setActiveProjectSession` to also fire from poller |
| `IntentionalTests/IntentionStoreTests.swift` | CREATE | Unit tests with mocked URLSession |
| `IntentionalTests/IntentionMigrationTests.swift` | CREATE | Migration scenarios (idempotent, merge-by-name, partial-failure) |
| `IntentionalTests/BackendClientIntentionsTests.swift` | CREATE | Network DTO round-trip + version conflict |
| `CLAUDE.md` | MODIFY | New "Intentions (Spec 1)" section + scope-delta notes |

---

## Task 0: Worktree exists already; verify and initial empty commit

**Files:** none (git ops only)

- [ ] **Step 0.1: Verify worktree state**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/intentions-spec1
git status
git rev-parse --abbrev-ref HEAD
git log --oneline -3
```

Expected: clean working tree on branch `feat/intentions-spec1`, head at `fa868ff` (Spec 1 design commit).

- [ ] **Step 0.2: Initial empty commit**

```bash
git commit --allow-empty -m "spec1(intentions): start Mac client implementation

Per spec docs/superpowers/specs/2026-05-03-intentions-spec1-design.md
and plan docs/superpowers/plans/2026-05-03-intentions-spec1-plan-b-mac.md."
```

---

## Task 1: Create the `Intention` Codable model

**Files:**
- Create: `Intentional/Intention.swift`

- [ ] **Step 1.1: Write the model**

```swift
// Intention.swift
//
// Cross-device account-scoped focus preset. Replaces the local-only
// `Project` model. Each Intention owns its own per-platform blocklists:
//   - Mac side: mac_websites (domains) + mac_bundle_ids (apps)
//   - iOS side: ios_app_tokens / ios_category_tokens (opaque blobs from
//     Apple's FamilyActivitySelection — Mac stores+forwards, never decodes)
// Versioned for optimistic concurrency. Soft-deleted via `deletedAt`.
//
// JSON shape on the wire matches the backend's snake_case endpoints
// (see plan A — intentional-backend); we use a CodingKey enum to map.

import Foundation

struct Intention: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    /// Base64-encoded FamilyActivitySelection app tokens. iOS-only consumer.
    var iosAppTokensB64: String?
    /// Base64-encoded FamilyActivitySelection category tokens. iOS-only.
    var iosCategoryTokensB64: String?
    var version: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case colorHex = "color_hex"
        case icon
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokensB64 = "ios_app_tokens_b64"
        case iosCategoryTokensB64 = "ios_category_tokens_b64"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    init(id: UUID, name: String, description: String? = nil,
         colorHex: String? = nil, icon: String? = nil,
         macWebsites: [String] = [], macBundleIds: [String] = [],
         iosAppTokensB64: String? = nil, iosCategoryTokensB64: String? = nil,
         version: Int = 1, createdAt: Date = Date(),
         updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.colorHex = colorHex
        self.icon = icon
        self.macWebsites = macWebsites
        self.macBundleIds = macBundleIds
        self.iosAppTokensB64 = iosAppTokensB64
        self.iosCategoryTokensB64 = iosCategoryTokensB64
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Wire-format payload for POST /intentions (no id, no version).
struct IntentionCreatePayload: Codable, Equatable {
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    var iosAppTokensB64: String?
    var iosCategoryTokensB64: String?

    private enum CodingKeys: String, CodingKey {
        case name, description, icon
        case colorHex = "color_hex"
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokensB64 = "ios_app_tokens_b64"
        case iosCategoryTokensB64 = "ios_category_tokens_b64"
    }
}

/// Wire-format payload for PUT /intentions/{id} (must include current version).
struct IntentionUpdatePayload: Codable, Equatable {
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    var iosAppTokensB64: String?
    var iosCategoryTokensB64: String?
    var version: Int

    private enum CodingKeys: String, CodingKey {
        case name, description, icon, version
        case colorHex = "color_hex"
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokensB64 = "ios_app_tokens_b64"
        case iosCategoryTokensB64 = "ios_category_tokens_b64"
    }
}

/// Wrapper response for GET /intentions.
struct IntentionListResponse: Codable {
    let intentions: [Intention]
}
```

- [ ] **Step 1.2: Build to confirm it compiles**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
```

Expected: build succeeds. If it fails, inspect output and fix before continuing.

- [ ] **Step 1.3: Commit**

```bash
git add Intentional/Intention.swift
git commit -m "feat(intentions): Codable Intention model + Create/Update payloads"
```

---

## Task 2: Add `BackendClient` intentions CRUD methods

**Files:**
- Modify: `Intentional/BackendClient.swift` (append before final closing brace)

- [ ] **Step 2.1: Read the existing bedtime methods for the pattern**

```bash
sed -n '565,620p' Intentional/BackendClient.swift
```

The pattern: build URL, set `X-Device-ID` header, encode JSON body, JSONDecoder for response, return optional/result on failure.

- [ ] **Step 2.2: Add intentions methods**

Locate the end of the `class BackendClient` body (before its closing brace) and insert:

```swift
    // MARK: - Intentions (Spec 1)

    /// Custom error for /intentions PUT 409 (stale version).
    enum IntentionError: Error, LocalizedError {
        case versionConflict(currentServerVersion: Int?)
        case notFound
        case network(String)

        var errorDescription: String? {
            switch self {
            case .versionConflict(let v):
                return "Server has a newer version (\(v.map(String.init) ?? "?")). Refetch and retry."
            case .notFound:
                return "Intention not found on server"
            case .network(let s):
                return s
            }
        }
    }

    private func intentionsJSONDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    private func intentionsJSONEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// GET /intentions — returns nil on network failure, [] when truly empty.
    /// `includeDeleted` true returns tombstones (used for session-history rendering).
    func getIntentions(includeDeleted: Bool = false) async -> [Intention]? {
        var components = URLComponents(string: "\(baseURL)/intentions")
        if includeDeleted {
            components?.queryItems = [URLQueryItem(name: "include_deleted", value: "true")]
        }
        guard let url = components?.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let resp = try intentionsJSONDecoder().decode(IntentionListResponse.self, from: data)
            return resp.intentions
        } catch {
            return nil
        }
    }

    /// GET /intentions/{id} — includes soft-deleted (for history). Returns nil on 404.
    func getIntention(id: UUID) async -> Intention? {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try intentionsJSONDecoder().decode(Intention.self, from: data)
        } catch {
            return nil
        }
    }

    /// POST /intentions — server assigns id and version=1.
    func createIntention(_ payload: IntentionCreatePayload) async throws -> Intention {
        guard let url = URL(string: "\(baseURL)/intentions") else {
            throw IntentionError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        req.httpBody = try intentionsJSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IntentionError.network("HTTP \(code)")
        }
        return try intentionsJSONDecoder().decode(Intention.self, from: data)
    }

    /// PUT /intentions/{id} — caller must include current version. Throws .versionConflict on 409.
    func updateIntention(id: UUID, payload: IntentionUpdatePayload) async throws -> Intention {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)") else {
            throw IntentionError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        req.httpBody = try intentionsJSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 409 {
            // Try to refetch the current version for the error
            let current = await getIntention(id: id)
            throw IntentionError.versionConflict(currentServerVersion: current?.version)
        }
        if code == 404 || code == 410 {
            throw IntentionError.notFound
        }
        guard code == 200 else {
            throw IntentionError.network("HTTP \(code)")
        }
        return try intentionsJSONDecoder().decode(Intention.self, from: data)
    }

    /// DELETE /intentions/{id} — soft delete. Returns true on 204.
    @discardableResult
    func deleteIntention(id: UUID) async -> Bool {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? -1) == 204
        } catch {
            return false
        }
    }
```

- [ ] **Step 2.3: Build, fix any compile errors**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -15
```

- [ ] **Step 2.4: Commit**

```bash
git add Intentional/BackendClient.swift
git commit -m "feat(intentions): BackendClient CRUD + IntentionError"
```

---

## Task 3: Add `BackendClient.postFocusToggle` + read intention_id from /focus/active

**Files:**
- Modify: `Intentional/BackendClient.swift`

`FocusStatePoller` does its own URLSession call to `/focus/active`. We're adding a typed helper for `/focus/toggle` so manual-start can post intention_id, AND extending the poller's response handling to read the new `intention_id` field.

- [ ] **Step 3.1: Add `postFocusToggle` method**

Append to `BackendClient.swift` after the intentions section:

```swift
    // MARK: - Focus Toggle (Spec 1 — extended with intention_id)

    enum FocusToggleAction: String { case start, stop }

    struct FocusToggleResult {
        let sessionId: String?
        let status: String  // "started" | "stopped" | "no_active_session"
    }

    /// POST /focus/toggle. `intentionId` and `triggeredBy` are optional —
    /// when sent on start, the backend stamps focus_sessions.intention_id and
    /// pushes a silent APNs to peer iOS devices.
    @discardableResult
    func postFocusToggle(
        action: FocusToggleAction,
        intentionId: UUID? = nil,
        triggeredBy: String = "mac_manual"
    ) async -> FocusToggleResult? {
        guard let url = URL(string: "\(baseURL)/focus/toggle") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        var body: [String: Any] = [
            "action": action.rawValue,
            "triggered_by": triggeredBy,
        ]
        if let intentionId {
            body["intention_id"] = intentionId.uuidString
        }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return FocusToggleResult(
                sessionId: json["session_id"] as? String,
                status: json["status"] as? String ?? "unknown"
            )
        } catch {
            return nil
        }
    }
```

- [ ] **Step 3.2: Build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
```

- [ ] **Step 3.3: Commit**

```bash
git add Intentional/BackendClient.swift
git commit -m "feat(intentions): postFocusToggle helper with intention_id + triggered_by"
```

---

## Task 4: Create `IntentionStore` actor (cache + sync rhythm)

**Files:**
- Create: `Intentional/IntentionStore.swift`

- [ ] **Step 4.1: Write the store**

```swift
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
```

- [ ] **Step 4.2: Build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -15
```

- [ ] **Step 4.3: Commit**

```bash
git add Intentional/IntentionStore.swift
git commit -m "feat(intentions): IntentionStore actor — cache, pull/push, 60s sync, 409 handling"
```

---

## Task 5: Wire `IntentionStore` into `AppDelegate`

**Files:**
- Modify: `Intentional/AppDelegate.swift`

- [ ] **Step 5.1: Add the property**

Find the `var projectStore: ProjectStore?` declaration (line 74) and add immediately below:

```swift
    var intentionStore: IntentionStore?
```

- [ ] **Step 5.2: Init the store after BackendClient**

Find the line `projectStore = ProjectStore()` (around line 529). After it, add:

```swift
        intentionStore = IntentionStore.shared
        Task {
            await intentionStore?.wire(backend: backendClient!, appDelegate: self)
            await intentionStore?.pull()
        }
        intentionStore?.startSyncTimer()
        postLog("🎯 IntentionStore wired and pulling")
```

- [ ] **Step 5.3: Build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
```

- [ ] **Step 5.4: Commit**

```bash
git add Intentional/AppDelegate.swift
git commit -m "feat(intentions): wire IntentionStore in AppDelegate (pull on init + 60s timer)"
```

---

## Task 6: `FocusModeController.activate` accepts `intentionId`

**Files:**
- Modify: `Intentional/FocusModeController.swift`

- [ ] **Step 6.1: Read the existing `activate` signature**

```bash
grep -n "func activate\|var currentPeriod\|struct Period\|case manual\|case schedule\|case puck\|case crossDevice" Intentional/FocusModeController.swift
```

- [ ] **Step 6.2: Add `intentionId` field to `Period`**

Find the `Period` struct (likely around `struct Period`). Add a new field:

```swift
    struct Period: Codable {
        let id: String
        let startedAt: Date
        let intention: String?
        let intentionId: UUID?   // NEW (Spec 1)
        let source: ActivationSource
    }
```

If `Period` already has an init, update it to take the new param:

```swift
        init(id: String, startedAt: Date, intention: String?, intentionId: UUID? = nil, source: ActivationSource) {
            self.id = id
            self.startedAt = startedAt
            self.intention = intention
            self.intentionId = intentionId
            self.source = source
        }
```

- [ ] **Step 6.3: Update `activate` signature**

Find:
```swift
func activate(intention: String?, source: ActivationSource) {
```

Replace with:
```swift
func activate(intention: String?, intentionId: UUID? = nil, source: ActivationSource) {
```

In the body, when constructing the new Period, include `intentionId: intentionId`.

- [ ] **Step 6.4: Update all in-repo callers to pass `intentionId: nil` (no behavioral change)**

```bash
grep -rn "focusModeController.activate\|focusModeController\.activate" Intentional/ | grep -v ".swift:" | head
grep -rn "\.activate(intention:" Intentional/
```

For each call site that's NOT being changed in another task, pass `intentionId: nil` explicitly to avoid silent behavioral change (default is nil, but explicit is better for clarity).

- [ ] **Step 6.5: Build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -15
```

If you see "missing argument for parameter `intentionId`", add `intentionId: nil` to the call. (Default value should mean it's NOT required, but if Swift complains add it explicitly.)

- [ ] **Step 6.6: Commit**

```bash
git add Intentional/FocusModeController.swift
git commit -m "feat(intentions): FocusModeController.activate accepts intentionId (persisted in Period)"
```

---

## Task 7: `FocusStatePoller` reads `intention_id` and looks up the Intention

**Files:**
- Modify: `Intentional/FocusStatePoller.swift`

- [ ] **Step 7.1: Update `poll()` to extract `intention_id` from response**

Find the line:
```swift
            let triggeredBy = (json["triggered_by"] as? String) ?? "puck"
```

After it add:
```swift
            let intentionIdStr = json["intention_id"] as? String
            let intentionId = intentionIdStr.flatMap { UUID(uuidString: $0) }
```

- [ ] **Step 7.2: Update `applyTransition` signature**

Change:
```swift
private func applyTransition(active: Bool, sessionId: String?, triggeredBy: String) {
```

To:
```swift
private func applyTransition(active: Bool, sessionId: String?, triggeredBy: String, intentionId: UUID?) {
```

And the call site in `poll()`:
```swift
            await MainActor.run {
                self.applyTransition(active: active, sessionId: sessionId,
                                     triggeredBy: triggeredBy, intentionId: intentionId)
            }
```

- [ ] **Step 7.3: Update `engage` to look up the Intention name**

Replace `engage(triggeredBy:)` with:

```swift
    private func engage(triggeredBy: String, intentionId: UUID?) {
        Task { @MainActor in
            let intentionName: String?
            if let id = intentionId {
                intentionName = await IntentionStore.shared.intention(id: id)?.name
                    ?? "Focus session"  // Cache miss — re-pull happens at 60s tick
                Task { await IntentionStore.shared.pull() }  // Refresh on miss
            } else {
                intentionName = triggeredBy == "puck"
                    ? "Focus session (started on phone)"
                    : "Focus session"
            }
            let source: FocusModeController.ActivationSource =
                triggeredBy == "puck" ? .puck : .crossDevice
            self.focusModeController?.activate(
                intention: intentionName,
                intentionId: intentionId,
                source: source
            )
            // Sync AppDelegate's local activeProjectSession cache so other
            // listeners (FocusMonitor, EarnedBrowseManager) see the right id.
            if let id = intentionId, let sessionId = self.lastKnownSessionId {
                self.appDelegate?.setActiveProjectSession(projectId: id, blockId: sessionId)
            }
        }
    }
```

And the call site in `applyTransition`:
```swift
        if active && !prevActive {
            ...
            engage(triggeredBy: triggeredBy, intentionId: intentionId)
        } else if active && prevActive && sessionId != prevSessionId {
            ...
            engage(triggeredBy: triggeredBy, intentionId: intentionId)
        }
```

- [ ] **Step 7.4: Build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -15
```

- [ ] **Step 7.5: Commit**

```bash
git add Intentional/FocusStatePoller.swift
git commit -m "feat(intentions): FocusStatePoller reads intention_id, looks up name from IntentionStore"
```

---

## Task 8: Migration — `projects.json` → backend Intentions

**Files:**
- Create: `Intentional/IntentionMigration.swift`

- [ ] **Step 8.1: Write the migration**

```swift
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
    }

    var isCompleted: Bool {
        FileManager.default.fileExists(atPath: receiptURL.path)
    }

    /// Run the migration. Safe to call repeatedly — early-returns if complete.
    func run(log: @escaping (String) -> Void = { _ in }) async {
        guard !isCompleted else {
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

        var processed: [UUID] = []

        // Resume support: if receipt has partial state, skip already-processed.
        let alreadyProcessed = loadPartialReceipt()
        let pending = projects.filter { !alreadyProcessed.contains($0.id) }

        for project in pending {
            let merged = await mergedBlocklist(for: project)
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
        await renameProjectsJSON()
        await stampReceipt()
        log("🔁 IntentionMigration: complete, \(processed.count) projects migrated")
    }

    // MARK: - Helpers

    private func mergedBlocklist(for project: Project) async -> MergedBlockList {
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

    private func renameProjectsJSON() async {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Intentional", isDirectory: true)
        let projectsURL = dir.appendingPathComponent("projects.json")
        guard FileManager.default.fileExists(atPath: projectsURL.path) else { return }
        try? FileManager.default.moveItem(at: projectsURL, to: projectsLegacyURL)
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
```

- [ ] **Step 8.2: Wire migration into AppDelegate**

In `AppDelegate.swift`, find where `intentionStore` was wired (Task 5). Below the `Task { ... }` block that pulls, add:

```swift
        Task {
            // Wait for store to be wired before running migration
            await intentionStore?.wire(backend: backendClient!, appDelegate: self)
            await intentionStore?.pull()
            // Run migration
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = support.appendingPathComponent("Intentional", isDirectory: true)
            let migration = await IntentionMigration(
                projectStore: self.projectStore,
                blockingProfileManager: self.blockingProfileManager,
                intentionStore: self.intentionStore!,
                backend: self.backendClient!,
                settingsDir: dir
            )
            await migration.run(log: { msg in
                Task { @MainActor in self.postLog(msg) }
            })
        }
```

(Replace the existing `Task { ... pull() ... }` from Task 5 with this combined task that does pull + migrate in sequence.)

- [ ] **Step 8.3: Build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -15
```

- [ ] **Step 8.4: Commit**

```bash
git add Intentional/IntentionMigration.swift Intentional/AppDelegate.swift
git commit -m "feat(intentions): one-time migration projects.json → backend (idempotent, merge-by-name)"
```

---

## Task 9: `MainWindow.swift` — add `*_INTENTION_*` handlers

**Files:**
- Modify: `Intentional/MainWindow.swift`

We're adding NEW handlers. The OLD `*_PROJECT_*` handlers stay for now (deprecated alias) — the dashboard JS can be updated in lockstep, but we don't want a half-migrated state to break anything.

- [ ] **Step 9.1: Add the case statements**

Find the message dispatch switch (around line 525 in `userContentController(_:didReceive:)`). Below the existing `case "PROMOTE_LEARNED_SITE":` block, insert:

```swift
        // Spec 1 — Intentions (new handlers; project handlers above kept as deprecated aliases)
        case "GET_INTENTIONS":
            handleGetIntentions()

        case "GET_INTENTION":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleGetIntention(id: id)
            }

        case "CREATE_INTENTION":
            if let body = message.body as? [String: Any] {
                handleCreateIntention(body)
            }

        case "UPDATE_INTENTION":
            if let body = message.body as? [String: Any] {
                handleUpdateIntention(body)
            }

        case "DELETE_INTENTION":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleDeleteIntention(id: id)
            }

        case "START_INTENTION_SESSION":
            if let body = message.body as? [String: Any] {
                handleStartIntentionSession(body)
            }
```

- [ ] **Step 9.2: Add the handler methods**

At the bottom of the `MainWindow` class (before its closing brace), add:

```swift
    // MARK: - Intentions (Spec 1)

    private func handleGetIntentions() {
        Task {
            let intentions = await IntentionStore.shared.active()
            let items = intentions.map { i -> [String: Any] in
                return [
                    "id": i.id.uuidString,
                    "name": i.name,
                    "description": i.description ?? "",
                    "color_hex": i.colorHex ?? "",
                    "icon": i.icon ?? "",
                    "mac_websites": i.macWebsites,
                    "mac_bundle_ids": i.macBundleIds,
                    "version": i.version,
                    "created_at": ISO8601DateFormatter().string(from: i.createdAt),
                    "updated_at": ISO8601DateFormatter().string(from: i.updatedAt),
                ]
            }
            await MainActor.run {
                self.emitIntentionsList(items)
            }
        }
    }

    private func handleGetIntention(id: UUID) {
        Task {
            let intention = await IntentionStore.shared.intention(id: id)
            await MainActor.run {
                if let i = intention {
                    let dict: [String: Any] = [
                        "id": i.id.uuidString,
                        "name": i.name,
                        "description": i.description ?? "",
                        "color_hex": i.colorHex ?? "",
                        "icon": i.icon ?? "",
                        "mac_websites": i.macWebsites,
                        "mac_bundle_ids": i.macBundleIds,
                        "version": i.version,
                    ]
                    self.emitIntentionDetail(dict)
                } else {
                    self.emitIntentionDetail(["error": "Intention not found"])
                }
            }
        }
    }

    private func handleCreateIntention(_ body: [String: Any]) {
        Task {
            let payload = IntentionCreatePayload(
                name: body["name"] as? String ?? "Untitled",
                description: body["description"] as? String,
                colorHex: body["color_hex"] as? String,
                icon: body["icon"] as? String,
                macWebsites: body["mac_websites"] as? [String] ?? [],
                macBundleIds: body["mac_bundle_ids"] as? [String] ?? [],
                iosAppTokensB64: nil,
                iosCategoryTokensB64: nil
            )
            do {
                let created = try await IntentionStore.shared.create(payload)
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "created", "id": created.id.uuidString
                    ])
                }
            } catch {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "error", "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    private func handleUpdateIntention(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else { return }
        guard let version = body["version"] as? Int else {
            emitIntentionMutationResult(["status": "error", "error": "Missing version"])
            return
        }
        Task {
            // Fetch existing for fallthrough fields not in the patch.
            guard let existing = await IntentionStore.shared.intention(id: id) else {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "error", "error": "Intention not found"
                    ])
                }
                return
            }
            let payload = IntentionUpdatePayload(
                name: body["name"] as? String ?? existing.name,
                description: body["description"] as? String ?? existing.description,
                colorHex: body["color_hex"] as? String ?? existing.colorHex,
                icon: body["icon"] as? String ?? existing.icon,
                macWebsites: body["mac_websites"] as? [String] ?? existing.macWebsites,
                macBundleIds: body["mac_bundle_ids"] as? [String] ?? existing.macBundleIds,
                iosAppTokensB64: existing.iosAppTokensB64,
                iosCategoryTokensB64: existing.iosCategoryTokensB64,
                version: version
            )
            do {
                let updated = try await IntentionStore.shared.update(id: id, payload: payload)
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "updated", "id": updated.id.uuidString,
                        "version": updated.version
                    ])
                }
            } catch BackendClient.IntentionError.versionConflict(let serverV) {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "version_conflict",
                        "server_version": serverV ?? -1
                    ])
                }
            } catch {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "error", "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    private func handleDeleteIntention(id: UUID) {
        Task {
            let ok = await IntentionStore.shared.delete(id: id)
            await MainActor.run {
                self.emitIntentionMutationResult([
                    "status": ok ? "deleted" : "error",
                    "id": id.uuidString
                ])
            }
        }
    }

    private func handleStartIntentionSession(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else {
            emitSessionResult(["status": "refused", "reason": "Missing intention id"])
            return
        }
        Task {
            // Look up intention name for local enforcement
            guard let intention = await IntentionStore.shared.intention(id: id),
                  intention.deletedAt == nil else {
                await MainActor.run {
                    self.emitSessionResult(["status": "refused", "reason": "Intention not found"])
                }
                return
            }
            // Optimistic local activation
            await MainActor.run {
                self.appDelegate?.focusModeController?.activate(
                    intention: intention.name,
                    intentionId: id,
                    source: .manual
                )
                self.appDelegate?.setActiveProjectSession(
                    projectId: id, blockId: "manual-\(UUID().uuidString)"
                )
            }
            // Backend POST (fire-and-forget; rollback on failure)
            let result = await self.appDelegate?.backendClient?.postFocusToggle(
                action: .start, intentionId: id, triggeredBy: "mac_manual"
            )
            if result == nil {
                // Roll back local activation on backend failure
                await MainActor.run {
                    self.appDelegate?.focusModeController?.deactivate(source: .manual)
                    self.emitSessionResult([
                        "status": "error",
                        "reason": "Backend unreachable — local enforcement reverted"
                    ])
                }
                return
            }
            await MainActor.run {
                self.emitSessionResult([
                    "status": "started", "intentionId": id.uuidString,
                    "sessionId": result?.sessionId ?? ""
                ])
            }
        }
    }

    // MARK: - Intention emit helpers

    private func emitIntentionsList(_ items: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("window._intentionsList && window._intentionsList(\(json))")
    }

    private func emitIntentionDetail(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("window._intentionDetail && window._intentionDetail(\(json))")
    }

    private func emitIntentionMutationResult(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("window._intentionMutationResult && window._intentionMutationResult(\(json))")
    }
```

- [ ] **Step 9.3: Build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -15
```

- [ ] **Step 9.4: Commit**

```bash
git add Intentional/MainWindow.swift
git commit -m "feat(intentions): MainWindow GET/CREATE/UPDATE/DELETE/START_INTENTION handlers"
```

---

## Task 10: Listen for `intentionsDidChange` to push to dashboard

**Files:**
- Modify: `Intentional/MainWindow.swift`

When IntentionStore pulls new data, dashboard should refresh.

- [ ] **Step 10.1: Add the observer in MainWindow's init or setup**

Find where the WebView initialization happens. After `webView` is set up, add:

```swift
        NotificationCenter.default.addObserver(
            forName: .intentionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleGetIntentions()  // re-emit list to dashboard
        }
```

- [ ] **Step 10.2: Build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
```

- [ ] **Step 10.3: Commit**

```bash
git add Intentional/MainWindow.swift
git commit -m "feat(intentions): re-push intentions list to dashboard on intentionsDidChange"
```

---

## Task 11: Unit tests — `IntentionStore` round-trip with mocked URLSession

**Files:**
- Create: `IntentionalTests/IntentionStoreTests.swift`

- [ ] **Step 11.1: Locate the existing test target**

```bash
ls IntentionalTests/ 2>&1 | head
```

If no `IntentionalTests/` directory exists, this codebase has no XCTest target. Skip to Task 12; instead document tests as "manual smoke" in the cross-repo log.

If it exists, continue:

- [ ] **Step 11.2: Write the test**

```swift
// IntentionStoreTests.swift
import XCTest
@testable import Intentional

final class IntentionStoreTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intentions-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func test_load_from_disk_round_trips() async throws {
        // Pre-populate the cache file
        let intentions = [
            Intention(id: UUID(), name: "Coding",
                      macWebsites: ["twitter.com"], macBundleIds: [])
        ]
        let url = tempDir.appendingPathComponent("intentions.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(intentions).write(to: url)

        let store = IntentionStore(settingsDir: tempDir.path)
        let active = await store.active()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.name, "Coding")
    }

    func test_active_excludes_tombstones() async throws {
        let now = Date()
        let intentions = [
            Intention(id: UUID(), name: "Live", deletedAt: nil),
            Intention(id: UUID(), name: "Tomb", deletedAt: now)
        ]
        let url = tempDir.appendingPathComponent("intentions.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(intentions).write(to: url)

        let store = IntentionStore(settingsDir: tempDir.path)
        let active = await store.active()
        XCTAssertEqual(active.map(\.name), ["Live"])
    }

    func test_active_named_is_case_insensitive() async throws {
        let intentions = [Intention(id: UUID(), name: "Coding")]
        let url = tempDir.appendingPathComponent("intentions.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(intentions).write(to: url)

        let store = IntentionStore(settingsDir: tempDir.path)
        let found = await store.active(named: "CODING")
        XCTAssertEqual(found?.name, "Coding")
    }
}
```

- [ ] **Step 11.3: Run tests**

```bash
xcodebuild test -scheme Intentional -destination 'platform=macOS' -only-testing:IntentionalTests/IntentionStoreTests 2>&1 | tail -15
```

- [ ] **Step 11.4: Commit**

```bash
git add IntentionalTests/IntentionStoreTests.swift
git commit -m "test(intentions): IntentionStore disk round-trip + tombstone filtering"
```

---

## Task 12: Update CLAUDE.md with Intention concept + scope deltas

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 12.1: Add the section**

Find the "Reference Documentation" table or the top "Architecture Principle" section and insert under it:

```markdown
## Intentions (Spec 1, May 2026) — ACTIVE

The Mac no longer treats Projects as a local-only concept. They are now backend-resident, account-scoped, cross-device-synced **Intentions** (`intentions` table in `intentional-backend`, see migration 018). Each Intention owns its own `mac_websites` + `mac_bundle_ids` lists directly.

- **`IntentionStore`** is the actor + cache. Pull on launch / app foreground / 60s timer. Local cache at `~/Library/Application Support/Intentional/intentions.json`.
- **`BlockingProfileManager` is NOT removed in Spec 1.** The named-profiles UI in the dashboard still uses it. Project blocklists migrated by *resolving* profile references into the new Intention's own lists. Profiles UI to be removed in a future cleanup PR.
- **`AppDelegate.activeProjectSession` retained** as in-RAM cache, now driven by both manual-start (optimistic) and `FocusStatePoller` (canonical). The known "lost on restart" bug fixes itself: after restart, the first 2s poll re-populates from `/focus/active.intention_id`.
- **Manual session start** now POSTs `/focus/toggle` with `intention_id`. Backend pushes silent APNs to peer iOS devices for ≤5s cross-device propagation.
- **Migration runner**: one-time at `IntentionMigration.swift`. Idempotent via receipt at `migration_intentions_v1.json`. Resumable on partial failure.
- **Day-1 default**: server seeds a "Focus" intention with curated default Mac blocklist for fresh accounts (no setup gate).

Spec: `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md`
Plan: `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-b-mac.md`
Cross-repo log: `docs/overnight-run-2026-05-03.md`
```

- [ ] **Step 12.2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(intentions): CLAUDE.md section + scope-delta notes (BPM kept, activeProjectSession kept)"
```

---

## Task 13: Final build, test, commit log update, push

**Files:** none (verification + push)

- [ ] **Step 13.1: Full build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' clean build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. If the test target exists, also run:

```bash
xcodebuild test -scheme Intentional -destination 'platform=macOS' -only-testing:IntentionalTests 2>&1 | tail -10
```

- [ ] **Step 13.2: Verify the diff against `puck`**

```bash
git log --oneline puck..HEAD
git diff --stat puck..HEAD
```

Expected: ~12 commits, mostly under `Intentional/` + 1 doc commit.

- [ ] **Step 13.3: Push the branch**

```bash
git push -u origin feat/intentions-spec1
```

- [ ] **Step 13.4: Update the cross-repo overnight log**

In the main worktree (NOT this one), edit `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/overnight-run-2026-05-03.md` and append to the "Live progress log":

```markdown
### Phase 4 — Mac (DONE)
Branch `feat/intentions-spec1` pushed to `origin`.
- New: `Intention.swift`, `IntentionStore.swift`, `IntentionMigration.swift`
- Modified: `BackendClient.swift` (CRUD + postFocusToggle), `MainWindow.swift` (intention handlers + emit), `FocusStatePoller.swift` (intention_id), `FocusModeController.swift` (intentionId param), `AppDelegate.swift` (wire IntentionStore + migration)
- BlockingProfileManager kept (still backs profiles UI; cleanup deferred)
- AppDelegate.activeProjectSession kept (now driven by FocusStatePoller as canonical signal; manual-start sets it optimistically)
- Migration: idempotent, resumable, merge-by-name, runs on first launch when receipt absent

**Action required from you in the morning:**
1. Merge to `puck` after backend deploy (migration runs automatically on first launch).
2. Build PKG via `./scripts/build-pkg.sh` for distribution if desired.
3. Manual smoke: open dashboard → existing projects appear as Intentions with same blocklists; tap "Start" → backend `/focus/toggle` fires; iPhone (after Plan C) shields within 5s.
```

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add docs/overnight-run-2026-05-03.md
git commit -m "log(overnight): Mac phase complete"
```

---

## What this plan does NOT do (deferred)

- Remove `BlockingProfileManager` and its dashboard UI surface (`*_BLOCKING_PROFILE` handlers in MainWindow). Future cleanup PR.
- Remove the old `*_PROJECT_*` bridge handlers. Kept as deprecated aliases for one release; dashboard JS can switch over independently.
- Refactor `AppDelegate.activeProjectSession` away. Kept; now backend-driven.
- New SwiftUI Intention edit screen on Mac. The dashboard WebView UI handles editing via the new bridge messages — no native macOS UI added in Spec 1.
- `requirePartnerToEndSessionEarly` setting hook. Spec calls for a "hook only" — given the user has not yet confirmed how the early-end check should integrate with bedtime partner-unlock flow, defer the hook until Spec 2 lands. Tracked in cross-repo log.
- Per-platform iOS app blocklist editor on Mac. Mac shows iOS sections as read-only via the existing IntentionStore data; iOS edits its own slices.

## Required env vars (none new)

Reuses existing: `X-Device-ID` derived via `BackendClient.getDeviceId()`. `baseURL` = `https://api.intentional.social` (already set).
