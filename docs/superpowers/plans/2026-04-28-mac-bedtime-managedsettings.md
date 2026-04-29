# Mac Bedtime — Migrate from `pmset sleepnow` to ManagedSettings + FamilyControls

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Mac's heavy-handed bedtime enforcement (custom full-screen overlay + force-sleep via `pmset sleepnow`) with the same FamilyControls + ManagedSettings shielding that the iPhone uses. Apps refuse to launch; the Mac stays awake; the user can finish what they're doing.

**Architecture:** `ManagedSettingsStore("bedtime")` configured with `shield.applications` from a user-selected allowlist (or all-except-allowlist semantics, mirroring iPhone). Drop `pmset sleepnow`, drop the auto-sleep countdown, drop the full-screen takeover NSWindow. Keep partner-code unlock, keep `BedtimeConfigSync` backend pull, keep `TrustedClock` tamper detection. Replace the overlay with a minimal "Bedtime active — apps disabled until 6:30 AM" status surface (menu bar + small banner, not full-screen).

**Tech Stack:** macOS 14+, FamilyControls.framework, ManagedSettings.framework, Swift 5.9+, AppKit (existing AppDelegate). Reuses iPhone's pattern.

---

## §0. Why this plan exists

On 2026-04-28, the user got force-slept at noon by `BedtimeEnforcer.forceSleep()`. Two compounding bugs were patched same day (commits `fda9a00` worktree, `eacf6d2` main):

1. `TrustedClock.detectDrift()` used `ProcessInfo.systemUptime` which doesn't advance during sleep. Any Mac sleep > 120s was misread as a clock tamper, forcing `.lockedOut` outside the bedtime window.
2. `BedtimeEnforcer.snoozeTimer` expiry called `transition(.lockedOut)` directly, bypassing the `settings.enabled` guard. Disabling bedtime mid-snooze didn't prevent the re-lock.

Both fixes shipped. But the existence of `pmset sleepnow` as a primary enforcement mechanism is the underlying problem. Even with the bugs fixed, the failure mode (Mac forcefully sleeps the entire system on a 3-min countdown) is too punishing for any single edge case in a complex state machine to remain acceptable.

The iPhone uses `ManagedSettingsStore` with a shield. Apps refuse to launch. No system-wide action. No countdown-to-shutdown. No way to lose unsaved work because of an enforcement decision. We bring the Mac in line with that model.

---

## §1. Current Mac architecture (what's there today)

| File | Role |
|---|---|
| `Intentional/BedtimeEnforcer.swift` | State machine: `idle / windDown / lockedOut / snoozed / overridden`. The `.lockedOut` transition shows a full-screen overlay; if `snoozeUsedTonight` is true, starts a 180s countdown that ends in `pmset sleepnow`. |
| `Intentional/BedtimeOverlayView.swift` | SwiftUI overlay — countdown UI, snooze button, partner-code entry, sleep-now button. |
| `Intentional/TrustedClock.swift` | Anchors a known-good time and detects clock tamper via drift between wall clock and `mach_continuous_time` (post-fix). |
| `Intentional/BedtimeConfigSync.swift` | Pulls `/bedtime/config` every 60s + on app foreground. Calls `enforcer.applyRemoteSettings(_:)`. |
| `Intentional/BackendClient.swift` | `bedtimeUnlockRequest`, `bedtimeUnlockVerify`, `bedtimeUnlockStatus` (added 2026-04-28). |

Enforcement primitives:
- `pmset sleepnow` — sleeps the Mac
- `KeyableWindow` at `.screenSaver` level — full-screen overlay
- `GrayscaleOverlayController` — wind-down desaturation

---

## §2. Target Mac architecture

