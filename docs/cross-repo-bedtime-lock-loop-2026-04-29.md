# Cross-repo: Bedtime Lock-Loop + Duration-Limited Extensions (2026-04-29)

Hand-off log for the bedtime rewrite per
[plan](superpowers/plans/2026-04-29-bedtime-lock-loop-and-duration-extensions.md).

**Status:** All code work complete; deployment / install steps remain for
the user.

---

## What shipped per repo

### Backend (`intentional-backend`)

Branch: `feat/bedtime-duration` (off `main`). Worktree at
`.claude/worktrees/bedtime-duration`.

| SHA | Title |
|---|---|
| `823d7df` | feat(bedtime): migration 016 — duration column on unlock requests |
| `65387da` | feat(bedtime): duration_minutes on unlock-request body with snap-point validation |
| `3acb3f7` | feat(bedtime): once-per-night limit + verify uses requested duration |
| `301d1e4` | feat(bedtime): partner email shows requested duration + until-wake phrasing |

What changed:
- Migration 016 adds `requested_duration_minutes INTEGER NOT NULL DEFAULT 30`
  to `bedtime_unlock_requests` with a CHECK constraint enforcing snap
  points: `(15, 30, 60, 120, -1)`.
- Pydantic body gains `duration_minutes` field with `field_validator`
  rejecting anything off-snap (422).
