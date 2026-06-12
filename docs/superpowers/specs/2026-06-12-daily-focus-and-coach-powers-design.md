# Daily Focus + Coach With Hands — Design Spec

**Date:** 2026-06-12
**Status:** approved-pending-review (brainstormed live with Ameer, visual companion session `.superpowers/brainstorm/83991-1781283630/`)
**Supersedes:** the session/goal "design debt" flagged in `docs/PROJECT-STATE-2026-06-12.md` and diagnosed in `docs/superpowers/debugging/2026-06-11-pill-blockless-manual-session.md`
**Builds on:** `2026-06-12-focus-agent-design.md` (the coach), `2026-05-18-deep-work-protocol.md` (five stages)

## Why (the evidence — Ameer's actual day, 2026-06-12)

The coach watched all morning (41 decisions). At 11:58 it decided to nudge about YouTube drift — **never shown (shadow mode)**. At 12:08 its one live action fired: the plan prompt. Ameer typed *"Idk what to do"* → the broken flow created a **permanent Weekly Goal named "Idk what to do"** + a session that died in 9 minutes → the coach read "plan set" and **silenced itself all afternoon** while drift continued. Meanwhile **all 10 of his block rules were `enabled=false`** — enforcement was disarmed. Three muzzles, one wasted day, user verdict: *"an agent that sends one message and then shuts the fuck up is powerless — it's not a good focus agent."*

This spec fixes the session/goal model AND gives the coach enforcement hands.

## Design principles (locked during brainstorm)

1. **Chat is the verb; objects are the nouns.** Talking to the coach is how things get made, but every accepted suggestion creates a concrete, bounded object. Free text NEVER creates a Weekly Goal.
2. **The ignore path is the main path** (ICP walkthrough framework). One proactive prompt per planless stretch, then **state, not notifications** — plus structural consequences. No nag ladders.
3. **Propose, don't ask.** Open questions tax executive function the ICP doesn't have. Chips from the user's real data; typing is the fallback, never the ask.
4. **Coach proposes, user confirms** (agency principle) for anything *created* — but the coach may unilaterally **tighten** enforcement within the user's pre-consented strictness dial. It can NEVER loosen, unlock, mint allowance, end a session early, or message the partner.
5. **Bench before live.** Every new coach action ships shadow-first with ground-truth scenarios; wrong-act rate 0 gates visibility (same discipline as S1–S3).

---

## 1 · Daily Focus (new concept)

A **Daily Focus** is today's commitment. It is NOT an Intention/Weekly Goal.

