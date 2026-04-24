# Overnight Run — Puck Focus Signal End-to-End Integration

**Date:** 2026-04-24 (started late evening of 2026-04-23)
**Run type:** Autonomous overnight, single agent, no checkpoints.
**Plan:** [`docs/superpowers/plans/2026-04-24-puck-focus-signal.md`](./superpowers/plans/2026-04-24-puck-focus-signal.md)

---

## Summary

**Status:** **Code-complete across all 3 repos. Ready for user review.**

- **Backend (intentional-backend):** All endpoint and auth changes done, 34 unit tests passing (19 new). PR not deployable until `SUPABASE_JWT_SECRET` is set on Railway.
- **iOS (puck-ios):** 3 new files + 4 edits + 2 pbxproj fixups. Xcode build succeeds for generic iOS Simulator.
- **macOS (intentional-macos-app):** 1 new file + 2 edits. Xcode Debug build succeeds.
- **End-to-end demo:** Not executed (requires physical Puck tap + user's signed-in devices). See §Verification for the commands the user can run tomorrow.

---

## Per-Repo Work

### 1. `intentional-backend`

**Branch:** `feat/puck-focus-signal` (from `main`)
**PR:** _see §Pushing & PRs below_

**Commits:**
```
6f718bd feat(migration): add supabase_user_id to accounts for Supabase auth federation
60146bd feat(auth): add Supabase JWT verifier and unified verify_any_token
59ef43a test(auth): unit tests for Supabase JWT verifier and verify_any_token
1f410d7 feat(focus): accept Supabase JWTs on focus-signal endpoints via email-linked accounts
2e0ca73 test(focus): integration tests for /devices/register and /focus/toggle with both token kinds
```

**What was changed**
- `migrations/011_add_supabase_user_id.sql` — NEW. Adds nullable `supabase_user_id` column to `accounts` + index. Additive only.
- `security.py` — NEW functions `verify_supabase_token()` and `verify_any_token()`. Existing `verify_access_token` untouched.
- `main.py` — NEW helper `_resolve_account_from_token()`; rewrote auth block on `/devices/register`, `/focus/toggle`, `/focus/active`, and `/ws/focus` to accept either token kind. Focus WebSocket `focus_signal` payload now includes `triggered_by`.
- `tests/test_auth_supabase.py` — NEW, 10 tests for verifier.
- `tests/test_focus_endpoints.py` — NEW, 9 integration tests for endpoints using both JWT kinds.

**Test results**
```
$ python3 -m pytest tests/ -v
34 passed, 4 warnings in 0.51s
```
The 4 warnings are pre-existing (urllib3/pyiceberg deprecations — unrelated).

**How the email-linking works**
- Supabase JWT → verify signature with `SUPABASE_JWT_SECRET` → extract `email` claim.
- Lowercase-trim email, look up `accounts.email`.
- If found: backfill `supabase_user_id` if empty; return `account_id`.
- If not found: `INSERT` a new `accounts` row with `email` + `supabase_user_id`. Duplicate-risk accepted (user has one email).
- `verify_any_token` returns a normalized payload with `token_source: "intentional" | "supabase"` so downstream code can disambiguate. Intentional-issued tokens keep the old fast-path (`sub` IS `account_id`).

**CRITICAL deploy-time TODO**
- **DO NOT merge/deploy until `SUPABASE_JWT_SECRET` env var is set on Railway.**
  Without it, all Supabase-authenticated requests return 401 (the verifier falls through). Intentional-JWT-authenticated clients continue to work either way.
- Grab the secret from Supabase Dashboard → Settings → API → **JWT Secret** (legacy HS256 secret; NOT the anon key).
- Apply migration `011_add_supabase_user_id.sql` before or alongside deploy.

---

### 2. `puck-ios`

**Branch:** `feat/intentional-backend-integration` (from `feature/evening-mode`)
**PR:** _see §Pushing & PRs below_

**Commits:**
```
f6903a6 feat(config): add Intentional backend base URL to Constants
d77ecd6 feat(network): add Intentional backend client + device registration + focus signal client
adfcae2 feat(coordinator): mirror Puck NFC taps to Mac via Intentional backend
0febd4d feat(auth): register device with Intentional backend after successful auth
690388e feat(xcode): register new Intentional backend network files
dfc17ae fix(xcode): register missing Evening/Bedtime service + view files
```

**What was changed**
- `Puck/Utils/Theme.swift` — added `Constants.IntentionalAPI.baseURL = "https://api.intentional.social"`.
- `Puck/Core/Network/IntentionalAPIClient.swift` — NEW. Thin HTTP client using `AuthService.shared.accessToken` (Supabase JWT) as Bearer.
- `Puck/Core/Network/IntentionalDeviceRegistration.swift` — NEW. `registerIfNeeded()` posts `POST /devices/register` once on login, persists the returned `device_id` in UserDefaults.
- `Puck/Core/Network/IntentionalFocusSignalClient.swift` — NEW. `toggleFocus(action: .start|.stop)` fire-and-forget hits `POST /focus/toggle`.
- `Puck/Core/Coordinator/PuckCoordinator.swift` — 2 edits: fire `start` on blocking-mode activation; fire `stop` on session end (blocking-only; bedtime is phone-only).
- `Puck/Core/Auth/AuthService.swift` — new private `triggerPostAuthBackendCalls()` hooked into `listenForAuthChanges`, `verifyOTP`, and `signInWithApple`.

**Pre-existing build issue fixed (not part of this feature, but blocked validation)**
- `feature/evening-mode` base branch had 4 Swift files NOT registered in the Xcode target:
  - `Puck/Core/Evening/EveningModeService.swift` (declares `BedtimeService`)
  - `Puck/Core/Evening/EveningShortcutsProvider.swift`
  - `Puck/Views/Evening/EveningModeView.swift` (declares `BedtimeView`)
  - `Puck/Views/Evening/EveningShortcutsSetupView.swift`
- Without them the project did NOT compile — all of them are referenced from `PuckCoordinator`, `PuckApp`, and `HomeView`. I added them to the `Puck` target via `xcodeproj` gem so my build verification could run. Documented in commit message. If the user prefers, this commit can be reverted on the feature branch and fixed separately on `feature/evening-mode`.

**Build verification**
```
$ xcodebuild -project Puck.xcodeproj -scheme Puck \
    -destination 'generic/platform=iOS Simulator' -configuration Debug build
** BUILD SUCCEEDED **
```
Many Swift 6 / CoreNFC Sendable warnings exist in the base branch — all pre-existing, none introduced by this PR.

---

### 3. `intentional-macos-app`

**Branch:** `feat/puck-focus-signal` (from `puck`)
**PR:** _see §Pushing & PRs below_

**Commits:**
```
18379c4 feat(focus): add IntentionalDeviceRegistration service for Mac
36e0e08 feat(focus): heartbeat timer, triggered_by propagation, Mac device registration
```

**What was changed**
- `Intentional/IntentionalDeviceRegistration.swift` — NEW. Fire-and-forget `POST /devices/register` using `BackendClient.getAccessToken()` as Bearer.
- `Intentional/FocusWebSocketClient.swift` — EDITED. `onFocusSignal` callback now passes `triggeredBy`; added `startHeartbeat(sessionId:)` + `stopHeartbeat()` (2-min timer); `disconnect()` stops heartbeat.
- `Intentional/AppDelegate.swift` — EDITED. WS callback updated; starts/stops heartbeat; passes `triggeredBy == "puck"` to `showFocusStartOverlay(isPuckTriggered:)`; calls `IntentionalDeviceRegistration.registerIfNeeded` after WS connect.

**Build verification**
```
$ xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build
** BUILD SUCCEEDED **
```

---

## End-to-End Verification (for Ameer to run tomorrow)

### Prerequisites (do these first, in order)

1. **Set Railway env var:**
   ```bash
   # From the Supabase dashboard: Settings → API → JWT Secret (legacy HS256 secret)
   railway variables --set SUPABASE_JWT_SECRET=<the-secret>
   ```
2. **Apply migration 011** (Railway auto-applies on deploy, or run manually in Supabase SQL editor):
   ```sql
   -- See migrations/011_add_supabase_user_id.sql
   ALTER TABLE accounts ADD COLUMN IF NOT EXISTS supabase_user_id UUID;
   CREATE INDEX IF NOT EXISTS idx_accounts_supabase_user_id ON accounts(supabase_user_id);
   ```
3. **Review & merge the 3 PRs** (links below). Merge backend LAST so deploy rolls out with env var already set.

### Test 1: Backend unit tests still pass on CI/local

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git checkout feat/puck-focus-signal
python3 -m pytest tests/ -v
```
Expect: 34 passed.

### Test 2: Curl focus/toggle with a mock Supabase JWT (local backend)

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
# Start backend locally
SUPABASE_JWT_SECRET=<real-or-test-secret> \
  JWT_SECRET=anything-here \
  SUPABASE_URL=https://zsccuqwqdinbmvyylwur.supabase.co \
  SUPABASE_SERVICE_KEY=<service-key> \
  RESEND_API_KEY=<your-key> \
  FROM_EMAIL='Intentional <noreply@intentional.social>' \
  uvicorn main:app --reload --port 8000 &

# Mint a test Supabase-style JWT (Python one-liner):
python3 -c "
import jwt, time
secret = '<real-or-test-secret>'
t = jwt.encode({
  'sub': 'test-sb-user',
  'email': 'ameer.rayan@gmail.com',
  'role': 'authenticated',
  'aud': 'authenticated',
  'exp': int(time.time()) + 3600,
  'iat': int(time.time()),
}, secret, algorithm='HS256')
print(t)
"
# Copy the token, then:
TOKEN='eyJ…'
curl -s -X POST http://localhost:8000/focus/toggle \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"action":"start"}' | jq
```
Expect: `{"session_id": "...", "status": "started", ...}`.

### Test 3: Mac WebSocket receives the signal

With the local backend running:
1. Run the Mac app from Xcode (Debug build; it points to `ws://localhost:8000`).
2. Observe the console — it should log `🔌 WebSocket connected`.
3. Fire the curl from Test 2. The Mac console should print `🔌 Focus signal: START …` and the focus start overlay should appear.
4. Fire with `{"action":"stop"}`. Mac logs `🔌 Focus signal: STOP …`, overlay dismisses / focus session ends.

### Test 4: Real Puck tap (physical device)

Pre-req: user (Ameer) is signed into both the Puck iOS app AND the Mac app under the SAME email (ameer.rayan@gmail.com). Railway has `SUPABASE_JWT_SECRET` set, backend is deployed, migration applied.

1. Tap Puck with iPhone.
2. Puck iOS should log `Intentional focus toggle: action=start status=started session=<id>` in its AppLogger output.
3. Mac app should simultaneously show the focus start overlay (since `triggered_by == "puck"`).
4. Tap Puck again to end the session. Mac dismisses overlay, local enforcement ends.

---

## Decisions Made Autonomously

1. **Auth approach: HS256 with `SUPABASE_JWT_SECRET` env var.**
   Supabase's newer asymmetric signing (RS256/JWKS) would be more robust, but the legacy HS256 JWT secret is:
   (a) one env var to add vs. fetching JWKS on every startup,
   (b) matches the existing intentional-JWT codepath exactly,
   (c) is what Supabase projects created before 2025 still use.
   If the user's Supabase project is already on asymmetric keys, the backend would need an additional RS256 verifier path — document this as a known follow-up if so.

2. **WebSocket handler inlines email-lookup instead of awaiting the HTTPException-raising helper.**
   `_resolve_account_from_token` uses `HTTPException` which FastAPI translates to HTTP responses, but WebSocket handlers need `websocket.close(code=…)`. Keeping the logic inlined (with the same upsert semantics) is cleaner than refactoring into a shared non-HTTPException path for ~40 lines of code.

3. **Bedtime is phone-only.**
   In `PuckCoordinator.activateMode`, I only fire `IntentionalFocusSignalClient.toggleFocus(action: .start)` for `.blocking` mode, not `.bedtime`. Bedtime is designed to affect the phone only (dim + selective app block). Propagating bedtime to the Mac would be confusing — the Mac has its own `BedtimeEnforcer`.

4. **pbxproj fix in the iOS branch.**
   The `feature/evening-mode` branch was un-buildable due to missing Xcode target refs (not a feature of this run). I included a fix commit with a clear explanation so the user can revert it if they want to surgically keep this PR scoped.

5. **I used `Task.detached` in `IntentionalFocusSignalClient.toggleFocus`.**
   This is safer than `Task` because it avoids inheriting the @MainActor context and prevents blocking on the main thread while NFC UI is dismissing.

6. **Default `triggered_by` to `"puck"` when missing in the Mac-side parse.**
   The backend `focus_sessions` table has `triggered_by DEFAULT 'puck'` and both broadcast call sites now include it; this is defensive only.

7. **Did NOT add reconnect-on-token-refresh logic on Mac.**
   The existing WS client reconnects on disconnect but does not auto-refresh the Supabase JWT. If the token expires mid-session (Supabase access tokens are 1h by default), the WS will fail to reconnect. This is acceptable for v1 — the Mac `backendClient.getAccessToken()` has its own refresh flow — but worth noting as a follow-up.

---

## Blockers / User TODOs

Numbered in priority order.

1. **Set `SUPABASE_JWT_SECRET` on Railway before merging the backend PR.**
   Without it, Supabase-authenticated clients (Puck iOS) will get 401s. This is a one-liner but it's a hard blocker.

2. **Apply migration `011_add_supabase_user_id.sql` before or at merge.**
   Additive column; can be applied safely to production without downtime.

3. **Review the iOS pbxproj fix commit (`dfc17ae`).**
   I added 4 pre-existing Evening/Bedtime files to the Xcode target to get the project building. If you want this PR to be pure scope, revert that commit and fix it separately on `feature/evening-mode`. But: this PR cannot merge green without that fix because Xcode won't build.

4. **Merge order matters:**
   - Merge backend PR FIRST (requires env var first).
   - Merge macOS PR to `puck` branch SECOND (Mac uses the WS; it tolerates backend being ahead).
   - Merge iOS PR THIRD (iOS is the originator; ok to lag).

5. **Physical Puck-tap test (not runnable overnight).**
   Requires both devices signed in to the same Supabase email, backend deployed with env var. See §Verification Test 4.

6. **Supabase asymmetric keys caveat.**
   If the user's Supabase project uses the newer asymmetric JWT signing (check: Dashboard → Settings → API → "JWT Signing Keys" shows an RSA key), the HS256 verifier will fail. In that case, swap `jwt.decode(..., algorithms=["HS256"])` to `algorithms=["RS256"]` and fetch the JWKS from `https://<project>.supabase.co/auth/v1/keys`. Current implementation assumes HS256 (legacy default). TODO if needed; one-file change in `security.py`.

---

## PR URLs

_(Filled in after `gh pr create` ran. See §Pushing & PRs.)_

- Backend: <pending push>
- iOS: <pending push>
- macOS: <pending push>

---

## Pushing & PRs

See Task 21 of the plan. User picks up the branches tomorrow morning.
