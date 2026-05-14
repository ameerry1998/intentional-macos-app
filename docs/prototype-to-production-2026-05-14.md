# Prototype → Production Diff Brief

**Date:** 2026-05-14
**Source of truth:** `docs/unified-design-2026-05-13/app.html` (the canonical interactive prototype)
**Target surfaces:** `Intentional/` (macOS app), `~/Documents/GitHub/intentional-backend/` (backend), `~/Documents/GitHub/puck-ios/` (iPhone, mostly read-only in this scope)

This brief is the input for a planning subagent. It captures every meaningful change made to the prototype during the May 2026 redesign sprint and is intended to be paired with a plan written in `docs/superpowers/plans/2026-05-14-*.md`.

---

## Decisions locked in (from 2026-05-14 brainstorm)

1. **Weekly Goals = Intentions, renamed.** Existing `intentions` table + `IntentionStore` + bridge messages keep working. Add the new fields below. Migration: rename column where it appears in the dashboard / bridge payloads / settings copy. Server table can stay `intentions` — Mac and dashboard just label as "Weekly Goal" in copy. No wholesale rebuild.
2. **Monthly Goals are a new top-level model.** New `monthly_goals` table on backend, new `MonthlyGoalStore` on Mac, new endpoints. `weekly_goal.linksTo` is FK → `monthly_goal.id` (nullable; goals can be "unlinked"). Plan tab shows the hierarchy.
3. **Plan tab is the Cloud Design React app, embedded verbatim in `dashboard.html` via WKWebView.** Same React bundle that's already inline in `app.html`. No SwiftUI rewrite.
4. **Focus Modes tab is removed.** The full-page Weekly Goal editor (reachable from Today + Plan cards) replaces it. The "Focus Mode" concept on the prototype was already redundant with Weekly Goals.
5. **Wake / Alarm category has no new Mac surface.** Existing `BedtimeLockLoop` (SACLockScreenImmediate every 10s) already covers it. iPhone owns the alarm trigger.

---

## What changed in the prototype that needs to land in production

### A. Sidebar restructure
**Before (current Mac dashboard):** flat list of tabs, no bottom-left status pill.
**After (prototype):**
- Order: Today → Plan → Sensitive Content → Accountability → Settings
- (Focus Modes removed, as decided above)
- Bottom-left of sidebar shows **active blocking pill** (e.g. "3 blocking" with chevron expand)
- **Theme toggle** at the very bottom (Dark / Light)
- App-wide light/dark theme via `body[data-theme="light"]`

### B. Today page
**Before:** the existing dashboard Today view.
**After (prototype):**
- **Header strip** of 3 weekly goal cards — each card shows title, outcome, status pill ("in progress" / "planned" / "unlinked"), hours-done count, and a small `⋮⋮` grip in the bottom-right.
- The card body **opens the Weekly Goal full-page editor** (`openWeeklyGoalEdit`) on click.
- The grip is **draggable to the schedule** (drop on an hour row → creates a session bound to that goal).
- Below the cards: the existing today's schedule (calendar with current block + dropped sessions visible).
- Calendar drop-target hover state (`drop-hover` + `drop-target` classes).

### C. Plan tab (Cloud Design React app)
The full React component lives at lines ~2268–2660 of `app.html`. Key features:
- **Week selector with history dropdown** — shows current week + previous weeks (`apr20`, `apr27`, `may4`, `may11`).
- **Monthly cards row** — 3 cards (Ship Puck / 4hr deep work / 10k followers). Click to select, weekly cards below highlight.
- **Weekly cards row** — same structure as Today, but shows historical data for past weeks.
- **Timeline strip** ("Today · Wednesday") — drag a weekly card onto an hour, hover to expand, click to open `TimelineBlock` (drag/resize sessions).
- **"Open today →"** link to switch back to Today tab.

The React code uses React + Babel CDN + inline JSX. CSS scoped under `.cd-plan`.

### D. Weekly Goal full-page editor (NEW — replaces the Focus Mode modal)
Renders into `#goal-edit-mount` inside `view-goal-edit`. Fields:

| Field | Type | Notes |
|-------|------|-------|
| Title | inline-editable input | "click to rename" pattern |
| **What are you working on?** | textarea, 140 char max | Used only if AI scoring is on. Drives relevance scoring. |
| AI scoring toggle | bool | Per-goal toggle |
| Custom rules drilldown | sub-page | Block list + Allow list (per goal) |
| Outcome (done looks like) | textarea | Goal-specific, not in old Intention model |
| Status | enum pills | `in-progress` / `planned` / `done` |
| For monthly goal | link to monthly_goal | FK |
| Strictness | enum pills | `standard` / `strict` (Soft removed per spec series) |
| Weekly target | int | hours / week |
| Delete | action | confirms |

**Sub-page: Custom Rules** — same full-page treatment. Shows BLOCK + ALLOW sections with input rows + Site/App buttons + entry list with × remove.

### E. Block-conflict warning (DISCUSSED, NOT YET IMPLEMENTED in prototype)
When user adds a site/app to a Weekly Goal's **Allow** list AND that same site/app is blocked by a globally-active Time Block, warn the user inline: *"Heads up: instagram.com is blocked 9–5 by your 'Block social media' block. Adding it here will override that during this goal's sessions."* — spec'd in the prototype's notes but the popup itself isn't built.

