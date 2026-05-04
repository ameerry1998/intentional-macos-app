# Spec — Weekly Budgets for Intentions (Deferred / Future)

**Date:** 2026-05-03
**Status:** Future spec — DO NOT IMPLEMENT before the Scheduled Intentions Redesign ships and stabilizes.
**Predecessor (must-be-done-first):** `docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md`

---

## Why this is its own spec

Ameer's instinct (correct): don't one-shot two big features at once. The Scheduled Intentions Redesign already covers the calendar parity, Intention picker, strictness presets, and sidebar restructure. Trying to bolt on the budgets feature alongside it produces two half-broken features instead of one solid one. Build the redesign first, validate it, then come back here.

The redesign spec does **prep work** (D8 sidebar slot, D9 schema fields) so this spec can land cleanly without nav restructure or migrations beyond endpoint/cron logic.

---

## What this spec adds (when it ships)

A user can:

1. **Set a weekly budget on any Intention.** *"Reading: 7h/week."* Optional per Intention — most stay budget-less.
2. **Pick an enforcement mode for each budget:** Track / Nudge / Auto-schedule / Strict.
3. **Optionally do a Sunday-night planning ritual** — confirm targets, accept auto-suggested blocks. Skippable; system auto-fills if you skip.
4. **See live budget progress** as pills on the Schedule header and as a card on the Home tab.
5. **Move budget-derived blocks within constraints** — same day or next day free; further requires partner unlock or 4h cool-down.
6. **Get partner notification** when behind on a Strict-mode budget at a user-configured threshold.
7. **Configure the ritual day + time** (default Sun 7pm; supports Friday-evening, Monday-morning, etc.) or disable it entirely.

---

## Locked product decisions

| # | Decision | Why |
|---|---|---|
| **WB1** | Weekly budgets are **per-Intention, optional**. Most Intentions won't have one. | Pure opt-in. Default product flow unchanged. |
| **WB2** | Four enforcement modes: **Track / Nudge / Auto-schedule / Strict**. The user picks one when they set the budget. | Range from "I'm curious" to "Hold me to this." Mirrors strictness preset philosophy from the redesign spec. |
| **WB3** | The Sunday-night ritual is **optional**. Configurable day + time. **Opt-out leaves budgets running** — system auto-fills based on last week's pattern (or sensible defaults if first week). | The ICP says forced upfront planning gets ignored. Budgets need to work without the ritual. |
| **WB4** | Budget-derived blocks can be dragged **within the same day OR to the next day** without friction. Dragging 2+ days requires partner unlock OR 4h cool-down (user picks at setup). | Closes the moment-of-weakness "push it all to Sunday night" pattern, but keeps real-life flexibility. |
| **WB5** | Budget-derived blocks **cannot be deleted** — only "Skip this slot." On skip, system auto-suggests a replacement slot later in the week to keep the budget intact. | Deleting a budget block is the bypass. Skip + reschedule is the legitimate path. |
| **WB6** | Behind-budget enforcement on **Strict mode** = partner notification at user-configured threshold (e.g. "tell my partner if I'm 50% behind by mid-week"). On other modes: notification to user only, never partner. | Reuses the partner-as-non-self-executive-function pattern. Only Strict mode loops in the partner. |
| **WB7** | Surfaces are **distributed**, not a single nav item: per-Intention setup in the Intention edit screen; pills on Schedule header; card on Home tab; full Weekly Planning page in the sidebar (D8 from redesign spec). | Mirrors the Sensitive Content pattern: invisible until you opt in, then progressively visible. |

---

## Surfaces & interactions

### A. Setup — per-Intention edit screen

The greyed "+ Add weekly target (coming soon)" placeholder from the redesign spec becomes active.

```
─────────────────────────
Weekly target
─────────────────────────
[ 7 ] hours per week

Enforcement mode:
○ Track only — just show progress
● Nudge — push me when I'm behind
○ Auto-schedule — fill my calendar
○ Strict — partner notified if behind

Behind-budget threshold (Strict only):
[─●──────] 50% behind by [Wed ▾]
```

### B. Schedule header — at-a-glance pills

When ANY Intention has an active budget, a horizontal scroll of pills appears above the Day/Week toggle:

```
[●Reading 4/7h ↗]  [●Gym 3/7h →]  [●Study 2/5h ↘]
```

- Dot color = Intention color
- Fraction = hours done / target
- Arrow = ahead / on-track / behind (↗ ahead, → on-track, ↘ behind)
- Tap pill → opens Weekly Planning page focused on that Intention

When NO budgets exist, the row collapses to 0 height (per redesign spec D9 prep).

### C. Home tab — weekly overview card

```
┌─ This week ──────────────────┐
│ Reading        ████░░░  4/7h │
│ Gym            ███░░░░  3/7h │
│ Study          ██░░░░░  2/5h │
│ ⚠ 2 days left, 3 budgets to hit │
└──────────────────────────────┘
```

Hidden when no budgets. Subtle behind-budget styling (warm accent) when ≥1 is at risk.

