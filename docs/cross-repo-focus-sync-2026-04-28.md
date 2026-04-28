# Cross-repo: Focus Mode sync (backend-as-master)

**Date:** 2026-04-28
**Branches:**
- `intentional-backend`: `main` (deployed via Railway)
- `intentional-macos-app`: `feat/focus-mode-consolidation`
- `puck-ios`: current default branch (no separate branch — rolls into next iOS build)

## Goal

Make a single boolean — "is the user's focus session active right now" — reliably consistent across iPhone, Mac, and backend. Today's incident: backend showed `status=active` for 5+ hours while iPhone said "no session," because iPhone's local SwiftData diverged and nothing reconciled. Mac correctly trusted backend and kept enforcing.

## Architecture decision

**Backend `focus_sessions` row is the canonical source of truth.** Each client treats its local representation as a CACHE of the backend state. On disagreement, backend wins.

- **iPhone**: SwiftData `FocusSession` is a cache. NFC tap optimistically updates local + posts to backend (with retry queue). On app foreground/boot, pulls `/focus/active` and reconciles.
- **Mac**: `FocusModeController.state` is in-memory + persisted to disk. Polls `/focus/active` every 2s. Persisted state seeds the controller on init so app-restart doesn't show "off" briefly when backend is "active."
- **Backend**: Postgres row with TTL safety net (`expires_at`). `/focus/active` filters on `status = 'active' AND expires_at > now()`. Sessions where no client ever sent stop expire after 12h instead of sitting active forever.

## What was changed, by repo

### `intentional-backend` (deployed)

- **Migration `012_add_focus_sessions_expires_at.sql`** — adds `expires_at TIMESTAMPTZ` column, backfills existing active rows with `started_at + 12h`, adds index for the new active-and-not-expired filter. Run manually in Supabase SQL editor.
- **`/focus/toggle` (start)** — now sets `expires_at = now() + 12h` on insert. Constant `FOCUS_SESSION_TTL_HOURS = 12` near top of `main.py`.
- **`/focus/active`** — now filters `WHERE status = 'active' AND expires_at > now()`. A session past its TTL is treated as ended even if no stop was POSTed.
- **`_resolve_account_dual_auth`** — helper that accepts either `Authorization: Bearer <jwt>` or `X-Device-ID: <hex>`. `/focus/toggle` and `/focus/active` use it. Bearer wins if both present. Device-ID auth has no expiry, no refresh, eliminates the JWT-15-min-expiry pain on Mac's polling path.
- Commits: `bba3333` (X-Device-ID dual auth), `f124d0e` (TTL).

### `intentional-macos-app` (PKG built, ready to install)

- **`Intentional/FocusStatePoller.swift`** — new file. Polls `/focus/active` every 2s with `X-Device-ID` auth. On state transition, drives `FocusModeController.activate()` / `.deactivate()`. Replaces the WebSocket reliance for cross-device focus signal (WS still wired in code but the poller now carries the load — see "what's NOT done" below).
- **`Intentional/FocusModeController.swift`** — added `loadFromDisk()` / `saveToDisk()` persistence to `~/Library/Application Support/Intentional/focus_mode_state.json`. State + period rehydrate on init. Eliminates the 2-second "wrong state" window after Mac restart while a session is active.
- **`Intentional/AppDelegate.swift`** —
  - `onStateChanged` now calls `applyDefaultBlockingProfile()` on enter-`.focus` (cross-device path was previously activating state without applying any blocklist) and `applyAlwaysActiveProfiles()` on enter-`.off`.
  - On boot, if `FocusModeController.state == .focus` (restored from disk), explicitly re-engages enforcement (default profile + `focusMonitor.onBlockChanged()`).
  - New `postFocusToggleToBackend(action:)` helper. Mac dashboard toggle and scheduler both POST `/focus/toggle` with `X-Device-ID`. Without this, manual Mac toggle only flipped local state and the poller would re-engage from backend 2s later — broken UX.
- **`Intentional/MainWindow.swift`** — added `GET_FOCUS_MODE` bridge so dashboard pulls current state on load (previously dashboard relied on push-only updates which raced page-load JS parse).
- **`Intentional/dashboard.html`** — sends `GET_FOCUS_MODE` in init block.

### `puck-ios` (compiled, ready to push to device)