### F. Sensitive Content tab (placeholder)
Prototype recreated the actual app's page. **No new product behavior** — but the page is currently a thin shell. Not a priority for v1 ship.

### G. Accountability tab (placeholder)
Partner pairing, code/email approvals. Already exists in production. Sidebar slot kept.

### H. Settings (drilldown restructure)
11 settings sub-pages with a unified drilldown pattern (index → subpage with `‹ Settings` back link). Sub-page IDs: `focus-mode`, `always-blocked`, `enforcement`, `account`, `theme`, `ai`, `content-safety`, `distractions`, `budget`, `bedtime`, `browsers`.

### I. Task creation overlay
Click an empty hour on the calendar → opens "New session" overlay with collapsible optional sections (Done-looks-like, Goal link, Auto-activate blocks, AI scoring).

---

## What's already shipping / no work needed

- **Bedtime lock loop** (`BedtimeLockLoop.swift` + `SACLockScreenImmediate`) — Wake/Alarm category is covered. No new Mac surface.
- **Strictness + pending-change cool-down + partner unlock** — backend endpoints partially deployed (see CLAUDE.md known fix #14 — partner-unlock endpoints DEFERRED). The new Weekly Goal editor needs the same wiring as the Intention strictness editor.
- **`IntentionStore`** — already pulls on launch / foreground / 60s timer, cache at `intentions.json`. Renaming to "Weekly Goal" in copy is the only change here.
- **`/focus/active` polling** — keep as-is. Session state still flows through this.

---

## Out of scope for this plan / deferred

- Sensitive Content full redesign (still placeholder)
- Block-conflict warning popup
- Calendar drag-to-create + edge-resize + move gestures (already deferred to v1.5 per CLAUDE.md #14)
- Native SwiftUI rewrite of Plan tab
- Monthly goal history beyond the current week's links
- Cross-week goal carry-over UI

---

## Open questions for the planning subagent to surface

1. **Migration path for existing Intentions data:** add the new fields with defaults? Backfill `weeklyTarget` and `outcome` from what data?
2. **Monthly Goals — when does a new month start?** Calendar month or rolling 30-day? UI for creating a new monthly goal?
3. **Drag-to-schedule from Plan tab into Today:** does it create a session for *today*, or does it ask the user which day?
4. **Goal → session binding semantics:** if a session is bound to a Weekly Goal, do we hard-block the user from running it outside that goal's strictness settings? Or just preferred-blocking?
5. **Backend endpoints to add or extend** — full list (suggested):
   - `GET/POST/PUT/DELETE /weekly_goals` (already exists as `/intentions`)
   - `GET/POST/PUT/DELETE /monthly_goals` (NEW)
   - `PUT /weekly_goals/{id}/links_to` — set/clear monthly goal FK
   - `GET /weekly_goals?week=YYYY-MM-DD` — filter by week
   - `GET /monthly_goals?month=YYYY-MM` — filter by month
6. **Dashboard bridge messages to add:**
   - `GET_MONTHLY_GOALS`, `CREATE_MONTHLY_GOAL`, `UPDATE_MONTHLY_GOAL`, `DELETE_MONTHLY_GOAL`
   - `LINK_WEEKLY_TO_MONTHLY`
   - `START_GOAL_SESSION` (with optional `monthly_goal_id` for analytics)
7. **Cross-device sync:** monthly goals follow the same WS/polling pattern as Intentions?
8. **Schema-cutting strategy:** ship monthly goals behind a feature flag, or unconditional?

---

## Files for the planning agent to read

- `docs/unified-design-2026-05-13/app.html` (the prototype — single source of truth for visuals + interactions)
- `Intentional/IntentionStore.swift` + `Intentional/MainWindow.swift` (current Intention model + bridge handlers)
- `Intentional/dashboard.html` (current dashboard UI to be modified)
- `Intentional/AppDelegate.swift` (initialization order, callback wiring)
- `~/Documents/GitHub/intentional-backend/app/api/intentions.py` (or equivalent — current endpoints)
- `~/Documents/GitHub/intentional-backend/migrations/` (existing schema for context)
- `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md` (the existing Intentions spec — most of this plan extends it)
- `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-b-mac.md` (existing Mac plan — extend, don't rewrite)
- `docs/superpowers/plans/2026-05-04-scheduled-intentions-redesign-plan-b-mac.md` (May 2026 redesign — most recent work, builds on it)
- `CLAUDE.md` (architecture rules, especially the May 2026 sections + #14)
- `MEMORY.md` and the linked memory files for accumulated context

---

## Format expectation for the resulting plan

Follow `superpowers:writing-plans` conventions:
- File at `docs/superpowers/plans/2026-05-14-prototype-to-production-<surface>.md`
- Split into per-surface plans (backend / Mac / dashboard-bundle) if scope warrants
- Each phase scoped to a slice that can be merged independently
- Each task has acceptance criteria + a clear DOR/DOD
- Explicit "What this plan does NOT do" section
- Migration / rollback considerations called out
