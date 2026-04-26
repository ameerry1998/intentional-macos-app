# Shipping checklist — Puck pivot overnight run — 2026-04-26

Practical companion to [`cross-repo-puck-pivot-2026-04-26.md`](./cross-repo-puck-pivot-2026-04-26.md). Use this when you wake up to actually merge + deploy.

---

## Suggested order

1. **Visual icon check** (2 min) — open the Mac and iOS apps from the icon-update branches, eyeball the new icons.
2. **Merge low-risk branches** (5 min) — icons + home restructure + docs. No backend dependency.
3. **Backend deploy** (10 min) — review backend diff, deploy `feat/account-based-partner` to Railway.
4. **Verify backend live** (2 min) — `curl` the new `/devices/link-legacy` endpoint with a stub payload, confirm 401/422 (not 500).
5. **Merge iOS partner-link branch** (2 min) — once backend is live.
6. **Open the iPhone app**, sign in, check that PartnerView now shows the partner you set on Mac. **This is the success criterion** for the partner sync work.
7. **Merge distractions guard branch** (2 min) — independent of all above.
8. **Coordinate with the session indicator agent** on `feat/active-session-indicator` and the schedule + session sync spec implementation.

---

## Branches to merge — copy-paste PR descriptions

### 1. `feat/mac-app-icon` → `intentional-macos-app:main`

**Title:** `chore(icon): refresh macOS app icon with Puck brand`

**Body:**
```markdown
Refreshes all 7 macOS icon sizes (16/32/64/128/256/512/1024) with the new
Puck-branded artwork from `~/Downloads/brand/puck-app-icon-*.png`.

- Sizes 16/32/64 generated from the 1024 master via `sips` for sharpness.
- Sizes 128/256/512/1024 copied directly from source files.
- Builds clean.

Visual: open the dock icon after running.
```

### 2. `feat/ios-app-icon` → `puck-ios:main`

**Title:** `chore(icon): refresh iOS app icon with Puck brand`

**Body:**
```markdown
Replaces the single 1024×1024 universal AppIcon.png with new Puck-branded
artwork. Xcode generates the remaining sizes at build time.

Builds clean for iPhone 17 simulator.
```

### 3. `feat/home-restructure` → `puck-ios:main`

**Title:** `feat(home): restructure home, move pucks to Settings, stub Routine tab`

**Body:**
```markdown
Per 2026-04-26 product direction:

- **HomeView idleContent**: Today section is now first; focus modes follow.
  Removed the puck row card (it was leading with "pair another puck," which
  most users don't need daily) and the Reclaimed time this week sparkline
  (too prominent for home; will live on a stats page when one exists).
- **SettingsView**: new Pucks section between Account and Focus, with one
  row per registered puck (tap to edit) and an "Add a puck" row that opens
  PuckSetupView.
- **RoutineView**: gutted to a "Schedule — coming soon" placeholder. The
  full schedule (calendar with focus blocks, drag-to-edit, mirrored from
  the Mac) is the eventual direction; tonight's scope is just the
  placeholder so the tab no longer leads with the routine UI that's slated
  for replacement.

`HabitGoalCreationView` and `WeeklyReportSheet` left in place
(unreferenced for now) so the work isn't lost when the schedule view lands.

Builds clean for iPhone 17 simulator.
```

### 4. `feat/account-based-partner` → `intentional-backend:main`

**Title:** `feat(partner): account-scoped partner sync across sibling devices`

**Body:**
```markdown
Fixes the cross-device partner sync issue documented in
`intentional-macos-app/docs/cross-repo-partner-sync-investigation-2026-04-26.md`:
partner data was stored on per-device users rows scoped by X-Device-ID, so
logging into the same email account on Mac and iOS didn't propagate the
partner. This change makes the existing `/partner` endpoints fan
reads/writes across all sibling rows linked to the same account_id, without
changing the wire format or requiring data migration.

## Backend changes (`main.py`)

- New helpers `_sibling_user_ids()` and `_account_partner_via_siblings()` for
  finding rows owned by the same logged-in account.
- `PUT /partner`: writes partner_email/name to the calling row AND every
  sibling row with the same account_id. Dedupes consent emails: if any
  sibling already has confirmed consent for this partner, skip the new
  email and return confirmed.
- `DELETE /partner`: clears partner + lock state on the calling row AND
  every sibling row.
- `GET /partner/status`: when the calling device's row has no partner set
  but is linked to an account, falls back to the most-recently-active
  sibling row that does have one.
- `POST /devices/link-legacy` (NEW, Bearer auth): sets users.account_id for
  a legacy device row, drawing the account from the JWT. Required because
  iOS authenticates via Supabase directly and never calls /auth/verify
  (the only other code path that links legacy device rows). Idempotent;
  409 if the row is already linked to a different account.

## Models (`models.py`)

New Pydantic models: `LinkLegacyDeviceRequest`, `LinkLegacyDeviceResponse`.

## Tests (`tests/test_partner_sync.py`)

11 new tests covering link-legacy (200/409/404/422 cases) and the
`GET /partner/status` sibling fallback (positive + 4 negative scenarios).
Total backend test count: 45 (was 34). All green in 0.67s.

## Backwards compatibility

Behavior is unchanged for devices without an account_id (sibling list is
empty in that case). No schema migration required.

## Client work that depends on this

- iOS: `puck-ios#feat/partner-link-account` (PR coming) — adds a call to
  `/devices/link-legacy` after every Supabase auth so the iOS legacy row
  gets account-linked.
