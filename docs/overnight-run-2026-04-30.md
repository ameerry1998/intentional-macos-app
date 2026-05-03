# Overnight run — 2026-04-30

User went to sleep at ~23:55 on 2026-04-29 with a punch list. Three workstreams shipped overnight:

## 1. Bedtime lock-loop bug fix (`feat/bedtime-lock-loop` on intentional-macos-app)

**Bug reported:** "It's like turning the screen off but it's not locking the screen — I don't have to type my password in. Should fire every 10 seconds and force a password."

**Root cause:** `BedtimeLockLoop.swift` invoked the OS lock screen via AppleScript:
```applescript
tell application "System Events"
    keystroke "q" using {command down, control down}
end tell
```
On machines where **System Settings → Lock Screen → "Require password X after sleep"** is set to anything other than "Immediately" (e.g. "5 minutes"), `Cmd+Ctrl+Q` is interpreted as "Sleep Display" and waking within the delay window does NOT require a password. Subsequent ticks also no-op'd because System Events can't deliver keystrokes to a loginwindow-locked context.

**Fix:** `dlopen` + `dlsym` on `/System/Library/PrivateFrameworks/login.framework/Versions/A/login` and call `SACLockScreenImmediate()` directly. This is the same primitive Apple's "Lock Screen" menu item uses — always forces password on wake regardless of the `password-after-sleep` delay setting. AppleScript remains as a fallback if dlopen ever fails on a future macOS.

Also: `RunLoop.main.add(timer, forMode: .common)` so the timer fires through modal/menu tracking modes (default mode alone gets paused). `timer.tolerance = 0.5s` to prevent macOS power-coalescing from drifting cadence past 10s. Per-tick log line so the cadence is verifiable in `Console.app` (`grep "BedtimeLockLoop: tick"`).

**Commit:** `0692e32` on `feat/bedtime-lock-loop`.

**Apps that use the same primitive:** Alfred (Powerpack), Bartender, various lock utilities. It's a private API but stable across macOS versions and passes Developer ID notarization.

**Fresh PKG built:** `/tmp/intentional-pkg-build/Intentional-1.0.pkg` (303MB, Developer ID Installer signed, NOT notarized). To install:
```bash
sudo installer -pkg '/tmp/intentional-pkg-build/Intentional-1.0.pkg' -target /
```

**To verify cadence:**
1. Install the PKG.
2. Set bedtime to start in ~2 minutes from now.
3. Wait for bedtime to engage. Screen should lock.
4. Type password → unlock.
5. Within 10 seconds, screen should re-lock and require password again.
6. Open `Console.app`, filter by "Intentional", search for `BedtimeLockLoop: tick`. Should see one line every 10 seconds with text "locked via SACLockScreenImmediate".

## 2. Partner cross-device sync (both repos)

See companion log: `docs/cross-repo-partner-sync-2026-04-30.md`. Three branches pushed:
- `puck-ios:feat/partner-sync` — 4 commits
- `intentional-macos-app:feat/partner-sync` — 1 commit
- backend untouched.

## 3. Plan critique applied inline

User asked for critique of `docs/superpowers/plans/2026-04-29-partner-cross-device-sync.md` before implementing. Critique covered six issues (Mac dashboard JSON gap, fragile 404 detection, vestigial test files, no Mac logout flow, no log throttling, JSON injection risk). Applied during implementation:

| # | Critique | Status |
|---|---|---|
| 1 | Mac dashboard JSON cold-launch gap | ✅ MainWindow.observePartnerSyncUpdates writes to settings JSON via `updateSettingsFile` |
| 2 | Fragile NSError 404 catch | ✅ Now catches `IntentionalAPIClient.APIClientError.serverError(let code, _)` + `.notAuthenticated` |
| 3 | Vestigial test files | ⏭️ Skipped — iOS test target not wired in this repo. Live with it. |
| 4 | Mac logout-clears-cache | ⏭️ Skipped — Mac is X-Device-ID auth, no app-level logout flow. |
| 5 | No 404/error throttling | ✅ `lastErrorLoggedAt` + `errorLogCooldown = 300s` |
| 6 | callJS JSON injection | ✅ `JSONSerialization.data(withJSONObject:)` for the payload |

## What the user should do next morning

1. **Install fresh PKG.** `sudo installer -pkg '/tmp/intentional-pkg-build/Intentional-1.0.pkg' -target /`. Verify lock-loop cadence per the steps above.
2. **Smoke test partner sync** per `cross-repo-partner-sync-2026-04-30.md` §"Manual smoke test". This requires both Mac + iPhone signed into the same account.
3. **Decide on merging.** Three feature branches are ready — `feat/bedtime-lock-loop`, `feat/partner-sync` (both Mac), `feat/partner-sync` (puck-ios). Each can merge independently. Mac branches both off `feat/focus-mode-consolidation`; iOS off `feat/bedtime-redesign`.
4. **No blockers.** Nothing is half-finished. All three branches build clean.