### D. Weekly Planning sidebar page

Promoted from the placeholder shipped in the redesign spec. Full content:

- "Plan next week now" button (open the ritual on-demand, any day)
- Reminder schedule controls: day + time + on/off toggle
- This week at a glance: budget pills with progress
- Last week recap: how you did against each budget
- 12-week trend per budget (small sparklines)
- "Auto-fill if I skip the ritual" toggle (default on)

### E. Sunday-night ritual — modal sheet

Triggered by notification at the configured day/time, OR opened on-demand from the Weekly Planning page.

```
Plan next week
─────────────────────────
Reading — 7h/week target
Suggested for next week:
  ☑ Mon 7-8 AM (60 min)
  ☑ Wed 7-8 AM (60 min)
  ☑ Sat 9-10:30 AM (90 min)
  ☑ Sun 9-10:30 AM (90 min)
  Total: 5h. Need: 2 more hours.
  [+ Add suggested slot]  [Adjust to 5h instead]

Gym — 7h/week target
Suggested:
  ☑ Tue 6-7:30 PM
  ☑ Thu 6-7:30 PM
  ☑ Sat 10-11:30 AM
  ☑ Sun 10-11:30 AM
  Total: 6h. Need: 1 more hour.

[ Confirm and schedule ]
```

If user dismisses without confirming: system uses last week's confirmed pattern (or first-time defaults) automatically.

---

## Schema additions (already in redesign migration 020)

These are seeds shipped in the redesign spec (D9). When this future spec ships, they get used:

```sql
ALTER TABLE intentions
  ADD COLUMN weekly_budget_hours NUMERIC(4,2);

ALTER TABLE intentions
  ADD COLUMN budget_enforcement TEXT
  CHECK (budget_enforcement IS NULL OR budget_enforcement IN ('track', 'nudge', 'auto_schedule', 'strict'));

ALTER TABLE time_blocks
  ADD COLUMN derived_from_budget BOOLEAN NOT NULL DEFAULT FALSE;
```

This spec adds:

```sql
-- Threshold settings for behind-budget partner notification (Strict mode)
ALTER TABLE intentions
  ADD COLUMN budget_behind_threshold_pct INTEGER
  CHECK (budget_behind_threshold_pct IS NULL OR budget_behind_threshold_pct BETWEEN 1 AND 99);
ALTER TABLE intentions
  ADD COLUMN budget_behind_check_day INTEGER
  CHECK (budget_behind_check_day IS NULL OR budget_behind_check_day BETWEEN 1 AND 7);

-- Settings for the ritual itself
CREATE TABLE weekly_planning_settings (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  ritual_day INTEGER NOT NULL DEFAULT 7    -- ISO 1=Mon..7=Sun, default Sunday
    CHECK (ritual_day BETWEEN 1 AND 7),
  ritual_hour INTEGER NOT NULL DEFAULT 19  -- 0–23, default 7pm
    CHECK (ritual_hour BETWEEN 0 AND 23),
  ritual_minute INTEGER NOT NULL DEFAULT 0
    CHECK (ritual_minute BETWEEN 0 AND 59),
  ritual_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  auto_fill_on_skip BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Track each week's commitment + completion
CREATE TABLE budget_weeks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  intention_id UUID NOT NULL REFERENCES intentions(id) ON DELETE CASCADE,
  week_start_date DATE NOT NULL,         -- Monday of that week
  target_hours NUMERIC(4,2) NOT NULL,
  completed_hours NUMERIC(4,2) NOT NULL DEFAULT 0,
  closed_at TIMESTAMPTZ,                 -- set Sunday night, or by user-confirmed close
  partner_notified_at TIMESTAMPTZ,
  UNIQUE(account_id, intention_id, week_start_date)
);
```

---

## Open product questions (resolve before implementing)

1. **Auto-suggest algorithm.** How does the system pick suggested slots for a given Intention's weekly target? Heuristics on free time + past patterns? Simple "evenly distribute"? Learning from user accept/modify history?
2. **What's the right "first week" default** when there's no last-week pattern to copy?
3. **Hard ceilings (anti-budgets).** *"Max 2h Twitter per week."* Different mechanic — caps not targets. Does this spec cover both, or split into a sibling spec?
4. **Multi-week budget cycles.** Some goals are monthly (*"20h gym this month"*) or quarterly. Out of scope for v1?
5. **Budget rollover.** If you hit 9h on a 7h Reading budget, does the extra 2h roll forward to next week? Defaults to no.
6. **Notification fatigue.** "Behind-budget" notifications on Strict mode could fire weekly for every budget. Need rate-limiting + smart batching.

---

## When to revisit

The redesign spec must be:
- Shipped to production (both Mac PKG + iPhone TestFlight)
- In use for ≥2 weeks
- No P0/P1 bugs open against it

THEN start brainstorming this spec for real (use `superpowers:brainstorming`, then `writing-plans`, then execute via subagents — same flow as Spec 1 and Spec 2). Until then, this doc is a memory of what we decided so we don't relitigate.