- macOS: no changes needed. Mac already calls `/auth/verify` with
  device_id, which links its row.
```

### 5. `feat/partner-link-account` → `puck-ios:main` (merge AFTER #4 deploys)

**Title:** `feat(partner): link legacy device to account on Supabase login`

**Body:**
```markdown
After every Supabase auth success, post the iOS legacy device_id to the
new backend `POST /devices/link-legacy` endpoint to set users.account_id
for the legacy users row. Required so the backend sibling-fanout in
`/partner` endpoints (intentional-backend `feat/account-based-partner`)
actually fans across this device — without the link the iOS row stays
unowned and partner data never syncs in either direction.

- `IntentionalAPIClient`: new `linkLegacyDeviceToAccount(deviceId:)`,
  Bearer auth, idempotent.
- `AuthService`: `triggerPostAuthBackendCalls` now also calls
  `linkLegacyDeviceToAccountIfNeeded` after the existing
  `IntentionalDeviceRegistration.registerIfNeeded`. Fires from all three
  auth paths (verifyOTP, signInWithApple, listenForAuthChanges →
  initialSession/signedIn). Failures are logged and swallowed — not
  user-facing — so a backend bookkeeping miss doesn't block app use.

## Verifying after merge

1. Backend `feat/account-based-partner` is already deployed.
2. Set partner on Mac (or have it already set).
3. Sign out of iOS app, sign back in.
4. Open Partner tab.
5. Within ~1 PartnerView refresh, the partner should appear.
6. Console shows: `[Auth] Linked legacy device to account: <hex>...`

Builds clean for iPhone 17 simulator.
```

### 6. `feat/distractions-guard` → `puck-ios:main`

**Title:** `feat(distractions): empty-mode confirmation across all activation paths`

**Body:**
```markdown
Extends the existing `hasApps` check (which previously only covered the
HomeView long-press → remote-start alert) to every iOS activation path,
so a synced-from-Mac mode with no iOS-side apps/categories/websites
configured can no longer silently start a no-op blocking session.

## Background

See `intentional-macos-app/docs/cross-repo-puck-pivot-2026-04-26.md`,
design note refinement on 2026-04-26: when distractions / blocklist sync
lands (account-scoped mode metadata + per-device tokens), iOS will receive
modes that have name/icon/intent/websites populated but zero local
FamilyControls tokens. Activating one without intervention is the worst
failure mode — user thinks they're blocked, nothing actually is.

## Changes

- **PuckCoordinator.swift**: new `onEmptyModeActivation` callback
  `((FocusMode, slug, proceed) -> Void)`. `activateMode()` detects
  blocking modes with all three blocklists empty and routes through the
  callback if wired; otherwise falls through with an info log so it's
  auditable. Bedtime modes are exempt (their effect is brightness / DND,
  not blocklist-based — empty bedtime still does something). Refactored
  the actual activation work into private `performActivation()` that
  the coordinator and the callback's proceed-closure both call.
- **ContentView.swift**:
  - New `PendingEmptyModeActivation` struct + `@State` binding.
  - Wires `PuckCoordinator.onEmptyModeActivation` in `setupNFCRouting` to
    surface a SwiftUI `.alert` ("No apps configured" / "Start anyway"
    or "Cancel"). proceed-closure fires on confirm.
  - `ModePickerSheet` (separate activation path that bypasses the
    coordinator and calls blockingService directly) gets the same guard
    inline + its own confirmation alert, since the picker is presented
    in a modal sheet and the coordinator-level alert can't fire on top
    of it.

Long-press → remote-start in HomeView already had this alert (see
`HomeView.swift:63` `hasApps` check) — left untouched.

## Manual smoke test

Create a focus mode, leave its FamilyActivityPicker empty, tap its NFC
puck — should now show the alert instead of starting a silent session.

Builds clean for iPhone 17 simulator.
```

### 7. `docs/puck-pivot-suite` → `intentional-macos-app:main`

**Title:** `docs(puck-pivot): overnight run notes — partner sync, distractions, schedule spec`

**Body:**
```markdown
Cross-repo log + investigation docs + spec for the 2026-04-26 overnight
work on the Puck pivot suite. Adds:

- `docs/cross-repo-puck-pivot-2026-04-26.md` — SSoT for the multi-stream
  overnight run. Two agents ran in parallel; coordination handoff is
  documented inline.
- `docs/cross-repo-partner-sync-investigation-2026-04-26.md` — root cause
  + Option A/B fix recommendations for the partner sync bug. Option A
  was implemented (see `intentional-backend#feat/account-based-partner`
  and `puck-ios#feat/partner-link-account`).
