# Intentional macOS App - Development Guide

## Cross-repo / Overnight Work — Single Source of Truth (MANDATORY)

When a task spans multiple repos (e.g. Puck integration touches `intentional-backend` + `puck-ios` + this repo) OR is an overnight autonomous run:

- **Final progress log always lives in THIS repo** at `docs/overnight-run-YYYY-MM-DD.md` (or `docs/cross-repo-<feature>-YYYY-MM-DD.md` for non-overnight multi-repo features).
- That file is the authoritative hand-off: what was completed, what was blocked, what's in which PR, what the user needs to do tomorrow morning.
- Before starting a multi-repo or overnight task, check `docs/` for an existing log to append to.
- When handing off to a subagent for multi-repo work, explicitly point them at this convention.
- Sibling repos live at `/Users/arayan/Documents/GitHub/intentional-backend`, `/Users/arayan/Documents/GitHub/puck-ios`, `/Users/arayan/Documents/GitHub/puck-partner-dashboard`, `/Users/arayan/Documents/GitHub/intentional-extension`.

---

## Use Superpowers Skills at the Appropriate Times (MANDATORY)

Every non-trivial task on this repo must route through the right skill — this is not optional:
- **Before designing a new feature or behaviour change:** invoke `superpowers:brainstorming` to align on intent, scope, and trade-offs. Don't skip this even on "simple" changes.
- **Before writing implementation code:** invoke `superpowers:writing-plans` once the design is approved. The plan goes to `docs/superpowers/plans/` and gets reviewed before code moves.
- **Before debugging a bug, test failure, or unexpected behaviour:** invoke `superpowers:systematic-debugging` — do NOT guess at fixes without root-cause analysis.
- **When executing a written plan:** invoke `superpowers:subagent-driven-development` — don't ask which execution mode to use, just start.
- **Before claiming work is done:** invoke `superpowers:verification-before-completion` — evidence before assertions, always.

Violating the letter of this process violates the spirit of the development approach. Use the skills.

---

## Documentation Maintenance (MANDATORY)

After completing any code changes, assess whether this CLAUDE.md or the relevant `docs/` file needs updating. Update if any of the following changed:
- New or modified message types (NativeMessagingHost ↔ extension)
- Changes to EarnedBrowseManager, TimeTracker, or ScheduleManager state/APIs
- New features or significant behavior changes
- Changes to focus enforcement, blocking, or overlay logic
- New Swift files or significant restructuring
- Dashboard UI changes that affect extension ↔ app interaction

Keep updates minimal and precise — just add/modify the relevant sections. Do not rewrite sections that haven't changed.

---

## Don't stop. Keep going. (MANDATORY)

When the user is in execution mode (asked you to ship N slices, or "keep going," or any equivalent), **do not stop to check in.** Per `superpowers:subagent-driven-development`: "Continuous execution: Do not pause to check in with your human partner between tasks. Execute all tasks from the plan without stopping."

Specifically:
- Do NOT say "should I continue?" or "want me to keep going?" between slices
- Do NOT ship a "status update" and then wait for permission
- Do NOT recommend stopping just because the work is hard or the context is large
- Do NOT estimate work in "days" or "weeks" if the user has explicitly said "today" — push as far as actually-possible-today and only stop when genuinely blocked
- Do NOT claim a task will produce "mediocre quality" as a reason to stop — ship it, the user will tell you if quality is bad

The ONLY valid reasons to stop:
1. BLOCKED — you literally cannot proceed without info from the user
2. Ambiguity in the spec that genuinely prevents progress on the current task
3. All tasks in the explicit plan are complete
4. The user explicitly said stop in the most recent message

Status updates are FINE if they're terse. Asking permission is NOT FINE. The user trusts you to ship. Ship.

---

## Plain-English TL;DR at end of every response (MANDATORY)

The user is non-technical-leaning and skims. Long technical responses lose them. **At the end of EVERY response — no matter how short or long — append a TL;DR section in plain English.**

**Format:**

```
---

**TL;DR:** [1–3 plain sentences. No file paths, no commit hashes, no jargon.
            Cover whichever apply: what I just did, and what I need from you.]
```

**Examples:**

- *After making changes:* `**TL;DR:** Fixed the calendar tap bug. Install the new PKG to test it. Nothing else needed from you right now.`
- *After asking a question:* `**TL;DR:** Want strictness to live on the Intention only, or also as a per-block override?`
- *After giving info / a recommendation:* `**TL;DR:** Three reasonable options; I'd pick A. Tell me which and I'll move.`
- *After research / explanation:* `**TL;DR:** Perplexity's main idea is "make bypassing slow + visible + social." We can add three of their specific suggestions later if you want.`

**Rules:**

