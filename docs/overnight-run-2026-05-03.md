# Overnight Run — 2026-05-03 — Spec 1: Unified Intentions

**Started:** 2026-05-03 (autonomous overnight)
**Branch convention:** `feat/intentions-spec1` in all three repos
**Spec:** `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md`

---

## TL;DR for the morning

(Updated continuously as work progresses. Final summary at bottom.)

---

## Repos & branches

| Repo | Path | Base | Feature branch | Worktree |
|---|---|---|---|---|
| Mac | `intentional-macos-app` | `puck` | `feat/intentions-spec1` | `.claude/worktrees/intentions-spec1` |
| Backend | `intentional-backend` | `main` | `feat/intentions-spec1` | `.claude/worktrees/intentions-spec1` |
| iOS | `puck-ios` | `main` | `feat/intentions-spec1` | `.claude/worktrees/intentions-spec1` |

---

## What I can do tonight (autonomous)

- Write & commit code on feature branches in all 3 repos
- Run all unit + integration tests locally; gate on green
- Run Mac build (`xcodebuild`) and Python tests (`pytest`)
- Cross-link spec ↔ plan ↔ code in commit messages
- Document everything in this log

## What requires you in the morning

- **Backend:** Push `feat/intentions-spec1` to remote, deploy to Railway. Run migration `018_add_intentions.sql` via Supabase SQL editor.
- **Mac PKG:** sign + notarize a fresh build via `./scripts/build-pkg.sh` if you want a distributable binary
- **iOS:** open Xcode, run on a real device or simulator. The DeviceActivity / FamilyControls path needs a real iPhone for full E2E.
- **Cross-device smoke test:** install both clients, create an Intention on Mac, tap Start, verify iPhone shields within 5s.

---

## Phase tracker

- [x] Phase 1 — Spec written (committed `fa868ff`)
- [ ] Phase 2 — Plans written (A/B/C)
- [ ] Phase 3 — Backend implementation
- [ ] Phase 4 — Mac implementation
- [ ] Phase 5 — iOS implementation
- [ ] Phase 6 — Final verification + handoff

---

## Plans

| Plan | File | Status |
|---|---|---|
| A — Backend | `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-a-backend.md` | (writing) |
| B — Mac | `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-b-mac.md` | (writing) |
| C — iOS | `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-c-ios.md` | (writing) |

---

## Live progress log

### Phase 1 — Spec (DONE)
Spec doc committed `fa868ff` on `puck`. Vocabulary locked: Intention/Time Block/Session/Goal. Decisions locked: 1A/2A/3A/4A/6A/7A/8A/9A. Bedtime stays separate. Puck behavior unchanged in Spec 1.

### Phase 2 — Plans (in progress)
(Updates will append here as plans land.)


### Phase 3 — Backend report

**Status:** GREEN
**Branch:** `feat/intentions-spec1` pushed to `origin` (final commit `5a92256`)
**Tasks completed:** 15 / 15
**Test results:** 116 passed / 2 pre-existing failures (not regressions)

#### What was built

- Migration: `migrations/018_add_intentions.sql` — `intentions` table (account-scoped, soft delete, optimistic concurrency via `version`, BYTEA blobs for iOS FamilyActivitySelection tokens) + `focus_sessions.intention_id` FK column + indexes + auto-bump `updated_at` trigger + RLS enabled (no policies = service-role only).
- Endpoints (all dual-auth: Bearer JWT or `X-Device-ID`):
  - `GET /intentions` — lists live intentions for the account; `?include_deleted=true` reveals tombstones; auto-seeds a Day-1 default "Focus" intention with curated blocklist (twitter, x, reddit, hn, youtube, instagram, tiktok, facebook) when account has zero rows EVER (live + deleted both 0).
  - `GET /intentions/{id}` — single intention; resolves tombstones (for session history).
  - `POST /intentions` — create; server assigns `id` + `version=1`. iOS tokens accepted as base64 strings.
  - `PUT /intentions/{id}` — update with optimistic concurrency. 409 on stale `version`, 410 if soft-deleted, 404 if not owned.
  - `DELETE /intentions/{id}` — soft delete (sets `deleted_at`); preserves session history.
- `POST /focus/toggle` extended:
  - Accepts optional `intention_id` and `triggered_by` in body.
  - Records both on the `focus_sessions` row.
  - Fires APNs background push (`content-available: 1`) to all peer iOS devices on BOTH start and stop with `{session_id, intention_id, action, triggered_by}`.
- `GET /focus/active` returns `intention_id` (in addition to existing fields).
- Account-deletion cascade (`auth.py`): explicit `intentions.delete().eq(account_id)` before account row is deleted (DB-level `ON DELETE CASCADE` on `intentions.account_id` is the belt; the explicit delete is the suspenders).

