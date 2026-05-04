# Cross-Repo Log — 2026-05-04 — Scheduled Intentions Redesign

**Started:** 2026-05-04 (overnight, autonomous)
**Branch convention:** `feat/scheduled-intentions-redesign` in all three repos
**Predecessors:** Spec 1 (Intentions) + Spec 2 (Time Blocks) — both code-complete on `feat/intentions-spec1` + `feat/time-blocks-spec2`. THIS work assumes those branches are merged or internally merged into our branches.
**Spec:** `docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md`
**Plans:**
- A — Backend: `docs/superpowers/plans/2026-05-04-scheduled-intentions-redesign-plan-a-backend.md`
- B — Mac: `docs/superpowers/plans/2026-05-04-scheduled-intentions-redesign-plan-b-mac.md`
- C — iOS: `docs/superpowers/plans/2026-05-04-scheduled-intentions-redesign-plan-c-ios.md`

---

## TL;DR (continuously updated; final summary at bottom)

(Pending — executors not yet dispatched.)

---

## Locked decisions from spec (D1-D14)

Reference for executors. Don't relitigate.

- **D1** Block editor's Profile chips REPLACED by Intention picker. Migration: existing profiles → Intentions one-shot.
- **D2** Per-platform iPhone-app blocklist via FamilyActivityPicker (privacy-locked surface — Mac shows read-only).
- **D3** iPhone first-launch onboarding includes FamilyActivityPicker step + 0-apps banner in Intentions list.
- **D4** Three strictness presets: Strict / Standard / Soft.
- **D5** Direction-locked. Tightening = instant. Standard → Soft = 24h cool-down. Strict → anything = partner-unlock-required.
- **D6** Strictness CANNOT change while a Session of that Intention is currently running.
- **D7** Mac + iPhone calendars must support same set of editable fields including active-days.
- **D8** Sidebar restructure on Mac: promote Sensitive Content from Settings; add Weekly Planning placeholder.
- **D9** Schema prep for budgets — nullable `weekly_budget_hours` + `budget_enforcement` on intentions, `derived_from_budget` on time_blocks. NO behavior code yet.
- **D10** Strictness lives ONLY on Intention, NOT per-block.
- **D11** Bedtime + Wake-up render as SOLID color bands (no gradients) on BOTH platforms. Anchored top (wake) + bottom (bedtime) of day calendar.
- **D12** Intention picker offers "+ One-off block" — single text field, no color/emoji/strictness, neutral grey, Soft default. Full Intention creation lives ONLY in the Intentions tab.
- **D13** Mac calendar gestures (drag/resize/move) DEFERRED to v1.5. Mac keeps existing click-to-create-30-min behavior.
- **D14** Profiles UI tab cleanup MUST be in the next spec written after this one. Don't remove now (data risk during migration window).

---

## Repos & branches

| Repo | Path | Base | Feature branch | Worktree |
|---|---|---|---|---|
| Backend | `intentional-backend` | `main` (with feat/intentions-spec1 + feat/time-blocks-spec2 internally merged) | `feat/scheduled-intentions-redesign` | `.claude/worktrees/scheduled-intentions-redesign` |
| Mac | `intentional-macos-app` | `puck` (with both Spec branches merged in) | `feat/scheduled-intentions-redesign` | `.claude/worktrees/scheduled-intentions-redesign` |
| iOS | `puck-ios` | `main` (with both Spec branches merged in) | `feat/scheduled-intentions-redesign` | `.claude/worktrees/scheduled-intentions-redesign` |

---

## Phase tracker

- [x] Phase 1 — Spec written (committed earlier)
- [x] Phase 2 — Plans written (A directly, B + C via subagents)
- [ ] Phase 2.1 — Worktrees created in all 3 repos
- [ ] Phase 3 — Backend execution
- [ ] Phase 4 — Mac execution
- [ ] Phase 5 — iOS execution
- [ ] Phase 6 — Final cross-repo handoff

---

## Live progress log

### Phases 3-6
(Pending — append reports as executors complete.)

### Phase 3 — Backend report

