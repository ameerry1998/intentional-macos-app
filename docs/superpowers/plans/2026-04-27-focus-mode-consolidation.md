# Focus Mode Consolidation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tangled set of nine focus-related concepts (Focus Gate, Intentional Mode, Focus Session, Always-Active Blocking, TimeState, etc.) with **one** controller and **three** states (OFF / FOCUS / BEDTIME). Tap puck = Focus Mode ON = the full intervention bundle fires.

**Architecture:** Introduce a new `FocusModeController` as the single source of truth for "is the app enforcing right now." All enforcement components (`FocusMonitor`, `SwitchInterventionCoordinator`, `BlockingProfileManager`) consult `focusModeController.isOn` instead of inferring state from `ScheduleManager.TimeState` or `FocusSessionManager.isActive`. The schedule becomes a *trigger source* that auto-flips Focus Mode at scheduled block boundaries; cross-device WebSocket signals also call into the same controller. `IntentionalModeController` and `FocusSessionManager` are deleted after their callers migrate.

**Tech Stack:** Swift 5.9 / SwiftUI / WKWebView (dashboard) / Foundation. macOS 14+. No new dependencies.

**Scope:** Mac-only. iPhone and backend changes are deferred (per Q5 — Mac stable first, iPhone+backend follow-up). The plan-your-day lock-screen overlay is dropped entirely in v1.

**TDD note:** This codebase has no Swift unit-test target. Adding one is out of scope for this consolidation. Verification per task = `xcodebuild ... build` succeeds + structural grep checks. End-to-end verification = manual smoke test at Task 11. This is the honest state of the project and matches the integration-shaped nature of the refactor.

---

## Build verification command (used in every task)

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

**Expected last line:** `** BUILD SUCCEEDED **`. If you see errors, fix them before committing.

---

## File map

### New files
| Path | Responsibility |
|---|---|
| `Intentional/FocusModeController.swift` | Single source of truth: state (OFF/FOCUS/BEDTIME), intention metadata, activate/deactivate API, change broadcast (NotificationCenter + closure callback). Absorbs everything that `IntentionalModeController` and `FocusSessionManager` did. |

### Modified files
| Path | What changes |
|---|---|
| `Intentional/AppDelegate.swift` | Init `FocusModeController` after `FocusMonitor`. Wire `ScheduleManager.onBlockChanged` → `FocusModeController`. Replace `onFocusSignal` body to call `FocusModeController` directly. Remove `intentionalModeController` and `focusSessionManager` references. |
| `Intentional/FocusMonitor.swift` | Replace TimeState-based enforcement allowlist with `focusModeController.isOn` check. |
| `Intentional/SwitchInterventionCoordinator.swift` | Replace internal `inWorkSession` flag with `focusModeController.isOn`. |
| `Intentional/ScheduleManager.swift` | Collapse `TimeState` enum to 3 cases (`.off`, `.focus`, `.bedtime`); update all 29 references. |
| `Intentional/EarnedBrowseManager.swift` | Add `static let featureEnabled: Bool = false` flag at top; gate all public methods so they early-return / return defaults when disabled. |
| `Intentional/dashboard.html` | Replace `focus-gate-today-toggle` and intentional-mode settings UI with a single Focus Mode toggle + intervention toggles list. Hide earned-browse UI behind same disable. |
| `Intentional/MainWindow.swift` | Add bridge messages: `FOCUS_MODE_TOGGLE`, `INTERVENTION_TOGGLE_SET`. Replace `SAVE_INTENTIONAL_MODE` handler. |
| `Intentional/FocusWebSocketClient.swift` | (No code change — handler is in AppDelegate. File listed for completeness.) |
| `Intentional/SocketRelayServer.swift` | Replace any `focusSessionManager` references with `focusModeController`. |
| `CLAUDE.md` | Update init order section, callback wiring section, and Known Bug Fixes. |
| `docs/ARCHITECTURE.md` | Replace TimeState description; add FocusModeController section. |
| `docs/FOCUS_ENFORCEMENT.md` | Rewrite "when does enforcement run" section to point at FocusModeController.isOn. |

### Deleted files (Task 9)
| Path | Why |
|---|---|
| `Intentional/IntentionalModeController.swift` | Functionality moved into FocusModeController; no callers remain. |
| `Intentional/FocusSessionManager.swift` | Same — merged into FocusModeController. |

---

## Task 1: Branch + FocusModeController scaffold

Create a feature branch and lay down the new controller as a no-op shell that compiles. No callers wired yet — we're just establishing the new type.

**Files:**
- Create: `Intentional/FocusModeController.swift`

- [ ] **Step 1: Create the branch**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git checkout puck
git pull --ff-only
git checkout -b feat/focus-mode-consolidation
```

- [ ] **Step 2: Write `FocusModeController.swift`**

Create `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/FocusModeController.swift` with the following content:

```swift
import Foundation
import AppKit

/// Single source of truth for "is the app enforcing right now."
///
/// Replaces IntentionalModeController + FocusSessionManager. All enforcement
/// components (FocusMonitor, SwitchInterventionCoordinator, blocking) consult
/// `isOn` instead of inferring state from TimeState / session presence.
///
/// Three states:
///   - .off      — free time. Enforcement dormant.
///   - .focus    — full intervention bundle active. Optional intention metadata.
///   - .bedtime  — wind-down enforcement. Different blocklist, no AI scoring.
final class FocusModeController {

    enum State: String {
        case off
        case focus
        case bedtime
    }

    enum ActivationSource: String {
        case manual          // dashboard toggle, Cmd+Shift+P
        case schedule        // ScheduleManager.onBlockChanged
        case puck            // iPhone / Puck physical
        case crossDevice     // any other client via WS
        case bedtimeSchedule
    }

    /// Lightweight metadata describing the current FOCUS / BEDTIME period.
    struct Period {
        let id: UUID
        let startedAt: Date
        let intention: String?
        let source: ActivationSource
    }

    // MARK: State

    private(set) var state: State = .off
    private(set) var currentPeriod: Period?

    var isOn: Bool { state == .focus }
    var isBedtime: Bool { state == .bedtime }

    // MARK: Callbacks

    /// Fired whenever state transitions. Always called on the main queue.
    /// Subscribers: FocusMonitor (clear cache, re-evaluate), BlockingProfileManager
    /// (recompute merged blocklist), SwitchInterventionCoordinator (update gate),
    /// dashboard push, menu bar pill.
    var onStateChanged: ((_ old: State, _ new: State, _ period: Period?) -> Void)?

    // MARK: Lifecycle

    init() {}

    // MARK: API

    /// Transition to .focus. Idempotent — calling while already in .focus updates
    /// the intention/source on the current period without re-firing onStateChanged.
    func activate(intention: String?, source: ActivationSource) {
        let old = state
        if state == .focus {
            // Already on; refresh metadata only.
            if let existing = currentPeriod {
                currentPeriod = Period(
                    id: existing.id,
                    startedAt: existing.startedAt,
                    intention: intention ?? existing.intention,
                    source: source
                )
            }
            return
        }
        let period = Period(
            id: UUID(),
            startedAt: Date(),
            intention: intention,
            source: source
        )
        state = .focus
        currentPeriod = period
        notify(old: old, new: state, period: period)
    }

