# Spec 2 Handoff Brief — Time Blocks (synced schedule + auto-fired Sessions)

**Date:** 2026-05-04
**Status:** Handoff brief — other agent owns design + plan + execution
**Successor to:** Spec 1 (`docs/superpowers/specs/2026-05-03-intentions-spec1-design.md`)
**Repos touched:** `intentional-backend`, `intentional-macos-app`, `puck-ios`

---

## TL;DR

Make a single weekly recurring schedule live on the backend. Both Mac and iPhone render it as a calendar, edit it, and auto-fire a Session when a Time Block starts. Nine-AM Monday hits → "Coding" Time Block fires → both devices apply Coding's blocklists for two hours → eleven-AM hits → both devices stop blocking, simultaneously.

That's the whole product promise of Spec 2.

---

## Hard prerequisite — DO NOT START until satisfied

Spec 1 must be deployed and verified before any Spec 2 code lands:

1. Backend `intentions` table exists and `/intentions` CRUD endpoints are live in production.
2. `focus_sessions.intention_id` column exists.
3. Mac client has migrated `projects.json` → backend Intentions and the local `IntentionStore` is reading from backend.
4. iOS client has migrated local `FocusMode.appTokens` → backend Intentions.
5. Cross-device manual Session start works end-to-end (start Coding on Mac → iPhone shields within 5s).

If any of those is incomplete, finish Spec 1 first. Spec 2 blocks reference `intention_id` — if Intentions aren't real on the backend, the foreign key has nothing to point at and the whole design collapses.

Confirm by checking:
```bash
cd /Users/arayan/Documents/GitHub/intentional-backend && \
  git log --oneline | grep -i intention | head -5
cd /Users/arayan/Documents/GitHub/intentional-macos-app && \
  git log --oneline | grep -i intention | head -5
cd /Users/arayan/Documents/GitHub/puck-ios && \
  git log --oneline | grep -i intention | head -5
```

---

## Acceptance criteria (what "working" looks like when Ameer wakes up)

The user-visible promise:

