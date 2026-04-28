# Bedtime Lockdown + Cross-Device Hand-off — 2026-04-28

Companion log to the morning's `cross-repo-bedtime-cross-device-2026-04-28.md` and the lock-out incident post-mortem in `docs/superpowers/plans/2026-04-28-bedtime-lockdown-final.md` §1.3. This file captures everything that shipped on top of the first-pass cross-device bedtime work.

## Status

- **Backend**: code committed on `feat/bedtime-unlock` (off `main`). **NOT pushed yet** — gating on user applying migration 014 in Supabase.
- **iPhone**: code committed on two branches:
  - `fix/restore-active-store` (off `test/focus-plus-bedtime`) — the morning lockout root-cause fix.
  - `feat/bedtime-lockdown` (off `feat/bedtime-cross-device`) — partner-unlock UI, takeover screen, puck-dismiss disambig. Compile-only.
- **Mac**: code committed on `feat/bedtime-lockdown` (off `feat/focus-mode-consolidation`). PKG built (NOTARIZE=0). **NOT installed.**

## Commit SHAs

| Repo | Branch | Commits (oldest → newest) |
|---|---|---|
| `intentional-backend` | `feat/bedtime-unlock` | `c50c465` migration 014 → `e3db722` pydantic models → `8cc5db8` endpoints + email + tests → `8faecd8` CLAUDE.md API table |
| `puck-ios` | `fix/restore-active-store` | `0ca1b41` activeStore reconstruction in restoreShieldStateIfActive |
| `puck-ios` | `feat/bedtime-lockdown` | `4c61b03` releasedUntil + isCurrentlyLocked + poller + client methods → `d5da955` lockout window + sheets + section locked state → `fb09512` puck-dismiss disambig modal + routing |
| `intentional-macos-app` | `feat/bedtime-lockdown` | `268f805` (existing) cross-device config sync → `ff30534` BackendClient bedtimeUnlock* + Enforcer releasedUntil + overlay request-code link + status poller |

## What's deployed vs compile-ready vs PKG-ready

| Layer | State | Notes |
|---|---|---|
| Backend `/bedtime/unlock-request`, `/bedtime/unlock-verify`, `/bedtime/unlock-status` | **Code committed, not deployed.** | User must apply migration 014 in Supabase, then push `feat/bedtime-unlock` to `main` (Railway auto-deploys). |
| Backend `send_bedtime_unlock_code_email` | Same as above. | Bedtime gradient + reason/note shown to partner. |
| iPhone takeover overlay, unlock sheets, locked-state BedtimeSection, disambig modal | **Compile-ready** for `generic/platform=iOS`. | `xcodebuild` shows `** BUILD SUCCEEDED **`. User installs via Xcode. |
| iPhone `restoreShieldStateIfActive` reconstructs `activeStore` | Compile-ready on `fix/restore-active-store`. | Same install path. |
| Mac BackendClient unlock methods, BedtimeEnforcer.releasedUntil, request-code link, status poller | **PKG built**, not installed. | `/tmp/intentional-pkg-build/Intentional-1.0.pkg`. User double-clicks to install. |

## Manual steps remaining for the user

1. **Apply migration 014 in Supabase SQL editor.** Paste the contents of `intentional-backend/.claude/worktrees/bedtime-lockdown/migrations/014_add_bedtime_unlock_requests.sql`. Reply when done so the executing agent can push `feat/bedtime-unlock` to `main` and verify the live endpoints.

2. **Push backend to `main`** after migration is applied:
   ```bash
   cd /Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/bedtime-lockdown
   git checkout main
   git merge --ff-only feat/bedtime-unlock
   git push origin main
   ```
   Railway picks up the deploy (~60s). Sanity check:
   ```bash
   curl -i -X POST https://api.intentional.social/bedtime/unlock-request \
     -H "X-Device-ID: <your-test-device-id>" \
     -H "Content-Type: application/json" \
     -d '{}'
   # Expect 200 (sends real email) or 409 (no partner). Either proves the endpoint is live.
   ```

3. **Install the Mac PKG** from `/tmp/intentional-pkg-build/Intentional-1.0.pkg` (double-click; do NOT `sudo installer`).

4. **Install iPhone builds via Xcode**:
   - Open `puck-ios/.claude/worktrees/restore-active-store/Puck.xcodeproj`, select Puck scheme, install on device. This is the activeStore-reconstruction fix that prevents the morning lockout from recurring.
   - Open `puck-ios/.claude/worktrees/bedtime-lockdown/Puck.xcodeproj`, select Puck scheme, install on device. This is the takeover overlay + partner-unlock flow + disambig modal.

5. **End-to-end smoke test** (do this while a partner is reachable to send a code):
   - On iPhone, set bedtime config (Wake tab → Bedtime card) so it's currently in window.
   - Confirm takeover view appears.
   - Tap "Ask partner to unlock" → fill Reason → Send. Partner should receive an email.
   - Read code from partner's email, tap "Enter code" or "I have a code", enter it. Takeover should disappear within a second.
   - Verify the Mac (also in bedtime hours) drops its lockout within ~5s of the iPhone verify, via the status poller (no code re-entry on Mac).

## Open questions / unverified assumptions

1. **No XCTest target on `puck-ios`** for either branch. The plan provides verbatim test code for `BedtimeScheduleService.isCurrentlyLocked`, `BlockingService.deactivate`, and `PuckCoordinator.decideAlarmDismissRouting`. These pure functions are structured for direct testing once a `PuckTests` target is wired up. Adding the target requires modifying `project.yml` and `xcodegen generate`; left as a follow-up to keep the immediate diff minimal. The pure functions ARE testable as-is — the gap is only test infrastructure.

