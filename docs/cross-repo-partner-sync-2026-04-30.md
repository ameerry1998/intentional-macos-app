# Partner Cross-Device Sync — 2026-04-30 hand-off

**Goal:** when a partner is set + confirmed via email link on one device, the other device(s) on the same account pick it up automatically without re-entry.

**Status: shipped on feature branches, ready to merge after manual smoke test.**

## What shipped

### iOS — `puck-ios` branch `feat/partner-sync`

Three commits on top of `feat/bedtime-redesign`:

| SHA | Subject |
|---|---|
| `2f9a1c2` | feat(partner): PartnerSyncService — fetches /partner/status, writes UserDefaults |
| `d9cee9b` | feat(auth): post authStateDidChange so PartnerSyncService can wipe on logout |
| `e583a4f` | feat(partner): wire PartnerSyncService from PuckApp scene phase |
| `131ff6d` | fix(partner): catch typed APIClientError + throttle error logging |

`PartnerSyncService` (singleton) fetches `/partner/status` on launch, on `willEnterForeground`, and every 60s while active. Writes the result to `UserDefaults` keys `partnerName`, `partnerEmail`, `partnerConsentStatus` — which the existing `@AppStorage` bindings in `PartnerView`, `BedtimeDetailView`, `BedtimeUnlockRequestSheet`, `BedtimeCard`, and `BedtimeScheduleService` (Live Activity) auto-pick-up. Drops cache on logout via `authStateDidChange` notification posted by `AuthService`.

Critique fix applied: original 404-detection used `error as NSError where error.code == 404` which never matches because `IntentionalAPIClient` throws typed `APIClientError.serverError(httpStatusCode, _)` cases. Now matches the typed enum + `.notAuthenticated`. All other errors throttle to one log per 5 min.

### Mac — `intentional-macos-app` branch `feat/partner-sync`

| SHA | Subject |
|---|---|
| `08df9e4` | feat(partner): Mac-side cross-device sync via /partner/status |

`PartnerSyncService.swift` (singleton) fetches `/partner/status` via `BackendClient.getPartnerStatus()` (already existed) on launch + `NSApplication.didBecomeActiveNotification` + every 60s. Posts `Notification.Name.partnerSyncDidUpdate`.

`MainWindow.swift` observes the notification, persists the values into the dashboard settings JSON via `updateSettingsFile { settings in ... }` (so they survive a page reload), and pushes the live values into the running dashboard via the existing `_partnerStatusResult` JS receiver. Payload uses `JSONSerialization` to escape partner names with apostrophes/quotes.

`AppDelegate.swift` initializes `PartnerSyncService.shared`, calls `configure(appDelegate:backendClient:)` after `BackendClient` is constructed, and calls `start()`.

Critique fixes applied:
- ✅ Settings JSON persistence (not just `UserDefaults`) so cold-launch dashboard renders correct partner.
- ✅ JSONSerialization payload (no quote-injection bugs).
- ❌ Mac-side logout-clears-cache deliberately skipped — Mac is X-Device-ID auth, no in-app sign-out flow comparable to iOS.

### Backend

Zero changes. The endpoints + sibling logic in `intentional-backend/main.py` already do the right thing per inspection (`POST /partner` writes to all sibling rows; `GET /partner/status` falls back to siblings).

---

## How it works end-to-end

1. User has Mac + iPhone signed into the same account (linked via account_id on the backend).
2. User sets partner email + name on iPhone. iPhone calls `POST /partner` → backend writes the partner to the iPhone's user row AND every sibling user row (the Mac's row). Partner gets a confirmation email.
3. Partner clicks confirmation link → backend flips `partner_consent.status` to `confirmed` for the user row that initiated.
4. User's Mac wakes / app foregrounds → `PartnerSyncService.pullAndApply()` fires `GET /partner/status`. Backend reads partner from Mac's user row (already populated by step 2 sibling-write). Returns `{partner_email, partner_name, consent_status: "confirmed"}`.
5. Mac's MainWindow.observePartnerSyncUpdates pushes the values into dashboard.html via `_partnerStatusResult` AND persists them to settings JSON. Dashboard re-renders with the partner's name.
6. iPhone's `PartnerSyncService.pull()` fires every 60s while active. UserDefaults updates → `@AppStorage("partnerName")` triggers SwiftUI redraw → BedtimeUnlockRequestSheet, PartnerView, etc. all show the partner's name.

---

## Manual smoke test (next morning)

1. **Mac smoke test.** Sign into Mac as user A. Don't set partner on Mac. Wait for `PartnerSyncService` to fire (≤60s after foreground). Open dashboard → Lock page. Should show no partner ("Add an accountability partner").
2. **iOS set + confirm flow.** On iPhone (same account), open Bedtime → set partner email = a real address you can check. Confirm via email link.
3. **Mac picks up automatically.** Switch to Mac, foreground the app. Within ~60s the dashboard should update — partner name appears, consent status flips to "confirmed". Check Console.app for `👥 PartnerSync: email=..., name=..., consent=confirmed`.
4. **iPhone reflects.** Foreground iPhone again. Bedtime card / unlock sheet should show the partner's name.
5. **Logout-clears.** On iPhone, sign out via settings. Re-sign in as a *different* user. Partner cache should be empty (no leftover partner from user A). Mac doesn't have an in-app sign-out so this only applies to iOS.

---

## Risks not covered

- **Two devices NOT on the same account.** If Mac and iPhone are on different `account_id`s, this sync doesn't bridge them — that's a separate "link my devices" feature. Workaround: sign in with the same email on both.
- **Polling interval = 60s.** "Just confirmed" propagation up to a minute. Push-on-confirm is a future polish.
- **Partial network failure.** A single failed pull doesn't crash; throttled error log every 5 min until the next success.

---

## What's NOT shipped

- APNs push from backend on consent change.
- In-app toast / notification when partner confirms.
- Mac sign-out flow → cache wipe (Mac doesn't have explicit sign-out).
- Cross-account device linking.

---

## Branches to merge

```
puck-ios:                 feat/partner-sync (4 commits) → feat/bedtime-redesign or main
intentional-macos-app:    feat/partner-sync (1 commit on top of feat/focus-mode-consolidation)
```

Both branches built clean (`xcodebuild ... ** BUILD SUCCEEDED **`).

## Companion: bedtime lock-loop fix on `feat/bedtime-lock-loop`

Same overnight session also fixed the bedtime lock-loop bug where macOS's lock screen wasn't actually requiring a password. See the entry in `docs/overnight-run-2026-04-30.md` for that one — fresh PKG built at `/tmp/intentional-pkg-build/Intentional-1.0.pkg` (303MB, Developer ID signed).