- `docs/cross-repo-puck-pivot-shipping-checklist-2026-04-26.md` —
  practical merge/deploy/verify checklist for the morning.
- `docs/superpowers/plans/2026-04-26-schedule-and-session-sync.md` —
  full implementation spec for the next implementer to pick up the
  iOS Schedule view + cross-device session sync. ~10-12 hours of work
  across phases B and C. Phase D (iOS schedule edits + distractions
  metadata sync) is sequenced for later.
```

---

## Backend deploy runbook (Railway)

The partner sync backend changes are on `feat/account-based-partner`. Here's how to deploy them safely.

### Pre-deploy review (5 min)

```bash
# Check what will deploy
gh pr view feat/account-based-partner --repo ameerry1998/intentional-backend
# Or read the diff directly
git -C ~/Documents/GitHub/intentional-backend log --oneline main..feat/account-based-partner
git -C ~/Documents/GitHub/intentional-backend diff main..feat/account-based-partner -- main.py models.py
```

What you'll see:
- `main.py`: ~150 LOC added — sibling helpers, modified PUT/GET/DELETE /partner, new POST /devices/link-legacy.
- `models.py`: ~20 LOC added — `LinkLegacyDeviceRequest`, `LinkLegacyDeviceResponse`.
- `tests/test_partner_sync.py`: 390 LOC added — 11 new tests.

No schema migration needed. No env-var changes needed.

### Deploy (Railway)

```bash
# Merge to main
gh pr create --repo ameerry1998/intentional-backend --base main --head feat/account-based-partner --title "feat(partner): account-scoped partner sync" --body-file <(echo "see commit message")
gh pr merge --auto --merge feat/account-based-partner
```

Railway auto-deploys on push to main. Watch the build:

```bash
# If Railway CLI is installed
railway logs --service intentional-backend

# Or from the dashboard
open https://railway.app
```

Build typically completes in 1-2 min.

### Post-deploy verification (3 min)

```bash
# 1. Health check still works
curl https://api.intentional.social/

# 2. New endpoint exists (will return 422 for missing body, NOT 404 — that's the success signal)
curl -X POST https://api.intentional.social/devices/link-legacy \
  -H "Authorization: Bearer fake-token-for-testing" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3"}'
# Expected: HTTP 401 (invalid token, but endpoint is wired)
# NOT expected: HTTP 404 (endpoint not deployed)

# 3. Existing partner endpoints still work
curl -H "X-Device-ID: $(your-device-id)" https://api.intentional.social/partner/status
# Should return your existing partner state, behavior unchanged
```

### Rollback (if needed)

```bash
# Revert the merge commit
git -C ~/Documents/GitHub/intentional-backend revert -m 1 <merge-commit-sha>
git -C ~/Documents/GitHub/intentional-backend push origin main
```

The change is fully backwards-compatible (unlinked devices behave exactly as before), so a rollback shouldn't break anything that was working pre-deploy.

---

## End-to-end verification (after backend deploy + iOS merge)

Reproduces the exact scenario from the original bug report.

1. **Backend live**: confirm via `curl POST /devices/link-legacy` returning 401 (not 404).
2. **macOS app**: log in if not already. Set partner to a known email if there isn't one set.
3. **iOS app**: install the post-merge build (TestFlight or local Xcode → device). Log in with the same email.
4. **Within ~5 seconds of iOS login**: console should show `[Auth] Linked legacy device to account: <hex>...`.
5. **Open Partner tab**: pull-to-refresh.
6. **Expected**: the partner from Mac appears with consent_status matching whatever it was on Mac.
7. **Bonus**: change the partner on Mac. Pull-to-refresh on iOS Partner tab. New partner appears.
8. **Bonus**: remove partner on iOS. macOS partner-status (visible in Mac dashboard) should also clear.

If step 6 fails, check:
- Did the link-legacy call succeed? Console log on iOS, or check `users` table in Supabase: the iOS device's row should have `account_id` set.
- Is the consent record present? Check `partner_consent` table by `user_id`.

---

## Coordination notes

The session indicator agent is working concurrently. Their branch is
`puck-ios:feat/active-session-indicator`. When you sync up:

- Their work (8325ba1: "show 'No active session' card on idle home") is
  local-only — no backend dependency, can merge anytime.
- Their next pickup (per the handoff in the cross-repo log) is the
  schedule + session sync spec implementation. Direct them to
  `docs/superpowers/plans/2026-04-26-schedule-and-session-sync.md`.

---

## What's NOT included in tonight's run

- Lazy-prompt FamilyControls picker for synced empty modes (mentioned in
  the design note). Requires UX design decisions; the narrow guard ships
  the safety mechanism without the new flow.
- Active session indicator cross-device wiring (depends on backend bits
  spec'd in Phase C — that's the session indicator agent's pickup).
- iOS schedule editing (Phase D in the spec).
- Production deploy of the backend (left for the user — code is ready).
- Any merges to main of any repo.
