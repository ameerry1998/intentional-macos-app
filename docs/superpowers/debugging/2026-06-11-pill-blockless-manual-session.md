# Diagnosis: Pill shows midnight countdown + phantom "Block complete" for blockless manual sessions

**Date:** 2026-06-11 (incident) / 2026-06-12 (diagnosis)
**Status:** Root cause identified — NO FIX APPLIED YET (diagnosis-only per systematic-debugging)
**Severity:** User-visible on every manual session started without a scheduled block (coach card AND Goals-page start button)

## Incident

A focus session started from the coach card (`AppDelegate.handleCoachCardStart` → `startIntentionSession` → `FocusModeController.activate(source: .manual)`, no `ScheduleManager` block exists) produced:

- **(a)** Pill timer in `.timer` mode showing **"709:35" counting DOWN** — i.e. minutes:seconds until 23:59 — instead of a 25:00 countdown or a count-up.
- **(b)** Later, the pill flipped to **"Block complete 0:00 / 0% focused"** while the session was still active (sidebar still said "Focusing" / Stop session).

## Root cause (a): the synthetic block ends at 23:59, and the pill blindly counts down to block end

The pill has **no concept of a session** — it only knows blocks. Its `endsAt` comes exclusively from `ScheduleManager.currentBlock`'s end time:

1. `AppDelegate` wires `focusModeController.onStateChanged`. On `.off → .focus` with `scheduleManager.currentBlock == nil` it **injects a synthetic block ending at 23:59**:
   - `Intentional/AppDelegate.swift:823-838` — `endHour: 23, endMinute: 59, blockType: .focusHours`, then `scheduleManager?.injectFocusSessionBlock(synthetic)`.
   - This was added in commit `c026a0f` (2026-05-17, "inject synthetic block for sessionless .focus activations") so that enforcement paths that `guard let block = manager.currentBlock` have context. The 23:59 end was an enforcement placeholder; nobody considered that the pill renders it.
