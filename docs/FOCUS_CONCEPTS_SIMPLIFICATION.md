# Focus Concepts — Simplification Proposal

**Date written:** 2026-04-27 (during overnight debugging)
**Status:** DRAFT — no code changes yet. Read in the morning, edit, then we plan.

---

## The problem in one sentence

We have **nine overlapping concepts** doing what should be one feature. Every bug we hit tonight came from these concepts disagreeing with each other.

## What we accidentally have today

| # | Concept | Where it lives | What it does |
|---|---|---|---|
| 1 | **Focus Gate** (a.k.a. Intentional Mode) | `IntentionalModeController` | Locks screen with planning overlay during scheduled work hours when there's no active block |
| 2 | **Focus session** | `focusSessionManager`, backend `focus_sessions` | Time-bounded "I'm working on X" event with optional intention; engages enforcement |
| 3 | **Schedule block** | `ScheduleManager`, type ∈ {Deep Work, Focus Hours, Free Time, Bedtime} | Planned period of time with a block type |
| 4 | **Always-active blocking profile** | `BlockingProfileManager.alwaysActive` | Background blocklist that's "on" all the time |
| 5 | **Blocking profile (per session)** | `BlockingProfileManager.merged(profileIds:)` | Domain/app blocklist applied during a session |
| 6 | **Focus mode** (iOS) | `FocusMode` SwiftData model | Same shape as a Mac profile + intention, called something different |
| 7 | **TimeState** | `ScheduleManager.currentTimeState` | enum: disabled / freeTime / snoozed / unplanned / focusHours / deepWork |
| 8 | **AI relevance scoring + grayscale** | `FocusMonitor` | Tints screen red when content is "off-task" — runs whenever timeState isn't in a small allowlist |
| 9 | **Context-switch overlay** | `SwitchInterventionCoordinator` | Countdown overlay when switching to a non-relevant app — runs when in a "work session" |

These are **not nine features**. They're nine internal subdivisions of one feature. The user doesn't think about them separately. The bugs come from any pair of them being out of sync.

## What you actually want (your words tonight)

> "Focus Gate when that is flipped on this should essentially be us in deep work mode (1) not distracting apps at all (2) we're expected to plan out our time on the schedule (3) we get the context switching overlay (4) any other features make sense?"

i.e. **Focus Gate = the only switch.** ON = enforcement bundle. OFF = Mac is a Mac.

## Proposed simplified model

### The single concept: **Focus Mode**

> "Focus Mode" replaces "Focus Gate", "Intentional Mode", "Focus session", and the implicit "always-on enforcement" all at once.

It has **three states**:

| State | Meaning | What's enforced |
|---|---|---|
| **OFF** | Free time. Mac is a Mac. | Nothing. AI scorer dormant, no overlays, no red shift, no blocking. |
| **ON (open)** | "I'm focusing right now" — no specific intention. | Always-on blocklist enforced. Distractions blocked. Context-switch overlay armed. AI scoring on. Pill widget visible. |
| **ON (with intention)** | "I'm working on **X** specifically." | Same as ON (open) PLUS: stricter blocklist (mode-specific), stricter switch-overlay tier, intention recorded for the session log. |

### The single rule: anything you tap, swipe, or schedule maps to this

| Action | Resulting state |
|---|---|
| Tap puck on iPhone | Focus Mode ON (with intention from the chosen mode) |
| Tap puck again | Focus Mode OFF |
| Cmd+Shift+P on Mac | Focus Mode ON (open, no intention until you type one) |
| Schedule says "Deep Work block" + auto-start enabled | Focus Mode ON (with intention from the block title) |
| Schedule says "Free Time" or block ends | Focus Mode OFF |
| Schedule says "Bedtime" | Bedtime mode (separate — it's not focus, it's sleep) |
| Wake time reached + auto-on enabled | Focus Mode ON (open) |
| Sleep time reached | Bedtime mode |
| User toggles Focus Gate off in dashboard | Focus Mode OFF |

### What `unplanned` becomes

`unplanned` (no scheduled block, not in a session) maps to **Focus Mode = OFF**. Free browsing, no enforcement. The "you should plan your day" prompt is a *separate, optional* nag — not a side effect of Focus Mode being on.

### The schedule's role becomes simpler

The schedule is no longer the *source of truth* for whether you're focusing. It's a *recommendation* that can flip Focus Mode ON automatically at scheduled times, if you want.

- Schedule has a Deep Work block at 9 AM → at 9 AM, Focus Mode auto-flips ON
- Schedule has Free Time at 12 PM → at 12 PM, Focus Mode auto-flips OFF
- Schedule has Bedtime at 11 PM → at 11 PM, Bedtime mode kicks in
- No schedule for current time → Focus Mode unchanged (whatever state you set manually stays)

### The four states become one or two