    /// Transition to .bedtime. Same idempotency as activate().
    func activateBedtime(source: ActivationSource = .bedtimeSchedule) {
        let old = state
        if state == .bedtime { return }
        let period = Period(
            id: UUID(),
            startedAt: Date(),
            intention: nil,
            source: source
        )
        state = .bedtime
        currentPeriod = period
        notify(old: old, new: state, period: period)
    }

    /// Transition to .off. Idempotent.
    func deactivate(source: ActivationSource) {
        let old = state
        if state == .off { return }
        state = .off
        currentPeriod = nil
        notify(old: old, new: state, period: nil)
    }

    // MARK: Internal

    private func notify(old: State, new: State, period: Period?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onStateChanged?(old, new, period)
            NotificationCenter.default.post(
                name: .focusModeChanged,
                object: self,
                userInfo: ["old": old.rawValue, "new": new.rawValue]
            )
        }
    }
}

extension Notification.Name {
    static let focusModeChanged = Notification.Name("focusModeChanged")
}
```

- [ ] **Step 3: Add the file to the Xcode project**

The file must be registered in `Intentional.xcodeproj/project.pbxproj` so the build picks it up. Use `xcodeproj` ruby gem if available, or do it manually:

```bash
# Verify the file is included in the build
cd /Users/arayan/Documents/GitHub/intentional-macos-app
ls -la Intentional/FocusModeController.swift
# If using xcodeproj gem:
ruby -rxcodeproj -e "
  p = Xcodeproj::Project.open('Intentional.xcodeproj')
  g = p.main_group['Intentional']
  ref = g.new_reference('FocusModeController.swift')
  t = p.targets.find { |t| t.name == 'Intentional' }
  t.source_build_phase.add_file_reference(ref)
  p.save
"
```

If the ruby gem isn't installed, edit `project.pbxproj` manually: add a `PBXFileReference` and a `PBXBuildFile` entry mirroring an existing peer Swift file (e.g., `IntentionalModeController.swift`), and add the new build file to the `PBXSourcesBuildPhase` for the `Intentional` target. Diff a single peer file's pattern to find what to copy.

- [ ] **Step 4: Build**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

Expected last line: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Intentional/FocusModeController.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(focus): scaffold FocusModeController with 3-state model

OFF/FOCUS/BEDTIME, idempotent activate/deactivate, change broadcast via
closure + NotificationCenter. Not wired in yet — Task 1 of the focus-mode
consolidation plan."
```

---

## Task 2: Wire FocusModeController into AppDelegate

Instantiate `FocusModeController` and add it to the init sequence. Don't yet replace any callers — both the old controllers (`IntentionalModeController`, `FocusSessionManager`) and the new one coexist for one task's worth of build. This keeps the diff small and reversible.

**Files:**
- Modify: `Intentional/AppDelegate.swift`

- [ ] **Step 1: Read the current AppDelegate init region**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/AppDelegate.swift` and find:
1. The property declarations near the top (around line 30-50) where managers like `intentionalModeController`, `focusMonitor`, `earnedBrowseManager`, `scheduleManager` are declared.
2. The `applicationDidFinishLaunching` body where these are instantiated (around line 200-700).

You're looking specifically for where `focusMonitor` is instantiated (init step 15 per CLAUDE.md). FocusModeController gets initialized **immediately after** `focusMonitor` so all subsequent wiring can reference it.

- [ ] **Step 2: Add the property**

In the property declarations section of `AppDelegate.swift`, add (next to `var focusMonitor: FocusMonitor?`):

```swift
var focusModeController: FocusModeController?
```

- [ ] **Step 3: Instantiate after FocusMonitor init**

In `applicationDidFinishLaunching`, find the line that creates `FocusMonitor` (something like `focusMonitor = FocusMonitor(...)`). Immediately after that block's closing brace, add:

```swift
        // Step 15.5: FocusModeController — single source of truth for "is the app enforcing"
        // (replaces IntentionalModeController + FocusSessionManager — see plan
        // docs/superpowers/plans/2026-04-27-focus-mode-consolidation.md)
        focusModeController = FocusModeController()
        postLog("✅ FocusModeController initialized (state=off)")
```

- [ ] **Step 4: Build**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Intentional/AppDelegate.swift
git commit -m "feat(focus): instantiate FocusModeController in AppDelegate

Wired after FocusMonitor init. No callers yet — coexists with
IntentionalModeController + FocusSessionManager during the migration."
```

---

## Task 3: EarnedBrowseManager feature flag

Per the user's call: keep the code, defer the feature, single flag at the top of the manager. All public methods early-return / return inert defaults when the flag is off. No call-site churn (50+ sites).

**Files:**
- Modify: `Intentional/EarnedBrowseManager.swift`
- Modify: `Intentional/dashboard.html` (hide earned UI)

- [ ] **Step 1: Read the current EarnedBrowseManager**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/EarnedBrowseManager.swift` and identify the public method surface. Typical methods (verify by reading): `recordWorkTick()`, `recordSocialMediaTime(...)`, `recordAssessment(...)`, `onBlockChanged(...)`, properties `availableMinutes`, `blockFocusStats`, `todaySummary()`.

- [ ] **Step 2: Add the feature flag at the top of the class**

Inside the class declaration, immediately after the opening brace, add:

```swift
    // MARK: - Feature flag (deferred — see docs/FOCUS_CONCEPTS_SIMPLIFICATION.md)
    /// When false, the manager is inert: public methods early-return, properties
    /// return zero/empty defaults. Code is preserved for re-enable later.
    static let featureEnabled: Bool = false
```

- [ ] **Step 3: Gate every public method and computed property**

For every public method body, add an early return as the first executable statement. For methods returning `Void`:

```swift
    func recordWorkTick() {
        guard EarnedBrowseManager.featureEnabled else { return }
        // ... existing body unchanged ...
    }
```

For methods returning a value, return an inert default:

```swift
    func todaySummary() -> (blockCount: Int, focusedMinutes: Int, avgFocusScore: Double) {
        guard EarnedBrowseManager.featureEnabled else { return (0, 0, 0.0) }
        // ... existing body unchanged ...
    }
```

For computed properties:

```swift
    var availableMinutes: Int {
        guard EarnedBrowseManager.featureEnabled else { return 0 }
        // ... existing body unchanged ...
    }
```

Apply this pattern to **every** public method and property. Read the file methodically; don't skip any. There's no call-site change required — the inert defaults make all callers work as if the pool is permanently empty.

- [ ] **Step 4: Hide the earned-browse UI in dashboard.html**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/dashboard.html` and search for `earned`, `earnedMinutes`, `earned-browse`, `earned-status`. For each visible UI element (cards, buttons, settings rows) that surfaces earned-browse status, add `style="display: none;"` inline OR wrap in a hidden container. Do NOT delete the markup — keep it for easy re-enable.

Concretely: any element with id matching `*earned*` or class matching `*earned*` gets `style="display: none;"`. If there's a JavaScript renderer like `renderEarnedStatus()`, leave it intact — it'll just operate on hidden DOM.

- [ ] **Step 5: Build + commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

