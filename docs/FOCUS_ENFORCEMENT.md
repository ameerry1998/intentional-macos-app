# Focus Enforcement (FocusMonitor)

## When Does Enforcement Run?

Enforcement runs IFF `FocusModeController.isOn == true`. The controller has three states (off/focus/bedtime); only `.focus` engages full enforcement. Bedtime is a separate concept (wind-down ramp, different blocklist).

All enforcement entry points (`FocusMonitor.evaluateApp()`, `FocusMonitor.pollActiveTab()`, `SwitchInterventionCoordinator`) gate on `focusModeController.isOn`. The controller is the single activation path — schedule transitions, dashboard toggle, cross-device WS, and puck all call `focusModeController.activate()` / `.deactivate()` / `.activateBedtime()`. There is no separate `intentionalModeEnabled` flag or `focusSession.isActive` gate predicate.

## Block Start Ritual (BlockRitualController)
When a block starts, a ritual card shows BEFORE the timer and enforcement activate. The user sets their intention and if-then plan, then clicks Start (or it auto-starts after 3 min for work / 30s for free time).

- **Deep Work / Focus Hours**: Full ritual card — focus question, 3 if-then plan options, Start/Edit/+15 min buttons, Skip link
- **Free Time**: Simple transition card — "Enjoy your break. X min available." + Start button
- While ritual is showing, `awaitingRitual = true` — `evaluateApp()` and `pollActiveTab()` return early (no enforcement)
- Edit mode allows inline block title/time/type editing → calls `ScheduleManager.updateBlock()`
- +15 min button calls `ScheduleManager.pushBlockBack(id:minutes:)` — shifts block start forward
- If-then plan selection saved to `UserDefaults("defaultIfThenPlan")` for pre-filling next ritual
- Focus question pre-fills from block description

## Block End Ritual (BlockEndRitualController)
When a focus block ends, a reflection card shows celebrating what the user accomplished.

- **Work blocks**: Full card — "Session complete" header, block stats, earned minutes, focus bar (green ≥80%, amber ≥50%, red <50%), emoji self-assessment (5 options, 0-4), "What went well?" text field, next block preview, Done button
- **Free Time blocks**: Simple "Break over" card — block type/time, next block preview, Done button
- Does NOT set `awaitingRitual` — enforcement for the new block can begin alongside the end ritual
- Auto-dismiss after 120s (saves whatever was entered)
- Skip conditions: no previous block, same block ID (edit), 0 totalTicks, trivial free time (0 ticks)
- Back-to-back blocks: end ritual shows first → Done dismisses → start ritual shows for new block
- Self-assessment and reflection saved to `BlockFocusStats` (persisted in `earned_browse.json`)
- Triggered in `AppDelegate.onBlockChanged` closure AFTER existing logic, captures previous block data BEFORE `earnedBrowseManager.onBlockChanged()` resets activeBlockId

## Two Input Paths
1. **Non-browser apps**: Detected via `NSWorkspace.didActivateApplicationNotification`, scored by app name
2. **Browser tabs**: Read via AppleScript (title + URL), polled every 10s while browser is frontmost

## Deep Work Enforcement (Aggressive)
| Real Time | Cumulative | Event |
|-----------|-----------|-------|
| ~3-5s | 10s | AI scores tab → **Nudge** + timer dot turns red |
| ~10s | 10s | **Auto-redirect** to last relevant URL + brief nudge + **grayscale starts** (30s fade) |
| revisit | — | **Instant redirect** (0s grace) |
| ~295s | 300s | **Intervention overlay** (60s mandatory game, escalating 90s/120s) |
| return | — | Grayscale snaps back over 2s, timer dot turns indigo |

Native apps: 5s grace → blocking overlay + grayscale starts.
Justification: "This is relevant" accepted → 3 min suppression only (no permanent whitelist), grayscale pauses.

**Floating timer widget**: Pill-shaped widget in top-right corner during all focus schedule blocks (Deep Work, Focus Hours, Free Time). Shows `[dot] block title [MM:SS]`. Dot: indigo=focused, red=distracted. Draggable. Auto-dismisses when block ends.

**Unscheduled pill cards** (3-state `NoPlanData.CardState`):

| State | Condition | Card | Dismiss |
|-------|-----------|------|---------|
| `noPlan` | `focusModeController.isOn == false` AND no schedule set | "What are you working on?" + 3 quick-block buttons (Deep Work/Focus/Free Time) + "Plan Full Day →" + snooze | No dismiss — must snooze or act |
| `gap` | `focusModeController.isOn == false` AND remaining blocks exist | "UNSCHEDULED" + "Up next in Xm" + accent-bar block list + "Schedule Now" button | − button minimizes to dock (30 min snooze) |
| `doneForDay` | `focusModeController.isOn == false` AND no remaining blocks AND blocks existed | Green "DAY COMPLETE" + stats + focus badge | − button minimizes; auto-dismiss 30s |

Quick-block buttons create a block starting now with default duration (adjusted for afternoon: shorter). "Schedule Now" opens the dashboard calendar with a pre-filled 1-hour focus block at the current time via `MainWindow.openScheduleWithNewBlock()`.

**Darkening overlay**: Full-screen click-through overlay (`.floating` level, `ignoresMouseEvents = true`). Progressive black overlay: alpha 0.0→0.45 over 30s (0.5s steps). Snap-back: 2s to clear. Creates a drained/muted visual effect.

## Focus Hours Enforcement (Gentle)
| Real Time | Cumulative | Event |
|-----------|-----------|-------|
| ~3-5s | 10s | **Level 1 nudge #1** (auto-dismiss 8s) |
| ~65s | 70s | **Level 1 nudge #2** + **grayscale starts** (30s fade) |
| ~125s | 130s | **Level 1 nudge #3** |
| ~185s | 190s | **Level 1 nudge #4** |
| ~235s | 240s | **Red warning nudge** ("intervention in 60s") |
| ~295s | 300s | **Intervention overlay** (60s mandatory game, escalating 90s/120s) |
| return | — | Grayscale snaps back over 2s |

## Irrelevance Threshold
Cumulative: 300 seconds of cumulative distraction triggers escalation (both Deep Work and Focus Hours). Distraction counter decays when user returns to relevant content.

## Social Media Delegation
Social media sites (YouTube, Instagram, Facebook) are skipped by FocusMonitor — the Chrome extension handles enforcement for those.

## Distracting Apps (User-Configured)
User-configured distracting apps (`distractingAppBundleIds` set, synced from `onboarding_settings.json`) skip AI scoring and grace periods — enforcement is immediate:
- Checked BEFORE always-allowed list (user intent overrides defaults)
- `isCurrentlyIrrelevant` set to `true` immediately (no grace period limbo)
- Gradual grayscale starts immediately via `startDesaturation()` (same progressive shift as browser tabs)
- Deep Work: blocking overlay shown; Focus Hours: nudge shown
- Cumulative distraction counter incremented on each evaluation

## Always-Allowed Apps (~100 bundle IDs)
Terminals, IDEs, code editors, password managers, system utilities. Auto-earn work ticks during work blocks. Logged to `relevance_log.jsonl` with reason "Always-allowed app".
