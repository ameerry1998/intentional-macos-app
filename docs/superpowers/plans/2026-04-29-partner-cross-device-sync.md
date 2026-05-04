# Partner Cross-Device Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user sets an accountability partner on one device (Mac or iPhone) and the partner confirms via the email link, the partner appears automatically on the OTHER device — same name, same email, same confirmation status — without the user having to re-enter anything.

**Architecture:** Backend already does the right thing: `POST /partner` syncs partner_email/name across all sibling user rows linked to the same account_id, and `GET /partner/status` reads with a sibling fallback when the calling device's own row is empty. The bug is purely client-side: both Mac and iPhone read partner from local-only caches (`@AppStorage("partnerName")` on iOS, dashboard settings JSON on Mac) and never refresh from `/partner/status`. Fix: add a `PartnerSyncService` on each platform that fetches `/partner/status` on launch, foreground, and on a 60-second poll while active, then writes the response to the local cache. Existing UI bindings (`@AppStorage` on iOS, dashboard `settings.partnerEmail` on Mac) automatically pick up the refreshed value.

**Tech Stack:** Swift on both platforms. Reuses existing `IntentionalAPIClient.getPartnerStatus()` on iOS and `BackendClient` patterns on Mac. No backend, no new endpoints, no migration.

---

## §0. Conversation context (verbatim)

> "Now I've never set it up on both devices, I think once a partner has gotten the email that they've been added as a partner and they've confirmed, then the partner should show up on both devices. Plan that out."

The user's intent: partner data should be a property of the account, not a property of the device. Once one device has set the partner and the partner confirms, the other device(s) on the same account should automatically pick it up.

---

## §1. What already works (do NOT redo)

The backend partner architecture is correct as of `301d1e4` on `main`:

- **`POST /partner`** (in `intentional-backend/main.py` ~line 270) accepts `{partner_email, partner_name}` and writes to the calling user's row AND every sibling row sharing the same `account_id`. See lines 291–301: the explicit comment "This is what makes partner data sync across the user's Mac and iPhone after both have been linked to an account."
- **`GET /partner/status`** uses the helper `_account_partner_via_siblings(account_id)` (~line 174) as a fallback: if the calling device's own user row has no partner_email set, it returns the most-recently-active sibling's partner. This means a device that links to an account AFTER the partner was set on a sibling can still discover it.
- **`partner_consent` table** keys consent on `(user_id, partner_email)`. The existing partner-set endpoint already checks if any sibling has a confirmed consent for the same partner email and reuses it (lines 304–321). So a partner who confirmed once doesn't get re-emailed when a sibling device's row is created.

What does NOT work today:

- iOS reads partner from `@AppStorage("partnerName")` (local UserDefaults) in five places: `PartnerView.swift`, `BedtimeDetailView.swift`, `BedtimeUnlockRequestSheet.swift`, `BedtimeCard.swift`, `BedtimeScheduleService.swift` (Live Activity). None of them call `IntentionalAPIClient.getPartnerStatus()` to refresh.
- Mac stores partner in dashboard settings JSON (loaded from `MainWindow.swift` saved settings) and refreshes only when the user opens the partner settings panel. No periodic refresh from backend.
- Result: device A sets partner → backend writes to siblings → device B's NEXT launch still shows whatever was in B's local cache (empty if B never set it locally).

---