1. **Both devices show the same calendar.** Open the schedule on Mac, see Mon–Fri 9–11am "Coding" block. Open iPhone, see the same block. Edit it on iPhone (drag to 10–12), Mac reflects the change within 60s.
2. **iPhone calendar UX matches addy-ios DayCalendarView.** Long-press 0.5s + drag to move (15-min snap). Top/bottom edge handles to resize. Tap an empty slot to create a new block. Empty schedule = empty calendar grid (no "set up your week" gate).
3. **At 9am Monday, both devices auto-start a "Coding" Session.** Backend fires it. No user tap. Mac's pill turns red, iPhone shields the Coding apps. At 11am, both stop simultaneously.
4. **Switching blocks at the boundary is seamless.** If the schedule has Coding 9–11am and Reading 11am–12pm back-to-back, the Reading Session starts the instant Coding ends. Single active Session at a time per Spec 1.
5. **Generic blocks work without an Intention.** A "Deep Work 2–4pm" block with `intention_id = NULL` fires a generic Session that uses the user's curated default Mac blocklist + the default Intention's iOS apps. (Don't require the user to bind an Intention to every block.)
6. **The Mac calendar UI in `dashboard.html` keeps working but now reads from backend.** Mac no longer writes `daily_schedule.json` for blocks (the file stays on disk for safety, never read again).

If those six are true when Ameer wakes up: ship it.

---

## Pinned product decisions (don't relitigate; if you disagree, document and move on)

| Decision | Choice | Reasoning |
|---|---|---|
| Schedule model | **Recurring weekly** with `active_days` array — drops Mac's today-only one-off | Backend already supports this (existing `schedule_blocks` table). Mac switches to "today's view of recurring weekly template." Matches iPhone. ICP-aligned: user won't manually re-plan every day, but a stable weekly rhythm gets used. |
| Blocks reference Intentions? | `intention_id` column **NULLABLE**, FK→intentions(id) | Generic blocks (no Intention) work using a default blocklist. Bound blocks (with Intention) use that Intention's per-platform blocklists. Optional binding = lower friction for new users. |
| Session firing | **Backend cron tick every 60s** scans for Time Blocks where `start_hour:start_minute` == now and creates a Session via the same internal `_create_focus_session()` path Spec 1 uses | Cross-device authority — neither client decides "now is 9am, fire it." Backend is single source of truth. Reuses Spec 1's Session machinery + APNs push to iPhone. |
| Session ending | Backend cron tick at end-of-block ends the Session. Same APNs broadcast Spec 1 uses for stop. | Symmetric with start. |
| iPhone calendar UI | **Mimic `addy-ai-ios/Views/Home/DayCalendarView.swift`** — long-press-drag, edge-resize, tap-empty-to-create, 15-min snap, 6am–10pm grid, 60pt/hr | Addy-ios component is the explicit reference per Ameer. Don't reinvent. Read that file first; port the interaction model. |
| Per-Intention iOS apps (not per-block) | iPhone shielding for a Time Block uses the bound Intention's `ios_app_tokens` (set in Spec 1). Per-block iOS app blocklists are NOT a thing in Spec 2. | Spec 1 made Intentions own iOS app tokens. Repeating that per-block would duplicate state. |
| Existing iPhone per-block App Group keys (`schedule_block_tokens_<id>`) | **Leave dormant.** Spec 2 doesn't read or write them. They sit on disk doing nothing. | No need for migration; clean sweep can happen later. |
| Mac generic-block default blocklist | If `intention_id IS NULL`, use the seeded "Focus" Intention's `mac_websites` + `mac_bundle_ids` as the fallback | Reuses Spec 1's Day-1 default. |
| `schedule_blocks` table rename | **Rename to `time_blocks`** in a migration. Add `intention_id`, `intensity` enum, `updated_at` keep-alive. | Naming consistency with locked vocab. |
| Endpoint paths | Move `/schedule/blocks` → `/time_blocks` (GET, PUT). Keep `/schedule/blocks` as a redirect for one release cycle so old Mac clients don't break mid-deploy. | Clean naming, soft transition. |
| Goals | **Out of scope.** That's Spec 3. | Spec 2 is just synced schedule + auto-fired sessions. |

---

## Architecture sketch

### Backend changes

**Migration 018 (write a new file, do NOT edit 017):**
- `ALTER TABLE schedule_blocks RENAME TO time_blocks`
- `ALTER TABLE time_blocks ADD COLUMN intention_id UUID NULLABLE REFERENCES intentions(id)`
- `ALTER TABLE time_blocks ADD COLUMN intensity TEXT NOT NULL DEFAULT 'deep_work' CHECK (intensity IN ('deep_work', 'focus_hours'))`
- `ALTER TABLE time_blocks ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`
- `CREATE INDEX idx_time_blocks_account_active ON time_blocks(account_id) WHERE enabled = TRUE`

**Endpoints:**
- `GET /time_blocks` — list all enabled blocks for the account (dual auth)
- `PUT /time_blocks` — atomic-replace (same shape as today's `PUT /schedule/blocks`, max 50 blocks). Body items now include optional `intention_id` + `intensity`.
- Keep `/schedule/blocks` as a 301 redirect to `/time_blocks` for one release.

**Cron scanner (new module — `time_block_scheduler.py`):**
- Tick every 60 seconds (use the same scheduler infra Spec 1 added for APNs maintenance, or `apscheduler` if not present).
- For each account with `enabled` Time Blocks:
  - Find blocks where `current_minute >= start_minute` and `current_minute < (start_minute + 1)` and `today's iso_weekday IN active_days` and `enabled = TRUE`. (One-minute window so the tick can drift slightly.)
  - For each match: call `_create_focus_session(account_id=..., intention_id=block.intention_id, triggered_by='schedule')`. Spec 1's machinery handles APNs broadcast.
- Same logic for end-of-block: find Sessions whose backing Time Block ends at this minute and call `_end_focus_session(reason='schedule_ended')`.
- Idempotency: tag each Session with the originating `time_block_id` + a date stamp. Don't fire twice for the same block on the same day.

**Schema for `focus_sessions` extension:**
- Add `time_block_id UUID NULLABLE REFERENCES time_blocks(id)` so the scheduler can match end events back to the block.
- Add `triggered_by` enum value `'schedule'` to the existing set.

### Mac changes

- `ScheduleManager` rewires from local `daily_schedule.json` to `BackendClient.getTimeBlocks()` + `BackendClient.putTimeBlocks()`. Same atomic-replace semantics as iOS already uses.
- Local `daily_schedule.json` is renamed `daily_schedule.legacy.json` on first launch (kept for safety, never read again).
- `FocusBlock` Swift struct → renamed to `TimeBlock`. Adds `intentionId: UUID?` and `intensity: Intensity` (deep_work / focus_hours). Drops the old `blockType` enum's `.freeTime` case (free time = absence of a block).
- Calendar UI in `dashboard.html` (function `renderCalendar` ~ line 8274 + `renderCalendarBlocks` ~ line 8328): no UI change required, just data source change. Block edits POST to backend immediately (no debounce save bug — write-through).
- `FocusStatePoller` (already polls `/focus/active` every 2s for Spec 1) automatically picks up auto-fired Sessions because they create a `focus_sessions` row the same way manual ones do. **No client-side scheduler needed on Mac.**
- The 10-second `ScheduleManager` timer that watches for block transitions: keep it for UI updates (highlight the current block in the calendar) but it no longer drives enforcement — backend cron does that.
- `DailySchedule` model in Mac code: rename its `dailyPlan: [String]` field to `dayNotes` and `goals: [String]` to `dayItems` to free up "Plan" and "Goal" naming for the Spec 3 layer (per the vocab decision Ameer locked earlier). Search-and-replace; trivial.

### iPhone changes

- `IntentionalBlock` SwiftData model → renamed to `TimeBlock`. Add `intentionId: UUID?` + `intensity: Intensity`.
- `ScheduleBlocksService` → renamed to `TimeBlocksService`. Endpoint URL changes from `/schedule/blocks` to `/time_blocks`. Existing pull/push pattern (60s + foreground + push on edit) is unchanged.
- **New:** `DayCalendarView` Swift component, ported from `/Users/arayan/Documents/GitHub/addy-ai-ios/addy-ai-ios/Views/Home/DayCalendarView.swift`. Read that file first — the interaction model is the spec.
- **New:** Schedule tab restored to the tab bar (the `case schedule` enum entry that was removed earlier). The tab renders `DayCalendarView` bound to the local `TimeBlocksService` blocks for "today's day-of-week" filtered from the recurring weekly template.
- DeviceActivityMonitor extension changes: **NONE** required for Spec 2's auto-fired Sessions. The auto-firing happens server-side via APNs push (Spec 1 infra). The DeviceActivity extension can stay focused on bedtime + the legacy per-block iPhone schedule (which we're leaving dormant).
- Crucially: when an APNs push arrives saying "Session of Intention X started," the existing Spec 1 push handler already applies the right shield. No new code path for "schedule fired this Session" — it looks identical to a manual start from the iPhone's perspective.

---

## Files to read first (orient quickly)

In this order:

1. `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md` — Spec 1, your prerequisite.
2. `intentional-backend/migrations/017_schedule_blocks.sql` — current schedule blocks table you're renaming.
3. `intentional-backend/main.py` — search for `/schedule/blocks` endpoints. Pattern to mirror for `/time_blocks`.
4. `intentional-macos-app/Intentional/ScheduleManager.swift` — Mac's current local-only schedule. You're rewiring this to backend.
5. `intentional-macos-app/Intentional/dashboard.html` lines ~8270–8330 — calendar UI rendering. Confirm no changes needed.
6. `puck-ios/Puck/Core/Schedule/ScheduleBlock.swift` + `ScheduleBlocksService.swift` — iPhone's existing Time Blocks data layer. You're renaming + extending.
7. **`addy-ai-ios/addy-ai-ios/Views/Home/DayCalendarView.swift` — THE reference for the iPhone calendar UI. Read end-to-end. Port the interaction model verbatim.**

---

## Out of scope (don't slip them in)

- Goals (Spec 3).
- Per-block iOS app blocklists (use the Intention's tokens; if no Intention, fallback to default Intention).
- Bedtime Time Blocks (bedtime stays its own subsystem per Spec 1's decision).
- New anti-tamper mechanics for ending auto-fired Sessions early (the optional `requirePartnerToEndSessionEarly` setting from Spec 1 already covers this).
- Mac puck behavior changes (separate decision, deferred).
- A "templates" library of pre-built schedules (nice future feature, not in scope).
- Calendar sync with Google Calendar / iCal (not in scope; this is the in-product schedule only).

---

## Suggested execution order

1. Backend migration 018 + endpoint rename + cron scanner → ship to staging → verify with curl + manually inserted rows.
2. Backend deploy to production.
3. Mac client rewires `ScheduleManager` to backend. Keep the local file fallback for one release cycle so users who haven't upgraded backend client yet don't lose schedules.
4. iOS `TimeBlocksService` + new `DayCalendarView` UI + Schedule tab restored.
5. Cross-device smoke: create block on Mac → see on iPhone within 60s. Set block start time to "now+2min" → both devices auto-fire Session at that time. End time hits → both devices stop.

---

## Notes for the executing agent

- **Don't ask Ameer questions.** All product decisions are pinned above. If you hit a genuine ambiguity, document the decision you made in the cross-repo log and proceed.
- **Spec 1 must be solid first.** If Spec 1 has open issues when you start, fix those before starting Spec 2 work — Spec 2 will surface any Spec 1 bugs immediately and they'll be harder to debug compounded.
- **Cross-repo log convention** (per project CLAUDE.md): write progress to `docs/cross-repo-time-blocks-spec2-2026-05-04.md` in `intentional-macos-app`. Source of truth for the morning hand-off.
- **One Time Block table, one schedule.** No per-device schedules. Account-keyed throughout.
- **Recurring weekly is the model.** No one-off date-specific blocks. (If Ameer ever wants those, that's a Spec 2.5 with an `effective_date` column added; not now.)