#### Test coverage

- `tests/test_intentions.py` (17 tests): GET list + tombstone exclusion + include_deleted, GET single (404 for cross-account, 200 with tombstone), POST (success + base64 round-trip + empty-name 422), PUT (version bump + 409 stale + 404 not owned), DELETE (soft + 404 not owned), sibling sync (Mac creates → iPhone reads), account-delete cascade.
- `tests/test_focus_intention_id.py` (5 tests): start with intention_id recorded, start without intention_id (backward compat), `/focus/active` returns intention_id, APNs payload shape on start, APNs payload on stop.
- `tests/test_intention_seeding.py` (4 tests): seeds Day-1 default for fresh account, does NOT seed when account has live intentions, does NOT seed when account has only tombstones (respect deletion intent), idempotent under back-to-back GETs.

#### Files changed

- `migrations/018_add_intentions.sql` (new)
- `models.py` (added IntentionCreate / IntentionUpdate / Intention / IntentionListResponse, added intention_id + triggered_by to FocusToggleRequest, added intention_id to FocusActiveResponse)
- `main.py` (added 5 endpoints, base64 codec utils, _row_to_intention, _maybe_seed_default_intention, intention_id wiring in /focus/toggle start + stop, /focus/active returns intention_id, APNs push fan-out on start + stop)
- `auth.py` (added explicit `intentions` delete in /auth/delete-confirm cascade)
- `tests/test_intentions.py` (new)
- `tests/test_focus_intention_id.py` (new)
- `tests/test_intention_seeding.py` (new)

#### Pre-existing failures (NOT regressions, present on `main` baseline)

- `tests/test_focus_endpoints.py::test_focus_active_no_session` — that test file's local `_FakeQuery` is missing a `.gt` method; `/focus/active` calls `.gt("expires_at", now_iso)` and the mock blows up. The new test file `tests/test_focus_intention_id.py` has its own `_FakeQuery` (in `tests/test_intentions.py`) WITH a `.gt` implementation, so my test_focus_active_returns_intention_id test passes.
- `tests/test_partner_sync.py::test_partner_status_no_account_returns_none` — `_resolve_account_dual_auth` correctly returns 401 for an unlinked device, but the test expects 200. This is a stale test assertion that was never updated when partner-status auth tightened.

I did NOT fix these — they're pre-existing bugs unrelated to Spec 1, and fixing them is out of scope. Files: `tests/test_focus_endpoints.py` (lines 90-105 for the FakeQuery, would need a `.gt` method); `tests/test_partner_sync.py:314` (assertion vs auth contract mismatch).

#### Deviations from plan