2. The injection calls `recalculateState(forceCallback: true)` (`Intentional/ScheduleManager.swift:357-360`), which sets `currentBlock = injectedFocusBlock` and fires `onBlockChanged` (`ScheduleManager.swift:806-817`).
3. `FocusMonitor.onBlockChanged()` (`Intentional/FocusMonitor.swift:840`) → `showTimerForCurrentBlock()` (`FocusMonitor.swift:936-948`) computes:
   ```swift
   let endOfBlock = Calendar.current.date(
       bySettingHour: block.endHour, minute: block.endMinute, second: 0, of: now
   ) ?? now
   deepWorkTimerController?.show(intention: block.title, endsAt: endOfBlock)
   ```
   For the synthetic block that is **today 23:59:00**. (The ritual path at `FocusMonitor.swift:915-919` computes the same `endOfBlock`, so it doesn't matter whether the start ritual showed first.)
4. `DeepWorkTimerController.show(intention:endsAt:)` starts a 1 s countdown off `vm.endsAt.timeIntervalSinceNow` (`Intentional/DeepWorkTimerController.swift:238-260`) and renders `mins:secs` remaining. A session started at ~12:09 PM → 709 min 35 s until 23:59 → **"709:35"**.

So the "minutes until midnight" figure is exactly `(23:59 − session start)` from the synthetic block. There is no per-session duration anywhere: `FocusModeController.Period` (`Intentional/FocusModeController.swift:31-45`) carries `startedAt` but **no planned end / duration**, so the pill literally has nothing better to display today — this is a design gap, not just a wrong constant.

## Root cause (b): the countdown hits 0 at 23:59 and flips the pill to `.blockComplete`; nothing ever rescues it while the session lives on

There are only **two** setters of `.blockComplete` in the codebase:

| Setter | File:line | Can fire here? |
|---|---|---|
| Countdown reaches 0: `if remaining <= 0 { ... if vm.mode == .timer { vm.mode = .blockComplete } }` | `DeepWorkTimerController.swift:240-246` | **YES — at exactly 23:59:00**, when `endsAt` (the synthetic block's end) passes. |
| End Block button on the pill | `FocusMonitor.swift:1290-1291` (`handleEndBlockTapped`) | No — user didn't tap. |

Sequence at 23:59 during a still-active manual session:

1. The 1 s countdown timer's `remaining <= 0` branch fires → pill shows "0:00" and switches to `.blockComplete` (`DeepWorkTimerController.swift:241-246`).
2. **Nothing ends the session**: the backend `focus_sessions` row is still active (12 h `expires_at` TTL; manual stop never sent), `FocusStatePoller` keeps reporting active, `FocusModeController.state` stays `.focus`. So the sidebar correctly says "Focusing" while the pill says "Block complete".
3. **Nothing rescues the pill**:
   - The celebration → `resumeAfterCelebration` path that normally clears `.blockComplete` only runs when `ScheduleManager` reports a *scheduled* block ending (AppDelegate captures prev-block stats on `onBlockChanged`). The injected block never "ends" — `recalculateState` returns it unconditionally while it's set (`ScheduleManager.swift:806-817`) — so no celebration is ever shown.
   - Worse, `FocusMonitor.onBlockChanged()` **explicitly defers** whenever the pill is in `.blockComplete`/`.celebration` (`FocusMonitor.swift:842-850`, sets `pendingBlockStartAfterCelebration = true` and returns), so every subsequent recalc/foreground/60s-sync `onBlockChanged` refuses to re-show the timer. The pill is wedged.
   - The only cleanup is on session end: AppDelegate's `.focus → .off` branch dismisses a pill stuck in `.blockComplete` and clears the injected block (`AppDelegate.swift:900-912`).

So (b) is a **deterministic consequence of (a)**: every blockless manual session that survives until 23:59 wedges the pill in "Block complete" for the rest of the session. No hour-boundary tick, noPlan/gap card, or ScheduleManager block-end check is involved — those were ruled out (the 10 s tick at `ScheduleManager.swift:876-880` produces no callback while the injected block is set and unchanged; `showNoPlan`/coach-card view-models are created with `mode != .timer`, and the countdown's flip is gated on `vm.mode == .timer`).

### Sub-finding: "0% focused" is an R6 stub regression

`FocusMonitor.pushFocusStatsToTimer()` (`FocusMonitor.swift:2824-2826`) is hard-coded post-R6:

```swift
private func pushFocusStatsToTimer() {
    deepWorkTimerController?.update(focusPercent: 0, earnedMinutes: 0)
}
```

and `DeepWorkTimerController.update(focusPercent:earnedMinutes:)` unconditionally sets `hasFocusData = true` (`DeepWorkTimerController.swift:379-383`). `focusStatText` then renders `"0% focused"` instead of the neutral `"Focusing"` placeholder (`DeepWorkTimerController.swift:1026-1028`) — the exact "angry red 0%" state the `hasFocusData` guard was built to avoid (`DeepWorkTimerController.swift:761`). This affects ALL sessions (scheduled too) since R6 deleted EarnedBrowseManager, not just blockless ones.

## Q3: Dashboard-started manual sessions (Goals page) — same bug, NOT a coach-card regression

- Today, `START_INTENTION_SESSION` (`Intentional/MainWindow.swift:758`, handler at `MainWindow.swift:3473`) calls the **same** `AppDelegate.startIntentionSession` (`AppDelegate.swift:1767-1793`) as the coach card — the paths were merged on 2026-06-12 in `921217c`.
- Before that merge, MainWindow's inline implementation (verified via `git show 921217c~1:Intentional/MainWindow.swift`) did the identical thing: `focusModeController.activate(intention:intentionId:source: .manual)` with no schedule block → synthetic injection → midnight countdown.
- Therefore: **any** blockless manual session — Goals page, coach card, dashboard toggle, puck, cross-device — has shown the until-23:59 countdown since `c026a0f` (2026-05-17), and would wedge into `.blockComplete` if still running at 23:59. The coach card merely made blockless midday sessions common enough to notice.

## Related latent gap (noted, not the incident)

`ScheduleManager.injectedFocusBlock` is **in-memory only** — not persisted. If the app restarts mid-manual-session, `FocusModeController` rehydrates `.focus` from disk but the boot-reconcile path bypasses `onStateChanged` (documented in CLAUDE.md), so the synthetic block is never re-injected: `currentBlock == nil` → `showTimerForCurrentBlock()` **dismisses the pill entirely** and every `guard let block` enforcement path goes dark. Different symptom (no pill at all), same missing-session-model root.

## Root-cause summary

1. **The pill renders blocks, not sessions.** Manual sessions have no duration model (`Period` has no planned end), so the synthetic enforcement-context block's arbitrary 23:59 end leaks into the UI as a countdown-to-midnight.
2. **The synthetic block never "ends" but its rendered countdown does** — at 23:59 the pill self-transitions to `.blockComplete` with no block-end event behind it, and the `.blockComplete` deferral logic in `FocusMonitor.onBlockChanged` guarantees it stays wedged until session stop.
3. (Cosmetic but real) `pushFocusStatsToTimer` is a `(0, 0)` stub since R6 that defeats the `hasFocusData` neutral state → "0% focused".

## Fix directions (for the fix phase — NOT implemented)

- Give manual sessions a real pill presentation: either a count-UP from `Period.startedAt`, or a chosen/default session length (e.g. the goal's `weeklyTargetHours`-derived or a 25/50-min picker) carried on `Period`. The synthetic block should stop being the pill's time source — `showTimerForCurrentBlock` can branch on `injectedFocusBlock != nil` / `period.source == .manual`.
- Whatever the timer shows, `.blockComplete` must only be entered from a genuine block/session end, or the countdown-zero branch must check that the backing block actually ended (not synthetic).
- Restore `pushFocusStatsToTimer` to push real relevance-derived stats (e.g. from the `SessionFocusScore`/relevance-log machinery) or stop calling `update()` so `hasFocusData` stays false and the pill shows neutral "Focusing".