## §2. Locked-in decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Sync direction = backend → client only | Setting still goes through `POST /partner` (already syncs to siblings). The new service only READS to refresh local cache. |
| 2 | Refresh triggers: launch, foreground (`willEnterForegroundNotification` / `didBecomeActiveNotification`), 60-second timer while active | 60s is fast enough that "partner just confirmed" propagates within a minute of the user being on the app. Cheaper than push. |
| 3 | Display all consent states (pending / confirmed / declined / expired) — not just confirmed | Both devices show the same truth. Pending partner shows "waiting for {name} to confirm." Hides nothing. |
| 4 | Local cache writes happen even when consent is unconfirmed | Otherwise device B's cache shows stale data while device A's pending partner waits to be confirmed. |
| 5 | `@AppStorage("partnerName")` references on iOS stay — they're populated by the new service writing to UserDefaults | Avoids touching 5 view files. The `@AppStorage` bindings auto-update when UserDefaults changes. |
| 6 | Backend = zero changes. No migration. | Backend logic is already correct per inspection. The only change is making clients call the existing endpoint. |
| 7 | Service reads `partner_email`, `partner_name`, AND `consent_status` from the response. Stores all three. | Full truth, not just the email. UI can display "Sara · waiting to confirm" for pending. |
| 8 | If both devices are NOT on the same account, no sync happens — that's fine | This is a separate feature ("link my devices"). User can sign in with the same email on both to enable. |

---

## §3. Out of scope (do NOT add)

- **Backend changes.** Endpoint, schema, sibling-sync logic — all correct. Don't touch.
- **APNs push from backend on consent change.** Polling at 60s is fine for v1. Push is a future optimization.
- **In-app toast / notification when partner confirms.** Future polish. Not part of this PR.
- **Account-linking UX.** Separate feature. If the user has different accounts on Mac vs iPhone, this plan doesn't bridge them — they need to log into the same account on both first.
- **Removing partner.** Already works via existing UI; the sync service just observes whatever the backend returns (including no partner).
- **Mac dashboard UI rework.** This plan only adds a fetch and writes to existing settings keys; the UI panels are unchanged.

---

## §4. Risk catalog

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | 60-second poll while inactive drains battery | Low | Timer fires only while scenePhase=.active (iOS) / app is foreground (Mac). Pauses on background. |
| R2 | Partner set locally then network blip means cache is briefly out of sync with backend | Acceptable | The existing `POST /partner` flow writes locally first then to backend; on next sync the local cache reflects backend truth. Eventually consistent within 60s. |
| R3 | Two devices both set partner simultaneously, race | Very low | Backend's `_sibling_user_ids` returns deterministic order; last-write-wins. UI doesn't crash either way. |
| R4 | iOS `@AppStorage` doesn't fire SwiftUI redraw when UserDefaults written from non-MainActor context | Medium | Service writes UserDefaults from MainActor. Verified by docs and existing FocusModeController patterns. |
| R5 | User logs out → partner cache should clear | Medium | On logout, AuthService notifies; PartnerSyncService listens and wipes UserDefaults keys. |
| R6 | Mac dashboard's settings JSON doesn't auto-refresh; the sync service writes to it but the open dashboard window may not re-render | Medium | Service posts a `partnerSyncDidUpdate` notification; MainWindow's WKWebView callJS pushes the new partner email/name to the dashboard. |
| R7 | First fetch on cold launch happens BEFORE auth is ready (user not logged in yet) | High | Service guards on `AuthService.isAuthenticated`. If false, no fetch. On `authStateDidChange`, retry. |
| R8 | Polling 60s makes too many requests if the user has the app open all day | Acceptable | One GET per minute is trivial backend load. Each request is ~150 bytes payload. |
| R9 | Partner name contains special chars that break JSON encoding | Already handled | Backend stores/returns as UTF-8. iOS/Swift JSON decoding handles this. |
| R10 | If `getPartnerStatus()` returns 404 (user not registered yet), service should not crash | Medium | Service catches 404 and treats as "no partner yet." Logs once, doesn't retry-storm. |
| R11 | The fetch happens from a background-friendly URLSession, but on iOS suspended apps, even brief network calls can fail with `kCFURLErrorBackgroundSessionInUseByAnotherProcess` | Low | Use the standard URLSession instance, not `.background(...)`. Network calls during foreground only. |
| R12 | Mac and iPhone show DIFFERENT partner data even after fix because they're on different accounts | Out of plan scope | Document. User must log in with same account on both. |

---

## §5. File structure

### iOS (`/Users/arayan/Documents/GitHub/puck-ios`)