- `_FakeQuery.__init__` originally used `self._data = list(data)` which copied the caller's list, so test assertions like `focus_sessions[0]["intention_id"]` couldn't observe inserts. Changed to `self._data = data` (keep the caller's list reference) so tests can observe inserts/updates in-place. This is in `tests/test_intentions.py`. The plan's text said the new `_FakeDB` is "more sophisticated" and instructed me to fix bugs in it; this was such a bug.
- The plan said to use `logger.warning(...)` for the APNs failure path, but `main.py` has no module-level `logger` import. Used `logging.getLogger(__name__).warning(...)` inline (matches the existing pattern in lines 3763 and 4016).
- All test setups had to include `email` on the account row (originally only had `id` + `supabase_user_id`). Without email, `_resolve_account_from_token` couldn't match by email, auto-created a new account with a different ID, and intentions queries filtered to the wrong account. Added `email` to every accounts fixture in the new tests.
- Test file `tests/test_intentions.py` ended up with both the `_FakeDB` infrastructure AND the test assertions — `tests/test_focus_intention_id.py` and `tests/test_intention_seeding.py` import `_FakeDB`, `_supabase_jwt`, `_client` from `tests.test_intentions` (per the plan's Step 1 of Task 10).
- `pytest -v` from the repo root crashes on `test_heartbeat.py` (a pre-existing diagnostic SCRIPT, not a test, that calls `exit(1)` at module load). Use `pytest tests/` to scope to the test directory. Pre-existing — not introduced by this branch.

#### Action required from user (you) in the morning

1. **Apply migration 018 in Supabase SQL editor.** Paste the contents of `migrations/018_add_intentions.sql` into the SQL editor and run. The migration is idempotent (`IF NOT EXISTS` everywhere). Order matters: this must run BEFORE the deployed backend tries to read or write `intentions` rows or `focus_sessions.intention_id`.
2. **Merge `feat/intentions-spec1` → `main`.** Open the PR (`https://github.com/ameerry1998/intentional-backend/pull/new/feat/intentions-spec1`), review, merge.
3. **Trigger Railway deploy** (auto on push-to-main, or manual).
4. **Smoke-test:**
   ```bash
   # Replace <RAILWAY_URL> + <YOUR_DEVICE_ID>
   curl -H "X-Device-ID: <YOUR_DEVICE_ID>" https://<RAILWAY_URL>/intentions
   # Expect: 200 with {"intentions":[...]} — at minimum the seeded "Focus" intention.

   curl -X POST -H "X-Device-ID: <YOUR_DEVICE_ID>" -H "Content-Type: application/json" \
     -d '{"name":"Test Coding","mac_websites":["twitter.com"]}' \
     https://<RAILWAY_URL>/intentions
   # Expect: 200 with version=1.

   # Confirm /focus/active returns intention_id:
   curl -H "X-Device-ID: <YOUR_DEVICE_ID>" https://<RAILWAY_URL>/focus/active
   ```
5. **Pre-existing test failures** (above) are not blockers — they were broken on `main` before this branch. File a follow-up if you want them fixed.

#### Notes for downstream Mac + iOS phases

- The 5 endpoints are stable. Plan B (Mac) and Plan C (iOS) can call them without backend changes.
- `intention_id` is optional on `/focus/toggle` — older clients will keep working unchanged.
- iOS tokens (`ios_app_tokens_b64` / `ios_category_tokens_b64`) are JSON-safe base64 strings server-side. iOS clients should base64-encode the `Data` from `FamilyActivitySelection` before sending and base64-decode on receipt.
- APNs `content-available: 1` is fired on both start and stop. iOS clients listening should handle both; Mac doesn't need APNs (it polls `/focus/active` every 2s).
- Day-1 seed only fires on the first `GET /intentions`. iOS or Mac calling `POST /intentions` first will skip the seed (so don't expect a "Focus" intention to magically appear if you never GET first).


### Phase 4 — Mac report

**Status:** GREEN
**Branch:** `feat/intentions-spec1` pushed to `origin` (final commit `9089c33`)
**Tasks completed:** 13 / 13
**Build:** `xcodebuild ... clean build` → `BUILD SUCCEEDED`
**Tests:** No XCTest target wired in this codebase — created `IntentionalTests/IntentionStoreTests.swift` as manual smoke spec. Existing `IntentionalTests/` files are not compiled by the default scheme.

#### What was built

- **`Intention.swift`** — Codable model with snake_case CodingKeys mapping the backend's wire format. Three structs: `Intention`, `IntentionCreatePayload` (no id/version), `IntentionUpdatePayload` (must include version), plus `IntentionListResponse` wrapper.
- **`IntentionStore.swift`** — Actor with disk cache (`intentions.json`), pull on init/foreground/60s timer, push on CRUD, 409 retry-with-refetch on version conflict. Tombstones retained locally for session-history rendering. Posts `.intentionsDidChange` notification on any cache mutation.
- **`IntentionMigration.swift`** — One-time migration of `projects.json` → backend Intentions. Idempotent via `migration_intentions_v1.json` receipt. Resumable on partial failure. Merges by name into existing backend Intentions (set-union of `mac_websites` / `mac_bundle_ids`). Resolves project `blocklistIds` references by calling `BlockingProfileManager.mergedBlockList(profileIds:)` and unioning with the project's own `blocked` HostItems.
- **`BackendClient.swift`** — Added `getIntentions / getIntention / createIntention / updateIntention / deleteIntention` with custom `IntentionError` (versionConflict / notFound / network). Added `postFocusToggle(action:intentionId:triggeredBy:)` — typed wrapper around POST `/focus/toggle`.
- **`MainWindow.swift`** — Six new bridge messages: `GET_INTENTIONS`, `GET_INTENTION`, `CREATE_INTENTION`, `UPDATE_INTENTION`, `DELETE_INTENTION`, `START_INTENTION_SESSION`. Legacy `*_PROJECT_*` handlers retained as deprecated aliases. `handleStartIntentionSession` does optimistic local activation (FocusModeController + activeProjectSession) then POSTs `/focus/toggle`; rolls back local state on backend failure. Listens for `.intentionsDidChange` to re-emit the intentions list to the dashboard.
- **`FocusStatePoller.swift`** — Reads `intention_id` from `/focus/active` response; resolves Intention via `IntentionStore.shared.intention(id:)`; threads name + id through to `FocusModeController.activate(intention:intentionId:source:)`. Cache miss falls through with a generic name AND triggers an out-of-band pull. Also mirrors the resolved id into `AppDelegate.activeProjectSession` so the in-RAM cache is canonically backend-driven (fixes the lost-on-restart bug — first 2s poll re-populates).
- **`FocusModeController.swift`** — `Period` gains optional `intentionId: UUID?`. Persistence schema bumped to v2 (added `periodIntentionId`); v1 blobs deserialize forward-compatibly. `activate()` signature: `intention: String?, intentionId: UUID? = nil, source: ActivationSource` — default value means existing call sites compile unchanged. Idempotent same-state activations now refresh both intention name AND intentionId, firing the change callback if either differs.
- **`AppDelegate.swift`** — Wires `IntentionStore.shared` after `ProjectStore` init; runs migration on first launch in same Task.

#### Files changed

- New: `Intentional/Intention.swift`, `Intentional/IntentionStore.swift`, `Intentional/IntentionMigration.swift`, `IntentionalTests/IntentionStoreTests.swift`
- Modified: `Intentional/BackendClient.swift`, `Intentional/MainWindow.swift`, `Intentional/FocusStatePoller.swift`, `Intentional/FocusModeController.swift`, `Intentional/AppDelegate.swift`, `Intentional.xcodeproj/project.pbxproj`, `CLAUDE.md`

#### Deviations from plan

- **`BlockingProfileManager` retained** (per scope-honest delta in plan). The named-profiles UI still uses it. Migration resolves profile references into Intention.mac_websites/mac_bundle_ids at migration time. Profiles UI removal deferred to a future cleanup PR.
- **`AppDelegate.activeProjectSession` retained** (per scope-honest delta in plan). Now driven by both manual-start (optimistic, in MainWindow.handleStartIntentionSession) and `FocusStatePoller` (canonical, on session detect). The "lost on restart" bug fixes itself: first 2s poll after restart re-populates from `/focus/active.intention_id`.
- **xcodeproj fixup**: the worktree's `.gitignore` excludes `*.mp4`, so `zen-nature.mp4` and `13136082_3840_2160_60fps.mp4` (already referenced in the pbxproj from a prior commit) were absent. Copied them in from the parent worktree's `Intentional/` to satisfy the build. Not a code change, but worth noting if the worktree gets re-cloned.
- **Stub-then-fill for new files**: created empty `IntentionStore.swift` and `IntentionMigration.swift` placeholders during Task 1 (to keep the build green when registering all 3 file refs in pbxproj at once) and filled them in Tasks 4 and 8 respectively. Functionally identical to the plan; just an ordering nuance.
- **No XCTest target**: `IntentionalTests/` directory exists with .swift files but no scheme/target wires them up. The plan said "if no test target exists, document tests as manual smoke" — followed that path. The new test file is identically structured to the existing ones, so adding a target later will pick it up.

#### Action required from user (you) in the morning

1. **Wait for backend deploy + migration 018 to land** (Phase 3 instructions above). The Mac client safely handles backend-unreachable today (CRUD returns nil/throws; no crashes), but Start Session will roll back optimistically until the backend is live.
2. **Merge `feat/intentions-spec1` → `puck`**. The migration runs automatically on first launch when receipt is absent; nothing else to do.
3. **Build PKG** via `./scripts/build-pkg.sh` if you want a distributable binary. Standard signing rules apply (don't re-sign, don't strip entitlements).
4. **Manual smoke test**:
   - Open dashboard. (Note: dashboard JS still uses `*_PROJECT_*` messages — see follow-up below. The new `*_INTENTION_*` handlers are reachable from JS but no UI calls them yet.)
   - Existing projects should appear in `intentions.json` after first launch (migration writes them via backend, then pull caches them).
   - On the backend, hit `GET /intentions` for the device's account — should see all migrated projects as Intentions with merged blocklists.
   - With backend live + iOS Plan C deployed: tap Start Session, iPhone shields within ~5s.

#### Handoff notes

- **Dashboard JS not migrated.** The Swift bridge now supports `*_INTENTION_*` messages, but the dashboard HTML/JS still calls the old `*_PROJECT_*` ones. Both code paths exist in parallel; there's no break, but there's also no UI exercising the new handlers yet. Migrating the JS is a follow-up PR — straightforward swap of `window.webkit.messageHandlers.NativeBridge.postMessage({ type: 'GET_PROJECTS' })` → `'GET_INTENTIONS'`, plus the response receivers (`window._projectsList` → `window._intentionsList`, etc.).
- **`BlockingProfileManager` cleanup deferred.** Future PR can remove the named-profiles UI from the dashboard, the `*_BLOCKING_PROFILE` MainWindow handlers, and the `BlockingProfileManager` class itself once all profile users have migrated to direct Intention blocklists.
- **`requirePartnerToEndSessionEarly` hook deferred** (per plan). Spec called for a "hook only" but the early-end interaction with bedtime partner-unlock isn't designed yet. Tracked for Spec 2.
- **Mac iOS-blocklist editor deferred** (per plan). Mac shows `ios_app_tokens_b64` / `ios_category_tokens_b64` as opaque blobs through IntentionStore; iOS edits its own slice via FamilyActivitySelection.