- Always at the END, after the full technical answer. Never replace the technical content — append.
- Maximum 3 sentences. If it doesn't fit in 3, the answer is too complex; restructure.
- No code, no file paths, no commit hashes, no jargon the user wouldn't say themselves.
- If the response is purely a one-liner answer, the TL;DR can be skipped (the answer IS the TL;DR).
- "What I want from you" should be explicit when it applies — *"Tell me X / approve Y / wait for Z."*

**Why:** the user has gotten lost in 2-page responses repeatedly. The TL;DR is the failsafe. They can ignore the body if the TL;DR tells them what they need.

---

## Documentation Patterns: Markdown vs HTML (MANDATORY)

This project uses a **two-layer documentation system**. Use the right format for the job.

**The entry point** is [`docs/index.html`](docs/index.html) — open it in Chrome to see the curated index of every doc, dated reports, and design mockups. Always update the index when you add a new doc that should be discoverable.

| Layer | Format | Filename pattern | What it's for |
|---|---|---|---|
| **Reference** | Markdown | `docs/SUBSYSTEM_NAME.md` (UPPER_SNAKE_CASE) | Evergreen source of truth — updated when behavior changes. Renders on GitHub. Source for "how does this work right now." |
| **Snapshot** | HTML | `docs/topic-YYYY-MM-DD.html` (kebab-case + ISO date) | Point-in-time visual report — audits, run logs, decision docs, sprint plans. **Never edit an old one** — write a new one with a new date if state has changed. |
| **Mockup** | HTML | `docs/topic-vN-variant.html` (versioned, no date) | Visual design exploration. May or may not be the chosen direction. Reference, not normative. |

**Decision rules — when writing a new doc, ask:**
- "Will this still be true in 6 months?" Yes → Markdown. No → dated HTML.
- "Should this get diffed in PRs?" Yes → Markdown. No → HTML.
- "Will I want to skim this in Chrome?" Yes → HTML. No → Markdown.

**HTML reports are most useful when they're dense.** Use status pills, color-coded tables, ranked lists. Save the prose for Markdown. Match the existing visual style (see `docs/feature-parity-2026-04-25.html` and `docs/index.html` for the CSS pattern — coral/gold accent, dark surface, pill components).

**When you create a new HTML report:**
1. Save as `docs/<topic>-YYYY-MM-DD.html` using today's date.
2. Add a card to `docs/index.html` in the appropriate section (Reports & audits, Cross-repo, or Design mockups).
3. Reuse the CSS variables and pill classes from existing pages — keep visual consistency.
4. Don't update old dated reports. Write a new one and link from the old.

**For cross-repo / overnight runs:** the Markdown log at `docs/overnight-run-YYYY-MM-DD.md` is the authoritative hand-off (per the cross-repo convention above). The Markdown is the source of truth; an accompanying HTML report is optional but helpful for visual summaries.

---

## Product Overview

Intentional is a macOS focus enforcement app that works with a companion Chrome extension. The Puck physical device provides a simple on/off toggle for blocking mode. Setting an intention upgrades blocking from dumb (block all distracting sites) to smart (AI scores relevance). See [docs/PUCK_SPEC.md](docs/PUCK_SPEC.md) for full product vision, blocking modes, and Puck branch changes.

**Architecture Principle: Logic Lives Here.** All enforcement logic, overlays, timers, and behavioral features belong in this macOS app — NOT in the Chrome extension. The extension is a sensing layer for AI content scoring. The app has OS-level capabilities (AppleScript, NSWindow overlays, process monitoring) that the extension cannot replicate, and centralizing logic here avoids duplication and ensures cross-browser consistency.

**Architecture Principle: Backend is Source of Truth for Cross-Device State.** Focus session state (`is the user focused right now`) lives canonically in `focus_sessions` on the backend. Each client (Mac, iPhone) treats its local representation as a cache. Mac polls `/focus/active` every 2s via `X-Device-ID` auth (no JWT TTL pain). iPhone reconciles on foreground/boot. Backend rows have `expires_at` TTL safety net so sessions where no client ever sent stop self-expire after 12h. See `docs/cross-repo-focus-sync-2026-04-28.md` for the full architecture, why it changed, and what's still follow-up.

---

## Intentions (Spec 1, May 2026) — ACTIVE

The Mac no longer treats Projects as a local-only concept. They are now backend-resident, account-scoped, cross-device-synced **Intentions** (`intentions` table in `intentional-backend`, see migration 018). Each Intention owns its own `mac_websites` + `mac_bundle_ids` lists directly.

