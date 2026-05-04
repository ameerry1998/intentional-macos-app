# Spec 1 — Intentions as a Cross-Device Synced Entity

**Date:** 2026-05-03
**Status:** Design (awaiting implementation plan)
**Repos touched:** `intentional-backend`, `intentional-macos-app`, `puck-ios`
**Successor specs:** Spec 2 — Time Blocks (synced schedule + auto-fired Sessions); Spec 3 — Goals.

---

## Vocabulary (locked)

| Term | Meaning |
|---|---|
| **Intention** | A reusable, named bundle of "what to block" + a stated purpose. Lives at account scope. The thing you choose when you focus. |
| **Time Block** | A scheduled time window during which an Intention runs. *(Spec 2 — out of scope here.)* |
| **Session** | The runtime record that an Intention is actively running right now. Single-active-at-a-time per account. Cross-device propagated. |
| **Goal** | A weekly aspiration, served by one or more Intentions. *(Spec 3 — out of scope here.)* |

---

## Goals of this spec

1. Promote Intentions from a local-only Mac concept (`Project`) into a backend-resident, account-scoped, cross-device entity.
2. Reconcile iOS's existing `FocusMode` model with the new Intention concept without breaking existing NFC pucks.
3. When a Session of an Intention starts on one device, the other device begins enforcing the Intention's correct per-platform blocklist within ~5 seconds.
4. A fresh user can start a useful Session without configuring anything — Day-1 zero-config.

## Non-goals

- Synced schedule / Time Blocks (Spec 2).
- Goals (Spec 3).
- Bedtime conversion to an Intention — Bedtime stays its own subsystem.
- Per-block iOS DeviceActivitySchedule rewiring (Spec 2).
- New anti-tamper mechanics for ending a Session early (separate decision; an opt-in setting is provided as a hook).

---

## ICP framing

The product's working ICP is an ADHD knowledge worker who does not pre-plan and whose willpower is unreliable at moments of crisis. Spec 1 is shaped by that:

- **Day-1 default Intention** is seeded server-side ("Focus") with a curated default Mac blocklist. Fresh user can immediately tap "Start Focus" — no setup gate.
- **Manual session start is the load-bearing surface**, not pre-planned schedules (those come in Spec 2 and are aspirational, not the wedge).
- **Switching Intentions transitions** rather than rejects ("I changed my mind" doesn't punish you).
- **Anti-tamper hook** is provided as an opt-in setting (`requirePartnerToEndSessionEarly`) so the friction-on-end behavior can be turned on without a data-model change.

---

## Architecture overview

### What ships

- **Backend:** new `intentions` table, six CRUD endpoints, `focus_sessions.intention_id` column, `/focus/toggle` extended.
- **Mac:** `ProjectStore` → `IntentionStore`; `BlockingProfileManager` removed; bridge messages renamed; `AppDelegate.activeProjectSession` removed (active intention now read from backend session state); `FocusModeController.activate` accepts `intentionId`. Local `projects.json` migrated one-time to backend.
- **iOS:** new `IntentionStore`; new "Intentions" tab; existing `FocusMode` SwiftData model demoted to "NFC binding pointer" (carries `intentionId`, no longer carries the app tokens directly). `BlockingService.activate` and `PuckCoordinator` propagate to backend on activation. Local `FocusMode.appTokens` migrated one-time to backend Intentions.

### What's added in lockstep across all three repos

| Concern | Backend | Mac | iOS |
|---|---|---|---|
| Intention CRUD | new endpoints | new store + UI | new store + UI |
| Per-platform blocklist payload | stored as opaque columns | edits Mac side | edits iOS side via FamilyActivityPicker |
| Active session propagation | existing `/focus/toggle` extended | existing `FocusStatePoller` extended | existing poller + new APNs push handler |

### What's deliberately untouched

- iOS `BedtimeScheduleService` and `bedtime_config` table.
- iOS `IntentionalBlock` / `ScheduleBlocksService` / DeviceActivity per-block scheduling — Spec 2 territory.
- Mac `daily_schedule.json` and `ScheduleManager` — Spec 2 territory.
- Mac `BlockingProfileManager` callers OUTSIDE of project blocklist resolution — implementation audit will identify any and replace per-caller (assumed minimal; tracked as a follow-up).
- Mac puck behavior (generic Focus toggle) — separate decision deferred.

---

## Data model

### `intentions` table (new)

```
intentions
├── id                   UUID PK (server-generated)
├── account_id           UUID FK→accounts (sibling-shared, indexed)
├── name                 TEXT NOT NULL
├── description          TEXT NULLABLE  -- the old "intention text" e.g. "ship Viper alpha"
├── color_hex            TEXT NULLABLE  -- UI hint
├── icon                 TEXT NULLABLE  -- SF Symbol name; both platforms render
├── mac_websites         TEXT[] NOT NULL DEFAULT '{}'  -- domains to block on Mac
├── mac_bundle_ids       TEXT[] NOT NULL DEFAULT '{}'  -- macOS app bundle IDs to block
├── ios_app_tokens       BYTEA NULLABLE  -- opaque encoded FamilyActivitySelection
├── ios_category_tokens  BYTEA NULLABLE  -- opaque encoded FamilyActivitySelection
├── version              INT NOT NULL DEFAULT 1  -- optimistic concurrency
├── created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
├── updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
└── deleted_at           TIMESTAMPTZ NULLABLE  -- soft delete; preserves session history
```

Indexes:
- `idx_intentions_account_id_active` on `(account_id) WHERE deleted_at IS NULL`
- `idx_intentions_id` PK

### `focus_sessions` table (extended)

Add column:
```
intention_id  UUID NULLABLE FK→intentions(id)
```

NULLABLE so older clients calling `/focus/toggle` without `intention_id` still succeed. No cascade on intention soft delete; the FK resolves regardless of `deleted_at`.

### Per-platform blocklist semantics

| Field | Editor | Reader | Other-platform UI |
|---|---|---|---|
| `mac_websites` | Mac | Mac (`FocusMonitor`, extension) | iOS shows read-only list |
| `mac_bundle_ids` | Mac | Mac (`FocusMonitor`) | iOS shows read-only list |
| `ios_app_tokens` | iOS (`FamilyActivityPicker`) | iOS (`ManagedSettingsStore`) | Mac shows "Edit on iPhone" |
| `ios_category_tokens` | iOS | iOS | Mac shows "Edit on iPhone" |

Apple's privacy model means iOS app tokens cannot be enumerated outside iOS. Mac stores+forwards but never introspects.

### Conflict handling

- Last-write-wins keyed on `version` integer.
- `PUT /intentions/{id}` requires the client's current `version`. Server returns 409 if mismatched.
- On 409, client refetches and surfaces a non-blocking banner: *"This Intention was changed on another device. Your edits weren't saved."*
- Rare in practice (one user across two devices); the version guards against silent overwrite.

---

## Backend endpoints

All endpoints accept dual auth (Bearer JWT or `X-Device-ID`), resolved via the existing `_resolve_account_dual_auth()` helper. All are account-scoped.

| Method | Path | Body / params | Returns |
|---|---|---|---|
| `GET` | `/intentions` | — | `[Intention]` excluding soft-deleted |
| `GET` | `/intentions?include_deleted=true` | — | `[Intention]` including tombstones |
| `GET` | `/intentions/{id}` | — | single `Intention` (incl. deleted) |
| `POST` | `/intentions` | `IntentionCreate` (no `id`/`version`) | `Intention` (with server-assigned `id`, `version=1`) |
| `PUT` | `/intentions/{id}` | `IntentionUpdate` (must include current `version`) | `Intention` (with bumped `version`) — or `409` |
| `DELETE` | `/intentions/{id}` | — | `204` (sets `deleted_at = now()`) |

### Extended endpoint

`POST /focus/toggle` (existing) gains optional `intention_id` on start:
```jsonc
{
  "action": "start",
  "intention_id": "uuid",   // optional; NULL preserves backwards compat
  "triggered_by": "mac_manual" | "ios_manual" | "ios_nfc" | "puck"
}
```

`GET /focus/active` response (existing) gains an `intention_id` field.

### APNs push (uses existing `device_push_tokens` infra)

When `POST /focus/toggle` action=`start` succeeds:
- Backend looks up all `device_push_tokens` for the account except the originating device.
- Sends a silent APNs push to each iOS device with `{session_id, intention_id, started_at, action: "start"}`.
- Mac is NOT push-notified — it relies on existing 2s `FocusStatePoller` cadence (works because the Mac app is always running in the background when relevant).

---

## Sync mechanics

### Two rhythms

**Intention edits (slow lane, ~60s):** mirrors the proven `BedtimeConfigSync` / `PartnerSyncService` pattern.
- Each client keeps a local cached copy of all Intentions on disk.
- **Pull:** `GET /intentions` on app launch, on app foreground/`didBecomeActive`, and every 60s while active.
- **Push:** create/edit/delete calls hit the corresponding endpoint immediately; on success, refresh local cache from response.

**Session start/stop (fast lane, ~2–5s):**
- Mac: existing `FocusStatePoller` polls `/focus/active` every 2s. Continues unchanged.
- iOS: existing poller (when foregrounded) + new APNs handler (for backgrounded/closed app). Push delivery target: ≤5s p95.
- On either client, when a new session is detected, the client looks up the Intention from `IntentionStore` cache and applies the per-platform blocklist.

### Tombstones

Soft-deleted Intentions stay in the local cache so session-history UI can render `"Coding (deleted)"`. The `GET /intentions` (default) endpoint hides them from the active list. Hard delete only via account-deletion cascade.

### Optimistic local enforcement

When the user taps Start, local enforcement begins **before** the `POST /focus/toggle` response arrives. If the server rejects (rare — only on account lock), local enforcement rolls back with a non-blocking toast. Rationale: ICP demands the start feel instant.

---

## Mac changes

### Refactor: `ProjectStore` → `IntentionStore`

- `ProjectStore` (actor, local-only JSON) becomes `IntentionStore` (actor + backend client; local JSON is a write-through cache).
- File on disk renamed from `projects.json` to `intentions.json`. Old file renamed to `projects.legacy.json` (kept for safety, never read again after migration).
- `BlockingProfileManager` is **removed entirely**. Each Intention owns its own `mac_websites` and `mac_bundle_ids` directly. Existing profiles migrate by being merged into the project that referenced them.

### Bridge messages renamed (`MainWindow.swift` ↔ dashboard)

| Old | New |
|---|---|
| `GET_PROJECTS` | `GET_INTENTIONS` |
| `GET_PROJECT_DETAIL` | `GET_INTENTION_DETAIL` |
| `CREATE_PROJECT` | `CREATE_INTENTION` |
| `UPDATE_PROJECT` | `UPDATE_INTENTION` |
| `DELETE_PROJECT` | `DELETE_INTENTION` |
| `START_PROJECT_SESSION` | `START_INTENTION_SESSION` |
| `PROMOTE_LEARNED_SITE` | `PROMOTE_LEARNED_SITE` (unchanged; now Intention-owned) |

Dashboard JS updated in lockstep.

### `AppDelegate.activeProjectSession` removed

The in-RAM `(projectId, blockId)` tuple goes away. Active intention is now derived from `FocusStatePoller`'s session payload (`session.intention_id`). Backend is the single source of truth → fixes the existing "lost on app restart" bug for free.

### `FocusModeController.activate` signature

```swift
func activate(intention: String?, intentionId: UUID?, source: ActivationSource)
```

`intentionId` is stored in the `Period` state and persisted to `focus_mode_state.json` (so a crash/restart preserves the binding).

### Migration of local `projects.json`

On first launch post-upgrade:

1. Read `projects.json`. For each project:
   - Resolve blocklists: own `allowed`/`blocked` HostItems + any referenced `BlockingProfileManager` profiles, merged.
   - Build an Intention payload (`name`, `description = project.intention`, `mac_websites`, `mac_bundle_ids`).
   - `POST /intentions`.
2. On success, rename `projects.json` → `projects.legacy.json` and write a migration receipt (`migration_intentions_v1.json`) so re-runs are skipped.
3. If the account already has Intentions on the server (e.g. iOS migrated first), Mac merges by name: any Mac project whose name matches an existing Intention is merged into that Intention's lists; conflicts resolved by union (set semantics).

Idempotent and re-runnable on partial failure.

### Day-1 default

If after migration the account has zero Intentions, server seeds one named **"Focus"** with a curated default Mac blocklist:
```
twitter.com, x.com, reddit.com, news.ycombinator.com,
youtube.com, instagram.com, tiktok.com, facebook.com
```
User can immediately tap "Start Focus" with no further setup.

---

## iOS changes

### The split

- **`Intention`** (new) lives on the backend. Carries `ios_app_tokens`, `ios_category_tokens`, plus the Mac-side fields, plus name/description/color/icon.
- **`FocusMode`** (existing SwiftData model) is **demoted** to a local "NFC binding" object. Schema slimmed to `(localId, name, intentionId, color, nfcSlug)`. Its `appTokens`/`categoryTokens` move into the bound Intention.

This preserves existing pucks: NFC tap still goes through `FocusMode` → `BlockingService`, but the actual blocklist lives once on the backend.

### New "Intentions" tab

List → tap to edit. Edit screen:
- Name, description (text fields).
- Color, icon (pickers).
- **iPhone apps** section: native `FamilyActivityPicker` (already used for bedtime allowlist + per-block blocklist — proven flow). Picked tokens encoded into `ios_app_tokens`.
- **Mac websites** section: read-only list with caption *"Edit on Mac"*.
- **Mac apps** section: read-only list with caption *"Edit on Mac"*.

### `BlockingService.activate(focusMode)` rewiring

```swift
func activate(_ mode: FocusMode) {
    guard let intentionId = mode.intentionId,
          let intention = intentionStore.cachedIntention(intentionId) else {
        // Fallback for the migration window: if intentionId is unset (pre-migration row)
        // OR cache miss (Intention not yet pulled), use the FocusMode's own legacy
        // appTokens/categoryTokens so pucks never silently no-op.
        applyLegacyShield(from: mode); return
    }
    let selection = decode(intention.iosAppTokens, intention.iosCategoryTokens)
    managedSettingsStore.shield.applications = selection.applicationTokens
    managedSettingsStore.shield.applicationCategories = selection.categoryTokens
    Task { try? await focusToggleClient.start(intentionId: intentionId, triggeredBy: "ios_nfc") }
}
```

`PuckCoordinator` flow unchanged from the user's perspective; the propagation to backend is a side effect.

### Migration of local `FocusMode` rows

On first launch post-upgrade, for each `FocusMode` of `modeType == .blocking`:

1. POST `/intentions` with `{name, ios_app_tokens, ios_category_tokens}`.
2. Stamp returned `intention_id` onto the local `FocusMode` row.
3. Clear the now-redundant `appTokens`/`categoryTokens` fields on the FocusMode (or leave them as a fallback for a release cycle, then remove).

Bedtime FocusModes (`modeType == .bedtime`) are skipped — Bedtime stays separate per design decision.

If the account already has Intentions on the server (e.g. Mac migrated first), iOS merges by name: any local FocusMode whose name matches an existing Intention is bound to that Intention's id, and the iOS tokens are uploaded as a `PUT` (with version) to populate `ios_app_tokens` if empty.

### Day-1 default

Fresh iPhone install with no `FocusMode` rows and no remote Intentions: the server's seeded "Focus" Intention appears in the Intentions tab on first sync. iPhone user can immediately add iPhone apps to it via FamilyActivityPicker. If the user only has iPhone (no Mac yet), `mac_websites` stays as the default — irrelevant to the iPhone-only experience.

---

## Manual Session flow (the user-visible promise)

### Start (manual, Mac)

1. User taps Start on the pill or in the Intentions list. UI sends `START_INTENTION_SESSION { intentionId }`.
2. Mac calls `POST /focus/toggle { action: "start", intention_id, triggered_by: "mac_manual" }`.
3. Mac immediately enters local enforcement (optimistic). `FocusModeController.activate(intention: name, intentionId: id, source: .manual)`. `FocusMonitor` reads the Intention's `mac_websites` + `mac_bundle_ids` and starts blocking.
4. Backend creates `focus_sessions` row, pushes APNs to all other devices on the account.
5. iPhone receives push within ≤5s (even closed/backgrounded). Push handler decodes `ios_app_tokens` from the cached Intention, applies via `ManagedSettingsStore`. App is now shielding.

### Stop (manual, either device)

Same flow, action=`stop`. Backend marks the session ended, pushes APNs to other devices, each clears its enforcement. Friction unchanged from today (one tap), with optional opt-in for partner-unlock-on-early-end via setting (see below).

### Start (manual, iOS via app or NFC)

Identical with reversed roles. NFC path: `PuckCoordinator` → `BlockingService.activate(focusMode)` → also POSTs `/focus/toggle` with the bound `intention_id`. Mac sees it via 2s polling and starts blocking websites.

### Switching Intentions (active "Coding", user starts "Reading")

- Backend's "single active session per account" rule auto-ends the prior session with `end_reason = 'superseded'` and creates the new one in the same transaction.
- Losing client gets the new session via the next push/poll and switches its enforcement. No user-facing prompt or rejection — Intent transitions smoothly. (Per Q8 = A.)

### Optional friction setting (`requirePartnerToEndSessionEarly`)

- New per-account setting (default `false`).
- When `true`, ending a Session within the first **N** minutes routes through the existing partner unlock flow (same mechanism bedtime uses today). Default N = 25 (one Pomodoro); tunable in advanced settings.
- Spec 1 has no scheduled session end, so "early" is purely the time threshold. Once Spec 2 ships, "early" will *also* mean "before the Time Block's scheduled end" — that extension is additive and doesn't change the data model.
- Hook only — UI for this setting is a single toggle in advanced settings. Not promoted in onboarding.

---

## Edge cases

| Scenario | Behavior |
|---|---|
| Network down on Intention save | Local cache holds the edit; non-blocking toast: *"Saved locally; will sync when online."* Retried on next pull cycle. |
| Network down on Session start | Local enforcement starts immediately; `POST /focus/toggle` queued. On reconnect, replays. If backend rejects, local rolls back with toast. |
| Two devices start two Intentions in the same instant | Backend's single-active-session rule means whichever request lands second wins. Losing device sees its own session ended via next push. Non-corrupting. |
| Mac app killed mid-session | On relaunch, `FocusStatePoller` fetches `/focus/active`, rehydrates Intention from cached `IntentionStore`. Enforcement resumes within 2s. |
| iOS DeviceActivity extension fires for a legacy block before migration | Extension reads App Group cache; legacy bedtime/schedule keys still present and untouched. Worst case: extension does nothing for one fire. Resolved on next launch. |
| Soft-deleted Intention referenced by an active Session | FK resolves regardless of `deleted_at`. Session lives out its life. New starts against deleted intention return 410. |
| User deletes account | Existing cascade in `auth.py` deletion flow extended to include `intentions`. `focus_sessions.intention_id` already cascades via `account_id`. |
| 409 on PUT /intentions | Client refetches, shows banner *"This Intention was changed on another device. Your edits weren't saved."* User must re-edit on top of the new version. |
| Migration fails partway (e.g. network down between project N and N+1) | Migration receipt records last-completed project id. Next launch resumes from there. Idempotent. |

---

## Rollout

Deployable in three independent steps without breaking any client:

1. **Backend ships first.** New table + endpoints + `focus_sessions.intention_id` column (NULLABLE). Backwards-compatible — older clients calling `/focus/toggle` without `intention_id` succeed with NULL.
2. **Mac client ships.** Runs migration of `projects.json` → backend Intentions on first launch. Existing Sessions started by old code remain valid (intention_id NULL is fine).
3. **iOS client ships.** Migrates local `FocusMode.appTokens` → backend Intentions. Pucks now propagate sessions to backend.

Old `BlockingProfileManager` files and `daily_schedule.json` are untouched — Spec 2 territory.

---

## Testing

### Backend

- Integration tests for all six endpoints + the `intention_id` extension to `/focus/toggle`.
- Sibling-sync test: device A creates Intention, device B (same account) GETs and sees it within one pull cycle.
- 409-on-stale-version test.
- Cascade-on-account-delete test.
- APNs send is mocked; assert push payload shape.

### Mac

- `IntentionStore` migration of `projects.json` → snapshot test against a fixture with profiles, learned sites, blocklists.
- `FocusMonitor` integration test: mock backend returns session with `intention_id`, verify correct blocklist applied.
- Optimistic enforcement rollback test: mock `/focus/toggle` to fail; assert local enforcement reverts.

### iOS

- `IntentionStore` migration of `FocusMode` rows → snapshot test against fixture.
- UI test: Intention edit screen → FamilyActivityPicker → backend payload round-trip.
- Push-notification handler test (use `XCTestExpectation` against a mocked APNs delivery).
- NFC flow test: simulated tap → `BlockingService` activates correct shield AND POSTs `/focus/toggle`.

### Cross-device manual smoke test

Before each release: install both clients on the same account. Create Intention on Mac. Tap Start on Mac. Assert iPhone shields the right apps within 5s (push), within 60s without push (poll fallback).

---

## Out of scope reminders

- **Time Blocks / synced schedule** — Spec 2.
- **Goals** — Spec 3.
- **Bedtime → Intention conversion** — separate decision, not blocking.
- **iOS DeviceActivity per-block scheduling** — Spec 2.
- **New anti-tamper mechanics for ending Sessions** — only the opt-in `requirePartnerToEndSessionEarly` setting hook is in scope; default behavior unchanged.
- **Puck role assignment (wake-up vs focus)** — separate decision; pucks behave as today in Spec 1.

---

## Open follow-ups (track in cross-repo log post-implementation)

- After Spec 1 stabilizes, decide whether `BlockingProfileManager` removal in Mac broke any non-project caller (audit during implementation, not assumed).
- Decide on a follow-up sweep PR to delete `projects.legacy.json` and `BlockingProfileManager` profile files on disk after a few weeks of stable telemetry.
- Decide whether the optional `requirePartnerToEndSessionEarly` setting should be on by default in a future release (an ICP-aligned move), or always opt-in.