```bash
git add Intentional/EarnedBrowseManager.swift Intentional/dashboard.html
git commit -m "feat(earned): gate behind featureEnabled flag (default off)

Earned browse mode is deferred per the focus-mode consolidation. All
public methods early-return; UI elements hidden. Code is preserved for
later re-enable."
```

---

## Task 4: Collapse TimeState enum to 3 cases

`ScheduleManager.TimeState` currently has 7 cases (`deepWork`, `focusHours`, `freeTime`, `unplanned`, `snoozed`, `noPlan`, `disabled`) and 29 call sites. Collapse to 3 (`off`, `focus`, `bedtime`) and migrate all references. The schedule view code that needs to render different *block types* still has block types — it reads from `FocusBlock.type`, not `TimeState`. TimeState's only role going forward is "what mode should Focus Mode be in right now."

**Files:**
- Modify: `Intentional/ScheduleManager.swift`
- Modify: many other Swift files that reference `TimeState.*` (~29 sites)

- [ ] **Step 1: Read the current TimeState definition**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/ScheduleManager.swift` around line 196 and confirm:

```swift
enum TimeState: String {
    case deepWork = "deep_work"
    case focusHours = "focus_hours"
    case freeTime = "free"
    case unplanned = "unplanned"
    case snoozed = "snoozed"
    case noPlan = "no_plan"
    case disabled = "disabled"

    var isWork: Bool { self == .deepWork || self == .focusHours }
}
```

- [ ] **Step 2: Replace the enum**

Replace the enum block with:

```swift
enum TimeState: String {
    case off
    case focus
    case bedtime

    /// Compatibility shim: same semantics as before — true when the schedule
    /// expects work to happen.
    var isWork: Bool { self == .focus }
}
```

- [ ] **Step 3: List every call site**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
grep -rn "TimeState\." Intentional --include="*.swift" > /tmp/timestate_sites.txt
wc -l /tmp/timestate_sites.txt   # should be ~29
cat /tmp/timestate_sites.txt
```

- [ ] **Step 4: Migrate each call site**

For each site, apply the mapping:

| Old | New |
|---|---|
| `.deepWork`, `.focusHours` | `.focus` |
| `.freeTime`, `.unplanned`, `.snoozed`, `.noPlan`, `.disabled` | `.off` |
| (any new case with bedtime semantics) | `.bedtime` |

For switch statements that exhaustively matched all 7 cases, collapse to 3:

```swift
// Before:
switch state {
case .deepWork, .focusHours:  // do work things
case .freeTime, .unplanned, .snoozed, .noPlan, .disabled: // do free things
}

// After:
switch state {
case .focus:    // do work things
case .off:      // do free things
case .bedtime:  // do bedtime things (new — likely a no-op in many places)
}
```

For raw-string conversions that used the old `rawValue` (e.g., logging `state.rawValue == "deep_work"`), update to the new raw values (`"off"`, `"focus"`, `"bedtime"`).

In `ScheduleManager`'s own `recalculateState()` (find via grep: `grep -n "recalculateState\|currentTimeState" Intentional/ScheduleManager.swift`): the function decides what the current state should be based on the active block. New mapping:

```swift
// In recalculateState() / wherever state is computed:
if let block = currentBlock {
    switch block.type {
    case .deepWork, .focusHours:
        currentTimeState = .focus
    case .freeTime:
        currentTimeState = .off
    case .bedtime:
        currentTimeState = .bedtime
    }
} else {
    currentTimeState = .off  // unplanned + no block + disabled all collapse here
}
```

- [ ] **Step 5: Build (expect failures, fix them)**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -50
```

Compiler will flag every reference to a removed case. Walk the errors top-down, applying the mapping. Re-run until clean.

- [ ] **Step 6: Commit**

```bash
git add -u Intentional/
git commit -m "refactor(schedule): collapse TimeState to {off, focus, bedtime}

Old 7 cases (deepWork/focusHours/freeTime/unplanned/snoozed/noPlan/disabled)
mapped down to 3. unplanned, freeTime, snoozed, disabled, noPlan → .off
deepWork, focusHours → .focus. New .bedtime case for sleep windows.

Block type still drives schedule rendering — TimeState now only describes
what mode Focus Mode should be in."
```

---

## Task 5: FocusMonitor uses FocusModeController.isOn

Replace the TimeState-driven enforcement allowlist in `FocusMonitor.evaluateApp` with a single check against `focusModeController.isOn`. This is the bug fix the user's been chasing — with this change, enforcement only runs when Focus Mode is on, full stop.

**Files:**
- Modify: `Intentional/FocusMonitor.swift`

- [ ] **Step 1: Add the controller reference**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/FocusMonitor.swift`. Find the property declarations near the top of the class. Add:

```swift
    /// Source of truth for "should we be enforcing right now."
    /// Replaces the old TimeState-based allowlist.
    weak var focusModeController: FocusModeController?
```

(Use `weak` to avoid retain cycles if AppDelegate holds the strong reference.)

- [ ] **Step 2: Update the enforcement gate**

Find line 1629 (or wherever the current allowlist lives — look for `state == .disabled || state == .freeTime`):

```swift
// Current code (around line 1617-1634):
if state == .disabled || state == .freeTime || state == .snoozed || state == .unplanned {
    debugLog("👁️ EXIT: state=\(state.rawValue) — browsing allowed freely")
    handleRelevantContent()
    stopBrowserPolling()
    return
}
```

Replace with:

```swift
// New: enforcement runs iff Focus Mode is ON. Bedtime and Off both bypass.
guard focusModeController?.isOn == true else {
    debugLog("👁️ EXIT: focus mode not on (state=\(focusModeController?.state.rawValue ?? "nil")) — browsing allowed freely")
    handleRelevantContent()
    stopBrowserPolling()
    return
}
```

This deletes the allowlist branches entirely. All four old "browsing allowed" cases (disabled/freeTime/snoozed/unplanned) collapse into "Focus Mode is OFF."

- [ ] **Step 3: Wire the controller in AppDelegate**

Open `Intentional/AppDelegate.swift`. After the line where `focusModeController` is instantiated (added in Task 2), and after `focusMonitor` is instantiated, add:

```swift
        focusMonitor?.focusModeController = focusModeController
```

Place this immediately after `focusModeController = FocusModeController()` (Task 2 added that line).

- [ ] **Step 4: Subscribe to state changes for cache invalidation**

Where the existing `scheduleManager.onBlockChanged` callback clears the relevance cache, add an equivalent subscription on `focusModeController.onStateChanged` (since the schedule no longer drives enforcement directly). In `AppDelegate.applicationDidFinishLaunching`, after `focusModeController = FocusModeController()`:

```swift
        focusModeController?.onStateChanged = { [weak self] old, new, period in
            guard let self = self else { return }
            self.postLog("🎯 Focus Mode: \(old.rawValue) → \(new.rawValue)" + (period?.intention.map { " (\"\($0)\")" } ?? ""))
            self.relevanceScorer?.clearCache()
            self.focusMonitor?.onBlockChanged()  // re-evaluate immediately
            self.socketRelayServer?.broadcastScheduleSync()
            self.mainWindowController?.pushScheduleUpdate()
        }
```