- **`IntentionStore`** is the actor + cache. Pull on launch / app foreground / 60s timer. Local cache at `~/Library/Application Support/Intentional/intentions.json`.
- **`BlockingProfileManager` is NOT removed in Spec 1.** The named-profiles UI in the dashboard still uses it. Project blocklists migrated by *resolving* profile references into the new Intention's own lists. Profiles UI to be removed in a future cleanup PR.
- **`AppDelegate.activeProjectSession` retained** as in-RAM cache, now driven by both manual-start (optimistic) and `FocusStatePoller` (canonical). The known "lost on restart" bug fixes itself: after restart, the first 2s poll re-populates from `/focus/active.intention_id`.
- **Manual session start** now POSTs `/focus/toggle` with `intention_id`. Backend pushes silent APNs to peer iOS devices for ≤5s cross-device propagation.
- **Migration runner**: one-time at `IntentionMigration.swift`. Idempotent via receipt at `migration_intentions_v1.json`. Resumable on partial failure.
- **Day-1 default**: server seeds a "Focus" intention with curated default Mac blocklist for fresh accounts (no setup gate).
- **Bridge messages**: dashboard ↔ Mac uses `GET_INTENTIONS`, `GET_INTENTION`, `CREATE_INTENTION`, `UPDATE_INTENTION`, `DELETE_INTENTION`, `START_INTENTION_SESSION`. Legacy `*_PROJECT_*` handlers retained as deprecated aliases for one release cycle.

Spec: `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md`
Plan: `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-b-mac.md`
Cross-repo log: `docs/overnight-run-2026-05-03.md`

---

## Weekly + Monthly Goals (May 14, 2026) — ACTIVE

Intentions are surfaced to users as "Weekly Goals." The underlying Swift type (`Intention`) and DB table (`intentions`, which is a SQL view over `focus_modes` post-migration 022) keep their names. Each Intention/Weekly Goal carries new fields the prototype editor exposes:

- `outcome` (done-looks-like text)
- `status` enum (planned | in_progress | done | slipped | dropped)
- `weeklyTargetHours`
- `intentText` (≤140 chars; drives AI scoring when `aiScoringEnabled`)
- `aiScoringEnabled` (bool, default true)
- `allowWebsites` + `allowBundleIds` (per-goal Allow list — but **globally-active Time Blocks override these** per §17b.7 of requirements doc)
- `monthlyGoalId` (FK → MonthlyGoal; nullable for "unlinked" goals)
- `weekOf` (ISO Monday date; nullable = unscheduled)

New top-level type `MonthlyGoal` (`Intentional/MonthlyGoal.swift`) + actor `MonthlyGoalStore`. Cache at `~/Library/Application Support/Intentional/monthly_goals.json`. Sync pattern mirrors `IntentionStore` (pull on launch + foreground + 60s timer).

**One-shot migration:** `IntentTextMigration.runIfNeeded` copies `Intention.description` → `intentText` for goals that don't have it yet. Idempotent via receipt at `migration_intent_text_v1.json`. Runs after first IntentionStore pull on launch.

**New bridge messages (dashboard ↔ Mac):**
- `GET_MONTHLY_GOALS`, `GET_MONTHLY_GOAL`, `CREATE_MONTHLY_GOAL`, `UPDATE_MONTHLY_GOAL`, `DELETE_MONTHLY_GOAL`
- `LINK_WEEKLY_TO_MONTHLY` (set/clear `monthly_goal_id` on an Intention)
- `START_GOAL_SESSION` (alias of `START_INTENTION_SESSION`; carries optional `monthly_goal_id` for future analytics — currently ignored)
- `intentionToDict` extended with the 9 new fields → `_intentionsList` receiver
- `monthlyGoalToDict` → `_monthlyGoalsList` / `_monthlyGoalDetail` / `_monthlyGoalCreated` / `_monthlyGoalUpdated` / `_monthlyGoalDeleted` receivers

**Backend:** migration 026 (`intentional-backend`) adds 9 columns to `focus_modes` (refreshes the `intentions` view), creates `monthly_goals` table + indexes + RLS + triggers. CRUD endpoints at `/monthly_goals`. Extended `/intentions` POST + PUT round-trips the new fields. `GET /intentions?week=YYYY-MM-DD` filters by week.

**Theme toggle: OUT OF SCOPE** for this ship (§10 + §17b.12 of requirements doc). Dark-only.

Brief: `docs/prototype-to-production-2026-05-14.md`
Requirements: `docs/requirements-2026-05-14.md` (§17b authoritative for resolved Q&A)
Plans: `docs/superpowers/plans/2026-05-14-prototype-to-production-plan-{a,b,c}.md`
Cross-repo log: `docs/overnight-run-2026-05-14.md`

---

## Parallel Development (Worktree Workflow)

This repo uses git worktrees for parallel feature development. Multiple Claude Code agents may be working on different features simultaneously in separate worktrees.

