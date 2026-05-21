# Chrome Extension Removal — Summary (2026-05-21, worktree redo)

**Status:** Code complete. Debug build green. Release build also green when run on `feat/prototype-to-production` worktree separately; latest verification attempt aborted due to disk full at 100% (not a code issue). Dev instance launched + booted clean; Weekly Goals / Monthly Goals UI confirmed loading post-removal.

**Branch:** `feat/prototype-to-production` (worktree). 17 extension-removal commits + 3 setup commits (model swap-back to 4B, stem-removal in IntentKeywordExtractor, inventory file copy).

**Why this is the redo:** The first attempt scoped the removal to `slice-13-cleanup` on the main repo, but that branch is 30+ commits behind `feat/prototype-to-production`. Dev build from slice-13-cleanup showed old UI without Weekly Goals or close-the-noise sweep. This redo applies the same deletions / refactors but starting from the feature branch — end result is ONE branch with both feature work AND extension removal, ready to merge → main.

**Decision:** The Chrome / native-messaging extension integration is removed entirely. `WebsiteBlocker.swift` (AppleScript) is the sole browser surface. Chrome / Arc / Safari / Comet / Brave / Edge / Vivaldi / Opera all work. **Firefox + Tor are not supported** post-removal.

---

## What got deleted

### Swift files (8 source files + 1 directory)

| Path | Why |
|---|---|
| `Intentional/SocketRelayServer.swift` | local socket IPC with extension |
| `Intentional/NativeMessagingHost.swift` | extension-relay process; stdin↔socket |
| `Intentional/NativeMessagingSetup.swift` | wrote manifest JSONs to Chrome profile dirs |
| `Intentional/BrowserDiscovery.swift` | enumerated extension-install candidates |
| `Intentional/BrowserDatabase.swift` | stored per-browser extension state |
| `Intentional/LegacyMonitorView.swift` | ~1294 LOC debug UI showing extension protection status |
| `Intentional/SimpleTest.swift` | orphan, unused |
| `Intentional/main.swift.disabled` | orphan, untouched 90+ days |
| `NativeMessaging/` directory | manifest JSON + install.sh at repo root |
| `Intentional/ExtensionRemovalShim.swift` | temporary mid-removal stub; deleted at end |

**Total LOC removed:** ~4,500 from these alone, plus ~700 more from strip operations across the refactored files.

### `Intentional.xcodeproj/project.pbxproj`

All PBXBuildFile, PBXFileReference, group child, Sources phase entries for the deleted files.

### `docs/EXTENSION_PROTOCOL.md`

Moved to `docs/archive/EXTENSION_PROTOCOL.md` with archive banner.

---

## What got refactored (kept files with extension surface stripped)