What was `disabled / freeTime / snoozed / unplanned / focusHours / deepWork` collapses to:
- `OFF` (was: disabled, freeTime, snoozed, unplanned)
- `ON` (was: focusHours, deepWork — distinguished by intention/block type, but enforcement is the same)
- `BEDTIME` (separate)

## What gets renamed / removed in the consolidation

| Old name | Where it goes |
|---|---|
| Focus Gate | Renamed to Focus Mode (or kept as the "auto-lock if work hours and no plan" optional sub-feature, separate from Focus Mode) |
| Intentional Mode | Same as Focus Gate — collapses |
| Focus session | Becomes "Focus Mode ON with intention." Not a separate concept; it's metadata. |
| Always-active blocking | Becomes "Focus Mode ON (open) blocklist." |
| Per-session blocking profile | Becomes "intention-specific blocklist layered on top." |
| TimeState enum | Collapses to {OFF, ON, BEDTIME} |
| Focus mode (iOS) | Renamed to "intention" — it's a saved set-of-distractions-and-name. Used to populate Focus Mode ON. |
| `unplanned` enforcement | DELETED. Unplanned = OFF. |

## What survives untouched

- **Bedtime mode.** Genuinely separate — sleeping isn't focusing.
- **Schedule itself** (the calendar view, blocks, etc.). It just becomes a *trigger source* instead of a separate enforcement engine.
- **Always-allowed apps.** Orthogonal — apps you can use even in Focus Mode.
- **Partner lock.** Orthogonal cross-device security.
- **AI relevance scoring.** Runs whenever Focus Mode is ON, dormant otherwise.
- **The pill widget.** Renders the current state of Focus Mode. (Off / On / On + intention / Bedtime.)

## The migration plan (sketch — not finalized)

1. **Phase 1 — Rename + collapse.** Rename `IntentionalModeController` → `FocusModeController`. Inline the `focusSessionManager` state into it. The combined controller is the source of truth for "is focus mode on."

2. **Phase 2 — Schedule becomes a trigger source.** `ScheduleManager.onBlockChanged` calls `FocusModeController.activate(intention:)` or `.deactivate()`. The controller owns enforcement; the schedule owns timing.

3. **Phase 3 — Delete `unplanned` enforcement path.** Anywhere FocusMonitor checks `currentTimeState`, replace with `focusModeController.isOn`. `unplanned` = nothing happens.

4. **Phase 4 — Rename concepts in UI.** Dashboard: "Focus Gate" → "Focus Mode" toggle. iOS: "Focus mode" → "Intention." Cross-repo log update.

5. **Phase 5 — Backend simplifies.** `focus_sessions` table becomes `focus_periods` — every Focus Mode ON window is a period, with optional intention metadata. No "stale session" problem because a period has explicit start/end and any device can end it.

## Open design questions (decide together when you wake)

- **Should "no plan during scheduled work hours" still trigger a screen lock?** That's the original Focus Gate behavior. It feels like a separate "nag" feature on top of Focus Mode rather than core to it.
- **Auto-on at wake time?** You wanted wake/sleep times. Auto-on at wake = "Focus Mode is on by default during waking hours." Counterintuitive — most people want to ease in. Maybe it stays OFF and you flip it on each morning.
- **What happens on Mac when you tap puck on iPhone?** I think Focus Mode ON, but should it default to "open" (no intention) or use the iPhone Mode's name as intention?
- **iOS-only device (no Mac)** — Focus Mode lives on iPhone alone. Does it sync to a non-existent Mac? (No-op until they install Mac app.)

## What this fixes

Every bug we hit tonight in one stroke:

- **Phantom session.** Eliminated — there's no separate "session" object that can drift from "is focus on."
- **Stale active session in backend.** Periods have explicit end events; backend auto-closes a period if it hasn't received a heartbeat in 30 min.
- **Unplanned = enforcement.** Eliminated — unplanned = OFF.
- **Confused toggle ("nothing happens when I flip Focus Gate").** Toggle directly maps to ON/OFF; visible enforcement starts immediately or doesn't.
- **Cross-device disagreement.** Periods are account-scoped, both devices read/write the same record.
- **"Focus session active on phone but Mac doesn't know."** Same Focus Mode state lives in the backend; both apps subscribe.

## What it doesn't fix (separate work)

- iPhone fire-and-forget POST → still need persistent retry queue on iPhone.
- Schedule UI on iPhone → still its own port.
- Distractions sync (account-scoped Mode metadata) → still its own feature.

These are orthogonal to the conceptual cleanup. They each become smaller once Focus Mode is the only thing.

## What I'm NOT doing tonight

- Writing any of this in code.
- Renaming anything.
- Touching another file.

When you're up: read this, redline it, push back where I have the model wrong, then we plan with the writing-plans skill, then we ship in one cohesive PR rather than another patch storm.

Sleep.