**How it works:**
- `main` branch has the latest stable code
- Each feature gets its own worktree + branch under `.claude/worktrees/` or a sibling directory
- Each agent works in its own worktree — no file conflicts during development
- Features merge to main one at a time; the second feature rebases onto the updated main

**If you are in a worktree:**
- Run `git log --oneline main..HEAD` to see what other branches have been merged since you branched
- Before finishing, rebase onto main: `git fetch && git rebase main`
- Your worktree only has the macOS app. The companion Chrome extension may also have a parallel worktree — coordinate changes at the message boundary (NativeMessagingHost.swift ↔ background.js)

**Cross-repo coordination:** Features often span both the macOS app and extension. When adding/changing messages between them, document the message format in your commit message so the other agent (working on the other repo's worktree) can match it.

**Active worktrees:** Run `git worktree list` to see all active worktrees and their branches.

---

## Initialization Order (AppDelegate)

Order matters. Components have dependencies that must be wired in sequence.

```
1.  BackendClient           → API client
2.  MainWindow (WKWebView)  → Dashboard/onboarding UI
3.  Menu bar icon
4.  PermissionManager       → Accessibility permission monitoring
5.  SleepWakeMonitor
6.  WebsiteBlocker          → AppleScript tab blocking
7.  BrowserMonitor          → Protection status (references WebsiteBlocker)
8.  Backend: registerDevice, sync lock/partner state
9.  Strict mode init        → Reads `strictModeEnabled` from UserDefaults → login item, watchdog, flag file
10. TimeTracker             → Cross-browser usage aggregation
11. EarnedBrowseManager     → Load pool from disk
11a. ProjectStore            → Load projects.json
12. Wire TimeTracker.onSocialMediaTimeRecorded → EarnedBrowseManager.recordSocialMediaTime
13. ScheduleManager         → Load schedule, recalculateState
14. RelevanceScorer         → AI model initialization
15. FocusMonitor            → Desktop monitoring (refs: ScheduleManager, RelevanceScorer)
15a. FocusModeController    → Single source of truth for is-app-enforcing (3 states: off/focus/bedtime). Replaces IntentionalModeController + FocusSessionManager. Persists state to disk on every notify(); rehydrates on init so app-restart doesn't briefly show "off" while a session is active.
15b. BlockRitualController   → Wired to FocusMonitor.ritualController
15c. BlockEndRitualController → Wired to FocusMonitor.endRitualController
15d. ContentSafetyMonitor     → Load enabled from settings, start if enabled
15e. SwitchInterventionCoordinator + SwitchOverlayController → Gate now reads FocusModeController.isOn
16. Wire ScheduleManager.onBlockChanged → FocusModeController.activate / .deactivate / .activateBedtime
17. Manual activeBlockId sync + initial Focus Mode activation if a block is currently active
18. NativeMessagingHost (template)
19. SocketRelayServer       → Start accepting extension connections
20. NativeMessagingSetup    → Auto-discover extensions, install manifests
21. Heartbeat timer (2 min interval)
22. FocusStatePoller       → Polls /focus/active every 2s with X-Device-ID auth. On state transition, drives FocusModeController.activate/.deactivate. Backend-as-master cross-device sync; no JWT-expiry pain.
23. (boot reconcile)       → If FocusModeController.state == .focus from disk restore, applyDefaultBlockingProfile() + focusMonitor?.onBlockChanged() to re-engage enforcement.
```

### Critical Callback Wiring

```swift
// ScheduleManager.onBlockChanged → triggers Focus Mode transitions
scheduleManager.onBlockChanged = { block, state in
    switch state {
    case .focus:    focusModeController.activate(intention: block?.title, source: .schedule)
    case .bedtime:  focusModeController.activateBedtime(source: .bedtimeSchedule)
    case .off:      focusModeController.deactivate(source: .schedule)
    }
    // Domain logic (project sessions, celebration display) preserved separately
}

// FocusModeController.onStateChanged → fans out enforcement
focusModeController.onStateChanged = { old, new, period in
    relevanceScorer.clearCache()
    earnedBrowseManager.onBlockChanged(blockId:blockTitle:)  // before focusMonitor — preserves activeBlockId-before-recordWorkTick invariant
    focusMonitor.onBlockChanged()
    socketRelayServer.broadcastScheduleSync()
    mainWindow.pushScheduleUpdate()
    mainWindow.pushFocusModeUpdate(state: new)
    if new == .off { switchCoordinator.reset() }
}

// TimeTracker.onSocialMediaTimeRecorded → deduct from earned pool
timeTracker.onSocialMediaTimeRecorded = { platform, minutes, isFreeBrowse in
    earnedBrowseManager.recordSocialMediaTime(minutes:isWorkBlock:isJustified:)
    socketRelayServer.broadcastEarnedMinutesUpdate()
    mainWindow.pushEarnedUpdate()
}

// TimeTracker.onSessionChanged → broadcast to all browsers
timeTracker.onSessionChanged = { platform in
    socketRelayServer.broadcastSessionSync()
}
```

**Order invariant**: `earnedBrowseManager.onBlockChanged` must run BEFORE `focusMonitor.onBlockChanged` because FocusMonitor may call `recordWorkTick`, which needs the correct `activeBlockId`.

---

## Known Bug Fixes

1. **activeBlockId nil on startup**: `ScheduleManager.init()` calls `recalculateState()` before `onBlockChanged` callback is wired. Fixed by manual sync after wiring: `earnedBrowseManager.onBlockChanged(blockId: scheduleManager.currentBlock?.id)`.

2. **Callback execution order**: `earnedBrowseManager.onBlockChanged` must run BEFORE `focusMonitor.onBlockChanged`. FocusMonitor's `onBlockChanged` may call `recordWorkTick`, which needs the correct `activeBlockId` already set.

3. **MLX parse error fail-open**: Changed from fail-open (relevant=true on error) to fail-closed (relevant=false, confidence=0). Prevents broken AI from silently allowing all content.

4. **Chrome blocked by WebsiteBlocker with extension active**: `BrowserMonitor` now cross-checks socket connection status (definitive) with file-based detection, instead of immediately marking browser as unprotected on socket disconnect.

5. **Extension-launched process killing the app**: Chrome SIGTERMs then SIGKILLs native messaging hosts. Fixed by relay architecture: extension-launched processes are always thin relays, primary app is launched independently via `NSWorkspace`.

6. **Settings 800ms debounce losing changes**: `onSettingChange()` in dashboard.html uses an 800ms debounce before calling `saveAllSettings()`. If the user quits the app within 800ms of toggling, settings are lost. Fixed for Content Safety toggle (now saves immediately). Consider fixing for all toggles.

7. **PKG build re-signs with Developer ID Application + Developer ID provisioning profile.** The archive is signed with Apple Development, then re-signed inside-out (FilterExtension → frameworks → main app) with Developer ID Application using transformed entitlements. The `sensitivecontentanalysis.client` entitlement is stripped from PKG builds because Apple doesn't support it for Developer ID distribution — the app falls back to OpenNSFW for NSFW detection. The `content-filter-provider` value is changed to `content-filter-provider-systemextension` for Developer ID. The source entitlements file is NOT modified.

8. **NEVER strip or remove entitlements from the source file.** All entitlements exist for a reason. The build script handles transforming them for Developer ID signing. Do not modify `Intentional.entitlements` to remove capabilities.

9. **Whole-app UI freeze from AppleScript on main queue.** `WebsiteBlocker.appleScriptQueue` was declared as `DispatchQueue.main`, and a 0.5s timer fired `NSAppleScript.executeAndReturnError` on it for every active browser. Each call blocks on `mach_msg` waiting for the browser's Apple Event reply (200–600ms). Result: menu bar, pill, and dashboard all sluggish; dashboard `fps=14–23` with `longTasks=0` (the stall was on the native main thread, not in JS). Fixed by moving `appleScriptQueue` to a background serial queue (`DispatchQueue(label: "com.intentional.applescript", qos: .userInitiated)`). Apple Event Manager spins up its own nested `CFRunLoop` for reply delivery on whatever thread calls `AESendMessage`, so background execution is safe. **Rule: never dispatch synchronous AppleScript, Apple Events, or sync XPC to `DispatchQueue.main`. Use a background serial queue.**

10. **Queued project session does not auto-activate when its block becomes current.** `handleStartProjectSession` only sets `activeProjectSession` + calls `recordSessionStart` on the immediate path (no currentBlock). When a session is queued behind an existing block, the new FocusBlock is inserted but no active session is set and no `SessionEntry` is created until that block activates. Proper fix: observe `ScheduleManager.onBlockChanged` for the queued blockId and call `setActiveProjectSession` + `recordSessionStart` on activation. See [docs/PROJECTS.md](docs/PROJECTS.md).

11a. **Partner cache desync across devices (April 30, 2026).** Backend's `POST /partner` already wrote `partner_email`/`partner_name` to every sibling user row sharing an `account_id`, and `GET /partner/status` already fell back to siblings on empty rows. But the iOS client only read partner from `@AppStorage("partnerName")` (UserDefaults) and the Mac dashboard only fetched on navigation to the "pending" view. So a Mac signed into the same account as an iPhone never picked up a partner that was set + confirmed via the iPhone. Fix: `PartnerSyncService` on each platform fetches `/partner/status` on launch + foreground/`didBecomeActive` + every 60s while active, writes the result to UserDefaults (iOS) / settings JSON + dashboard (Mac), and reuses the existing `_partnerStatusResult` JS receiver for live updates. iOS clears cache on logout via `authStateDidChange`; Mac has no in-app sign-out so no cache wipe needed. See `docs/cross-repo-partner-sync-2026-04-30.md` and `docs/superpowers/plans/2026-04-29-partner-cross-device-sync.md`.

11. **Tangled focus state (April 2026 consolidation).** Nine overlapping concepts — Focus Gate, Intentional Mode, Focus Session, Always-Active Blocking, TimeState (7 cases), etc. — caused recurring desync bugs (screen red on YouTube without a session, focus gate not engaging on cross-device signal, phantom sessions, focus session active on phone but Mac doesn't know). Consolidated into `FocusModeController` with three states (OFF/FOCUS/BEDTIME). Schedule + cross-device WS + manual toggle + puck all flow through the same controller. Enforcement components (`FocusMonitor`, `SwitchInterventionCoordinator`) read `focusModeController.isOn`. `IntentionalModeController` and `FocusSessionManager` deleted (~700 lines net). See `docs/FOCUS_CONCEPTS_SIMPLIFICATION.md` and `docs/superpowers/plans/2026-04-27-focus-mode-consolidation.md`.

11b. **Bedtime config desync between Mac and iPhone (April 30, 2026).** Each device read its own local `bedtime_settings.json`; a toggle on iPhone never reached the Mac and vice versa. Backend already had `GET/PUT /bedtime/config` keyed by account_id, but the lock-loop branch was forked before the original `BedtimeConfigSync` shipped on `feat/bedtime-lockdown` — so the production PKG that included it lived elsewhere. Fix: ported `BedtimeConfigSync` (pull on launch + didBecomeActive + 60s timer; push on user edit via `MainWindow.handleSaveBedtimeSettings → BackendClient.putBedtimeConfig`). Last-write-wins via backend upsert on `account_id`. One-time migration of legacy local file → backend. See `docs/superpowers/plans/2026-04-29-partner-cross-device-sync.md` (sibling-sync architecture is identical pattern).

12. **Bedtime full-screen overlay replaced by lock-loop (April 2026).** `BedtimeOverlayView` (the full-screen blanket NSWindow) was easy to dismiss / route around and didn't actually prevent the user from operating the Mac. Replaced with `BedtimeLockLoop` which fires the OS lock screen every 10s while bedtime is `.locked`. Apps + downloads + music keep running; user re-enters via password / Touch ID; 10s gives enough room for partner-code entry without locking mid-keystroke. State machine simplified to `inactive | windDown(t30/t15/t5/t1) | locked | released`. Removed `forceSleep` (pmset), `snoozeUsedTonight`, `BedtimeOverlayView`, the wind-down redShift/grayscale phases. Wind-down cascade now lives in `BedtimeWindDownController` as native macOS notifications (`.timeSensitive`, bypasses DND) at T-30 / T-15 / T-10 / T-5 / T-1. Pill gains `.bedtimeWindDown` and `.bedtimeLocked` modes; pill also snaps to top-right on every `show()` so users don't lose it off-screen. Partner unlock now duration-limited via slider (15/30/60/120 min or until wake) with once-per-night cap. See `docs/cross-repo-bedtime-lock-loop-2026-04-29.md` and `docs/superpowers/plans/2026-04-29-bedtime-lock-loop-and-duration-extensions.md`.

   **Lock primitive (April 30, 2026 fix):** original implementation invoked the lock screen via AppleScript `keystroke "q" using {command down, control down}`. On machines where "Require password X after sleep" is set to a delay (5min/1hr), macOS interpreted this as Sleep Display, so wake-from-sleep didn't require a password. Subsequent ticks also no-op'd silently because System Events can't deliver keystrokes to a loginwindow-locked context. **Fix:** `dlopen` + `dlsym` on `/System/Library/PrivateFrameworks/login.framework/Versions/A/login` and call `SACLockScreenImmediate()` directly — same primitive Apple's "Lock Screen" menu item uses, always forces password regardless of the `password-after-sleep` delay. AppleScript remains as fallback if dlopen ever fails on a future macOS. Also added `RunLoop.main.add(timer, forMode: .common)` and `timer.tolerance = 0.5s` to harden the 10s cadence. **Rule: don't lock the screen via AppleScript keystroke. Use SACLockScreenImmediate via dlopen.**

13. **iPhone scheduled blocks via DeviceActivityMonitor (April 30, 2026).** Puck iPhone now has a Schedule tab ("Blocks") where users create recurring Deep Work / Focus Hours blocks. At the scheduled time, `PuckBedtimeMonitor` (the DeviceActivity extension) applies a per-block `ManagedSettingsStore` shield — even with the app closed. The extension dispatches on `DeviceActivityName` prefix: `"bedtime"` → existing bedtime path unchanged; `"schedule_<8 hex chars>"` → per-block path reads blocklist from App Group UserDefaults (`BedtimeSharedStorage.loadBlockBlocklist(blockId:)`). Block timing is authoritative on the backend at `/schedule/blocks` (4 commits on `intentional-backend:feat/schedule-blocks`); per-device app blocklists are local-only. Mac does NOT yet read this endpoint — the Mac has its own schedule format. See `docs/cross-repo-iphone-schedule-2026-04-30.md` and `docs/superpowers/plans/2026-04-30-iphone-schedule-tab.md`.

14. **Scheduled Intentions Redesign (May 2026).** Block editor's "Blocking Profiles" chips are gone — replaced by an Intention picker dropdown sourced from `IntentionStore`. Block editor also drops the Block Type segmented control (Free Time = absence of block per Spec 2). New active-days pill row (Mon–Sun, default `[1..5]`). Each Intention now has a `strictnessPreset` (Strict / Standard / Soft) edited from the Intentions tab. Tightening is instant; softening Standard→Soft has a 24h cool-down (server-side cron, cancellable, warm-tone D15 confirm copy); softening from Strict requires a partner unlock code (reuses generalized `BedtimeUnlockRequestView` with `UnlockRequestKind.intentionStrictness`). Strictness control greys out during an active Session of that Intention (D6). Sidebar restructured to 8 items: Today / Intentions / Schedule / Distractions / Sensitive Content / Weekly Planning / Accountability / Settings. Sensitive Content promoted from Settings to its own page; Weekly Planning is a placeholder for the deferred budgets feature (D9 schema prep landed; behavior deferred). Bedtime + Wake render as solid bands on the calendar (deep navy `#3B2459` bottom, warm coral `#F38B5C` top, no gradients per D11). Calendar gestures (drag-to-create / edge-resize / move) explicitly DEFERRED to v1.5 per D13. One-shot migration `BlockingProfilesToIntentionsMigration` rebinds existing block→profile bindings to block→intention idempotently with a receipt at `~/Library/Application Support/Intentional/migration_profiles_to_intentions_v1.json`. Per D14, `BlockingProfileManager` and its data file are NOT removed in this redesign — only the chips UI is hidden. Cleanup (Profiles tab + dashboard handlers + `BlockingProfileManager`) deferred to a follow-up spec after ≥2 weeks of stability.

   **Architecture key points:**
   - `Intention.strictnessPreset` + `pendingStrictnessChange` + `weeklyBudgetHours` + `budgetEnforcement` fields decode tolerantly so older payloads still parse.
   - New `BackendClient` methods: `updateIntentionStrictness`, `getPendingStrictnessChange`, `cancelPendingStrictnessChange`, `requestIntentionStrictnessUnlock`, `verifyIntentionStrictnessUnlock`. Backend endpoints actually deployed: `PUT /intentions/{id}/strictness`, `GET /intentions/{id}/strictness/pending`, `POST /intentions/{id}/strictness/cancel`. Partner-unlock endpoints (`POST /intention_strictness_unlock_requests`, `POST /intention_strictness_unlock_requests/{id}/verify`) are referenced by Mac + iOS clients but **DEFERRED on backend** (Plan A "What this plan does NOT do"). Strict-step-down softening will throw a runtime error in the UI dialog until the backend endpoints land — request stage fails with "Couldn't reach partner". Tightening + Standard→Soft cool-down both work end-to-end.
   - New `MainWindow` bridge messages: `UPDATE_INTENTION_STRICTNESS`, `CANCEL_PENDING_STRICTNESS_CHANGE`, `OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET`, `OPEN_INTENTION_EDITOR`. Intentions list payload now includes `strictness_preset`, `pending_strictness_change`, `weekly_budget_hours`, `budget_enforcement`.
   - `BedtimeUnlockRequestView` gains `kind: UnlockRequestKind` enum (`.bedtime` vs `.intentionStrictness(intentionId, toPreset, intentionName)`); duration slider hidden when not bedtime.
   - Block editor JS: Intention picker dropdown sources from `intentionsCache` (populated by `_intentionsList` receiver). Change handler `onEditorIntentionChange` either binds the picked Intention or opens the slide-in `+ Create new Intention` mini-editor. Active-days pills mutate `block.activeDays` directly (defaults to `[1..5]`).

---

## Build & Distribution

### Development (Xcode)
Standard `xcodebuild` or Xcode IDE. Debug builds run directly from DerivedData. Uses Apple Development signing with automatic provisioning.

### Production (PKG Installer)
**Build command:** `./scripts/build-pkg.sh`
**Skip notarization:** `NOTARIZE=0 ./scripts/build-pkg.sh`
**Output:** `/tmp/intentional-pkg-build/Intentional-{VERSION}.pkg`

**CRITICAL:** Never re-sign the app binary after Xcode archives it. This causes AMFI Error 163 (SIGKILL, exit code 137, no crash report). See [docs/PKG_BUILD_GUIDE.md](docs/PKG_BUILD_GUIDE.md).

**CRITICAL:** Never strip or remove entitlements from `Intentional.entitlements`. The build script transforms them for Developer ID signing. Fix signing/profile config instead.

> Full build guide: [docs/PKG_BUILD_GUIDE.md](docs/PKG_BUILD_GUIDE.md)

---

## Reference Documentation

Detailed docs for each subsystem live in `docs/`. Read the relevant doc when working on that feature area.

| Doc | What's in it |
|-----|-------------|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Project structure, architecture diagram, process model (relay/primary), state machine, persistence files, backend API |
| [PUCK_SPEC.md](docs/PUCK_SPEC.md) | Product vision, Puck integration, blocking modes, new systems (April 2026), extension role changes |
| [FOCUS_ENFORCEMENT.md](docs/FOCUS_ENFORCEMENT.md) | FocusMonitor enforcement timelines (Deep Work vs Focus Hours), block start/end rituals, pill widget, overlays, distracting apps, always-allowed apps |
| [EARNED_BROWSE_SYSTEM.md](docs/EARNED_BROWSE_SYSTEM.md) | Earning rates, cost multipliers, intent bonus, delay escalation, per-block tracking, pool state |
| [AI_SCORING.md](docs/AI_SCORING.md) | Relevance scorer pipeline (keyword→cache→LLM), Qwen3-4B / Apple FM models, fail-closed policy |
| [CONTENT_SAFETY_MONITOR.md](docs/CONTENT_SAFETY_MONITOR.md) | On-device NSFW detection, two-pass capture, OpenNSFW for Developer ID builds, partner notification |
| [CS_TESTING_WINDOW_PLAYBOOK.md](docs/CS_TESTING_WINDOW_PLAYBOOK.md) | How to pause CS emails + enforcement constraint for a debugging window, and how to fully reverse it. Paired scripts in `intentional-backend/scripts/` (`pause_cs_constraint.py` / `resume_cs_constraint.py`) + env var `CS_EMAILS_PAUSED_UNTIL` |
| [CONTEXT_SWITCHING_OVERLAY.md](docs/CONTEXT_SWITCHING_OVERLAY.md) | Non-skippable countdown on app/tab switches during a work block. Coordinator, overlay, tier math, grace periods |
| [EXTENSION_PROTOCOL.md](docs/EXTENSION_PROTOCOL.md) | Socket architecture, native messaging protocol, all message types (app↔extension and dashboard↔Swift) |
| [PROJECTS.md](docs/PROJECTS.md) | Projects (intention-driven sessions): data model, ProjectStore actor API, 7 bridge messages, start-session queue/immediate/refuse rules, blocklist delete guard |
| [STRICT_MODE.md](docs/STRICT_MODE.md) | App persistence, partner-gated enable/disable, Cmd+Q behavior, watchdog, edge cases |
| [PRIORITY_TODOS.md](docs/PRIORITY_TODOS.md) | Implementation backlog: Intentional Mode, permission monitoring, NE integration, anti-tamper hardening |
| [PKG_BUILD_GUIDE.md](docs/PKG_BUILD_GUIDE.md) | PKG build pipeline, signing details, daemon relaunch strategy, testing checklist |
| [ROADMAP.md](docs/ROADMAP.md) | Product roadmap, psychology research, feature priorities (P0-P3), coaching language overhaul |
| [EARN_YOUR_BROWSE_IMPLEMENTATION.md](docs/EARN_YOUR_BROWSE_IMPLEMENTATION.md) | Full earned browse implementation spec with UI mockups, extension changes, message protocol |
| [CALENDAR_BLOCK_RULES.md](docs/CALENDAR_BLOCK_RULES.md) | Block manipulation rules (past locked, active limited, future editable) |
| [BLOCK_TYPE_ENFORCEMENT_SETTINGS.md](docs/BLOCK_TYPE_ENFORCEMENT_SETTINGS.md) | Per-block enforcement toggles (6 mechanisms per block type) |

---

## Reminder: Use Superpowers Skills at the Appropriate Times

Second placement because this is load-bearing and easy to skip. Before any meaningful work:
- Non-trivial change? → `superpowers:brainstorming` first, then `superpowers:writing-plans`, then `superpowers:subagent-driven-development`.
- Bug / unexpected behaviour? → `superpowers:systematic-debugging` before touching code.
- About to say "done"? → `superpowers:verification-before-completion` first — run the thing, confirm output.

Skipping these because a task "feels simple" is exactly when you get burned. Route through the skill.