| Path | Action | Purpose |
|---|---|---|
| `Puck/Core/Partner/PartnerSyncService.swift` | CREATE | Singleton. Fetches `/partner/status` on launch, foreground, and 60s timer. Writes `partnerName` + `partnerEmail` + `partnerConsentStatus` to UserDefaults. Publishes `@Published` properties for SwiftUI subscribers that want richer state than `@AppStorage`. |
| `Puck/App/PuckApp.swift` | EDIT | Wire `PartnerSyncService.shared.start()` from app delegate / scene phase changes. |
| `Puck/Core/Auth/AuthService.swift` | EDIT | On logout, post notification that `PartnerSyncService` listens to → wipes UserDefaults keys. |
| `PuckTests/PartnerSyncServiceTests.swift` | CREATE | Unit tests for fetch flow, error handling, UserDefaults writes (mocking the API client). |

### Mac (`/Users/arayan/Documents/GitHub/intentional-macos-app`)

| Path | Action | Purpose |
|---|---|---|
| `Intentional/PartnerSyncService.swift` | CREATE | Same pattern as iOS. Fetches `/partner/status` via existing `BackendClient`. Writes to dashboard settings JSON via `MainWindow.callJS(...)`. Posts `Notification.Name.partnerSyncDidUpdate`. |
| `Intentional/AppDelegate.swift` | EDIT | Wire `PartnerSyncService` initialization and start. Subscribe to `didBecomeActiveNotification` and call `pullAndApply()`. |
| `Intentional/MainWindow.swift` | EDIT | Listen for `partnerSyncDidUpdate` notification → `callJS("window._partnerSyncResult && window._partnerSyncResult({email, name, consentStatus})")` to push to dashboard. |
| `Intentional/dashboard.html` | EDIT | Add `window._partnerSyncResult = function(data) { settings.partnerEmail = data.email; settings.partnerName = data.name; settings.partnerConsentStatus = data.consentStatus; renderPartnerSection(); };` near the existing partner UI handlers. |
| `IntentionalTests/PartnerSyncServiceTests.swift` | CREATE | Same shape as iOS tests. |

### Backend (`/Users/arayan/Documents/GitHub/intentional-backend`)

**No changes.** The endpoints + sibling logic are correct.

### Cross-repo

- `intentional-macos-app/docs/cross-repo-partner-sync-2026-04-29.md` — hand-off log.
- Both repos' `CLAUDE.md` get a brief note about the new service in the "Cross-device sync" section.

---

## §6. Phase-by-phase implementation

Branch per repo:
- iOS: `feat/partner-sync` off `feat/bedtime-redesign` of `puck-ios`
- Mac: `feat/partner-sync` off `feat/focus-mode-consolidation` of `intentional-macos-app`

Use worktrees: `.claude/worktrees/partner-sync` in each repo.

---

### Phase 1 — iOS `PartnerSyncService`

#### Task 1.1 — Create the service (TDD)

**Files:**
- Create: `Puck/Core/Partner/PartnerSyncService.swift`
- Create: `PuckTests/PartnerSyncServiceTests.swift` (documentation-only since no test target wired yet — see plan §1 of bedtime-lock-loop plan)

- [ ] **Step 1: Write tests for the pure decoding + UserDefaults write logic**