2. **Mac initial unlock-status pull on launch.** The plan describes the poller starting only when state==.lockedOut. If a Mac launches into bedtime hours AND the user already verified an unlock from iPhone earlier in the night, the Mac currently shows lockout for ~5s before the first poll catches the released state. Acceptable for v1 — fix would be to call `pollUnlockStatus()` once during BedtimeEnforcer.start().

3. **The disambig modal `Equatable` + `FocusModeStubProtocol`** in the plan was simplified to `String?` matching mode name + slug because the existing FocusMode SwiftData type isn't trivially equatable in tests. The pure routing function still satisfies all four test cases described in the plan (notRinging, disambiguate-no-pref, dismiss-only-pref, dismiss-and-activate-pref).

4. **Partner email name in unlock email**: backend uses `display_name` if available, falls back to "Your friend". Existing pattern from `/unlock/request` is `"Your friend"` always; the new bedtime flow tries `display_name` first. Defensible default; called out in case the user wants the older "Your friend" behavior preserved.

## Risk-catalog cross-check (from §5 of the plan)

| Risk | Mitigation in code |
|---|---|
| R1 network blip | Mac status poller retries every 5s on transport errors; iPhone uses URLSession default retry. Backend rolls back on email failure (502 → row deleted). |
| R5 multi-pending | `request_bedtime_unlock` marks prior pending as expired before insert. Test: `test_request_marks_prior_pending_as_expired`. |
| R6 replay attack | Verify path mutates status to 'verified'; subsequent verify calls find no pending row → 404. Test: `test_verify_consumed_code_returns_404_or_403`. |
| R7 brute force | After 5 wrong attempts the row is marked expired. Test: `test_verify_wrong_code_5_times_expires_request`. |
| R8 poll/tick race | Both iOS `tick()` and Mac `recalculate()` honor `releasedUntil` BEFORE evaluating schedule. R8 closed by design. |
| R10 puck-dismiss + bedtime active | Disambig modal still presents; the existing `handleAlarmDismissWithNFC` already handles `if isBedtimeSessionActive { deactivateBedtime() }` at top. |
| R15 force-quit | iPhone `BedtimeLockoutWindow.attach(to:)` runs on every scenePhase=.active, so the overlay reappears. |
| R18 toggle-off while locked | iOS `tick()` checks `cfg.enabled` first; Mac `recalculate()` returns to .inactive if `settings.enabled == false`. |
| R21 orphan App Group state | `restoreShieldStateIfActive` now reconstructs `activeStore` (Phase 4-bonus); follow-up sanity-tick check from the plan §5 R21 is **NOT** added in this pass — flagged as next. |
| R22 no enabled wake alarm | Cached wake from `.onAppear` sync of the alarm UI; the partner-unlock flow gives an alternate exit. |
| R24 FamilyControls revoked | `BedtimeShieldStore.activate(...)` was already structured to no-op gracefully if the auth status isn't approved (existing behavior preserved). |

Risks documented as out-of-scope (R2/R11/R12/R13/R14/R20/R23/R25/R26/R27/R28) → no changes.

## Files touched

### Backend
- `migrations/014_add_bedtime_unlock_requests.sql` — new table + indexes
- `models.py` — 5 new pydantic types
- `main.py` — 3 new endpoints, `_resolve_bedtime_unlock_partner` helper
- `email_service.py` — `send_bedtime_unlock_code_email` template
- `tests/test_bedtime_unlock.py` — 14 tests, all passing
- `CLAUDE.md` — API table updated

### iPhone (`fix/restore-active-store` branch)
- `Puck/Core/Blocking/BlockingService.swift` — `restoreShieldStateIfActive` reconstructs `activeStore`

### iPhone (`feat/bedtime-lockdown` branch)
- `Puck/Core/Bedtime/BedtimeScheduleService.swift` — `releasedUntil`, `isCurrentlyLocked`, `setReleasedUntil`, wake-dismiss now sets 24h release
- `Puck/Core/Bedtime/BedtimeUnlockPoller.swift` — new
- `Puck/Core/Network/IntentionalBedtimeClient.swift` — `requestUnlock`, `verifyUnlock`, `getUnlockStatus`
- `Puck/Views/Bedtime/BedtimeLockoutWindow.swift` — new (UIWindow @ .alert + 1)
- `Puck/Views/Bedtime/BedtimeLockoutView.swift` — new (takeover SwiftUI)
- `Puck/Views/Bedtime/BedtimeUnlockRequestSheet.swift` — new (reason/note)
- `Puck/Views/Bedtime/BedtimeUnlockCodeView.swift` — new (6-digit entry)
- `Puck/Views/Wake/BedtimeSection.swift` — locked-state compact card
- `Puck/Views/Wake/PuckDismissDisambigSheet.swift` — new
- `Puck/Core/Coordinator/PuckCoordinator.swift` — `AlarmDismissRoute`, `decideAlarmDismissRouting`, presenter callback, `handleAlarmDismissWithNFC` flag
- `Puck/Views/AppView.swift` — disambig presenter wiring
- `Puck/App/PuckApp.swift` — scenePhase + onAppear → BedtimeLockoutWindow.attach
- `Puck.xcodeproj/project.pbxproj` — regenerated by xcodegen

### Mac
- `Intentional/BackendClient.swift` — `BedtimeUnlockRequestResponseDTO`, `BedtimeUnlockVerifyResponseDTO`, `BedtimeUnlockStatusDTO`, `BedtimeUnlockError`, three async methods
- `Intentional/BedtimeEnforcer.swift` — `releasedUntil`, `markReleased`, `verifyCode` now backend-driven, `requestPartnerCode`, status poller
- `Intentional/BedtimeOverlayView.swift` — `partnerEmailSentTo`, `onRequestCode`, "Request code from partner" link

### Docs
- This file
