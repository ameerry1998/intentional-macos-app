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

- **Anti-tamper hardening.** The product is currently bypassable in moments of weakness — that's an existential problem but it's a separate strategic design (Perplexity research + its own spec).
- **Budgeted Intentions** (e.g. "7h gym/week", "10h study/week"). Real product question, deserves its own design.
- **Goals layer** (the third spec in the original Intention/Time Block/Session/Goal vocabulary).

If you find yourself designing for those, stop and ask the user.

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
- Add a **"Strictness"** row: 3-segment control (Strict / Standard / Soft). Default: inherit from the bound Intention's preset.
- Block-level strictness can ONLY be HARDER than the bound Intention's preset (e.g. Intention is Standard → block can be Standard or Strict, not Soft). UI greys out the disallowed cells.
- Remove the existing "Block Type" segmented control (Focus / Free Time) — Free Time is now represented by the absence of a block, not a block type. (This was already done in Spec 2 backend; Mac UI cleanup is overdue.)

### Calendar gestures

These are the gaps vs iPhone. All must use 15-min snap on release.

- **Drag-to-create:** mousedown on empty calendar = start point; drag = preview block extending downward; mouseup = creates draft block + opens editor (current `onCalendarHourClick` becomes `onCalendarMouseDown` + handlers).
- **Edge-resize:** existing `.calendar-block-resize.top` / `.bottom` handles (lines ~8382-8385) need verification — make sure they snap to 15 min and respect overlap rules.
- **Block move:** long-press 0.5s on a block = enter move mode; drag relocates with snap; mouseup commits.
- **Visual feedback** during drag: faded preview block at projected position, end-time label updates live.

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
- **Strictness selector per block** — same direction-asymmetric rules as Mac.
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

ALTER TABLE time_blocks
  ADD COLUMN strictness_override TEXT
  CHECK (strictness_override IS NULL OR strictness_override IN ('strict', 'standard', 'soft'));

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
5. **Strictness mismatch between Intention preset and block override:** if Intention is "Standard" and a block overrides to "Strict," and the user later tries to soften the Intention to Soft, what happens to the block's override? Stays Strict? Falls back? Should there even BE block-level override? (Current spec says yes; designer should validate.)
6. **Recurring vs one-off blocks.** Spec 2 only supports weekly recurring. Several real use cases want one-off ("block social tomorrow 9-11am for the launch"). Should this spec add a `effective_date` column / one-off support? Or defer?

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
8. Drag-to-create on Mac calendar — works with 15-min snap.
9. Edit a block's active-days on Mac — toggle Mon/Wed/Fri only — see those days lit up; backend `time_blocks.active_days` updated.
10. The deprecated "Blocking Profiles" tab is gone after migration.

If those 10 are true, ship it.