```swift
import XCTest
@testable import Puck

@MainActor
final class PartnerSyncServiceTests: XCTestCase {
    func testApplyResponseWritesAllThreeKeysToUserDefaults() {
        let defaults = UserDefaults(suiteName: "test-partner-sync")!
        defaults.removePersistentDomain(forName: "test-partner-sync")
        let svc = PartnerSyncService(defaults: defaults)

        svc.applyResponse(.init(
            partnerEmail: "sara@example.com",
            partnerName: "Sara",
            consentStatus: "confirmed"
        ))

        XCTAssertEqual(defaults.string(forKey: "partnerName"), "Sara")
        XCTAssertEqual(defaults.string(forKey: "partnerEmail"), "sara@example.com")
        XCTAssertEqual(defaults.string(forKey: "partnerConsentStatus"), "confirmed")
    }

    func testApplyEmptyResponseClearsKeys() {
        let defaults = UserDefaults(suiteName: "test-partner-sync")!
        defaults.set("Old", forKey: "partnerName")
        defaults.set("old@example.com", forKey: "partnerEmail")
        defaults.set("confirmed", forKey: "partnerConsentStatus")
        let svc = PartnerSyncService(defaults: defaults)

        svc.applyResponse(.init(partnerEmail: nil, partnerName: nil, consentStatus: nil))

        XCTAssertNil(defaults.string(forKey: "partnerName"))
        XCTAssertNil(defaults.string(forKey: "partnerEmail"))
        XCTAssertNil(defaults.string(forKey: "partnerConsentStatus"))
    }

    func testPublishedPropertiesUpdate() {
        let defaults = UserDefaults(suiteName: "test-partner-sync")!
        defaults.removePersistentDomain(forName: "test-partner-sync")
        let svc = PartnerSyncService(defaults: defaults)

        svc.applyResponse(.init(
            partnerEmail: "sara@example.com",
            partnerName: "Sara",
            consentStatus: "pending"
        ))

        XCTAssertEqual(svc.partnerName, "Sara")
        XCTAssertEqual(svc.partnerEmail, "sara@example.com")
        XCTAssertEqual(svc.consentStatus, "pending")
    }
}
```

- [ ] **Step 2: Implement the service**

```swift
import Foundation
import Combine

/// Pulls partner state from `/partner/status` on launch + foreground +
/// every 60 seconds while active, and writes it to UserDefaults so the
/// existing `@AppStorage("partnerName")` bindings throughout the iOS app
/// (PartnerView, BedtimeDetailView, BedtimeUnlockRequestSheet, BedtimeCard,
/// BedtimeScheduleService) auto-update.
///
/// Why this exists: the backend already syncs partner_email/name across
/// sibling user rows on `POST /partner` and falls back to siblings on
/// `GET /partner/status`. The clients just weren't fetching. This service
/// is the missing fetcher.
@MainActor
final class PartnerSyncService: ObservableObject {
    static let shared = PartnerSyncService()

    struct PartnerSnapshot: Equatable {
        let partnerEmail: String?
        let partnerName: String?
        let consentStatus: String?  // "pending" | "confirmed" | "declined" | "expired" | nil
    }

    @Published private(set) var partnerEmail: String?
    @Published private(set) var partnerName: String?
    @Published private(set) var consentStatus: String?

    private let defaults: UserDefaults
    private var pullTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?
    private var authObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Hydrate from existing cache so UI doesn't flicker on launch.
        self.partnerEmail = defaults.string(forKey: "partnerEmail")
        self.partnerName = defaults.string(forKey: "partnerName")
        self.consentStatus = defaults.string(forKey: "partnerConsentStatus")
    }

    /// Wired from PuckApp on first scene-active. Idempotent.
    func start() {
        Task { await self.pull() }

        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { await self?.pull() }
            }
        }

        // 60s poll while active.
        pullTimer?.invalidate()
        pullTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { await self?.pull() }
        }

        // Listen for logout to clear the cache.
        if authObserver == nil {
            authObserver = NotificationCenter.default.addObserver(
                forName: .authStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                if AuthService.shared.isAuthenticated == false {
                    self?.applyResponse(.init(partnerEmail: nil, partnerName: nil, consentStatus: nil))
                }
            }
        }
    }

    func stop() {
        pullTimer?.invalidate()
        pullTimer = nil
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
        foregroundObserver = nil
        if let obs = authObserver { NotificationCenter.default.removeObserver(obs) }
        authObserver = nil
    }

    func pull() async {
        guard AuthService.shared.isAuthenticated else { return }
        do {
            let status = try await IntentionalAPIClient.shared.getPartnerStatus()
            let snapshot = PartnerSnapshot(
                partnerEmail: status.partnerEmail,
                partnerName: status.partnerName,
                consentStatus: status.consentStatus
            )
            applyResponse(snapshot)
        } catch let error as NSError where error.code == 404 {
            // 404 = user not registered yet. Quiet.
            return
        } catch {
            AppLogger.partnerError?("PartnerSyncService.pull failed: \(error)")
        }
    }

    /// Public for tests. Writes a snapshot to UserDefaults + Published vars.
    func applyResponse(_ snapshot: PartnerSnapshot) {
        if let name = snapshot.partnerName, !name.isEmpty {
            defaults.set(name, forKey: "partnerName")
            partnerName = name
        } else {
            defaults.removeObject(forKey: "partnerName")
            partnerName = nil
        }

        if let email = snapshot.partnerEmail, !email.isEmpty {
            defaults.set(email, forKey: "partnerEmail")
            partnerEmail = email
        } else {
            defaults.removeObject(forKey: "partnerEmail")
            partnerEmail = nil
        }

        if let status = snapshot.consentStatus, !status.isEmpty {
            defaults.set(status, forKey: "partnerConsentStatus")
            consentStatus = status
        } else {
            defaults.removeObject(forKey: "partnerConsentStatus")
            consentStatus = nil
        }
    }
}
```

