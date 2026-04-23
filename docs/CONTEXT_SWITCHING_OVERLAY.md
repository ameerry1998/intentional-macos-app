# Context-Switching Overlay (v1)

Non-skippable countdown overlay that fires on every app/tab switch during an active work block. Based on the "one sec" research pattern (Grüning et al., 2023, PNAS) — short friction + clear dismiss option drives behavior change; motivational copy does not.

## Settings

The overlay is gated per-block-type under **Settings → Enforcement → Context-switch countdown**. Both Deep Work and Focus Hours columns default to **on** (Free Time is always off — no work session). Persisted in `enforcementSettings` alongside the other mechanisms (Nudge, Red Shift, Auto-redirect, Blocking Overlay, Intervention, Audio Detection). Check: `ScheduleManager.isEnforcementEnabled(.contextSwitchOverlay)`.

## Components

- **`SwitchInterventionCoordinator`** — pure-logic state machine. Owns the per-session switch counter, tier math, grace-period clock, per-target dwell ledger. No AppKit / no UI.
- **`SwitchOverlayController`** — NSWindow + SwiftUI overlay using the same `KeyableWindow` + `VisualEffectBlur` pattern as `InterventionOverlayController`.
- **`FocusMonitor`** — detects the switch (app via `NSWorkspace.didActivateApplicationNotification`, tab via `browserPollTimer` diff) and routes to the coordinator. Acts as the `SwitchOverlayDelegate`.

## Tiers

| Tier | Switch count | Countdown |
|---|---|---|
| 1 | 0–2 completed | 10s |
| 2 | 3–5 completed | 15s |
| 3 | 6+ completed | 20s (capped) |

A "completed switch" is one where the user waited out the countdown and tapped Continue. Back to work does NOT increment.

Every 15 minutes of continuous dwell in a known target (≥60s dwell in this session) drops the effective counter by 3 (one tier worth).

## Grace periods (overlay suppressed)

- First 60 seconds after `sessionStarted(at:)`
- First 60 seconds after `breakEnded(at:)`
- Entire duration of a break (`onBreak == true`)
- Switching to a known target (≥60s dwell in this session)
- Switching to Intentional itself (`com.arayan.intentional` in `exemptBundleIds`)
- Not in a work block (`inWorkSession == false`)
- Switching to the same target currently in foreground
- Switches from/to apps with `NSApplication.ActivationPolicy.accessory` (menu-bar apps — prevents battery/menu clicks from firing)
- When `FocusOverlayWindow` or `InterventionOverlayController` is already visible (no overlay-on-overlay)

The last two are `FocusMonitor`-level guards added on top of the coordinator's logic — see `FocusMonitor.appDidActivate` and the tab-diff branch in `readAndScoreActiveTab`.

## Return target policy

When the user taps "Back to work", `preferredReturnTarget(excluding:at:)` picks:
1. The known target (≥60s dwell) with the highest cumulative session dwell; or
2. The most recent non-excluded target in the session's target history.

For app targets, the controller calls `NSRunningApplication.activate`. For browser tab targets, v1 activates the browser but does not restore the specific tab (punted to v2 — would require AppleScript tab enumeration).

## Files

- `Intentional/SwitchInterventionCoordinator.swift` — logic
- `Intentional/SwitchOverlayController.swift` — UI + view model
- `IntentionalTests/SwitchInterventionCoordinatorTests.swift` — unit tests

## Known v1 limitations

- Sleep/screen lock: session keeps running, no special handling.
- Browser tab "Back to work" activates the browser but lands on whatever tab is currently showing, not the specific prior-tab URL.
- Does not intercept ⌘-Tab window-within-app switches.
- Always-allowed apps (Finder, loginwindow, QuickTime) fire the overlay the same as any other app. If they become noisy in practice, expand `exemptBundleIds`.
- Counter does not persist across app restart — quitting Intentional mid-session resets the tier.
- Tab-switch detection is gated on `browserPollTimer` (10s interval), so overlay can lag up to 10s after an actual tab switch.