| File | New role |
|---|---|
| `Intentional/BedtimeShieldStore.swift` (NEW) | Wraps `ManagedSettingsStore(named: "bedtime")`. `activate(allowlist:)` and `deactivate()`. Idempotent (mirrors iPhone's `BedtimeShieldStore`). |
| `Intentional/BedtimeFamilyControlsAuth.swift` (NEW) | Manages FamilyControls authorization on Mac. Prompt-on-first-need, status check, re-prompt path. |
| `Intentional/BedtimeAllowlistStorage.swift` (NEW) | Persists `Set<ApplicationToken>` to disk (or App Group if shared with iPhone via iCloud — out of scope for v1). |
| `Intentional/BedtimeAllowlistView.swift` (NEW) | SwiftUI wrapper around `FamilyActivityPicker` for the user to select allowlist apps. Shown via dashboard. |
| `Intentional/BedtimeStatusBanner.swift` (NEW) | Small in-app status ("Bedtime active until 6:30 AM"), NOT full-screen. Replaces the full-screen overlay. |
| `Intentional/BedtimeEnforcer.swift` (MODIFIED) | State machine simplified: `inactive / locked / released`. Drop `windDown` (or keep the wind-down notifications only — no grayscale). Drop `snoozed` (snooze becomes a 10-min `releasedUntil`). Drop `pmset sleepnow`. |
| `Intentional/BedtimeOverlayView.swift` (DELETED) | Replaced by `BedtimeStatusBanner` + the system-level shield UI. |
| `Intentional/GrayscaleOverlayController.swift` (DELETED) | Wind-down grayscale removed. The shield itself is the wind-down (apps stop launching; user notices in seconds). |

Enforcement primitives now:
- `ManagedSettingsStore("bedtime").shield.applications = bedtimeShieldedApps` (iOS-equivalent)
- Banner status (menu bar + dashboard hero card)
- No `pmset` call anywhere

What stays:
- `BedtimeConfigSync` (backend pull, applied to enforcer)
- `TrustedClock` (still detects time tamper — refuses to release on a manipulated clock)
- Partner-code unlock via `/bedtime/unlock-verify` (unchanged)
- Wake-alarm ends bedtime (existing logic, just doesn't need to call `pmset`)

---

## §3. What changes in user-visible behavior

| Before (today) | After (this plan) |
|---|---|
| Bedtime starts → custom full-screen takeover | Bedtime starts → distracting apps refuse to launch; small banner says "Bedtime active until 6:30 AM" |
| Snooze → 10 min → returns to lockout → 3 min → **Mac sleeps** | Snooze → 10 min → re-evaluate (already shipped) |
| User cannot save in-progress work (overlay covers everything) | User can keep working in already-open apps; can save files; just can't launch new distracting apps |
| Wind-down → screen desaturates (grayscale) | Wind-down → notification only ("Bedtime in 15 minutes — wrap up") |
| Tamper false-positive → forced lockout → forced sleep | Tamper false-positive (already largely fixed) → app shield activates briefly → no system action |
| Allowlist not user-configurable on Mac | Allowlist user-configurable via `FamilyActivityPicker` on Mac, persisted, synced to iPhone via backend (eventually) |
| Strict-mode daemon respawns the app to keep enforcing | Same; daemon role unchanged. The shield SURVIVES app death (ManagedSettings is kernel-enforced). |

---

## §4. Out of scope (do NOT add)

- **Pre-flight macOS Downtime API integration.** macOS does NOT expose Screen Time / Downtime config to apps. We use ManagedSettings directly, not Apple's user-facing Downtime panel.
- **Per-app categories on Mac.** `ApplicationCategoryToken` is iOS-only. We shield specific applications (not categories) on Mac. If categories work on macOS 15+, treat as future enhancement.
- **Web-domain shielding via FamilyControls on Mac.** That path is iOS-only; we keep `WebsiteBlocker` (AppleScript) for browser tab blocking on Mac, unchanged.
- **iCloud-shared allowlist between Mac + iPhone.** v1 stores allowlist locally on each device. Sync via backend is a separate plan — `bedtime_config.allowlist_bundle_ids` already exists but uses opaque `ios-token-N` placeholders that don't survive the Mac↔iPhone boundary. Future enhancement.
- **Removing `BedtimeConfigSync`** — keep it. It's working.
- **Removing `TrustedClock`** — keep it. It's now correct (post-fix). It still has value as a tamper-detection signal that GUARDS unlocks (e.g., partner-code release should require a non-tampered clock to take effect).
- **Removing the strict-mode daemon** — out of scope. The daemon still serves the watchdog role (PKG persistence, anti-tamper).
- **Bringing `IntentionalModeController` or `FocusSessionManager` back** — these were intentionally deleted in the April 2026 consolidation. Don't reintroduce.

---

## §5. Risk catalog

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | macOS `ApplicationToken` shape differs from iOS, code that compiles on iPhone won't on Mac | Medium | Phase 1 spike: build a 50-line proof-of-concept on Mac that activates a shield. Validate the API surface BEFORE committing to the rest. If APIs are unusable, abort and stay on legacy enforcement (with the snooze-bypass + tamper fixes already in place). |
| R2 | `FamilyActivityPicker` SwiftUI view crashes or doesn't render on Mac | Medium | Same Phase 1 spike. Have a fallback "type bundle ID manually" form ready. |
| R3 | macOS user revokes FamilyControls authorization mid-bedtime | Low | Document; on revocation, app falls back to BedtimeStatusBanner-only (informational, no enforcement). Don't crash. |
| R4 | Apps already running when bedtime starts — shield doesn't kill them | Documented behavior | Acceptable. The shield prevents NEW launches. The user's already-open apps stay open. They can finish what they're doing. This is the friendlier model. Document explicitly. |
| R5 | `ManagedSettingsStore` shield outlives Mac app process death (just like on iPhone) | Documented | Already proven on iPhone: the shield is kernel-enforced. On launch, `BedtimeEnforcer` reconciles state from cached config + current time and either re-asserts or clears the shield. |
| R6 | User has no Apple Developer entitlements for FamilyControls on Mac | Low | The build script already provisions iOS FamilyControls for Puck. Verify Mac entitlements are in `Intentional.entitlements` BEFORE Phase 2. |
| R7 | Strict-mode daemon's "App watchdog" sees a running app + shield, decides to "fix" something and corrupts state | Low | Daemon is independent; doesn't touch ManagedSettings. Verify by reading the daemon source. No change expected. |
| R8 | User on macOS 13 (FamilyControls support partial pre-14) | Low | Set deployment target to macOS 14 minimum for the shielding code. Older systems fall back to legacy `pmset` path (kept as opt-in for users who can't upgrade). Or refuse to enable bedtime on macOS < 14. Decide in Phase 1. |
| R9 | Browser tabs already loaded keep distracting the user even with apps shielded | Documented limitation | `WebsiteBlocker` (existing AppleScript path) stays in play. Bedtime's iPhone-side already blocks `webDomainCategories = .all()`. On Mac, we lean on the existing tab blocker. Not a regression. |
| R10 | Partner-code unlock removes shield but `releasedUntil` not honored on first tick after restart | Already fixed pattern | iPhone's `BedtimeScheduleService.tick()` reads `releasedUntil` first. Mirror in Mac's `BedtimeEnforcer.evaluate()`. Existing code already does this. Verify in Phase 4. |
| R11 | App refuses to relaunch after PKG install due to FamilyControls auth prompt loop | Medium | Test on a clean machine. Ensure the auth prompt fires once and is persisted. Document the user-visible flow. |
| R12 | `BedtimeAllowlistView` opens a modal that the user has to dismiss before bedtime activates the first time | Low | Add a "Set up bedtime allowlist" hero card on the dashboard the first time bedtime is enabled. Don't force the picker; let the default be "block everything." User can opt to add allowlist entries later. |

---

## §6. File structure

### Created

| Path | Responsibility |
|---|---|
| `Intentional/BedtimeShieldStore.swift` | `activate(allowlist:)` + `deactivate()`. Owns `ManagedSettingsStore(named: "bedtime")`. ~50 lines. |
| `Intentional/BedtimeFamilyControlsAuth.swift` | `requestAuthorization() async throws`, `authorizationStatus`. Wraps `AuthorizationCenter`. ~30 lines. |
| `Intentional/BedtimeAllowlistStorage.swift` | Encode/decode `Set<ApplicationToken>` to file in App Support. Same pattern as iPhone's `BedtimeAllowlistStorage`. ~40 lines. |
| `Intentional/BedtimeAllowlistView.swift` | SwiftUI view hosting `FamilyActivityPicker`. Embed in the dashboard via existing `BedtimeOverlayView` deletion path. ~80 lines. |
| `Intentional/BedtimeStatusBanner.swift` | Compact status banner for active bedtime. Shows in the dashboard hero + as a menu-bar item title. ~60 lines. |
| `IntentionalTests/BedtimeShieldTests.swift` | Tests for activate/deactivate, allowlist round-trip. |

### Modified

| Path | Change |
|---|---|
| `Intentional/BedtimeEnforcer.swift` | Drop `windDown` phases (replace with single `.windDownNotificationFiredTonight` flag), drop `snoozed` state, drop `forceSleep`/`startAutoSleepCountdown`. State machine becomes `inactive / locked / released`. `transition(to: .locked)` calls `BedtimeShieldStore.shared.activate(allowlist:)` instead of `showLockoutOverlay`. `transition(to: .inactive)` calls `BedtimeShieldStore.shared.deactivate()`. |
| `Intentional/BedtimeOverlayView.swift` | DELETE. |
| `Intentional/GrayscaleOverlayController.swift` | DELETE. |
| `Intentional/AppDelegate.swift` | Remove `bedtimeEnforcer.start()` calling pmset paths; add `bedtimeShieldStore` initialization; remove `vm.onSleepNow` wiring. |
| `Intentional/MainWindow.swift` | Remove dashboard "Sleep now" / "Snooze" buttons (or repurpose snooze to set a 10-min `releasedUntil`). Add "Bedtime allowlist" entry that opens `BedtimeAllowlistView`. |
| `Intentional/Intentional.entitlements` | Verify `com.apple.developer.family-controls` is present for Mac target. Add if absent. |
| `Intentional.xcodeproj/project.pbxproj` | Link `ManagedSettings.framework` and `FamilyControls.framework` to the Mac target if not already. |
| `CLAUDE.md` | Document new architecture in "Known bug fixes" + "Initialization Order" sections. |

### Deleted

- `Intentional/BedtimeOverlayView.swift`
- `Intentional/GrayscaleOverlayController.swift`
- The auto-sleep countdown UI assets (if any standalone)

---

## §7. Phase-by-phase implementation

Branch: `feat/mac-bedtime-managedsettings` off `feat/focus-mode-consolidation`. Use a worktree.

### Phase 1 — Spike: validate macOS FamilyControls API

**Estimate:** ~80 lines, ~1 hour. **GATING.** If this phase doesn't compile + run on Mac, the whole plan is moot.

#### Task 1.1 — Add framework links + entitlement

- [ ] Verify `com.apple.developer.family-controls` is in `Intentional.entitlements`. If not, add:
  ```xml
  <key>com.apple.developer.family-controls</key>
  <true/>
  ```
- [ ] In Xcode (or via project.yml if used), link `FamilyControls.framework` and `ManagedSettings.framework` to the Mac app target.
- [ ] Build: `xcodebuild -workspace Intentional.xcworkspace -scheme Intentional -configuration Debug build 2>&1 | tail -3` should still report `BUILD SUCCEEDED`.

#### Task 1.2 — Spike: shield a single app

- [ ] Create `Intentional/Spike/MacFamilyControlsSpike.swift`:
  ```swift
  #if canImport(FamilyControls) && canImport(ManagedSettings)
  import FamilyControls
  import ManagedSettings
  
  @MainActor
  enum MacFamilyControlsSpike {
      static let store = ManagedSettingsStore(named: .init("spike"))
  
      static func authorize() async throws {
          try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
      }
  
      static func shieldAll() {
          // Use .all() — shield everything for the test
          store.shield.applicationCategories = .all()
      }
  
      static func clear() {
          store.clearAllSettings()
      }
  }
  #endif
  ```
- [ ] Add a debug menu item in the app's menu bar that calls `MacFamilyControlsSpike.authorize()` then `shieldAll()`. Trigger manually.
- [ ] Test: launch the app, click the debug item, observe whether (a) the auth prompt appears, (b) other apps refuse to launch after auth.
- [ ] If (a) fails on macOS 14+: ABORT THE PLAN. Document the API gap. Stay on the legacy enforcement (already de-fanged via the tamper + snooze fixes).
- [ ] If (b) fails: investigate which `shield` properties work on Mac (not all do — `applications`, `applicationCategories`, etc. may have different support levels).
- [ ] Document findings in `docs/cross-repo-mac-bedtime-spike-2026-MM-DD.md`.

**Stop gate:** Do not proceed until the spike proves the API surface is usable. If gaps, write a follow-up plan that adapts.

#### Task 1.3 — Commit spike findings

- [ ] Commit:
  ```
  spike(bedtime): proof-of-concept ManagedSettings shielding on Mac
  ```
- [ ] Either: continue to Phase 2 (API works), or: park the branch with the spike and a "what we learned" doc, and revert to legacy enforcement.

---

### Phase 2 — `BedtimeShieldStore` + auth + allowlist storage

**Estimate:** ~150 lines + tests.

#### Task 2.1 — `BedtimeFamilyControlsAuth.swift` (TDD)

**Files:**
- Create: `Intentional/BedtimeFamilyControlsAuth.swift`
- Create: `IntentionalTests/BedtimeFamilyControlsAuthTests.swift`

- [ ] Step 1: Write failing test that checks the wrapper returns `.notDetermined` on first call.

```swift
import XCTest
@testable import Intentional
import FamilyControls

final class BedtimeFamilyControlsAuthTests: XCTestCase {
    @MainActor
    func testStatusBeforeRequest() {
        let auth = BedtimeFamilyControlsAuth()
        // On a fresh test target the status is .notDetermined
        XCTAssertEqual(auth.authorizationStatus, .notDetermined)
    }
}
```

- [ ] Step 2: Run, FAIL (type doesn't exist).

- [ ] Step 3: Implement:

```swift
import Foundation
import FamilyControls

@MainActor
final class BedtimeFamilyControlsAuth {
    static let shared = BedtimeFamilyControlsAuth()
    private init() {}

    var authorizationStatus: AuthorizationStatus {
        AuthorizationCenter.shared.authorizationStatus
    }

    /// Throws if user denies. Idempotent on repeat call when already authorized.
    func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }
}
```

- [ ] Step 4: Test PASS.

- [ ] Step 5: Commit `feat(bedtime): FamilyControls auth wrapper for Mac`.

#### Task 2.2 — `BedtimeAllowlistStorage.swift` (TDD)

**Files:**
- Create: `Intentional/BedtimeAllowlistStorage.swift`
- Create: `IntentionalTests/BedtimeAllowlistStorageTests.swift`

- [ ] Step 1: Failing test:

```swift
import XCTest
@testable import Intentional
import FamilyControls

final class BedtimeAllowlistStorageTests: XCTestCase {
    @MainActor
    func testRoundTripEmptySet() {
        let storage = BedtimeAllowlistStorage()
        storage.save(Set<ApplicationToken>())
        let loaded = storage.load()
        XCTAssertEqual(loaded.count, 0)
    }
}
```

- [ ] Step 2: FAIL.

- [ ] Step 3: Implement:

```swift
import Foundation
import FamilyControls

@MainActor
final class BedtimeAllowlistStorage {
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bedtime_allowlist.json")
    }()

    func save(_ tokens: Set<ApplicationToken>) {
        if let data = try? JSONEncoder().encode(tokens) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func load() -> Set<ApplicationToken> {
        guard let data = try? Data(contentsOf: url),
              let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data)
        else {
            return []
        }
        return tokens
    }
}
```

- [ ] Step 4: PASS. Commit.

#### Task 2.3 — `BedtimeShieldStore.swift` (TDD)

**Files:**
- Create: `Intentional/BedtimeShieldStore.swift`
- Create: `IntentionalTests/BedtimeShieldStoreTests.swift`

- [ ] Step 1: Failing test:

```swift
import XCTest
@testable import Intentional
import FamilyControls
import ManagedSettings

final class BedtimeShieldStoreTests: XCTestCase {
    @MainActor
    func testActivateThenDeactivateClearsShield() {
        let store = BedtimeShieldStore.shared
        store.activate(allowlist: [])
        XCTAssertTrue(store.isActive)
        store.deactivate()
        XCTAssertFalse(store.isActive)
    }
}
```

- [ ] Step 2: FAIL.

- [ ] Step 3: Implement (mirrors iPhone, with macOS-appropriate shield properties):

```swift
import Foundation
import FamilyControls
import ManagedSettings

@MainActor
final class BedtimeShieldStore {
    static let shared = BedtimeShieldStore()
    private let store = ManagedSettingsStore(named: .init("bedtime"))
    private(set) var isActive: Bool = false
    private init() {}

    func activate(allowlist: Set<ApplicationToken>) {
        // Mirror iPhone's strategy: shield all apps except the user's allowlist.
        store.shield.applicationCategories = .all(except: allowlist)
        // Web domains: leave to existing WebsiteBlocker on Mac. Don't double-shield.
        isActive = true
        AppLogger.bedtimeInfo?("BedtimeShieldStore activated with \(allowlist.count) allowlisted apps")
    }

    func deactivate() {
        store.clearAllSettings()
        isActive = false
        AppLogger.bedtimeInfo?("BedtimeShieldStore deactivated")
    }
}
```

(Note: if Mac's `AppLogger` doesn't have `.bedtimeInfo`, swap for whatever logging facility exists. Reading the codebase first.)

- [ ] Step 4: PASS. Commit.

#### Task 2.4 — `BedtimeAllowlistView.swift`

**Files:**
- Create: `Intentional/BedtimeAllowlistView.swift`

- [ ] Implement a SwiftUI view hosting `FamilyActivityPicker`:

```swift
import SwiftUI
import FamilyControls

struct BedtimeAllowlistView: View {
    @State private var selection = FamilyActivitySelection()
    let storage = BedtimeAllowlistStorage()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow these apps during bedtime")
                .font(.headline)
            Text("Phone, Messages, Maps, sleep apps — anything else is shielded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            FamilyActivityPicker(selection: $selection)
                .frame(minHeight: 400)
            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .onAppear { selection.applicationTokens = storage.load() }
    }

    private func save() {
        storage.save(selection.applicationTokens)
    }
}
```

- [ ] Build (no test — SwiftUI views aren't unit-tested here). Commit.

---

### Phase 3 — Refactor `BedtimeEnforcer`

**Estimate:** ~200 lines net change.

#### Task 3.1 — Simplify the state machine

**Files:**
- Modify: `Intentional/BedtimeEnforcer.swift`

- [ ] Replace the existing enum with:

```swift
enum BedtimeState: Equatable {
    case inactive
    case locked        // shield applied, in window
    case released      // partner code accepted; shield cleared until releasedUntil
}
```

- [ ] Drop `WindDownPhase`, `case .windDown`, `case .snoozed`, `case .overridden`. (Or keep `.released` for the partner-unlock path — that's the rename of `.overridden`.)
- [ ] In `transition(to:)`:
  - `.inactive`: `BedtimeShieldStore.shared.deactivate()`. Cancel timers.
  - `.locked`: `BedtimeShieldStore.shared.activate(allowlist: BedtimeAllowlistStorage().load())`. No countdown, no `pmset`.
  - `.released`: `BedtimeShieldStore.shared.deactivate()`. Set `releasedUntil` from input.
- [ ] Delete `forceSleep()`, `startAutoSleepCountdown()`, `showLockoutOverlay()`, the `BedtimeOverlayView` reference, the `KeyableWindow` wiring.
- [ ] Keep `recalculate()`'s logic almost intact: enabled check, tamper check (still trips into `.locked`), `releasedUntil` short-circuit, `isInBedtime` → `.locked`, otherwise `.inactive`. Drop the wind-down branch.
- [ ] Keep `onMacWoke()` — but now it just calls `recalculate()`. The "snoozeUsedTonight" flag is gone; no need for the no-second-snooze logic.

- [ ] Build, commit `refactor(bedtime): state machine inactive/locked/released, no pmset`.

#### Task 3.2 — Wind-down notification (preserved, no grayscale)

- [ ] Keep `BedtimeLogic.windDownPhase(...)` pure function.
- [ ] In `recalculate()`, if `windDownPhase != .none && !windDownNotificationFiredTonight`, call `sendNotification("Bedtime in 15 minutes — wrap up what you're doing")`. Set the flag. Reset the flag at midnight or on next `.inactive` after `.locked`.
- [ ] No grayscale, no overlay, just a notification. iPhone-style.
- [ ] Commit.

#### Task 3.3 — Partner-code unlock path

- [ ] Already wired: `BedtimeOverlayView` → `BackendClient.bedtimeUnlockVerify(code:)`. But `BedtimeOverlayView` is being deleted.
- [ ] New entry point: a sheet from the `BedtimeStatusBanner` (Phase 4) that takes a 6-digit code and calls the existing endpoint.
- [ ] On verify success: `enforcer.markReleased(until: response.released_until)`.
- [ ] Build, commit.

---

### Phase 4 — `BedtimeStatusBanner`

**Estimate:** ~80 lines.

#### Task 4.1

**Files:**
- Create: `Intentional/BedtimeStatusBanner.swift`

- [ ] Compact card UI: moon glyph, "Bedtime active until {wakeTimeString}", "Ask Sara to unlock" link, "Edit allowlist" link. NOT full-screen.
- [ ] Embed in the dashboard hero. NOT a separate window.
- [ ] Optional: title in menu bar item changes to "🌙 Bedtime locked" while active.
- [ ] Build, commit.

---

### Phase 5 — Drop the legacy code

**Estimate:** ~10 minutes (mostly deletes).

- [ ] Delete `Intentional/BedtimeOverlayView.swift`.
- [ ] Delete `Intentional/GrayscaleOverlayController.swift`.
- [ ] Remove all `pmset`-related strings (audit via `grep -rn "pmset\|sleepnow" Intentional/`).
- [ ] Remove `vm.onSleepNow`, `BedtimeOverlayViewModel.onSleepNow` (the entire field). Audit for unused properties on the view model.
- [ ] Remove `countdownTimer`, `countdownSeconds`, `snoozeUsedTonight`, `snoozeTimer` from `BedtimeEnforcer`.
- [ ] Remove the `KeyableWindow` array tracking the overlay windows.
- [ ] Build clean, commit `chore(bedtime): drop pmset and full-screen overlay`.

---

### Phase 6 — PKG build + verification

- [ ] `NOTARIZE=0 ./scripts/build-pkg.sh`.
- [ ] Manually install on a test machine (or the user's, if they're willing).
- [ ] Verify: bedtime activates → distracting apps refuse to launch → user can keep working in already-open apps → no countdown → no `pmset sleepnow` ever fires → wake alarm dismisses bedtime → shield clears.
- [ ] Verify: `grep -rn "pmset\|sleepnow" Intentional/` returns nothing.
- [ ] Cross-repo log at `docs/cross-repo-mac-bedtime-managedsettings-YYYY-MM-DD.md`. CLAUDE.md updates.

---

## §8. Existing patterns to mirror

- **iPhone's `BedtimeShieldStore`** at `puck-ios/Puck/Core/Bedtime/BedtimeShieldStore.swift` — the canonical reference. The Mac version is a near-copy with platform-appropriate adjustments.
- **iPhone's `BedtimeScheduleService.tick()`** at `puck-ios/Puck/Core/Bedtime/BedtimeScheduleService.swift` — the cleanest version of "evaluate state, apply or deactivate shield." Mac's `BedtimeEnforcer.recalculate()` should converge to a similar shape.
- **iPhone's `BedtimeAllowlistStorage`** at `puck-ios/Puck/Core/Bedtime/BedtimeScheduleService.swift` (bottom of file) — App Group storage. Mac uses Application Support directory (single-user, single-process).
- **`ManagedSettingsStore`'s persistence** — kernel-enforced. The shield outlives the app process. Document in code comments.

---

## §9. Open follow-ups (do NOT fold into this plan)

- iCloud-shared bedtime allowlist between Mac + iPhone. Backend's `bedtime_config.allowlist_bundle_ids` exists but uses opaque iOS placeholders. Need a real cross-platform encoding.
- Removing the dead `WebsiteBlocker` AppleScript path if/when web-domain shielding lands on Mac via FamilyControls.
- Removing the strict-mode daemon if/when the user's threat model relaxes.
- Auditing the strict-mode daemon's interactions with ManagedSettings (it doesn't currently touch them, but verify after this lands).
- Live Activity / Mac equivalent (menu bar countdown). Mac doesn't have ActivityKit; consider a small status bar view instead.

---

## §10. Hand-off prompt for executing agent

Paste below into a fresh agent session:

> You are implementing the spec at `intentional-macos-app/docs/superpowers/plans/2026-04-28-mac-bedtime-managedsettings.md`. Read the WHOLE file first, including §1 (current architecture, do not redo), §4 (out-of-scope — do not violate), and §5 (risk catalog).
>
> Repo: `/Users/arayan/Documents/GitHub/intentional-macos-app`. Parent branch: `feat/focus-mode-consolidation`. Work in a worktree at `.claude/worktrees/mac-bedtime-managedsettings`, branch `feat/mac-bedtime-managedsettings`.
>
> Use `superpowers:subagent-driven-development` for execution. One commit per task.
>
> **Phase 1 is gating.** Do not write any of Phases 2-5 if the API spike fails. If `FamilyControls`/`ManagedSettings` shielding doesn't work on Mac, write the findings to a doc and pause. The legacy enforcement code stays as-is — the user has the tamper + snooze hotfixes already.
>
> Constraints:
> - Do NOT remove `BedtimeConfigSync`. It works.
> - Do NOT remove `TrustedClock`. It works (post-fix).
> - Do NOT remove the strict-mode daemon. Out of scope.
> - Do NOT bring back `IntentionalModeController` or `FocusSessionManager`.
> - Do NOT touch the iPhone repo. Mac-only.
> - Each iOS test MUST pass before commit. Mac UI changes verified via `xcodebuild ... | tail -3` showing `BUILD SUCCEEDED`.
> - PKG build is the final verification: `NOTARIZE=0 ./scripts/build-pkg.sh`. Do not `sudo installer`. Tell the user the PKG path.
>
> Final report: commit SHAs, what's deployed/built, manual steps remaining (FamilyControls auth prompt, allowlist setup), genuine open questions (especially: did the API spike succeed, and what shield properties work on Mac vs iOS).

---

## §11. Self-review

Spec coverage:
- Mid-day forced-sleep elimination → Phase 5 (drop pmset). ✓
- `pmset sleepnow` deletion → Phase 5. ✓
- Snooze countdown removal → Phase 3.1 (state machine refactor). ✓
- ManagedSettings shielding → Phases 2 + 3. ✓
- Allowlist UX on Mac → Phase 2.4. ✓
- Backend config sync preserved → §2 + §4 (out-of-scope: do not remove). ✓
- TrustedClock preserved → §4. ✓
- Partner-code unlock preserved → Phase 3.3. ✓
- macOS deployment-target validation → R8 mitigation in Phase 1. ✓

Placeholder scan:
- No "TBD" / "implement later" / "similar to". ✓
- All test code provided verbatim. ✓
- One area underspecified: `AppLogger.bedtimeInfo?(...)` — Phase 2.3 implementation note flags that the symbol may not exist on Mac and to verify against the codebase. ✓

Type/method consistency:
- `BedtimeShieldStore.shared.activate(allowlist:)` ↔ `BedtimeShieldStore.shared.deactivate()` — both used in Phase 3.1's transition function. Same names. ✓
- `BedtimeAllowlistStorage().load()` returns `Set<ApplicationToken>` ↔ `activate(allowlist: Set<ApplicationToken>)`. ✓
- `BedtimeFamilyControlsAuth.shared.requestAuthorization()` ↔ called from initial setup. Singular name, used consistently. ✓
- `BedtimeState` cases `.inactive / .locked / .released` ↔ used in Phase 3.1, 3.2, 3.3 transitions. Names match throughout. ✓
- `markReleased(until:)` (Phase 3.3) — must match the existing iPhone API of the same name. iPhone uses `setReleasedUntil(_:)`. PICK ONE. → Use `markReleased(until:)` on Mac for consistency with the existing Mac code (`BedtimeEnforcer` already exposed `markReleased(until:)` per the bedtime-lockdown work).

Risk → mitigation cross-check:
- Every risk in §5 has a Phase or out-of-scope reference. ✓
- R1, R2 — addressed in Phase 1 spike (gating).
- R8 — addressed in Phase 1 entitlement task.
- R12 — addressed implicitly: default allowlist is empty (block-everything), user can configure later.

No remaining gaps. Plan is ready for hand-off.