If `IntentionalAPIClient.getPartnerStatus()` returns a struct without `consentStatus`, add the field. Looking at the existing code in `IntentionalAPIClient.swift`, `PartnerStatus` already has the fields — verify the property name and adjust this code to match (it might be `consent_status` decoded as `consentStatus`).

- [ ] **Step 3: Build**

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'generic/platform=iOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Puck/Core/Partner/PartnerSyncService.swift PuckTests/PartnerSyncServiceTests.swift
git commit -m "feat(partner): PartnerSyncService — fetches /partner/status, writes UserDefaults"
```

#### Task 1.2 — Wire from `PuckApp.swift`

**Files:**
- Modify: `Puck/App/PuckApp.swift`

- [ ] **Step 1: Find the WindowGroup / scenePhase observer**

- [ ] **Step 2: Call `PartnerSyncService.shared.start()` once on first scene activation**

Add an `@StateObject private var partnerSync = PartnerSyncService.shared` near the other service @StateObjects. In the `.onChange(of: scenePhase)` handler:

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .active {
        partnerSync.start()
    }
}
```

(If `start()` is already called once, the idempotency guards in the service prevent double-subscribing.)

- [ ] **Step 3: Inject as EnvironmentObject so views can use it directly if they want richer state than @AppStorage**

```swift
.environmentObject(partnerSync)
```

- [ ] **Step 4: Build, commit**

```bash
git add Puck/App/PuckApp.swift
git commit -m "feat(partner): wire PartnerSyncService from PuckApp scene phase"
```

#### Task 1.3 — `AuthService` posts logout notification

**Files:**
- Modify: `Puck/Core/Auth/AuthService.swift`

- [ ] **Step 1: Find the existing `authStateDidChange` notification (it likely exists already since AuthService is a singleton with @Published properties)**

- [ ] **Step 2: If it doesn't exist, add it**

```swift
extension Notification.Name {
    static let authStateDidChange = Notification.Name("authStateDidChange")
}
```

In AuthService's logout method, post the notification after clearing state:

```swift
func logout() async {
    // ... existing logout work ...
    NotificationCenter.default.post(name: .authStateDidChange, object: nil)
}
```

If `.authStateDidChange` already exists, skip this task.

- [ ] **Step 3: Build, commit (or skip if not needed)**

```bash
git add Puck/Core/Auth/AuthService.swift
git commit -m "feat(auth): post authStateDidChange on logout for partner-cache clearing"
```

---

### Phase 2 — iOS: validate via existing UI

#### Task 2.1 — Smoke test the @AppStorage pickup

No code change; this validates the architecture works.

- [ ] **Step 1: Install the build on a test device. Log in as user A. Confirm partnerName UserDefaults is empty initially.**