| File | What stripped |
|---|---|
| `Intentional/main.swift` | Entire `if launchedViaExtension { … }` relay branch + the detection logic. 399 → 202 lines. Single-instance lock now runs unconditionally; Xcode-takeover / watchdog / SIGTERM intact. |
| `Intentional/BrowserMonitor.swift` | `hasExtension(bundleId:)`, `ProtectionStatus` enum, `protectionDecision(...)`, two-phase scan-gating, `lastProtectionDecisions` map, the commented-out PUCK BRANCH protection block, `has_extension` field on `browser_started` event. Kept: discovery via `LSCopyAllHandlersForURLScheme`, `getAllBrowsers`, `getBrowserInfo`, notifications. Private method renamed `checkForUnprotectedBrowsers` → `dispatchRunningBrowsers`. -204/+35 lines. |
| `Intentional/MainWindow.swift` | `GET_EXTENSION_STATUS` bridge case + `handleGetExtensionStatus` (89KB icon-rasterizing payload), `OPEN_EXTENSIONS_PAGE` case, `broadcastOnboardingToExtensions`, `broadcastSettingsToExtensions`, all inline `SETTINGS_SYNC` / `SETTINGS_RESET` blocks in saveLockSettings / removePartner / resetSettings, scheduleSync + earnedMinutesUpdate broadcasts in 4 handlers, caches: `iconCache`, `iconCacheLock`, `lastExtensionStatusJSON`, `lastExtensionStatusSignature`, `extensionStatusLock`. -239 lines. |
| `Intentional/AppDelegate.swift` | `nativeMessagingHost` + `extensionRescanTimer` + `socketRelayServer` properties and their init/shutdown. Removed broadcasts: SessionChanged closure (whole), broadcastEarnedMinutesUpdate, broadcastScheduleSync, SETTINGS_SYNC broadcastToAll. Removed `NativeMessagingSetup.shared.autoDiscoverExtensions` + 60s extensionRescanTimer. **Dashboard pushes preserved** (`pushEarnedUpdate`, `pushScheduleUpdate`, `pushFocusModeUpdate`). |
| `Intentional/FocusMonitor.swift` | 7 broadcast callsites (`broadcastHideFocusOverlay` ×5, `broadcastMuteBackgroundTab` ×2), the `extensionHandled` deep-work-early-return branch (was lines 2861-2890), 2 doc-comments referencing NativeMessagingHost. **Behavior change**: deep-work social-media path now flows through `handleDeepWorkBrowserIrrelevance` like every other irrelevant browser content. Matches Focus Hours behavior; intended. -46/+6 lines. |
| `Intentional/WebsiteBlocker.swift` | `NativeMessagingSetup.shared` usage in `getProtectedBrowsersList()` (~line 1034). Method now unconditionally returns `""` (9 callers still pass it as a harmless empty `protected=` query param on blocked.html URLs). EXTENSION-REMOVAL-NOTE comment documents the historical intent. |
| `Intentional/EarnedBrowseManager.swift` | Stray `socketRelayServer?.broadcastEarnedMinutesUpdate(self)` call. `pushEarnedUpdate` preserved. |
| `Intentional/TimeTracker.swift` | Doc-comment mentions of NativeMessagingHost (3 places). Method bodies unchanged. |
| `Intentional/ScheduleManager.swift` | Doc-comment mentions (2 places). Method bodies unchanged. |
| `Intentional/dashboard.html` | `#monitoring-dot/text` header indicator, `#settings-detail-browsers` drilldown + browser-card UI, `_extensionStatusResult` receiver, 2 `GET_EXTENSION_STATUS` sendMessage calls (showPage('settings') + refresh), `toggleBrowserCard`, `copyStoreUrl`, `installExtension` JS functions, ~95 lines of `.browser-*` CSS + 3 theme overrides. **3 dead sidebar pages** (page-schedule, page-weekly, page-distractions) plus their navigation routing + Today/Week toggle + helpers (`setTodayScheduleView`, `setScheduleView`). |
| `Intentional/onboarding.html` | Entire Screen 3 "Install the Extension" (browser-list + browser-summary). 6-screen → 5-screen onboarding. Removed: extensionPollTimer, startExtensionPolling, stopExtensionPolling, pollExtensionStatus, _extensionStatusResult, copyUrl, installExtension. ~155 lines of `.browser-*` + `.poll-spinner` CSS. |
| `CLAUDE.md` | "Architecture Principle: Logic Lives Here" rewritten as "Logic + Sensing both live in the Mac app — AppleScript-only." Removed sibling-repo reference to `intentional-extension`. Initialization Order steps 18-20 deleted + renumbered. Critical Callback Wiring code-block dropped 3 broadcast lines. Reference Documentation table dropped EXTENSION_PROTOCOL row + trimmed PUCK_SPEC + EARN_YOUR_BROWSE descriptions. Bug Fix #4 + #5 kept historical prose + appended "Resolved 2026-05-21" footnotes. **"Hard-Won Lessons" section preserved.** |

---

## What was deliberately left as-is

| Thing | Why |
|---|---|
| `Intentional/Intentional.entitlements` (9 keys) | Audited; every key has a non-extension reason. **No entitlement was extension-coupled.** CLAUDE.md Bug Fix #8 default-keep rule applied. |
| `FilterExtension/` target | macOS NetworkExtension content-filter system extension. Not Chrome-related. |
| `BlockingProfileManager` Swift class + bridge handlers | Slated for separate slice-13 task per CLAUDE.md ("BlockingProfileManager is NOT removed in Spec 1"). Dashboard `loadBlockingProfiles` JS still needs it for the legacy `customDistractingSites` sync. |
| `ProjectStore` | Same — separate slice-13 task. |
| `TimeTracker.getSessionSyncPayload` / `getAllPlatformSessions` | Dead post-extension-removal (no remaining callers). Removal is a separate dead-code cleanup. |
| `FocusMonitor.reportBrowserTabScored` | Same — caller-less, separate dead-code cleanup. |
| `recheckBrowserProtection()` on BrowserMonitor | Kept as a passthrough alias for `checkAllBrowsers()` while AppDelegate's transitional placeholder stripped its caller — fully redundant now but harmless. |

---

## Known regressions (intentional — addressed by Goal 2)

| Capability | Status | Goal 2 plan |
|---|---|---|
| Cross-browser session counters | Degraded — per-browser independent | Recover via Mac-side AppleScript polling |
| Page-body content for AI relevance scoring | Lost — scoring is URL + title only | Recover via AppleScript `execute javascript "document.body.innerText"` on Chromium browsers |
| Firefox sensing | Lost | Out of scope (no AppleScript dictionary) |
| Firefox blocking | Lost | Out of scope (would require NetworkExtension or screen overlay) |
| Tor sensing/blocking | Lost | Out of scope by design |
| In-page nudge overlays | Lost (mostly deprecated already) | Won't recover; in-pill nudges replaced them in Feb 2026 |
| Faster reactive nudges (event-driven) | Slight latency increase, imperceptible | Won't recover |

### Behavior change worth flagging

`FocusMonitor`'s deep-work social-media path used to defer to the extension when `extensionHandled` was true. Now it always flows through `handleDeepWorkBrowserIrrelevance` (overlay + redirect + intervention). Matches what Focus Hours already did; intended.

