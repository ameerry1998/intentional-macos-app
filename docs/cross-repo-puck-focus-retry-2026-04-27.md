# Cross-repo: Puck → Mac focus signal persistent retry queue

**Date:** 2026-04-27
**Branches:**
- `puck-ios` — `feat/home-restructure` (or current default)
- `intentional-macos-app` — `feat/focus-mode-consolidation`

## Symptom

User taps Puck NFC on iPhone → iPhone UI shows session active → **Mac never engages enforcement.**

## Root cause

`puck-ios/Puck/Core/Network/IntentionalFocusSignalClient.swift` was fire-and-forget:

```swift
func toggleFocus(action: Action) {
    Task.detached {
        do { try await IntentionalAPIClient.shared.post(...) }
        catch { AppLogger.nfcError(...) }   // logs and gone
    }
}
```

`Task.detached` is cancelled when iOS suspends the app. NFC tap is exactly the
case where the user often locks the phone seconds later → app suspends → POST
dies before reaching `https://api.intentional.social/focus/toggle` → backend
never broadcasts → Mac stays cold.

## Verification of the diagnosis

- Mac's `/auth/me` confirmed Mac account_id = `f0ff3ad0-cb78-43a6-b399-cc412714ee87`, email `ameer.rayan@gmail.com`
- Mac's `/focus/active` for that account = `{"active":false}` despite iPhone showing a live session
- Backend's `_resolve_account_from_token` dedupes by email — same email → same account_id, so iPhone POSTs (if they completed) WOULD reach Mac
- Both clients confirmed signed in to the same email
- Therefore iPhone's POST is failing to reach the backend at all

## Fix (this branch)

`IntentionalFocusSignalClient.swift` — replace fire-and-forget with persistent
retry queue:

- `UserDefaults`-backed `[PendingOp]` queue (`intentional_focus_pending_queue_v1`)
- `toggleFocus(action:)` synchronously enqueues an op and triggers a drain
- `drain()` is `@MainActor`, wraps `UIApplication.beginBackgroundTask` for ~30s of
  post-suspend runtime, processes ops in FIFO order, removes on success
- On failure: increments attempts, breaks (preserves order), retries on next drain
- Drops ops after `maxAttempts = 10` to prevent permanent backlog
- Caps queue at `maxQueueSize = 50` (drops oldest)
- Foreground drain wired internally via
  `UIApplication.willEnterForegroundNotification` — no `PuckApp.swift` changes
  needed
- Reentrancy guard prevents concurrent drains

## Out of scope (filed for follow-up)

- **Auth refresh on 401:** if `IntentionalAPIClient.send` returns 401, drain
  retries the queued op without forcing AuthService to refresh. Supabase Swift
  SDK auto-refreshes on its own cadence, so foreground drain typically sees a
  fresh token. If queue ops are dropped after 10 attempts due to persistent
  401, that's a separate bug.
- **Account dedup on backend:** confirmed working via `_resolve_account_from_token`.
  Not changed here.
- **iOS background URLSession:** could deliver after process death without
  user interaction; current solution requires a foreground OR successful
  in-bg-window completion. If real-world testing shows queue items stuck
  for hours, upgrade to background URLSession.

## Verification plan

1. Sideload the puck-ios build to your iPhone (see "Deploying" below)
2. Tap Puck on iPhone → iPhone UI shows session active
3. Watch Mac debug log
   `tail -f /var/folders/hr/z67v8qq15jsbjkcy4z8kpvqr0000gn/T/intentional-debug.log | grep -E "🔌|🎯"`
4. Expected: within seconds of tap, `🔌 Focus signal: START` then
   `🎯 Focus Mode: off → focus`
5. To stress: tap puck, immediately lock phone, wait 60s, unlock — Mac should
   STILL engage shortly after iPhone foreground triggers the drain

## Files changed

- `puck-ios/Puck/Core/Network/IntentionalFocusSignalClient.swift` — full rewrite
  (was 43 lines, now ~140 lines)

## Mac-side state at end of session

The macOS Focus Mode consolidation
(`feat/focus-mode-consolidation`, plan at
`docs/superpowers/plans/2026-04-27-focus-mode-consolidation.md`) is functioning
end-to-end via the dashboard toggle path:

- ✅ Migration ran cleanly (`focus_mode_v1_migration_complete = 1` in defaults)
- ✅ `🎯 Focus Mode: off → focus` log entry on toggle ON
- ✅ `onStateChanged` fanout fires `📋 SCHEDULE_SYNC broadcast`,
  `👁️ onBlockChanged() — resetting all state`
- ✅ `SwitchInterventionCoordinator` correctly suppressed
  (`notInWorkSession`) when Focus Mode is off
- ✅ Switch overlay rendered correctly when Focus Mode is on (countdown UI
  fired on Cmd-Tab to Chrome)

The cross-device puck path was the only smoke-test that didn't validate; the
fix above moves it.