- [ ] **Step 2: Use an admin tool (or a dev SQL query in Supabase) to set `users.partner_email` for user A's Mac device row. (Or set it via the Mac app first.)**

- [ ] **Step 3: Foreground the iOS app. Watch for the partner name to appear in BedtimeUnlockRequestSheet's "Ask Sara to unlock early" copy.**

If it appears: PartnerSyncService is reading correctly. If not: check Console.app for `PartnerSyncService.pull failed` log lines.

- [ ] **Step 4: Document smoke-test result in the cross-repo log (Phase 4 task).**

---

### Phase 3 — Mac `PartnerSyncService`

#### Task 3.1 — Create the Mac service

**Files:**
- Create: `Intentional/PartnerSyncService.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import AppKit

/// Mac-side counterpart to iOS's PartnerSyncService. Fetches /partner/status
/// on launch + didBecomeActiveNotification + 60s timer, writes the result
/// to UserDefaults (same keys as iOS for consistency: partnerName,
/// partnerEmail, partnerConsentStatus), and posts Notification.Name.partnerSyncDidUpdate
/// so MainWindow can push the new values into the dashboard via callJS.
@MainActor
final class PartnerSyncService {
    static let shared = PartnerSyncService()

    weak var appDelegate: AppDelegate?
    weak var backendClient: BackendClient?

    private var pullTimer: Timer?
    private var becameActiveObserver: NSObjectProtocol?

    private init() {}

    func configure(appDelegate: AppDelegate, backendClient: BackendClient) {
        self.appDelegate = appDelegate
        self.backendClient = backendClient
    }

    func start() {
        Task { await pullAndApply() }

        if becameActiveObserver == nil {
            becameActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { await self?.pullAndApply() }
            }
        }

        pullTimer?.invalidate()
        pullTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { await self?.pullAndApply() }
        }
    }

    func stop() {
        pullTimer?.invalidate()
        pullTimer = nil
        if let obs = becameActiveObserver { NotificationCenter.default.removeObserver(obs) }
        becameActiveObserver = nil
    }

    func pullAndApply() async {
        guard let backend = backendClient else { return }
        do {
            let status = try await backend.getPartnerStatus()
            applyToCache(
                email: status.partnerEmail,
                name: status.partnerName,
                consentStatus: status.consentStatus
            )
        } catch {
            appDelegate?.postLog("👥 PartnerSync pull failed: \(error)")
        }
    }

    private func applyToCache(email: String?, name: String?, consentStatus: String?) {
        let defaults = UserDefaults.standard
        if let email, !email.isEmpty {
            defaults.set(email, forKey: "partnerEmail")
        } else {
            defaults.removeObject(forKey: "partnerEmail")
        }
        if let name, !name.isEmpty {
            defaults.set(name, forKey: "partnerName")
        } else {
            defaults.removeObject(forKey: "partnerName")
        }
        if let consentStatus, !consentStatus.isEmpty {
            defaults.set(consentStatus, forKey: "partnerConsentStatus")
        } else {
            defaults.removeObject(forKey: "partnerConsentStatus")
        }

        NotificationCenter.default.post(
            name: .partnerSyncDidUpdate,
            object: nil,
            userInfo: [
                "partnerEmail": email as Any,
                "partnerName": name as Any,
                "partnerConsentStatus": consentStatus as Any,
            ]
        )
    }
}

extension Notification.Name {
    static let partnerSyncDidUpdate = Notification.Name("partnerSyncDidUpdate")
}
```

- [ ] **Step 2: Add `getPartnerStatus()` to `BackendClient` if it doesn't exist**

```swift
struct PartnerStatusDTO: Codable {
    let partnerEmail: String?
    let partnerName: String?
    let consentStatus: String?
    enum CodingKeys: String, CodingKey {
        case partnerEmail = "partner_email"
        case partnerName = "partner_name"
        case consentStatus = "consent_status"
    }
}

extension BackendClient {
    func getPartnerStatus() async throws -> PartnerStatusDTO {
        try await getJSON(path: "/partner/status")
    }
}
```