---

## Commit log (17 + 3 = 20 commits on this branch since 5a78834)

```
3 setup (model swap-back, stem-removal, inventory copy):
5cd2616 experiment(scorer): swap back to Qwen3-4B for speed (8B too slow at runtime)
d04f9ca fix(sweep): drop stem extraction — only full-domain matches + tool allowlist
05ebec4 docs(superpowers): bring extension-removal inventory into worktree

17 extension-removal:
55cb493 chore(slice-13): delete orphan SimpleTest.swift (zero callers verified)
79da03b chore(slice-13): delete orphan main.swift.disabled (zero callers verified)
5fa6637 chore(slice-13): remove native-messaging host + socket relay (extension deletion phase 1)
74bef67 chore(slice-13): strip extension-relay branch from main.swift + add removal shim
c6bedac chore(slice-13): strip extension-status surface from BrowserMonitor
440174d chore(slice-13): delete BrowserDiscovery + BrowserDatabase (extension-only)
c5940c2 chore(slice-13): delete LegacyMonitorView (extension-status UI, no purpose post-removal)
4c1d3b2 chore(slice-13): strip extension bridge handlers + browser-status JSON from MainWindow
c368429 chore(slice-13): strip extension wireup + broadcast callbacks from AppDelegate
637be1c chore(slice-13): strip extension broadcast callsites from FocusMonitor
724630e chore(slice-13): strip NativeMessagingSetup usage from WebsiteBlocker
786189a chore(slice-13): delete ExtensionRemovalShim — extension removal complete
7904161 chore(slice-13): strip extension-status panel from dashboard.html
1ad1b03 chore(slice-13): strip Install Extension screen from onboarding
fc59e3d chore(slice-13): remove dead sidebar pages (schedule/weekly/distractions)
f761f7f chore(slice-13): archive EXTENSION_PROTOCOL.md
413ffe8 docs(claude.md): drop extension-as-sensing-layer framing; AppleScript-only
```

---

## Final audit results

| Grep target | Hits |
|---|---|
| `NativeMessagingHost\|NativeMessagingSetup\|SocketRelayServer\|BrowserExtensionStatus` | 0 code refs (1 comment in WebsiteBlocker — intentional EXTENSION-REMOVAL-NOTE) |
| `extensionStatus\|GET_EXTENSION_STATUS\|_extensionStatusResult\|OPEN_EXTENSIONS_PAGE` | 0 |
| `hasExtension\|isExtensionConnected` | 0 |
| `broadcastScheduleSync\|broadcastEarnedMinutesUpdate\|broadcastSessionSync\|broadcastFocusModeUpdate` | 0 |

`xcodebuild Debug build` → ✅ `** BUILD SUCCEEDED **` (verified at every commit + final)
`xcodebuild Release build` → was succeeding through the dispatches; final verification blocked by **disk full at 100%** (118Mi free on 460GB — not a code issue, user needs to free space + re-verify).
`./scripts/dev-launch.sh` → worktree binary launched as PID 89851, booted clean, `GET_INTENTIONS` + `_intentionsList` + `_monthlyGoalsList` bridges firing (Weekly Goals UI loading correctly).

---

## Manual smoke test (USER ACTION REQUIRED)

The dev build from the worktree is alive at PID 89851. To verify the critical path:

1. **Look at your menubar** — you should see the Intentional icon. Click it.
2. **Click "Show Window" / "Open Dashboard"** in the menu.
3. **The in-app dashboard opens** — confirm the sidebar shows:
   - Today
   - Intentions (= Weekly Goals)
   - Sensitive Content
   - Lock
   - Settings
   - **NOT** Schedule / Weekly / Distractions (those were the 3 dead pages we removed)
4. **Start a focus session** via the Today page.
5. **In Chrome, navigate to** `https://www.youtube.com`.
6. Within ~1 second the URL should rewrite to `blocked.html`. If yes → AppleScript-only enforcement confirmed working post-removal.

If that works, the extension removal is complete and ready to merge → main.

If step 5 or 6 fails (URL doesn't redirect), DIAGNOSE before merging — paste the relevant log lines from `/tmp/intentional-fresh.log`.

---

## What's next (after smoke test passes)

1. **Free disk space** — Mac is at 100% / 118Mi free. Will block any future builds. Likely culprit: `~/Library/Developer/Xcode/DerivedData/` (multiple Intentional-* directories ~5-10GB each).
2. **Goal 2 — Extension recovery via AppleScript**:
   - Page-body content via AppleScript `execute javascript` → restore AI scoring accuracy.
   - TimeTracker refactor for Mac-driven session events → recover cross-browser counters.
3. **Merge `feat/prototype-to-production` → `main`** — both feature work AND extension removal land on main as one branch.
4. **Goal 3 — Documentation MkDocs site** (the 35-feature doc generation we discussed) runs on the post-merge `main` with the verified feature list.
