# Spec — Scheduled Intentions Redesign (Calendar + Intention Picker + Strictness Presets)

**Date:** 2026-05-03
**Status:** Handoff brief — design + plan owned by the next agent
**Predecessor specs:** Spec 1 (Intentions) + Spec 2 (Time Blocks) — both shipped on `feat/intentions-spec1` + `feat/time-blocks-spec2`. This spec assumes both are merged.

---

## What we're building

Three things, all in service of the original product vision: *"different projects/intentions throughout the day, each blocking different things, scheduled into a synced calendar both Mac and iPhone use."*

1. **Bind Time Blocks to Intentions via a real picker** (currently impossible from Mac).
2. **Make the Mac and iPhone calendars feel like the same product** (they currently don't).
3. **Add a strictness preset to each Intention** so "Coding" can enforce harder than "Email" without inventing new sliders.

---

## Out of scope (deferred to other specs)

- **Anti-tamper hardening.** The product is currently bypassable in moments of weakness — that's an existential problem but it's a separate strategic design (Perplexity research + its own spec at `docs/superpowers/specs/2026-05-03-anti-tamper-strategy-handoff.md`).
- **Budgeted Intentions** (e.g. "7h gym/week", "10h study/week"). Real product question, full design captured at `docs/superpowers/specs/2026-05-03-weekly-budgets-future-spec.md`. **This spec does the SCHEMA + UI prep work** (D9 + D8) so budgets can ship cleanly later, but does NOT implement budget logic, the Sunday ritual, auto-scheduling, or partner-notification-on-behind-budget.
- **Goals layer** (the third spec in the original Intention/Time Block/Session/Goal vocabulary).

If you find yourself designing budget *behavior* (auto-fill, ritual flow, behind-budget enforcement), stop and ask the user. Designing the *placeholder* (sidebar slot, "+ Add weekly target" CTA in Intention editor, empty space in Schedule header) is in scope per D8 + D9.

---

## Locked product decisions (do not relitigate)

| # | Decision | Rationale |
|---|---|---|
| **D1** | The Mac block editor's "Blocking Profiles" chips are **replaced** by a single "Intention" picker. Old profiles get auto-converted to Intentions on first launch (one-shot migration, idempotent receipt). | One concept, not two. The chips were a separate concept that pre-dated Intentions — keeping both creates two ways to define what gets blocked. |
| **D2** | Each device can have its own iPhone-app blocklist per Intention. Mac websites + Mac apps live on Intention; iPhone apps (Apple `FamilyActivitySelection` blob) also live on the same Intention but are populated via on-device picker. | Apple's privacy model literally prevents enumerating iPhone apps from off-device. There is no other path. |
| **D3** | iPhone first-launch onboarding includes a **FamilyActivityPicker step** that populates the seeded "Focus" Intention's iOS app tokens. After onboarding, **a yellow banner appears in the Intentions list** for any Intention with zero iPhone apps. | Otherwise day-1 user taps Start Focus and iPhone blocks nothing — they conclude the cross-device promise is broken. |
| **D4** | Each Intention has a **strictness preset**: `Strict` / `Standard` / `Soft`. Three options, fixed menu, no freeform sliders. | Real life isn't binary. Adds expressivity without inventing new gradient knobs (we already have the underlying mechanisms; this just binds them to Intentions). |
| **D5** | **Strictness preset is direction-locked**. Going harder (Soft → Standard → Strict) is instant. Going softer requires friction: **24h cool-down for Standard → Soft**; **partner-unlock-code for stepping down from Strict** to anything. | Closes the "switch to soft Intention to bypass" escape route. Mirrors the partner-unlock pattern that already works for bedtime. |
| **D6** | The strictness preset **cannot be changed at all while a Session of that Intention is currently running**. | Otherwise the user bypasses mid-session by toggling. Load-bearing. |
| **D7** | Mac and iPhone calendars must support the same set of editable block fields, including **active-days (Mon-Sun mask)**. Mac currently doesn't expose this — it's the worst current asymmetry. | Without active-days editable on both, the recurring-weekly model degrades to "everywhere or nowhere." |
| **D8** | **Sidebar restructure on Mac.** Promote `Sensitive Content` out of Settings into a sidebar item. Add a `Weekly Planning` sidebar item as a placeholder for the deferred budgets feature. Both visible from day one (faded when inactive, full-color when active). | Settings is where features go to die. Both are recurring-engagement features that need findability. Carving the slots NOW is much cheaper than restructuring nav later. |
| **D9** | **Schema prep for budgets.** Even though budgets are deferred to a separate spec, this spec adds a nullable `weekly_budget_hours` column on `intentions` and a nullable `derived_from_budget` boolean on `time_blocks`. Both default NULL/false; no enforcement code yet. Reserves visual space in the Intention edit screen and Schedule header for budget UI to land later. | Forward-compat schema is a one-line migration today; retrofitting it after blocks already exist is migrations + data backfills. Cheap insurance. |
| **D10** | **Strictness is per-Intention ONLY. Drop block-level strictness override entirely.** Block editor (Mac popover + iPhone sheet) does NOT show a strictness control. Editing strictness happens exclusively in the Intentions tab on the Intention itself. | Cleaner mental model: "this Intention is Strict" is one concept; "this Intention is Standard but THIS specific block is Strict" is two concepts. ADHD users don't need another lever per block. If you want a one-off stricter block, create a stricter Intention and bind to it. |
| **D11** | **Bedtime renders as a solid-color band anchored at the BOTTOM of the day calendar; Wake-up as a solid-color band anchored at the TOP.** No gradients on EITHER platform — Mac AND iOS use solid colors. No inset margins. Deep navy for bedtime, warm coral for wake. Visual anchors that don't compete with the rest of the schedule. | The gradient experiment was attempted in Claude Design and reverted; final answer is solid-only across both platforms for consistency. |
| **D12** | **The Intention picker on iPhone replaces "+ Create new Intention" with "+ One-off block."** The one-off path is dramatically simpler: just a single text field ("What is this block for?"). No color, no emoji, no strictness picker, no "what counts as on-task" essay. Inherits Soft strictness by default, neutral grey calendar color. Caption: *"Want to set this up properly? Create an Intention in the Intentions tab."* with link. Full reusable Intention creation lives ONLY in the Intentions tab — never inline in the picker. | A user trying to schedule a doctor's appointment shouldn't have to invent a permanent Intention, pick its color and emoji, and write its on-task description. The picker should help them schedule the moment without taking a detour. |
| **D13** | **Mac calendar gestures (drag-to-create, edge-resize, block-move) are EXPLICITLY DEFERRED to v1.5.** The Mac calendar in this redesign keeps the existing click-to-create-30-min behavior. Gestures get their own follow-up spec after redesign stabilizes. | The redesign is already large; gesture work is a meaningful chunk that doesn't share much code with the rest. Cleaner as its own thing. |
| **D14** | **The deprecated Profiles UI tab on Mac (CRUD for named blocking profiles) is NOT removed in this redesign — only the chips inside the block editor are replaced (per D1).** A follow-up cleanup spec will remove the Profiles tab + dashboard handlers + `BlockingProfileManager` entirely after the redesign is stable for ≥2 weeks. **This cleanup MUST be a section in the next spec written after this one.** | Removing the Profiles UI now risks deleting data while the migration is mid-flight. Keep the data layer for one release; remove the UI entry point but leave the file-based store intact until cleanup. |

---

## What "Strict / Standard / Soft" actually does

These bind to enforcement mechanisms the app already has (see `docs/FOCUS_ENFORCEMENT.md`, `docs/CONTEXT_SWITCHING_OVERLAY.md`, `docs/AI_SCORING.md`). No new mechanisms invented.

| Preset | Mac behavior | iPhone behavior |
|---|---|---|
| **Strict** | Block list applied + AI relevance scoring on every URL + full-screen intervention overlay on bypass attempt + 60-90s mandatory exercise to dismiss + context-switch overlay on app/tab change | App shield applied (existing FamilyControls behavior — no soft variants on iOS). Marked "strict" for parity in UI. |
| **Standard** | Block list applied + nudge banner on bypass attempt (in-pill, ignorable after 8s) + AI scoring optional | App shield applied. Same as Strict on iOS visually but no "you must complete an exercise" friction. |
| **Soft** | Nudge only — sites are NOT actually blocked, but a small "you're off-task" banner appears for 8s. AI scoring off. | App shield NOT applied. Local notification "you opened Twitter during Email" instead. |

iOS has limited gradient room because Apple's shielding is binary. The preset still exists on iPhone for future use and to keep the data model symmetric.

---

## Mac requirements

### Block editor — `dashboard.html` ~line 9108

- **Replace** `editor-profiles-row` (the Blocking Profiles chips) with an `editor-intention-picker` dropdown.
- Dropdown sourced from `IntentionStore` (already exists; pulls from backend `/intentions`).
- Default selection on a new block: the seeded "Focus" Intention if no other Intention is contextually appropriate.
- A "+ Create new Intention" option at the bottom of the dropdown opens a slide-in mini-editor without leaving the block editor.
- Add an **"Active days"** row: 7 toggle pills (M/T/W/T/F/S/S). Default on a new block: `[1,2,3,4,5]` (weekdays only).
- **No Strictness row in the block editor (per D10).** Strictness lives on the Intention itself, edited in the Intentions tab. The block editor shows the bound Intention's current preset as a small read-only caption next to the Intention name (e.g. *"Coding · Standard"*). Tapping the caption deep-links to the Intention's edit screen.
- Remove the existing "Block Type" segmented control (Focus / Free Time) — Free Time is now represented by the absence of a block, not a block type. (This was already done in Spec 2 backend; Mac UI cleanup is overdue.)

### Calendar gestures — **DEFERRED to v1.5 per D13**

Drag-to-create, edge-resize, and block-move are NOT in scope for this redesign. The Mac calendar keeps the existing click-to-create-30-min behavior (the `onCalendarHourClick` flow that already uses the draft pattern fix from `8bcf18b`). Gestures get their own follow-up spec after this redesign stabilizes.

### Optional but recommended

- **Today vs Week view toggle.** Mac currently shows only today's slice. Add a "Week" view (Mon-Sun, 7 columns) so the user can SEE the recurring pattern they've defined. iPhone is single-day-at-a-time which is fine on a phone; Mac has the screen real estate.
- **Strictness lock UI.** When user tries to soften an Intention's preset:
  - Standard → Soft: confirm dialog with copy "This change takes effect in 24 hours" + Cancel / Schedule.
  - Strict → anything: same partner-unlock-code flow that bedtime already uses (existing `BedtimeUnlockRequestSheet` infrastructure — re-use, don't reinvent).
  - During an active Session of this Intention: grey out the strictness control entirely with tooltip "Cannot change while session is running."

---

## iPhone requirements

### First-launch onboarding (D3)

- After auth + permissions, before reaching the home tab, show a step: **"Pick the apps you want to block during focus."**
- Native `FamilyActivityPicker` sheet. User picks. Save tokens to the seeded "Focus" Intention via `IntentionStore.update`.
- Skippable but with a clear "you can do this later from Settings" affordance. If skipped, the in-app banner (D3) handles the catch-up.
- Onboarding step is shown only once (track via UserDefaults `intention_picker_onboarding_shown`).

### Intentions list — banner

- For each Intention in the list, if `iosAppTokens` is null/empty, show an inline banner under the title: *"⚠️ 0 apps blocked on this phone — tap to add."*
- Tap → opens that Intention's edit screen with FamilyActivityPicker auto-presented.

### TimeBlockEditSheet — additions

The sheet exists from Spec 2. Additions:
- **Intention picker** at the top — already in the Spec 2 sheet, verify it's working with the new strictness lock rules (D6).
- **"+ Create Intention" inline option** — same as Mac.
- **No strictness selector in the block sheet (per D10).** Show the bound Intention's preset as a small read-only caption (*"Coding · Standard"*). Tap the caption to deep-link to the Intention's edit screen.
- **Active-days toggles** — already in the Spec 2 sheet. Verify default is `[1-5]` for new blocks.

### DayCalendarView — gesture polish

The view exists from Spec 2 (ported from addy-ai-ios). Polish:
- **Conflict-aware create:** tap-empty-to-create currently doesn't check for overlap before opening the sheet. Add: if the proposed slot collides with another block, snap end-time DOWN to the conflict point or show toast "Slot taken."
- **Snap math verification:** dragging to 9:07 should snap to 9:15 (or 9:00 — define the rule). Test against the spec, write a unit test.
- **Empty-schedule hint** card when zero blocks exist: *"Tap any empty hour to create your first block."*

---

## Shared (both platforms) requirements

- **Intention picker dropdown source-of-truth:** `IntentionStore` (Mac) / `IntentionStore` (iPhone). Already exists from Spec 1.
- **Block-to-Intention binding** persists via the existing `time_blocks.intention_id` column (Spec 2 backend, migration 019).
- **Strictness preset on Intention:** new column on `intentions` table — `strictness_preset` enum `(strict, standard, soft)`. Default `standard`. Backend migration 020 required.
- **Strictness override on block:** new optional column on `time_blocks` — `strictness_override` enum, NULL means "use the Intention's preset." Backend migration 020 also.
- **Cool-down record for softening:** new table `intention_strictness_changes` with `(account_id, intention_id, requested_at, takes_effect_at, from_preset, to_preset)`. Backend cron applies pending changes when `takes_effect_at <= now`.
- **Partner unlock for Strict-step-down:** reuse existing `bedtime_unlock_requests` infrastructure (or create parallel `intention_strictness_unlock_requests` table — preferred for clean separation).

---

## Sidebar restructure (D8)

The Mac dashboard's left sidebar today:

```
Today
Projects     ← rename to "Intentions" (per Spec 1)
Distractions
Accountability
Settings
```

Becomes:

```
Today
Intentions             ← renamed from Projects
Schedule               ← new — surfaces the calendar at top level
Distractions
Sensitive Content      ← promoted from Settings (D8)
Weekly Planning        ← new placeholder (D8) — opens to a "coming soon" view
Accountability
Settings
```

8 items total. Both new items render in the sidebar from day one. Sensitive Content uses the existing Settings page logic (just relocated). Weekly Planning is a placeholder page that says something like *"Plan your week — coming soon. Set weekly targets on each Intention to enable."* — with an active link back to Intentions.

When budgets ship in the future spec, the Weekly Planning page is filled in without nav changes.

iPhone tab bar stays as: `Home / Plan / Partner / Settings`. The sidebar restructure is Mac-specific because Mac has more nav real estate.

---

## Budget prep work (D9)

These changes ship in THIS spec, but no budget *behavior* runs yet. They're seeds.

### Backend migration 020 (extended)

Add to the migration already planned for D5/D6 (strictness preset + override + cool-down table):

```sql
-- D9: nullable fields for future budgets work. No backfill, no enforcement.
ALTER TABLE intentions
  ADD COLUMN weekly_budget_hours NUMERIC(4,2);  -- e.g. 7.0 for "7h/week"

ALTER TABLE intentions
  ADD COLUMN budget_enforcement TEXT
  CHECK (budget_enforcement IS NULL OR budget_enforcement IN ('track', 'nudge', 'auto_schedule', 'strict'));

ALTER TABLE time_blocks
  ADD COLUMN derived_from_budget BOOLEAN NOT NULL DEFAULT FALSE;
```

`weekly_budget_hours` NULL = "no budget set on this intention." `budget_enforcement` NULL = same. `derived_from_budget` defaults FALSE for all today's blocks; future budget logic flips it TRUE on auto-scheduled blocks.

### Mac UI prep

- **Intention edit screen:** at the bottom of the screen, add a section header "Weekly target" with a single row: *"+ Add weekly target (coming soon)"* — disabled, greyed, has a tooltip "Weekly budgets coming in a future update." Reserves visual space.
- **Schedule header:** above the Day/Week toggle, reserve a horizontal row that's empty today. Future budget pills will render here. Empty row collapses to 0 height when no budgets exist (which is always, today).
- **Weekly Planning sidebar page:** a placeholder view per the sidebar restructure section above.

### iPhone UI prep

- **Intention edit screen:** same "+ Add weekly target (coming soon)" disabled section at bottom.
- **Schedule header:** same reserved horizontal row, empty today.

### What is NOT included in this spec

- The Sunday-night ritual notification scheduling
- Auto-scheduling algorithm
- Behind-budget partner notification
- Budget enforcement modes (track / nudge / auto-schedule / strict)
- The weekly recap view, sparklines, history
- Day/time configurability of the ritual
- Any onboarding step related to budgets

All of those live in `docs/superpowers/specs/2026-05-03-weekly-budgets-future-spec.md`. This spec just makes sure that when they ship, the schema and visual containers already exist — no painful retrofit.

---

## Migration

### Mac one-shot: BlockingProfile → Intention

On first launch after this ships:
1. Read all `BlockingProfile` rows from `BlockingProfileManager.profiles`.
2. For each profile that's referenced by ≥1 existing block, create or merge into a backend Intention with the same name. Merge blocklist by set-union.
3. For each block that has `profileIds: [UUID]`, look up the Intention(s) those profiles became, and set `intentionId` to the first match (or merge into a new Intention if multiple).
4. Stamp receipt at `~/Library/Application Support/Intentional/migration_profiles_to_intentions_v1.json`.
5. After migration, the Profiles dashboard tab is hidden (but the data stays on disk for one release as safety net).

### Backend migration 020

```sql
ALTER TABLE intentions
  ADD COLUMN strictness_preset TEXT NOT NULL DEFAULT 'standard'
  CHECK (strictness_preset IN ('strict', 'standard', 'soft'));

-- D10: per-block strictness override REMOVED from spec. Strictness lives only
-- on the Intention. If users want a one-off stricter block, they create a
-- separate Intention with the desired preset and bind to it.

CREATE TABLE intention_strictness_changes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  intention_id UUID NOT NULL REFERENCES intentions(id) ON DELETE CASCADE,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  takes_effect_at TIMESTAMPTZ NOT NULL,
  from_preset TEXT NOT NULL,
  to_preset TEXT NOT NULL,
  applied_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ
);

CREATE INDEX idx_strictness_changes_pending
  ON intention_strictness_changes(takes_effect_at)
  WHERE applied_at IS NULL AND cancelled_at IS NULL;
```

Cron tick (in `time_block_scheduler.py` or a sibling file) applies pending changes when their time hits.

---

## Open product questions for the design phase

These are real decisions where I'd want the designer to come back with options before locking:

1. **Where exactly does the Intention picker live in the iPhone block editor?** Top of the sheet (most visible) or bottom (under time pickers)? Does the rest of the sheet adapt based on Intention selection?
2. **What does the "+ Create new Intention" inline flow look like?** Modal sheet on top of the block editor? Or full-screen replace?
3. **What does the Mac strictness lock UI look like in the dropdown vs the dialog?** Does the user even see "this change requires partner unlock" before they tap?
4. **What's the empty-state for the Intentions list on iPhone before the user has run onboarding?** Show the seeded "Focus" with the banner, or hide everything until onboarding completes?
5. **Recurring vs one-off blocks.** Spec 2 only supports weekly recurring. Several real use cases want one-off ("block social tomorrow 9-11am for the launch"). Should this spec add a `effective_date` column / one-off support? Or defer?

---

## Reference docs (read before starting)

- `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md` — what an Intention IS
- `docs/superpowers/specs/2026-05-04-time-blocks-spec2-handoff.md` — what a Time Block IS
- `docs/CALENDAR_BLOCK_RULES.md` — past/active/future editing rules
- `docs/FOCUS_ENFORCEMENT.md` — what the underlying enforcement mechanisms actually do (informs Strict/Standard/Soft binding)
- `docs/CONTEXT_SWITCHING_OVERLAY.md` — what the overlay looks like (Strict mode uses it)
- `docs/AI_SCORING.md` — relevance scorer (Strict mode includes it)
- `Puck/Views/Schedule/DayCalendarView.swift` (puck-ios) + `addy-ai-ios/Views/Home/DayCalendarView.swift` — iPhone calendar reference
- `Intentional/dashboard.html` lines ~9108-9220 — current Mac block editor (where the picker lives now)

---

## Acceptance criteria

A user can:

1. Open the Mac block editor, pick an Intention from a dropdown, save the block, see it bound on iPhone within 60s.
2. Create an Intention with strictness "Strict" — that Intention enforces with overlay + AI scoring + intervention exercise.
3. Try to soften that Intention to "Soft" — the system requires a partner unlock code (because it's stepping down from Strict).
4. Try to soften a different Intention from Standard to Soft — the change is queued and takes effect 24h later (with a "scheduled" banner shown until then).
5. Try to change preset during an active Session — the control is greyed out with the lock reason.
6. Open the iPhone first time — see a FamilyActivityPicker step in onboarding. Pick apps. They populate the seeded Focus Intention.
7. Create a new Intention on iPhone without picking apps — see a yellow "0 apps blocked" banner on it in the list.
8. ~~Drag-to-create on Mac calendar — works with 15-min snap.~~ **DEFERRED to v1.5 per D13.** Mac calendar keeps existing click-to-create-30-min behavior.
9. Edit a block's active-days on Mac — toggle Mon/Wed/Fri only — see those days lit up; backend `time_blocks.active_days` updated.
10. The deprecated "Blocking Profiles" tab is gone after migration.
11. Mac sidebar shows the new structure — `Sensitive Content` is reachable from sidebar (not buried in Settings); `Weekly Planning` exists as a placeholder page that gracefully says "coming soon."
12. Backend migration 020 has applied successfully — `intentions.weekly_budget_hours`, `intentions.budget_enforcement`, and `time_blocks.derived_from_budget` columns exist and are NULL/false for all existing rows. No behavior change visible to users yet.
13. Both clients show "+ Add weekly target (coming soon)" greyed out at the bottom of the Intention edit screen — reserving the visual slot.

If those 13 are true, ship it. The two extra items (#11–13) are explicit budget-prep — they don't add user-facing budget features but they let the future budget spec ship without nav restructures or schema migrations.