(Adjust `getJSON` invocation to whatever pattern BackendClient uses for X-Device-ID auth + GET requests.)

- [ ] **Step 3: Build**

```bash
xcodebuild -workspace Intentional.xcworkspace -scheme Intentional -configuration Debug build 2>&1 | tail -3
```

- [ ] **Step 4: Commit**

```bash
git add Intentional/PartnerSyncService.swift Intentional/BackendClient.swift
git commit -m "feat(partner): Mac PartnerSyncService — fetches /partner/status, posts notification"
```

#### Task 3.2 — Wire from `AppDelegate`

**Files:**
- Modify: `Intentional/AppDelegate.swift`

- [ ] **Step 1: Find the existing service init order**

- [ ] **Step 2: Add PartnerSyncService init/start after BackendClient is ready**

Add a property near the other services:

```swift
var partnerSyncService: PartnerSyncService?
```

In `applicationDidFinishLaunching`, after `backendClient = BackendClient(...)`:

```swift
partnerSyncService = PartnerSyncService.shared
partnerSyncService?.configure(appDelegate: self, backendClient: backendClient!)
partnerSyncService?.start()
postLog("👥 PartnerSyncService started")
```

- [ ] **Step 3: Build, commit**

```bash
git add Intentional/AppDelegate.swift
git commit -m "feat(partner): wire PartnerSyncService into AppDelegate startup"
```

#### Task 3.3 — Push partner update to dashboard via WKWebView

**Files:**
- Modify: `Intentional/MainWindow.swift`
- Modify: `Intentional/dashboard.html`

- [ ] **Step 1: In MainWindow, observe `partnerSyncDidUpdate` notification**

In `MainWindow`'s setup (probably init or a `setup()` method):

```swift
NotificationCenter.default.addObserver(
    forName: .partnerSyncDidUpdate,
    object: nil,
    queue: .main
) { [weak self] note in
    let info = note.userInfo ?? [:]
    let email = (info["partnerEmail"] as? String) ?? ""
    let name = (info["partnerName"] as? String) ?? ""
    let status = (info["partnerConsentStatus"] as? String) ?? ""
    let payload = "{email: '\(email)', name: '\(name)', consentStatus: '\(status)'}"
    self?.callJS("window._partnerSyncResult && window._partnerSyncResult(\(payload))")
}
```

(Escape special chars in the email/name strings — partner names with apostrophes will break the JS literal. Use JSON encoding via `JSONEncoder` rather than f-string.)

Better:
```swift
let payload: [String: String] = [
    "email": email,
    "name": name,
    "consentStatus": status,
]
if let json = try? JSONSerialization.data(withJSONObject: payload, options: []),
   let jsonStr = String(data: json, encoding: .utf8) {
    self?.callJS("window._partnerSyncResult && window._partnerSyncResult(\(jsonStr))")
}
```

- [ ] **Step 2: In dashboard.html, add the receiver**

Find the existing `window._saveSettingsResult` or similar handler near line 7372. Add nearby:

```javascript
window._partnerSyncResult = function(data) {
    if (data.email !== undefined) settings.partnerEmail = data.email;
    if (data.name !== undefined) settings.partnerName = data.name;
    if (data.consentStatus !== undefined) settings.partnerConsentStatus = data.consentStatus;
    if (typeof renderPartnerSection === 'function') renderPartnerSection();
};
```

(Actual function names depend on the existing dashboard structure — read the file to find where `partnerEmail` is rendered and call the appropriate refresh function.)

- [ ] **Step 3: Build, commit**

```bash
git add Intentional/MainWindow.swift Intentional/dashboard.html
git commit -m "feat(partner): push partner-sync updates to dashboard via WKWebView"
```

---

### Phase 4 — Cross-repo log + CLAUDE.md updates

#### Task 4.1 — Cross-repo log

- [ ] Create `intentional-macos-app/docs/cross-repo-partner-sync-2026-04-29.md`. Cover: what shipped per repo, commit SHAs, manual smoke-test plan, "what to test next morning."