| Field | Notes |
|---|---|
| `id` | UUID |
| `account_id` | FK accounts |
| `local_date` | the day it belongs to (user-local) |
| `title` | ≤60 chars, shown on pill/Today |
| `intent_text` | ≤140, defaults to title — feeds AI relevance scoring exactly like a goal's intentText |
| `linked_intention_id` | nullable FK → intentions; set when picked from "My weekly goals" (sessions then also credit the weekly goal's pace) |
| `created_via` | `coach_card` \| `today_tab` \| `promoted_from_chat` |
| `status` | `active` \| `done` \| `expired` |

- **Backend-resident** (new table, migration 032) so the coach reads it in context, the reckoning email reports it, and iOS can later render it.
- **Lifecycle:** expires at local midnight (status `expired` if not `done`). Next morning the coach may propose resuming it — but it never lingers as an active object.
- **Promotion:** one tap ("make this a weekly goal") creates an Intention from it — the ONLY path from typed text to a Weekly Goal, and it's explicit.
- Several sessions can run against one Daily Focus across the day.
- **Day-1 default:** none. The empty state IS the coach's opening.

## 2 · Sessions become real (kills the 4 bugs)

`FocusModeController.Period` gains: `plannedEndAt: Date?`, `dailyFocusId: UUID?`, `label: String?`. Backend `focus_sessions` gains `daily_focus_id` (FK, SET NULL), `planned_minutes`, `label`.

- **Duration:** every manual/coach session starts with a planned length (chip carries it; coach defaults 50 min work / 10 min sort-it-out). Pill counts down to `plannedEndAt` — **never to 23:59**.
- **At zero:** the genuine end ritual runs — "+25 more" or "done" — and the session actually ends (backend stop sent). `.blockComplete` may ONLY be entered from a genuine session/block end. This kills the 709:35 timer and the midnight wedge.
- **The synthetic 23:59 block dies.** Enforcement and pill read the session (Period) directly; whatever block-shaped shim the implementation keeps must carry the real `plannedEndAt` and be **persisted**.
- **Restart survival:** Period (with plannedEndAt/dailyFocusId/label) is already persisted by FocusModeController; boot reconcile must re-establish the pill countdown + enforcement context from it. App restart mid-session = pill comes back mid-countdown.
- **Visible + killable:** the session appears on the Today timeline ("Focusing on X until 2:50") and the pill menu + Today both expose **End session**. A session whose backing app dies or that is force-ended cleans up `daily_focus`-linked state. A dead session immediately clears "plan set" in coach context.

## 3 · The coach card v2 (plan prompt → mini-conversation)

Presets are ALWAYS present (user mandate):

```
🧭 <one-line contextual message — may reference yesterday's unfinished focus>
[▶ <top suggestion> · 50 min]        ← only when coach has real context
[🎯 My weekly goals]  [🤷 I'm not sure]
(or type what you're on…)
```

- **🎯 My weekly goals** → expands the in-progress Intentions inline; one tap → Daily Focus (linked) + session.
- **🤷 I'm not sure** → triage, never a dead end: coach proposes from (a) yesterday's unfinished Daily Focus, (b) most-touched project from telemetry, (c) weekly goals; final fallback = **10-min sort-it-out session** whose intent IS planning (notes/calendar/task apps count as on-task; it ends with the card re-shown, pre-filled with whatever the telemetry saw them write).
- **Typed text** → Daily Focus + session. Never an Intention. "Idk"-class answers are routed to the 🤷 path by the coach (bench scenarios cover this).
- **Multi-turn:** the card supports ≤3 short back-and-forth turns converging on a chip (minimal S5-converse pulled forward; full chat UI stays future).
- **Nothing is created until a chip is tapped.**

## 4 · Coach powers — the ladder (tighten-only)

The strictness dial (existing presets) = the coach's **maximum force**. The coach chooses when/what within it. Every use is logged (`coach_decisions.action`) and rendered on Today + the reckoning.

| Power | Behavior | Min dial |
|---|---|---|
| 🗣 Speak | nudge / rescue / credit / celebrate / plan card + chips (UNMUTE nudge+rescue — bench gate already passed at wrong-speak 0) | Soft |
| 🛑 Summon overlay | after **accumulated** drift in a planless stretch (~20–30 min, charter-tuned): non-skippable full-screen choice — the card's chips or "real break" (10 unblocked min, then re-ask) | Standard |
| ⏱ Soft-close | the existing 5-s close countdown aimed at the drifting tab | Standard |
| 🔒 Lock until declared | distraction sites behave as 🚫 until a Daily Focus is declared; the commitment is the key to the day | Strict |
| 🚫 Never | unlock · soften any rule · mint allowance · end sessions early · message the partner | — |

Charter v3 additions (bench-gated before any power goes live):
- **Drift accumulates** across a planless window — intermittent mixing over hours must trigger, not reset per 6-min sample.
- **"Plan set" is not a pass.** Coverage ends when the session ends/dies; a 9-minute dead session never silences the afternoon.
- New bench scenario categories: overlay-summon timing, soft-close appropriateness, lock-gate behavior, idk-triage routing. Wrong-act rate 0 required per action before it leaves shadow — same gate as speech.

**Ameer's machine: dial starts at Standard** (his choice pending; tightening to Strict is free and instant).

## 5 · Ambient state + Today page (the mirror)

- **Pill planless state:** persistent "unplanned · earning nothing · tank −Nm" chip-state after a prompt is ignored. State, not notifications.
- **Today page v1:** (1) Today's Focus slot (empty state = one line + the same chips); (2) auto-filled day timeline (TimeTracker + sessions + coach markers, including ignored ones); (3) tonight's reckoning preview line (what the partner/parent email will say).
- **Protection truth** (ships with this work): loud "nothing is blocked" banner when block rules are all disabled — today's silent-disarm can never recur invisibly. (Operationally fixed for Ameer 2026-06-12: 10 rules re-enabled, junk goal deleted.)

## 6 · Instrumentation

Every touchpoint records `shown / engaged / ignored (shown, expired untouched) / dismissed` — `ignored` is new and feeds back into coach context (it must adapt rather than repeat the form that gets ignored). Power usage events land on the Today timeline.

## Out of scope (logged follow-ups)

- **Opal-style Rules page restore** — user mandate 2026-06-12: the Rules tab should be the R6-deleted Opal-like Blocks page UI. Separate spec; verify what R6 removed from git history first.
- Parent/partner email content changes; iOS surfaces; voice input; full chat-history UI.
- Weekly-goal pace math changes (linked sessions credit pace via existing focus_sessions linkage).

## Sequencing (for the plan)

1. **Slice 1 — session model:** Daily Focus entity + bounded sessions + pill countdown/end ritual + restart survival + kill affordance + card v2 chips/triage. (Kills all 5 diagnosed bugs; everything else stands on it.)
2. **Slice 2 — unmute + Standard powers:** nudge/rescue live; drift accumulation + overlay summon + soft-close, shadow → bench → live; ambient planless pill state.
3. **Slice 3 — Strict lock + Today page v1 + protection banner.**

Each slice: bench gate where coach behavior changes, live GUI verification per `verifier-intentional-gui`, before/after screenshots.

## Open items

- Ameer to confirm: dial = Standard for his machine; 50/10-min defaults; midnight expiry.
- Spotify/SoundCloud are now blocked by the re-enabled rules — demoting them is partner-gated under strict mode; handle when asked.
