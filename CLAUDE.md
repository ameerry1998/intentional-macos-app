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

## Product Overview

Intentional is a macOS focus enforcement app that works with a companion Chrome extension. The Puck physical device provides a simple on/off toggle for blocking mode. Setting an intention upgrades blocking from dumb (block all distracting sites) to smart (AI scores relevance). See [docs/PUCK_SPEC.md](docs/PUCK_SPEC.md) for full product vision, blocking modes, and Puck branch changes.

**Architecture Principle: Logic Lives Here.** All enforcement logic, overlays, timers, and behavioral features belong in this macOS app — NOT in the Chrome extension. The extension is a sensing layer for AI content scoring. The app has OS-level capabilities (AppleScript, NSWindow overlays, process monitoring) that the extension cannot replicate, and centralizing logic here avoids duplication and ensures cross-browser consistency.

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
15a. BlockRitualController   → Wired to FocusMonitor.ritualController
15b. BlockEndRitualController → Wired to FocusMonitor.endRitualController
15c. ContentSafetyMonitor     → Load enabled from settings, start if enabled
15d. SwitchInterventionCoordinator + SwitchOverlayController → Wired to FocusMonitor (context-switching overlay v1)
16. Wire ScheduleManager.onBlockChanged callback  ← MUST be after all managers
17. Manual activeBlockId sync                      ← Catches app-started-during-block
18. NativeMessagingHost (template)
19. SocketRelayServer       → Start accepting extension connections
20. NativeMessagingSetup    → Auto-discover extensions, install manifests
21. Heartbeat timer (2 min interval)
```

### Critical Callback Wiring

```swift
// ScheduleManager.onBlockChanged → runs when active block changes
scheduleManager.onBlockChanged = { block, state in
    relevanceScorer.clearCache()
    earnedBrowseManager.onBlockChanged(blockId:blockTitle:)  // Set activeBlockId FIRST
    focusMonitor.onBlockChanged()                             // Then re-evaluate (may recordWorkTick)
    socketRelayServer.broadcastScheduleSync()
    mainWindow.pushScheduleUpdate()
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