(The exact callable names must match what's in your codebase — `relevanceScorer`, `focusMonitor`, `socketRelayServer`, `mainWindowController`. Read AppDelegate to confirm.)

- [ ] **Step 5: Build + commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

```bash
git add Intentional/FocusMonitor.swift Intentional/AppDelegate.swift
git commit -m "feat(focus): FocusMonitor enforcement gated on FocusModeController.isOn

Replaces the TimeState allowlist (disabled/freeTime/snoozed/unplanned).
Enforcement now runs IFF Focus Mode is on, full stop. The screen-red-on-
YouTube bug is impossible by construction in this model."
```

---

## Task 6: SwitchInterventionCoordinator uses FocusModeController

The coordinator currently has an internal `inWorkSession: Bool` flag that gets set/unset by an external caller (FocusSessionManager). Replace that flag with a live read from `focusModeController.isOn`.

**Files:**
- Modify: `Intentional/SwitchInterventionCoordinator.swift`

- [ ] **Step 1: Add the controller reference**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/SwitchInterventionCoordinator.swift`. Add a weak property:

```swift
    weak var focusModeController: FocusModeController?
```

- [ ] **Step 2: Replace the inWorkSession check**

Find line 110 (`if !inWorkSession { return .suppress(reason: .notInWorkSession) }`). Replace with:

```swift
        if focusModeController?.isOn != true {
            return .suppress(reason: .notInWorkSession)
        }
```

- [ ] **Step 3: Remove the inWorkSession flag and its setter**

Delete `private var inWorkSession: Bool = false` (line 51). Delete any setter method (often named `setInWorkSession(_:)` or `beginSession()`/`endSession()`). Update callers — there shouldn't be many; they were FocusSessionManager-side. Most likely the coordinator no longer needs to be told *anything* externally about session state; it just reads the live controller.

If the file's `init` takes an `inWorkSession` parameter, remove it. If it has a `currentTarget` reset that fires on session-end, you can either keep it (call from `focusModeController.onStateChanged` in AppDelegate when new is `.off`) or delete it for now and add back if needed.

- [ ] **Step 4: Wire in AppDelegate**

In `AppDelegate.applicationDidFinishLaunching`, after `focusModeController` is instantiated, find where `switchInterventionCoordinator` is created (near init step 15d) and add:

```swift
        switchInterventionCoordinator?.focusModeController = focusModeController
```

- [ ] **Step 5: Update the focus mode change handler to reset overlay state**

In the `focusModeController.onStateChanged` block (added in Task 5), add overlay reset on transition to `.off`:

```swift
            if new == .off {
                self.switchInterventionCoordinator?.reset()  // clear currentTarget, dwellLedger
            }
```

If `reset()` doesn't exist, add it as a public method on the coordinator that clears its internal tracking:

```swift
    /// Clear all per-session tracking (currentTarget, dwellLedger, lastSwitchAt).
    /// Called when Focus Mode transitions to .off.
    func reset() {
        currentTarget = nil
        dwellLedger.removeAll()
        // ... whatever else needs resetting (read the file to enumerate)
    }
```

- [ ] **Step 6: Build + commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

```bash
git add Intentional/SwitchInterventionCoordinator.swift Intentional/AppDelegate.swift
git commit -m "feat(focus): SwitchInterventionCoordinator gated on FocusModeController

Removes the externally-managed inWorkSession flag. Coordinator now reads
the live controller. State resets on Focus Mode → off."
```

---

## Task 7: ScheduleManager → FocusModeController wiring

The schedule becomes a *trigger source*. When a block starts/ends, it calls `focusModeController.activate(...)` / `.deactivate(...)`. The schedule no longer owns enforcement — only the controller does.

**Files:**
- Modify: `Intentional/AppDelegate.swift` (the `onBlockChanged` callback wired around line 655-671)
- Modify: `Intentional/ScheduleManager.swift` (only if `recalculateState` needs to fire activation on app launch)

- [ ] **Step 1: Read the existing onBlockChanged callback**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/AppDelegate.swift` around line 655-671. Confirm it currently looks roughly like:

```swift
scheduleManager?.onBlockChanged = { [weak self] block, state in
    guard let self = self else { return }
    self.postLog("📋 Block changed → \(state.rawValue)" + (block != nil ? " (\(block!.title))" : ""))
    // ...
    self.earnedBrowseManager?.onBlockChanged(blockId: block?.id, blockTitle: block?.title)
    self.focusMonitor?.onBlockChanged()
    self.intentionalModeController?.onBlockChanged(block: block, timeState: state)
    self.socketRelayServer?.broadcastScheduleSync()
    self.mainWindowController?.pushScheduleUpdate()
}
```

- [ ] **Step 2: Replace with FocusModeController calls**

Rewrite the callback body:

```swift
scheduleManager?.onBlockChanged = { [weak self] block, state in
    guard let self = self else { return }
    self.postLog("📋 Block changed → \(state.rawValue)" + (block != nil ? " (\(block!.title))" : ""))

    // Schedule is a trigger source for FocusModeController. The controller
    // fans out enforcement (FocusMonitor, blocking, switch overlay) via its
    // onStateChanged callback wired in applicationDidFinishLaunching.
    switch state {
    case .focus:
        let intention = block?.intention ?? block?.title
        self.focusModeController?.activate(intention: intention, source: .schedule)
    case .bedtime:
        self.focusModeController?.activateBedtime(source: .bedtimeSchedule)
    case .off:
        self.focusModeController?.deactivate(source: .schedule)
    }

    // EarnedBrowseManager is gated by featureEnabled; calling is harmless.
    self.earnedBrowseManager?.onBlockChanged(blockId: block?.id, blockTitle: block?.title)
}
```

Notice `intentionalModeController?.onBlockChanged(...)` is removed entirely. `focusMonitor?.onBlockChanged()`, `socketRelayServer?.broadcastScheduleSync()`, and `mainWindowController?.pushScheduleUpdate()` are all called from `focusModeController.onStateChanged` instead (Task 5, Step 4) — don't double-call them here.

(The `block?.intention` field may not exist — `FocusBlock` may only have `title` and `description`. If `intention` doesn't compile, fall back to `block?.title`.)

- [ ] **Step 3: Initial sync — fire activate on app launch if there's a current block**

In `applicationDidFinishLaunching`, after the manual `activeBlockId` sync (init step 17 per CLAUDE.md), add:

```swift
        // Initial sync: if a block is already active when the app starts, activate
        // Focus Mode immediately. (Catches app-started-during-block.)
        if let currentBlock = scheduleManager?.currentBlock {
            let state = scheduleManager?.currentTimeState ?? .off
            switch state {
            case .focus:
                focusModeController?.activate(intention: currentBlock.title, source: .schedule)
            case .bedtime:
                focusModeController?.activateBedtime(source: .bedtimeSchedule)
            case .off:
                break  // already off
            }
        }
```

- [ ] **Step 4: Build + smoke-check the schedule path**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

Manual smoke-check (~2 min): launch the app, schedule a 1-minute Deep Work block to start in 30 seconds, watch Console.app for `🎯 Focus Mode: off → focus`. When the block ends, expect `🎯 Focus Mode: focus → off`.

- [ ] **Step 5: Commit**

```bash
git add Intentional/AppDelegate.swift Intentional/ScheduleManager.swift
git commit -m "feat(focus): ScheduleManager triggers FocusModeController transitions

onBlockChanged now activates/deactivates Focus Mode based on block type.
Schedule no longer drives enforcement directly — the controller fans out
via its onStateChanged callback. Initial-block sync on app launch."
```

---

## Task 8: Cross-device WebSocket → FocusModeController

The iPhone tap-puck signal arrives via `FocusWebSocketClient.onFocusSignal`. Currently routes to `startFocusSession` / `endFocusSession` (FocusSessionManager). Reroute to FocusModeController. After this task, FocusSessionManager has zero callers and can be deleted in Task 9.

**Files:**
- Modify: `Intentional/AppDelegate.swift` (the `onFocusSignal` block around line 573-612)

- [ ] **Step 1: Read the current onFocusSignal handler**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/AppDelegate.swift` around line 573. Confirm it's roughly:

```swift
focusWebSocketClient?.onFocusSignal = { [weak self] action, sessionId, triggeredBy in
    DispatchQueue.main.async {
        guard let self = self else { return }
        if action == "start" {
            // ... startHeartbeat ... dismissFocusStartOverlay ... 
            // ... self.startFocusSession(profileIds:..., intention:..., aiEnabled: false, triggeredByPuck: ...)
        } else if action == "stop" {
            self.focusWebSocketClient?.stopHeartbeat()
            self.endFocusSession()
        }
    }
}
```

- [ ] **Step 2: Replace with FocusModeController calls**

Rewrite the body:

```swift
focusWebSocketClient?.onFocusSignal = { [weak self] action, sessionId, triggeredBy in
    DispatchQueue.main.async {
        guard let self = self else { return }
        if action == "start" {
            self.postLog("🔌 Focus signal: START (session: \(sessionId), triggeredBy: \(triggeredBy))")
            self.focusWebSocketClient?.startHeartbeat(sessionId: sessionId)
            self.dismissFocusStartOverlay()  // close any picker if open

            let intention = triggeredBy == "puck"
                ? "Focus session (started on phone)"
                : "Focus session"
            let source: FocusModeController.ActivationSource = triggeredBy == "puck" ? .puck : .crossDevice
            self.focusModeController?.activate(intention: intention, source: source)
        } else if action == "stop" {
            self.postLog("🔌 Focus signal: STOP (session: \(sessionId))")
            self.focusWebSocketClient?.stopHeartbeat()
            self.focusModeController?.deactivate(source: .crossDevice)
        }
    }
}
```

Note: `startFocusSession` and `endFocusSession` are no longer called. Those methods live elsewhere in AppDelegate and are part of the FocusSessionManager pathway; they'll be deleted in Task 9.

- [ ] **Step 3: Find and remove other startFocusSession/endFocusSession call sites**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
grep -rn "startFocusSession\|endFocusSession\|focusSessionManager" Intentional --include="*.swift"
```

For each remaining call site (excluding the FocusSessionManager.swift definitions themselves — those go in Task 9):
- If it's an "intent to start a session" caller: replace with `focusModeController?.activate(...)`.
- If it's an "intent to end a session" caller: replace with `focusModeController?.deactivate(...)`.
- If it's reading `focusSessionManager?.isActive`: replace with `focusModeController?.isOn`.
- If it's reading `focusSessionManager?.activeSession`: replace with `focusModeController?.currentPeriod` (note: shape differs — `Period` has `id`, `startedAt`, `intention`, `source`; `FocusSession` may have more fields. Where extra fields are needed, add them to `Period`. If only id/start/intention are needed, the current shape is fine).

In `Intentional/SocketRelayServer.swift` (per the explore report, line 250 references `earnedBrowseManager`; check for `focusSessionManager` references too):

```bash
grep -n "focusSessionManager\|FocusSessionManager" Intentional/SocketRelayServer.swift
```

Migrate each match.

- [ ] **Step 4: Build + commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

```bash
git add -u Intentional/
git commit -m "feat(focus): cross-device WS signal routes through FocusModeController

iPhone tap-puck → AppDelegate.onFocusSignal → FocusModeController.activate.
Same path for any cross-device start/stop. FocusSessionManager has no
callers after this — deletion in next task."
```

---

## Task 9: Delete IntentionalModeController + FocusSessionManager

After Tasks 5-8, both legacy controllers should have zero callers. Verify with grep, delete the files, remove project references, build clean.

**Files:**
- Delete: `Intentional/IntentionalModeController.swift`
- Delete: `Intentional/FocusSessionManager.swift`
- Modify: `Intentional/AppDelegate.swift` (remove property declarations, init code)
- Modify: `Intentional.xcodeproj/project.pbxproj` (remove references)

- [ ] **Step 1: Verify no callers remain**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
grep -rn "IntentionalModeController\|intentionalModeController" Intentional --include="*.swift" | grep -v "IntentionalModeController.swift"
grep -rn "FocusSessionManager\|focusSessionManager" Intentional --include="*.swift" | grep -v "FocusSessionManager.swift"
```

If either grep returns matches, those are stragglers — migrate them following Task 8's pattern, then re-run the greps until clean.

The only remaining mention of `IntentionalModeController` should be its property declaration and init in `AppDelegate.swift` (which we'll remove in this task) plus the file itself.

- [ ] **Step 2: Remove from AppDelegate**

Open `Intentional/AppDelegate.swift`. Remove:
- `var intentionalModeController: IntentionalModeController?` (property declaration)
- `intentionalModeController = IntentionalModeController(appDelegate: self)` (instantiation)
- `intentionalModeController?.start()` (if called)
- Any other reference

Same for `FocusSessionManager` if a property/init exists.

- [ ] **Step 3: Delete the files**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
rm Intentional/IntentionalModeController.swift
rm Intentional/FocusSessionManager.swift
```

- [ ] **Step 4: Remove project.pbxproj references**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
ruby -rxcodeproj -e "
  p = Xcodeproj::Project.open('Intentional.xcodeproj')
  ['IntentionalModeController.swift', 'FocusSessionManager.swift'].each do |name|
    p.files.select { |f| f.path == name }.each(&:remove_from_project)
  end
  p.save
"
```

If the gem isn't installed, manually edit `Intentional.xcodeproj/project.pbxproj` and remove all entries (PBXFileReference, PBXBuildFile, file in PBXSourcesBuildPhase) referencing those two filenames.

- [ ] **Step 5: Build clean**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug clean build 2>&1 | tail -30
```

Note `clean` before `build` to flush any cached references. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -A Intentional/ Intentional.xcodeproj/
git commit -m "refactor(focus): delete IntentionalModeController + FocusSessionManager

Both have zero callers after Tasks 5-8. FocusModeController is the only
remaining state holder for is-the-app-enforcing. Net delete: ~700 lines."
```

---

## Task 10: Dashboard UI — Focus Mode toggle + intervention toggles

Replace the existing `focus-gate-today-toggle` and any `SAVE_INTENTIONAL_MODE`-bound UI with: (a) one Focus Mode toggle that flips state instantly, and (b) a new Settings → Interventions list with one toggle per intervention. UI matches `docs/focus-states-ui-gallery.html`.

**Files:**
- Modify: `Intentional/dashboard.html`
- Modify: `Intentional/MainWindow.swift` (add bridge messages)
- Modify: `Intentional/AppDelegate.swift` (handler glue)

- [ ] **Step 1: Add bridge message handlers in MainWindow.swift**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/MainWindow.swift` and find the `userContentController(_:didReceive:)` switch statement (around line 277-522). Add two new cases (and remove `case "SAVE_INTENTIONAL_MODE"` if present):

```swift
            case "FOCUS_MODE_TOGGLE":
                handleFocusModeToggle(body: body)
            case "INTERVENTION_TOGGLE_SET":
                handleInterventionToggleSet(body: body)
```

Add the corresponding methods at the bottom of the class:

```swift
    /// Body: { "on": Bool }
    private func handleFocusModeToggle(body: [String: Any]) {
        guard let on = body["on"] as? Bool else { return }
        let app = NSApp.delegate as? AppDelegate
        if on {
            app?.focusModeController?.activate(intention: nil, source: .manual)
        } else {
            app?.focusModeController?.deactivate(source: .manual)
        }
    }

    /// Body: { "key": String, "enabled": Bool }
    /// key ∈ { "distractions_blocking", "switch_overlay", "ai_relevance",
    ///         "screen_red_shift", "off_task_nudge", "block_start_ritual",
    ///         "block_end_ritual", "pill_widget", "force_quit_apps",
    ///         "earned_browse_mode" }
    private func handleInterventionToggleSet(body: [String: Any]) {
        guard let key = body["key"] as? String,
              let enabled = body["enabled"] as? Bool else { return }
        // Persist to UserDefaults under "intervention.<key>"
        let defaultsKey = "intervention.\(key)"
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        NotificationCenter.default.post(
            name: .interventionToggleChanged,
            object: nil,
            userInfo: ["key": key, "enabled": enabled]
        )
    }
```

Add the notification name to a sensible shared file (e.g., end of `FocusModeController.swift`):

```swift
extension Notification.Name {
    static let interventionToggleChanged = Notification.Name("interventionToggleChanged")
}
```

- [ ] **Step 2: Remove the old SAVE_INTENTIONAL_MODE handler**

In `MainWindow.swift`, find `handleSaveIntentionalMode(...)` and `case "SAVE_INTENTIONAL_MODE":`. Delete both. The intentional-mode settings storage is gone.

- [ ] **Step 3: Update dashboard.html — Focus Mode toggle**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/dashboard.html`. Find line ~4410:

```html
<div style="flex:1;font-size:13px;font-weight:500;">Focus Gate</div>
<label class="toggle"><input type="checkbox" id="focus-gate-today-toggle" onchange="onFocusGateTodayToggle(this.checked)"><span class="toggle-track"></span></label>
```

Replace with:

```html
<div style="flex:1;font-size:13px;font-weight:500;">Focus Mode</div>
<label class="toggle"><input type="checkbox" id="focus-mode-toggle" onchange="onFocusModeToggle(this.checked)"><span class="toggle-track"></span></label>
```

In the `<script>` section, replace the old `onFocusGateTodayToggle` function with:

```javascript
function onFocusModeToggle(on) {
    window.webkit.messageHandlers.intentional.postMessage({
        type: "FOCUS_MODE_TOGGLE",
        on: on
    });
}
```

Also delete any function named `onFocusGateTodayToggle` (or leave a 1-line stub that calls `onFocusModeToggle` for migration).

- [ ] **Step 4: Add Settings → Interventions section**

Find the Settings section in dashboard.html (search for "settings-menu" or "Settings"). Add a new "Interventions" panel that lists 10 toggles. Use the same toggle component pattern that already exists in the file. Template (adapt class names to match the file's existing patterns):

```html
<div class="settings-section" id="interventions-settings">
    <h3>Interventions</h3>
    <p class="muted">When Focus Mode is on, these enforce automatically. Toggle off any to soften the bundle.</p>
    <div id="intervention-toggles">
        <!-- Populated by JS — see renderInterventionToggles() -->
    </div>
</div>
```

JS to render and persist:

```javascript
const INTERVENTIONS = [
    { key: "distractions_blocking", label: "Distractions blocking",     desc: "Hard block apps + sites in your distractions list.", defaultOn: true },
    { key: "switch_overlay",         label: "Context-switch overlay",    desc: "10s countdown when switching to a non-relevant app.", defaultOn: true },
    { key: "ai_relevance",           label: "AI relevance scoring",      desc: "Browser tabs scored against your intention.",         defaultOn: true },
    { key: "screen_red_shift",       label: "Screen red shift",          desc: "Gradual screen tint when off-task.",                  defaultOn: true },
    { key: "off_task_nudge",         label: "Off-task nudge toast",      desc: "Small reminder before harder interventions.",         defaultOn: true },
    { key: "block_start_ritual",     label: "Block start ritual",        desc: "Forces you to type intention before a scheduled block.", defaultOn: true },
    { key: "block_end_ritual",       label: "Block end ritual",          desc: "3-sec stats card at end of block.",                   defaultOn: true },
    { key: "pill_widget",            label: "Always-on pill widget",     desc: "Menu bar pill with state, intention, timer.",         defaultOn: true },
    { key: "force_quit_apps",        label: "Distracting app force-quit", desc: "HARD MODE: distracting apps minimized/quit on activation.", defaultOn: false },
    { key: "earned_browse_mode",     label: "Earned browse mode",        desc: "Earn distraction-time credits during focus. (Currently disabled.)", defaultOn: false },
];

function renderInterventionToggles() {
    const container = document.getElementById("intervention-toggles");
    if (!container) return;
    container.innerHTML = INTERVENTIONS.map(it => {
        const stored = localStorage.getItem("intervention." + it.key);
        const isOn = stored === null ? it.defaultOn : (stored === "true");
        return `
            <div class="settings-row">
                <div style="flex:1;">
                    <div style="font-weight:600;">${it.label}</div>
                    <div class="muted" style="font-size:11px;">${it.desc}</div>
                </div>
                <label class="toggle">
                    <input type="checkbox" ${isOn ? "checked" : ""}
                           onchange="onInterventionToggle('${it.key}', this.checked)">
                    <span class="toggle-track"></span>
                </label>
            </div>
        `;
    }).join("");
}

function onInterventionToggle(key, enabled) {
    localStorage.setItem("intervention." + key, enabled ? "true" : "false");
    window.webkit.messageHandlers.intentional.postMessage({
        type: "INTERVENTION_TOGGLE_SET",
        key: key,
        enabled: enabled
    });
}

// Call renderInterventionToggles() once on dashboard load.
```

Hook `renderInterventionToggles()` into the existing dashboard init (find where other render-on-load functions are called).

- [ ] **Step 5: Update the Focus Mode toggle to reflect live state**

The toggle should reflect the current `FocusModeController.state`. Add a push handler from Swift to JS that updates the toggle when state changes externally (puck tap, schedule, etc.).

In `MainWindow.swift`, add (or extend if it exists):

```swift
    func pushFocusModeUpdate(state: FocusModeController.State) {
        let js = """
            if (typeof onFocusModeStateUpdate === 'function') {
                onFocusModeStateUpdate('\(state.rawValue)');
            }
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
```

In `AppDelegate.applicationDidFinishLaunching`, extend the `focusModeController.onStateChanged` handler (Task 5, Step 4) to push to dashboard:

```swift
            self.mainWindowController?.pushFocusModeUpdate(state: new)
```

Add JS handler in dashboard.html:

```javascript
function onFocusModeStateUpdate(stateRaw) {
    const toggle = document.getElementById("focus-mode-toggle");
    if (!toggle) return;
    toggle.checked = (stateRaw === "focus");
    // (Optionally: render a "BEDTIME" badge somewhere when stateRaw === 'bedtime'.)
}
```

- [ ] **Step 6: Build + commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

```bash
git add Intentional/dashboard.html Intentional/MainWindow.swift Intentional/AppDelegate.swift Intentional/FocusModeController.swift
git commit -m "feat(dashboard): Focus Mode toggle + 10 intervention toggles

Replaces focus-gate-today-toggle and SAVE_INTENTIONAL_MODE-bound UI.
Toggle reflects live FocusModeController state; intervention prefs persist
to UserDefaults via INTERVENTION_TOGGLE_SET bridge message."
```

---

## Task 11: First-launch wipe migration + docs update

Per Q4 — wipe device state on first launch of the new build. Then update the canonical docs.

**Files:**
- Modify: `Intentional/AppDelegate.swift`
- Modify: `CLAUDE.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/FOCUS_ENFORCEMENT.md`

- [ ] **Step 1: Add the migration function**

In `Intentional/AppDelegate.swift`, add a new method:

```swift
    /// One-time migration: clear local focus state when this build runs for the first
    /// time. Account auth, schedule, distractions list, partner config are preserved.
    /// Cleared: any focus-session leftovers, intentional-mode state, blocking-profile
    /// "active" selections, intervention preferences (will fall back to defaults).
    private func runFocusModeMigrationIfNeeded() {
        let migrationKey = "focus_mode_v1_migration_complete"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        postLog("🔄 Running Focus Mode v1 migration — wiping local focus state")

        // 1. Clear UserDefaults keys related to old controllers.
        let keysToWipe = [
            "intentionalModeEnabled",
            "intentionalMode.lastShown",
            "intentionalMode.recoveryCount",
            "focusSession.activeId",
            "focusSession.startedAt",
            "focusGate.todayEnabled",
            "blockingProfile.activeIds"
        ]
        for k in keysToWipe { defaults.removeObject(forKey: k) }

        // 2. Clear any on-disk JSON state files that the old controllers wrote.
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let intentionalDir = appSupport.appendingPathComponent("Intentional", isDirectory: true)
            for filename in ["intentional_mode_state.json", "focus_session.json"] {
                let url = intentionalDir.appendingPathComponent(filename)
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
            }
        }

        defaults.set(true, forKey: migrationKey)
        postLog("✅ Focus Mode v1 migration complete")
    }
```

(File names `intentional_mode_state.json` and `focus_session.json` are best-guess — confirm by `find ~/Library/Application\ Support/Intentional -name "*.json"` on a dev machine and update the list.)

- [ ] **Step 2: Call the migration before any controller init**

In `applicationDidFinishLaunching`, add the call **before** any manager is instantiated (i.e., at the very top of the function body, right after any logging setup):

```swift
        runFocusModeMigrationIfNeeded()
```

- [ ] **Step 3: Update CLAUDE.md**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/CLAUDE.md`. Find the **Initialization Order** section (under "## Initialization Order (AppDelegate)"). Replace any line referencing `intentionalModeController` or `focusSessionManager` with a single line for `FocusModeController`. Update the init order:

Replace the existing 21-step list. Find the relevant block (steps 14-17) and update to:

```
14. RelevanceScorer         → AI model initialization
15. FocusMonitor            → Desktop monitoring (refs: ScheduleManager, RelevanceScorer)
15a. FocusModeController    → Single source of truth for is-app-enforcing (replaces IntentionalModeController + FocusSessionManager)
15b. BlockRitualController   → Wired to FocusMonitor.ritualController
15c. BlockEndRitualController → Wired to FocusMonitor.endRitualController
15d. ContentSafetyMonitor     → Load enabled from settings, start if enabled
15e. SwitchInterventionCoordinator + SwitchOverlayController → Wired to FocusMonitor (gate now reads FocusModeController.isOn)
16. Wire ScheduleManager.onBlockChanged → FocusModeController.activate / .deactivate / .activateBedtime
17. Manual activeBlockId sync + initial Focus Mode activation if a block is currently active
```

In the **Critical Callback Wiring** subsection of CLAUDE.md, replace the `scheduleManager.onBlockChanged` block with:

```swift
// ScheduleManager.onBlockChanged → triggers Focus Mode transitions
scheduleManager.onBlockChanged = { block, state in
    switch state {
    case .focus:    focusModeController.activate(intention: block?.title, source: .schedule)
    case .bedtime:  focusModeController.activateBedtime(source: .bedtimeSchedule)
    case .off:      focusModeController.deactivate(source: .schedule)
    }
    earnedBrowseManager.onBlockChanged(blockId:blockTitle:)  // gated by featureEnabled flag
}

// FocusModeController.onStateChanged → fans out enforcement
focusModeController.onStateChanged = { old, new, period in
    relevanceScorer.clearCache()
    focusMonitor.onBlockChanged()
    socketRelayServer.broadcastScheduleSync()
    mainWindow.pushFocusModeUpdate(state: new)
    if new == .off { switchInterventionCoordinator.reset() }
}
```

In the **Known Bug Fixes** subsection, add a new entry at the bottom:

```
11. **Tangled focus state (April 2026 consolidation).** Nine overlapping concepts — Focus Gate, Intentional Mode, Focus Session, Always-Active Blocking, TimeState, etc. — caused recurring desync bugs (screen red on YouTube without a session, focus gate not engaging on cross-device signal, phantom sessions). Consolidated into `FocusModeController` with three states (OFF/FOCUS/BEDTIME). Schedule + cross-device WS + manual toggle + puck all flow through the same controller. Enforcement components read `focusModeController.isOn`. See `docs/FOCUS_CONCEPTS_SIMPLIFICATION.md` and `docs/superpowers/plans/2026-04-27-focus-mode-consolidation.md`.
```

- [ ] **Step 4: Update docs/ARCHITECTURE.md and docs/FOCUS_ENFORCEMENT.md**

Open `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/ARCHITECTURE.md`. Find any mention of TimeState, IntentionalMode, or "focus session" as state-bearing concepts. Replace those passages to describe FocusModeController as the single state holder. Add a short section near the top of the architecture doc:

```markdown
### Focus Mode (the master state)

`FocusModeController` is the single source of truth for whether the app is enforcing. Three states:
- `.off` — free time. No enforcement runs.
- `.focus` — full intervention bundle (blocking, switch overlay, AI scoring, pill, etc.).
- `.bedtime` — wind-down enforcement.

All triggers (schedule transitions, dashboard toggle, Cmd+Shift+P, iPhone tap-puck via WS) call into `FocusModeController.activate()` / `.deactivate()` / `.activateBedtime()`. The controller fans out via its `onStateChanged` closure to: FocusMonitor (cache clear + re-eval), SwitchInterventionCoordinator (gate update), SocketRelayServer (broadcast), MainWindow (dashboard push).

`ScheduleManager.TimeState` collapses to the same three cases — it now describes "what mode should Focus Mode be in for the current block," not "what enforcement should run."
```

In `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/FOCUS_ENFORCEMENT.md`, rewrite any "when does enforcement run" text to point at `focusModeController.isOn`. Delete or strike-through references to `unplanned`, `intentionalModeEnabled`, `focusSession.isActive` as gate predicates.

- [ ] **Step 5: Build + commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -30
```

```bash
git add Intentional/AppDelegate.swift CLAUDE.md docs/ARCHITECTURE.md docs/FOCUS_ENFORCEMENT.md
git commit -m "feat(focus): one-time migration + docs update

Migration wipes local focus state on first launch of the new build
(account auth, schedule, distractions, partner config preserved).
CLAUDE.md / ARCHITECTURE.md / FOCUS_ENFORCEMENT.md updated to describe
the consolidated 3-state FocusModeController model."
```

---

## Task 12: End-to-end smoke test

Manual verification that the consolidated model behaves correctly across the four trigger paths. No code changes — this is a pure verification step.

- [ ] **Step 1: Clean install + first-launch wipe verification**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug clean build 2>&1 | tail -5
# Run the dev build (or install fresh from PKG if testing the production path):
open -a Intentional   # adapt path if needed
```

In Console.app, filter for `Intentional` and confirm a log line `🔄 Running Focus Mode v1 migration — wiping local focus state` appears on first launch, and `✅ Focus Mode v1 migration complete` follows. On a second launch, neither line should appear (idempotent).

- [ ] **Step 2: Smoke path A — manual dashboard toggle**

In the dashboard, flip the Focus Mode toggle ON. Confirm:
- Console log: `🎯 Focus Mode: off → focus`
- Pill widget visible
- Open Twitter in Safari → blocked overlay appears
- Cmd-Tab to a distracting app → 10s countdown overlay appears

Flip toggle OFF. Confirm:
- Console log: `🎯 Focus Mode: focus → off`
- Pill widget hides
- Open Twitter in Safari → no block (free browsing)
- Cmd-Tab to a distracting app → no overlay

- [ ] **Step 3: Smoke path B — schedule trigger**

In the schedule, create a Deep Work block starting in ~30 seconds, lasting 1 minute. Wait for it to start. Confirm:
- Console log: `📋 Block changed → focus (...)` then `🎯 Focus Mode: off → focus (schedule)`
- Pill visible, intention shows the block title
- Block ends → `📋 Block changed → off` then `🎯 Focus Mode: focus → off`

- [ ] **Step 4: Smoke path C — cross-device WebSocket signal**

On the iPhone (puck-ios build), tap the puck to start a focus session. Confirm on Mac:
- Console log: `🔌 Focus signal: START (...)` then `🎯 Focus Mode: off → focus (puck)`
- Full enforcement engages (overlay + blocking + pill)

Tap puck again to end. Confirm Mac:
- Console log: `🔌 Focus signal: STOP (...)` then `🎯 Focus Mode: focus → off (crossDevice)`

This is the original failing path that motivated the consolidation. If it works here, the bug is fixed by construction.

- [ ] **Step 5: Smoke path D — unplanned time = no enforcement**

End all sessions. Schedule no blocks. Open Safari to YouTube. Confirm:
- Screen does NOT shift red
- No grayscale tint
- No nudge toast
- Console log shows `👁️ EXIT: focus mode not on (state=off) — browsing allowed freely`

This is the second bug that motivated the consolidation.

- [ ] **Step 6: Settings → Interventions UI**

In dashboard, navigate to Settings → Interventions. Confirm 10 toggles render. Toggle one off (e.g., "Screen red shift"). Confirm UserDefaults gets `intervention.screen_red_shift = false`. (Actual enforcement of the toggle preference is out of scope for this plan — the toggles persist; honoring them in code is a follow-up.)

- [ ] **Step 7: Final commit + branch push**

If any documentation gaps surfaced during testing, capture them in a follow-up commit. Then:

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git log --oneline puck..HEAD   # review the consolidation commits
git push -u origin feat/focus-mode-consolidation
```

Open a PR titled "feat(focus): consolidate 9 concepts into FocusModeController (3 states)". The PR body should list the 12 task commits and link `docs/FOCUS_CONCEPTS_SIMPLIFICATION.md`.

---

## Out of scope (deferred)

Tracked for follow-up; not in this plan:
1. **iPhone-side consolidation** — same FocusModeController shape, applied to puck-ios. Phase 2.
2. **Backend `focus_periods` table** — replacing `focus_sessions` with heartbeat-driven auto-close. Phase 3.
3. **Honoring intervention toggles in code** — Task 10 persists prefs; actual gating of e.g. screen-red-shift behind `intervention.screen_red_shift` is its own scoped change.
4. **"Plan-your-day" lock screen** — dropped entirely in v1 per Q1. Reintroduce later as opt-in intervention #11 if missed.
5. **Wake/sleep alarms** — designed in `docs/focus-states-ui-gallery.html`, separate plan.
6. **Earned browse mode** — gated behind `featureEnabled = false` in Task 3. Re-enable when product direction is settled.
7. **Bedtime enforcement specifics** — the `.bedtime` state is wired through but the actual bedtime blocklist swap and wind-down ramp are their own feature.

---

## Self-review (done by plan author)

**Spec coverage** (against `docs/FOCUS_CONCEPTS_SIMPLIFICATION.md`):

- ✅ "Focus Mode" as single concept replacing 9 → Tasks 1, 5-9
- ✅ 3 states (OFF/FOCUS/BEDTIME) → Tasks 1, 4, 7, 10
- ✅ Tap puck = full bundle fires → Task 8
- ✅ Schedule as trigger source, not enforcement engine → Task 7
- ✅ `unplanned` = OFF (no enforcement) → Task 5
- ✅ Backend = source of truth across devices (Mac end of the contract) → Task 8
- ✅ Wipe device state on migration → Task 11
- ✅ Earned browse: comment out, keep code, defer → Task 3 (feature flag, not commenting)
- ✅ No working-hours trigger → confirmed via deletion of IntentionalModeController in Task 9

**Placeholder scan:** No "TBD," "implement later," or vague "handle errors" instructions. Every step has concrete code, file paths, and commands. Two best-guess items flagged in-text: (a) JSON state-file names in Task 11 Step 1, (b) `block?.intention` field that may need to fall back to `block?.title` in Task 7.

**Type consistency:** `FocusModeController.State` cases (`.off`, `.focus`, `.bedtime`) match `TimeState` cases after Task 4. `ActivationSource` cases used consistently across Tasks 7, 8, 10. `Period` struct fields (`id`, `startedAt`, `intention`, `source`) referenced consistently.

**Verification model:** Build succeeds at the end of every task. Manual smoke test at Task 12 covers all four trigger paths plus the migration. No unit tests because the project has no test target — this is documented at the top.