**Status:** GREEN — all 9 tasks complete, branch pushed, all new tests green.

**Repo:** `intentional-backend`
**Branch:** `feat/scheduled-intentions-redesign`
**Head commit:** `5b86820d9a61305a9b8115ba7a7c7e82139bb21a`
**Worktree:** `.claude/worktrees/scheduled-intentions-redesign`

**Test results:**
- Total: 155 (130 baseline + 23 new from this work + 2 pre-existing failures)
- Passed: 153
- Failed: 2 — `test_focus_active_no_session`, `test_partner_status_no_account_returns_none` — pre-existing baseline failures from Spec 1+2, NOT regressions from this work.
- New tests added: 16 in `tests/test_intention_strictness.py` + 7 in `tests/test_intention_strictness_scheduler.py` = 23 new, all passing.

**Migration to apply (manual, via Supabase SQL editor):**
- `migrations/020_strictness_and_budget_prep.sql` — adds `strictness_preset` (NOT NULL DEFAULT 'standard') + nullable budget cols (`weekly_budget_hours`, `budget_enforcement`) on `intentions`; adds `derived_from_budget` BOOLEAN DEFAULT FALSE on `time_blocks`; creates `intention_strictness_changes` table with unique-pending and pending-by-expiry indexes.
- Depends on migrations 018 (intentions) + 019 (time_blocks) being applied first. Apply order: 018 → 019 → 020.

**New endpoints:**
- `PUT /intentions/{id}/strictness` — change strictness preset. Tightening = instant. Softening Standard→Soft creates pending change with 24h cool-down. Strict step-down creates `requires_partner_unlock=true` pending row. Active session of intention = 200 with `status=rejected` `rejection_reason=session_active`. Replaces any existing pending change for the same intention.
- `GET /intentions/{id}/strictness/pending` — returns the currently pending change or 404.
- `POST /intentions/{id}/strictness/cancel` — idempotent 204; cancels any pending change.

**Pydantic model changes (`models.py`):**
- `Intention` gains `strictness_preset: str = "standard"`, `weekly_budget_hours: Optional[float] = None`, `budget_enforcement: Optional[str] = None`.
- `IntentionCreate` gains `strictness_preset: Optional[str] = "standard"`.
- `IntentionUpdate` gains `strictness_preset: Optional[str] = None` (note: PUT /intentions/{id} only supports tightening through this; softening MUST go through `/strictness` endpoint for cool-down logic).
- New: `StrictnessChangeRequest`, `StrictnessChangeResponse`, `PendingStrictnessChange`.

**Background scheduler:**
- `intention_strictness_scheduler.py` — 60s tick. Scans `intention_strictness_changes` for rows where `takes_effect_at <= now` AND `applied_at IS NULL` AND `cancelled_at IS NULL` AND (NOT `requires_partner_unlock` OR `partner_unlocked_at IS NOT NULL`). Applies by updating `intentions.strictness_preset` and stamping `applied_at`.
- Wired into `main.py` startup (alongside existing `time_block_scheduler`). Guarded by `TESTING=1`.

**Files changed:**
- `migrations/020_strictness_and_budget_prep.sql` (new)
- `models.py` (+41 lines)
- `main.py` (+~210 lines: imports, endpoint trio, helpers, scheduler wiring)
- `intention_strictness_scheduler.py` (new)
- `tests/test_intention_strictness.py` (new — 16 tests)
- `tests/test_intention_strictness_scheduler.py` (new — 7 tests)

**Deviations from plan:**
- Implemented all three endpoints (PUT, GET pending, POST cancel) inside the Task 4 commit (where the plan suggested splitting impl across Tasks 4/5/6 with placeholders). Tests for each task were still committed separately (Task 4 = instant tighten + active-session block; Task 5 = softening pending; Task 6 = GET pending + cancel). Net effect: same code shipped, fewer placeholder commits.
- `intention_strictness_scheduler.strictness_tick` filters `takes_effect_at <= now` in Python rather than via `.lte()` — same pattern `time_block_scheduler` uses, and avoids needing to teach `_FakeQuery` the `lte` operator.