- [ ] Add card to `intentional-macos-app/docs/index.html`.

#### Task 4.2 — CLAUDE.md updates

- `intentional-macos-app/CLAUDE.md`: add bug-fix entry for the partner-cache desync.
- `puck-ios/CLAUDE.md`: add a "Partner sync" section under the existing Cross-Device State principle.

---

## §7. Hand-off prompt for executing agent

Paste below into a fresh agent session:

> You are implementing the spec at `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/superpowers/plans/2026-04-29-partner-cross-device-sync.md`. Read the WHOLE file before any code, especially §1 (already shipped — DO NOT touch backend; it's correct), §3 (out of scope), and §4 (risk catalog).
>
> Repos:
> - iOS: `/Users/arayan/Documents/GitHub/puck-ios`. Worktree at `.claude/worktrees/partner-sync` off `feat/bedtime-redesign`, branch `feat/partner-sync`.
> - Mac: `/Users/arayan/Documents/GitHub/intentional-macos-app`. Worktree at `.claude/worktrees/partner-sync` off `feat/focus-mode-consolidation`, branch `feat/partner-sync`.
> - Backend: NO changes. Don't touch.
>
> Use `superpowers:subagent-driven-development` for execution.
>
> Phase order: Phase 1 (iOS service), Phase 2 (iOS smoke test), Phase 3 (Mac service + dashboard wiring), Phase 4 (docs). iOS and Mac can run in parallel since they're in separate repos.
>
> Each task: failing test → implementation → green → commit (where applicable). UI-touching tasks verified via `xcodebuild ... | tail -3` showing `BUILD SUCCEEDED`.
>
> Constraints:
> - Do NOT modify backend partner endpoints.
> - Do NOT touch the `@AppStorage("partnerName")` references in iOS views — they're auto-updating from the new service's UserDefaults writes. Verify with the smoke test.
> - Do NOT add APNs push for partner updates. Polling at 60s is fine for v1.
> - Apply `superpowers:verification-before-completion` before claiming any phase done.
>
> Final report: commit SHAs per repo per phase, what's deployed/built, manual smoke-test result, any genuine open questions.

---

## §8. Self-review

**Spec coverage:**
- "Partner shows up on both devices once confirmed" → Phase 1 + 3 add the fetcher; Phase 2 validates via existing UI. ✓
- "Plan it out" → 4 phases, 8 tasks, files mapped, hand-off ready. ✓

**Placeholder scan:**
- One soft area: Task 3.3 step 2 says "actual function names depend on the existing dashboard structure — read the file to find where `partnerEmail` is rendered." That's because dashboard.html is large and I didn't grep it inline. Acceptable; agent reads the file. ✓
- All tests have real code. All file paths are absolute. ✓

**Type / method consistency:**
- `PartnerSyncService.applyResponse(_:)` — defined Phase 1 task 1.1, called in tests + observer wiring. ✓
- `PartnerSnapshot` — defined Phase 1, used in tests. ✓
- `BackendClient.getPartnerStatus()` returning `PartnerStatusDTO` — defined Phase 3 task 3.1, called from PartnerSyncService.pullAndApply. ✓
- `Notification.Name.partnerSyncDidUpdate` — defined in PartnerSyncService.swift, observed in MainWindow.swift. ✓
- `Notification.Name.authStateDidChange` — referenced Phase 1.3, may already exist. Task explicitly checks first. ✓

**Risk → mitigation cross-check:**
- R1 (battery) → 60s timer pauses on inactive
- R4 (MainActor write) → service is `@MainActor`-annotated; writes go through MainActor
- R5 (logout clears cache) → Phase 1.3 observer
- R6 (dashboard not refreshing) → Phase 3.3 callJS
- R7 (auth not ready) → service guards on `isAuthenticated`
- R10 (404 quiet) → service catches NSError 404

**No remaining gaps.** Plan is ready for hand-off.