- **`Puck/Core/Network/IntentionalFocusSignalClient.swift`** — added `reconcileFromBackend()`. Pulls `/focus/active` and reconciles local SwiftData / blocking against backend. Called on app foreground (after queue drain) and on app boot (in `PuckCoordinator.configure`). Handles: backend inactive + local active → end local. Backend active + local inactive → log + wait for user NFC tap (resurrecting requires mode slug, which backend doesn't carry).
- **`Puck/Core/Coordinator/PuckCoordinator.swift`** — added `deactivateForBackendReconcile()` for the reconcile-driven teardown. Suppresses redundant backend stop POST (backend already inactive). Boot-time reconcile triggered from `configure(modelContext:)`.
- **`Puck/Core/Blocking/BlockingService.swift`** — fixed a state-restore bug independent of the cross-device work but in the same theme: `init()` always set `blockingState = .idle` even though the FamilyControls Shield persists at OS level. Now reads App Group `puck_blocking_*` keys and restores `blockingState = .active(...)` if Shield is still applied. Re-arms timer if duration was set and end-time is still in the future. `writeShieldSessionInfo` now persists `start_time` + `end_time` for the restore to work.
- **`Puck/Models/Sessions.swift`** — added `EndReason.backendReconcile` case for the new teardown path.

## What's deliberately NOT done

- **WebSocket removal** — Mac's `FocusWebSocketClient` is still wired in parallel with the poller. Both can drive `focusModeController.activate()`; they're idempotent so the duplication is harmless. Removing is pure cleanup, not a sync correctness issue. Follow-up.
- **iOS resurrect (backend-active + local-inactive)** — currently logs and waits for user NFC tap. To auto-resurrect, backend's `/focus/active` response would need a `mode_slug` field so iPhone knows which mode to apply. Follow-up.
- **Heartbeat actively bumping TTL** — TTL is set once at session start (12h). Long sessions past 12h get auto-ended even if a client is still actively claiming them. For typical use this is fine; if needed, add a `POST /focus/heartbeat` and have Mac's poller bump TTL every minute.
- **Schedule on backend** — Mac's `ScheduleManager` is still local. When a scheduled block fires, Mac POSTs `/focus/toggle` so backend knows. If Mac is asleep at the scheduled time, the POST never fires (same as today). Real fix is to move the scheduler itself to the backend; bigger work, follow-up.
- **Time zone correctness** — uses device-local time. If the user crosses time zones with an active session, behavior is undefined. Follow-up.

## Verification done tonight

- Backend deploy verified via curl: start with `X-Device-ID` returns session_id; `/focus/active` returns the new session; stop ends it. Logs `bof…` PKG verifies `expires_at` is set on insert.
- Mac PKG (Phases 1, 2, 3, 5) compiled clean.
- iOS (Phase 4 + Shield restore) compiled clean.
- End-to-end: user tapped Puck on iPhone → backend session created → Mac poller picked up → Mac engaged → blocklist applied (youtube + instagram blocked per default profile). Confirmed by user.
- iOS Shield restore: user confirmed iPhone home view now shows active session after app force-quit + relaunch (previously showed "no session").

## Known limitation that surfaced today (not fixed)

The `accounts` table can have multiple rows for the same email if Supabase Auth and the email-OTP flow each created their own row before `_resolve_account_from_token`'s email dedupe was added. We did not encounter this tonight because both clients now resolve via email lookup which uses `.limit(1)` on a stable order. If it does happen, the symptom is "iPhone POSTs to one account, Mac polls another, broadcasts never reach Mac." Cleaner fix is a UNIQUE constraint on `accounts.email`. Follow-up.

## Hand-off

Run `git log --oneline f124d0e..HEAD` on each repo to see remaining uncommitted work in each branch (Mac and iOS still have uncommitted changes from tonight's session as of doc-write time; user is testing before commit).

To roll forward:
1. Apply `012_add_focus_sessions_expires_at.sql` in Supabase if not already (check via `SELECT column_name FROM information_schema.columns WHERE table_name = 'focus_sessions';`)
2. Backend deployed automatically on push to main.
3. Mac PKG at `/tmp/intentional-pkg-build/Intentional-1.0.pkg` (rebuild with `NOTARIZE=0 ./scripts/build-pkg.sh` if stale)
4. iOS via `Cmd+R` from Xcode with device connected
