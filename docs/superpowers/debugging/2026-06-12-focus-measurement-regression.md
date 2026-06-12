# Live in-session focus % stuck at "0% focused / +0m" (R6 stub regression)

**Date:** 2026-06-12
**Area:** Pill (DeepWorkTimerController) live focus stats · FocusMonitor
**Status:** FIXED

## Symptom

During an active focus session the floating timer pill showed **"0% focused"**
and **"+0m"** for the entire session, regardless of how relevant the user's
screen actually was. It used to compute a live focus % + earned minutes from
in-session relevance scoring and display it.

## Root cause

Two compounding bugs, both introduced by the **R6 cleanup** (June 2026,
`EarnedBrowseManager` deletion).

### 1. The data source was deleted and replaced with a hardcoded zero stub

Before R6, `FocusMonitor.pushFocusStatsToTimer()` read the live numbers from
`EarnedBrowseManager.blockFocusStats[activeBlockId]`:

```swift
// pre-R6
private func pushFocusStatsToTimer() {
    guard let ebm = appDelegate?.earnedBrowseManager else { return }
    if let blockId = ebm.activeBlockId, let stats = ebm.blockFocusStats[blockId] {
        deepWorkTimerController?.update(focusPercent: stats.focusScore,
                                       earnedMinutes: stats.earnedMinutes)
    } else {
        deepWorkTimerController?.update(focusPercent: 0, earnedMinutes: 0)
    }
}
```

R6 deleted `EarnedBrowseManager` (the per-block tick accountant, which had in
fact been emitting all-zeros behind a dead feature flag for some time). The
replacement just hardcoded the zeros:

```swift
// R6 stub — the regression
private func pushFocusStatsToTimer() {
    deepWorkTimerController?.update(focusPercent: 0, earnedMinutes: 0)
}
```

So nothing computed a real number anymore.

### 2. The neutral-placeholder guard was defeated

`DeepWorkTimerController.update(focusPercent:earnedMinutes:)` **unconditionally**
set `hasFocusData = true`:

```swift
viewModel?.hasFocusData = true  // first real score arrived
```

`hasFocusData` exists precisely so a just-started session shows a neutral
"Focusing" placeholder instead of an angry red "0% focused". But because the
stub pushed `(0, 0)` on the very first call (right after the pill is shown), the
flag flipped true immediately and the pill locked into "0% focused" for the
whole session. The earned chip "+0m" was likewise always rendered (never gated).

## Fix

The relevance scorer still runs in-session and `FocusMonitor.logAssessment()`
appends one JSONL line per evaluation to `relevance_log.jsonl`.
`SessionFocusScore.compute()` already derives the canonical session focus_score
(sent to the backend on session stop) from that log: **relevant ÷ total**
qualifying assessments, **excluding** `isEvent` lines (red-shift / intervention
/ override events) and `neutral` lines (neutral-app / override entries logged as
`relevant:true, confidence:0`).

We reuse that *exact* derivation for the live number, but from an **in-memory
running tally** instead of re-reading the (multi-MB, unbounded) log tail —
because `pushFocusStatsToTimer()` fires on every poll tick / recovery and must
stay cheap.

**Data source used for the live %:** two `Int` counters in `FocusMonitor`,
`sessionAssessmentTotal` and `sessionAssessmentRelevant`, incremented at the
single `logAssessment()` funnel using the same exclusion rule as
`SessionFocusScore` (`if !isEvent && !neutral { total += 1; if relevant {
relevant += 1 } }`). Reset to 0 per session in `resetEnforcementState()`
(alongside `blockRecoveryCount` etc.).

**Formula:** `percent = round(sessionAssessmentRelevant / sessionAssessmentTotal
* 100)` when `total > 0`; placeholder when `total == 0`. Identical to what
`SessionFocusScore.compute(sessionStart…now)` would return over the same window
(same qualifying set, same ratio).

**Placeholder fix:** `update(...)` now takes a `samples` argument and only sets
`hasFocusData = true` when `samples > 0`, so a just-started session (0 samples)
keeps the neutral "Focusing" state.

**Earned minutes (caveat):** there is **no honest live source** for earned
minutes. The allowance earn rule grants minutes *once*, on session stop
(`AppDelegate.postAllowanceEarn` on the `.focus → .off` transition), not
incrementally. Per the "omit rather than fake" rule we push `earnedMinutes: 0`
and suppress the earned chip entirely (new `hasEarnedData` flag, only set when
`earnedMinutes > 0`) so the pill no longer shows a misleading "+0m". A real
live earned readout would require metering the allowance spend/earn per tick —
out of scope for this fix.

## Files changed

- `Intentional/FocusMonitor.swift` — added `sessionAssessmentTotal` /
  `sessionAssessmentRelevant`; tally in `logAssessment()`; reset in
  `resetEnforcementState()`; rewrote `pushFocusStatsToTimer()` to compute the
  live %.
- `Intentional/DeepWorkTimerController.swift` — `update(focusPercent:
  earnedMinutes:samples:)` only flips `hasFocusData` when `samples > 0`; added
  `hasEarnedData` published flag; `earnedText` returns "" until real earned
  data exists.

## Verification (session timeline reasoning)

1. **Just-started session** → `resetEnforcementState` zeroes the counters,
   fresh viewModel has `hasFocusData=false`, `pushFocusStatsToTimer` pushes
   `samples=0` → `hasFocusData` stays false → pill shows **"Focusing"** (neutral
   grey), earned chip hidden. ✓
2. **After N relevant + M irrelevant ticks** → push computes
   `round(N/(N+M)*100)`, `samples = N+M > 0` → `hasFocusData=true` → pill shows
   **"X% focused"** with the right color band; % drops on distraction
   (irrelevant handlers also push) and rises on recovery. ✓
3. **Matches `SessionFocusScore`** → identical qualifying set (excludes
   `isEvent` + `neutral`, keeps `userOverride` relevant lines) and identical
   ratio. The in-memory tally over the session window equals
   `SessionFocusScore.compute()` over the same window. ✓

Build: `xcodebuild -project Intentional.xcodeproj -scheme Intentional
-configuration Debug build` → **BUILD SUCCEEDED**.

## Known minor caveat

On the "unchanged relevant tab" poll path, `pushFocusStatsToTimer()` is called
just before that tick's `logAssessment()`, so the displayed % lags the true
value by at most one ~10s tick and self-corrects on the next push. The
irrelevant path logs before pushing, so it's exact. Not worth reordering
load-bearing enforcement code for a sub-tick display lag.