- `/bedtime/unlock-request` rejects 409 when a `verified` row has
  `released_until > now()` (the "you've already used your extension
  tonight" path).
- `/bedtime/unlock-verify` reads the row's `requested_duration_minutes`
  and computes `released_until = now + duration` (or for `-1`, the next
  `bedtime_config.wake_hour:wake_minute` boundary; falls back to 7:00 if
  no config).
- Email template (`send_bedtime_unlock_code_email`) now includes a
  duration phrase: "asking for 30 more minutes" / "asking for 1 more
  hour" / "asking to stay up until your normal wake time (6:30 AM)".
  Subject is now "<user> is asking for more time".

Tests: 24 in `tests/test_bedtime_unlock.py` pass (was 14 pre-016 — 10
new). Broader `tests/test_bedtime_*.py` suite all green (40 total).
One pre-existing failure in `tests/test_focus_endpoints.py` is unrelated
and exists on `main`.

### Mac (`intentional-macos-app`)

Branch: `feat/bedtime-lock-loop` (off `feat/focus-mode-consolidation`).
Worktree at `.claude/worktrees/bedtime-lock-loop`.

| SHA | Title |
|---|---|
| `eb7796c` | feat(bedtime): BedtimeLockLoop — 10s system Lock-Screen cadence |
| `ec4a48f` | feat(bedtime): consolidate state machine; lock-loop replaces overlay |
| `1899413` | feat(pill): snap to top-right on every new session start |
| `9c476e4` | feat(pill): bedtime windDown + locked modes wired from enforcer |
| `d26a6cc` | feat(bedtime): Mac unlock-request slider view + BackendClient + dashboard hook |

What changed:
- New file `BedtimeLockLoop.swift`: 10s `Timer` calling
  `NSAppleScript("keystroke \"q\" using {command down, control down}")`
  to invoke macOS's native Lock Screen. Self-cancels via tick() when
  enforcer leaves `.locked`.
- `BedtimeEnforcer` rewritten: state machine simplified to
  `inactive | windDown(t30/t15/t5/t1) | locked | released`. Removed
  `snoozed`, `overridden`, `snoozeUsedTonight`, `forceSleep` (pmset),
  overlay window management, BedtimeOverlayViewModel.
- New file `BedtimeWindDownController.swift`: schedules
  `UNUserNotificationCenter` requests at T-30 / T-15 / T-10 / T-5 / T-1
  with `.timeSensitive` interruption level (bypasses DND). Idempotent —
  identifier prefix `bedtime.winddown.` so re-scheduling clears stale
  pending without disturbing other notifications.
- Deleted file: `BedtimeOverlayView.swift`. The full-screen blanket is
  replaced by Apple's lock screen.
- `DeepWorkTimerController`: pill snaps to top-right of
  `NSScreen.main.visibleFrame` on every `show()` (16pt insets). Saved
  drag positions in UserDefaults are no longer read. Two new pill
  modes: `.bedtimeWindDown` (moon glyph, "Bedtime in N min") and
  `.bedtimeLocked` (lock glyph, "Bedtime active — locked until 6:30 AM"
  with "Ask partner" button).
- `AppDelegate.handleBedtimeStateChange(from:to:)` is the bridge: on
  `.windDown(phase)` → `pill.showBedtimeWindDown(...)`, on `.locked`
  → `pill.showBedtimeLocked(...)`, on `.inactive`/`.released` →
  `pill.dismiss()` (only when pill is in a bedtime mode — preserves
  active deep-work timers).
- `BackendClient.bedtimeUnlockRequest(durationMinutes:reason:note:)`
  with `BedtimeUnlockError.alreadyUsed` / `.noPartner` / `.other`.
- New file `BedtimeUnlockRequestView.swift` (SwiftUI): 5-snap chip
  selector + reason picker + note field. Hosted in a floating
  `NSWindow` via `NSHostingController`, opened from the pill's "Ask
  partner" tap.

`xcodebuild ... -scheme Intentional ... build` ⇒ **BUILD SUCCEEDED**.
PKG not yet built — see "manual steps" below.

### iOS (`puck-ios`)

Branch: `feat/bedtime-duration-iphone` (off `feat/bedtime-redesign`).
Worktree at `.claude/worktrees/bedtime-duration`.

| SHA | Title |
|---|---|
| `10a042a` | feat(bedtime): iOS unlock sheet — duration slider + once-per-night error |

What changed:
- `IntentionalBedtimeClient.UnlockRequestBodyDTO` gains
  `duration_minutes` field. `requestUnlock(...)` defaults to 30 to keep
  legacy call sites compiling. On backend 409 with "already" detail,
  throws `AlreadyUsedError` (LocalizedError).
- `BedtimeUnlockRequestSheet`: new 5-chip duration selector inserted
  above the reason chips (3-col grid: 15 min / 30 min / 1 hour / 2 hours
  / Until wake). Selected chip rendered in violet. `send()` passes the
  selected duration; on `AlreadyUsedError` sets `alreadyUsed=true` and
  shows the new banner.
- New file `BedtimeAlreadyUsedView.swift`: small banner with moon glyph
  shown when the sheet receives the once-per-night response.

`xcodebuild ... -destination 'generic/platform=iOS' build` ⇒
**BUILD SUCCEEDED**.

---

## Manual steps remaining (user)

1. **Apply migration 016 in Supabase.** Open the Supabase SQL editor,
   paste the contents of
   `intentional-backend/.claude/worktrees/bedtime-duration/migrations/016_add_unlock_request_duration.sql`,
   run it. **Do this before pushing the backend branch to main** —
   without the column, `/bedtime/unlock-request` will 500 on insert.
2. **Push backend.** Once the migration has been applied:
   ```
   cd /Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/bedtime-duration
   git checkout main && git merge --ff-only feat/bedtime-duration && git push origin main
   ```
   Railway auto-deploys on push. Confirm deploy is live with
   `curl -i -X POST https://api.intentional.social/bedtime/unlock-request \
   -H "X-Device-ID: <id>" -H "Content-Type: application/json" \
   -d '{"duration_minutes": 30, "reason": "test"}'` — expect 200 (or 409
   if the test account has an active extension; both prove deploy worked).
3. **Build the Mac PKG.** Run
   `cd /Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/bedtime-lock-loop && NOTARIZE=0 ./scripts/build-pkg.sh`.
   The output PKG lands at `/tmp/intentional-pkg-build/Intentional-*.pkg`.
   Install via Finder double-click + admin password (do NOT install with
   sudo from the CLI — the postinstall scripts check that the user is the
   one launching).
4. **Install iOS via Xcode.** Open
   `/Users/arayan/Documents/GitHub/puck-ios/.claude/worktrees/bedtime-duration/Puck.xcodeproj`,
   select the Puck scheme, plug in the test iPhone, and Run.
5. **End-to-end smoke test.** With both clients installed:
   1. Mac dashboard → bedtime card → set start time to 2 minutes from
      now → save.
   2. At T-2, expect a macOS notification "Bedtime in 2 minutes"
      (truncated cascade since 30/15/10/5 already elapsed).
   3. Wait for T-0. Expect screen to lock, password prompt. Re-enter,
      get back in for ~10s, locks again. The pill in the top-right
      shows "Bedtime active — locked until N AM".
   4. Tap "Ask partner" → window opens with the duration slider. Select
      15 min, send.
   5. Email arrives with "asking for 15 more minutes" phrasing.
   6. Enter the code on either device. Mac stops locking. iPhone shield
      drops.
   7. After 15 min, both re-engage. Open the sheet again → expect
      "Already used your extension tonight" banner; send button disabled.
   8. Wait through to wake alarm. Both clients show bedtime ended.

---

## Open questions / risks for the user

- **macOS 26 TCC:** First time `BedtimeLockLoop` invokes the lock
  AppleScript, the OS may prompt for Automation / System Events
  permission. If so, grant it under
  System Settings → Privacy & Security → Automation → Intentional →
  System Events. Without this, the lock loop will silently fail
  (logged via `appDelegate?.postLog`) and bedtime falls back to soft
  enforcement (pill shows but no system lock).
- **Wake-config change after verify:** If the user requests "Until
  wake" at 22:30 with wake set to 6:30, then changes wake to 7:30 at
  23:00, the original 6:30 boundary stays — backend's `released_until`
  is locked at verify time. Documented as edge case R8 in the plan.
- **Cross-tz wake math:** Backend stores wake h:m without timezone.
  For users abroad, the email phrasing "until 6:30 AM" is in the
  device's local time. No fix planned (R13).
- **iOS Live Activity:** Not modified. The locked-state Live Activity
  on the iPhone lock screen continues to mirror released_until via the
  existing `BedtimeUnlockPoller`. Verify after install that the timer
  on the lock-screen card decrements toward the partner-granted
  duration, not 8h.

---

## Skipped / out-of-scope (per plan §3)

- Endpoint Security framework integration.
- macOS FamilyControls / ManagedSettings (still unsupported).
- Brightness fade during wind-down.
- Snooze button on wind-down notifications during the lock window.
- Removing the strict-mode daemon.