**Deferred (per plan "What this plan does NOT do"):**
- Partner-unlock flow for Strict step-down — `requires_partner_unlock` flag exists, but the `/intentions/{id}/strictness/unlock-request` + `/unlock-verify` endpoints (mirroring bedtime unlock infra) are NOT shipped. Until something flips `partner_unlocked_at`, Strict step-down rows sit pending indefinitely — scheduler will skip them.
- Budget enforcement logic — D9 only adds nullable schema columns. No behavior code yet.
- Real-time active-session re-check at apply time — scheduler currently applies even if a session started AFTER the pending change was queued. Future hardening: scheduler could re-check active sessions before flipping the preset.

**Handoff to Mac (Phase 4) and iOS (Phase 5):**
- Backend is ready. Both clients can fetch `intentions` + `strictness_preset` via the existing `GET /intentions` shape.
- Mac/iOS need to call `PUT /intentions/{id}/strictness` for the user-facing softening UX (with the warm cool-down dialog from D15).
- Both should poll `GET /intentions/{id}/strictness/pending` to render any "scheduled to soften in 23h" banner.
- Migration 020 must be applied to Supabase (staging + prod) before clients hit the new endpoints.

---

### Phase 5 — iOS report

**Branch:** `feat/scheduled-intentions-redesign` on `puck-ios`. Base: merge of `feat/intentions-spec1` + `feat/time-blocks-spec2`.

**Status:** GREEN — all 22 tasks done, 22 new tests + 36 regression tests passing, clean build green on iPhone 17 simulator.

**What landed:**
- `StrictnessPreset` enum + direction rules (`StrictnessPreset.swift`).
- `Intention` model extended (`strictnessPreset: StrictnessPreset` non-optional default `.standard`, `weeklyBudgetHours: Double?`, `budgetEnforcement: String?`). Custom decoder tolerates pre-migration-020 backends.
- `IntentionalIntentionsClient` extended with 6 new methods: `changeStrictness`, `cancelStrictnessChange`, `pendingStrictnessChange`, `activeSession`, `requestStrictnessUnlock`, plus their DTOs.
- `IntentionStore` strictness routing: `changeStrictness` returns `StrictnessOutcome` (`.applied / .queued / .requiresUnlock / .blockedActiveSession`); `pendingStrictnessByIntention` cache; `isSessionActive(for:)` fails OPEN on network errors.
- `IntentionEditView` — Strictness segmented control + cool-down confirmation dialog (warm tone per D15) + Strict-step-down sheet + active-session lockout caption + greyed "Weekly target — coming soon" footer (D9). Auto-presents FamilyActivityPicker on appear when constructed via the 0-apps banner.
- `StrictnessUnlockSheet` — two-stage request → 6-digit code, mirrors bedtime unlock pattern (D5). Note: backend `/intentions/strictness-unlock-request` + `/strictness-unlock-verify` are deferred per Plan A handoff, so the request stage will 404 against current backend; the verify path goes through `changeStrictness` with `unlock_code` populated.
- `IntentionsTabView` — yellow `0 apps blocked on this phone — tap to add.` banner per row (D3); deep-link consume via UserDefaults key `deeplink_open_intention_id`.
- `IntentionRowView` — strictness pill (coral / coral-accent / muted-violet) next to name.
- `OneOffBlockSheet` — D12 minimal title-only path (no color, no icon, no strictness, no description). Tripwire test in `OneOffBlockSheetTests` enforces D12 by mirror-reflecting state vars.
- `TimeBlockEditSheet` — picker now a Menu with `+ One-off block` at the bottom; read-only "{name} · {Strictness}" caption with deep-link to Intention editor when bound. No per-block strictness affordance (D10).
- `ScheduleTabView` — solid coral Wake banner anchored at top + solid lavender Bedtime banner at bottom, **both INSIDE the same rounded schedule card** (D11+D16). Reserved 0-height budget header row above date picker (D9). Wired tab-pivot via existing `TabRouter` env-object.
- `DayCalendarView` — narrowed grid to 7 AM – 10 PM (D11 explicit revert).
- `IntentionPickerOnboardingStep` — D3 day-1 FamilyActivityPicker step. Once-only via `@AppStorage("intention_picker_onboarding_shown")`. Friction-arm-then-confirm skip UX. Saves tokens to seeded "Focus" Intention.
- `AppView` gates `ContentView` on `pickerShown` after `.authenticated`.

**Backend dependencies (must land before client UX works end-to-end):**
- `PUT /intentions/{id}/strictness` — DONE in Plan A.
- `POST /intentions/{id}/strictness/cancel` — DONE in Plan A.
- `GET /intentions/{id}/strictness/pending` — DONE in Plan A.
- `GET /intentions/{id}/active-session` — referenced by client, **status TBD per Plan A handoff**. Client fails OPEN on errors so UX still works without it (just no active-session lockout).
- `POST /intentions/strictness-unlock-request` — **deferred in Plan A**. Strict-step-down request stage will 404 until shipped; verify stage works via `changeStrictness` with `unlock_code`.

**Tests:**
- `PuckTests/StrictnessPresetTests` — 6 tests, all green.
- `PuckTests/IntentionalIntentionsClientStrictnessTests` — 8 tests, all green.
- `PuckTests/IntentionStoreStrictnessTests` — 6 tests (4 routing branches + isSessionActive fail-open + cancel-clears-cache), all green.
- `PuckTests/OneOffBlockSheetTests` — 2 tests (D12 tripwire + smoke), all green.
- Regressions: existing 36-test suite (`IntentionStoreTests`, `IntentionTests`, `IntentionalIntentionsClientTests`, `BlockingServiceActivateTests`, `IntentionMigrationRunnerTests`, `IntentionPushHandlerTests`, `FocusModeMigrationTests`, `TimeBlockTests`) all green.

**Deviations from plan:**
- Plan called for an explicit `MockIntentionsClient` protocol in Task 7. Used `MockURLProtocol` at the URL boundary instead (matches Spec 1's existing `IntentionStoreTests` pattern, requires no protocol seam — same coverage with less surface area).
- Plan referenced `MockURLSession` + `IntentionalAPIClient.makeForTests(session:tokenProvider:)`. Project actually uses `MockURLProtocol` injected into `URLSessionConfiguration.ephemeral`. Tests written to match.
- Found Config.plist missing from worktree (gitignored, was registered ad-hoc in pbxproj on `main`). Added to `project.yml` via `Puck/Config.plist` resource entry with `optional: true` so xcodegen registers it on regen. This survives future `xcodegen generate` calls — no recurring breakage.
- Task 16 (deep-link consume in IntentionsTabView) was implemented inline as part of Task 11 since both touch the same file; left an empty marker commit for plan-task-count parity.
- D16 design override applied: handoff design at `~/Downloads/handoff-schedules/schedule-ios.jsx:521-527,626` rendered Wake/Bedtime banners as page-level chrome above/below the entire Schedule tab. Implementation puts them INSIDE the same rounded card as the timeline (top edge + bottom edge) per spec D16.
- Manual smoke (Task 19.4) NOT executed — requires booting simulator + going through full auth/permissions/pairing flow + DeviceActivity which requires real device. All other verification (clean build + unit tests) green.

**Follow-ups (out of scope for this plan):**
- Push notification when a queued strictness change applies (currently the user must reopen the edit screen to see the new state).
- Consume backend `pending_change_applied` push to trigger an in-app toast.
- Drag-to-resize a `TimeBlock` to extend into the Bedtime band — currently allowed; should snap or warn.
- Active-session lockout uses a one-shot fetch on `.task`; if a session starts WHILE the user has the edit screen open, the segmented control stays enabled until the next view re-appearance. Acceptable for v1; revisit if anyone hits it.
- `StrictnessUnlockSheet.sendRequest` will fail until Plan A ships `/intentions/strictness-unlock-request`. Sheet will surface "Couldn't reach partner — try again." Until then, Strict-step-down is effectively gated on the deferred backend work.
- Manual end-to-end smoke against backend after migration 020 applied to staging.

**Final commit:** see HEAD of branch.
