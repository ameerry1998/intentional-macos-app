# Block Type Enforcement Settings

## Task

Implement per-block-type enforcement settings. Users should be able to toggle individual enforcement mechanisms on/off for Deep Work and Focus Hours block types. This involves changes to:

1. **`dashboard.html`** — Settings page: add a "Focus Enforcement" section with toggles. Today page: add ⋯ menu to schedule header buttons.
2. **`FocusMonitor.swift`** — Gate each enforcement mechanism behind its toggle before firing.
3. **Settings persistence** — Add new fields to `focus_settings.json` (via the existing `GET_SETTINGS`/`SAVE_SETTINGS` message flow in `MainWindow.swift`).

Read CLAUDE.md for full architecture context. The key files are `dashboard.html` (all UI), `FocusMonitor.swift` (enforcement logic), `MainWindow.swift` (JS↔Swift bridge and settings I/O), `GrayscaleOverlayController.swift` (red shift effect), `NudgeWindowController.swift` (nudge cards), `FocusOverlayWindow.swift` (blocking overlay), and the intervention overlay controller.

**Important: Background audio detection is a NEW feature that doesn't exist yet.** Include the toggle in the UI and settings persistence, but the actual detection logic is not implemented yet. The toggle should be saved and readable by FocusMonitor, but since there's no background audio detection code to gate, the toggle won't have a runtime effect until that feature is built separately. Wire it up so it's ready.

## Overview

Users should be able to configure which enforcement mechanisms are active for each block type (Deep Work and Focus Hours). Free Time has no enforcement, so it gets no settings.

Settings are configured in the Settings page and persist to disk. When the account is locked (partner lock or self-lock), these settings become read-only — the user can see them but cannot change them.

---

## Entry Points

### 1. Three-dot menu on schedule buttons (Today page)

The `+ Deep Work` and `+ Focus Hours` buttons in the schedule header each get a subtle three-dot menu icon (⋯) on their right side. Clicking it navigates to the Settings page, scrolled/focused to the enforcement settings for that block type.

```
SCHEDULE                    [+ Deep Work ⋯] [+ Focus Hours ⋯] [+ Free Time]
```

- The ⋯ is small, low-opacity (e.g., 40% opacity, brightens on hover)
- Only Deep Work and Focus Hours get the dots. Free Time has no enforcement settings.
- Clicking ⋯ navigates to Settings page → Focus Enforcement section, with the relevant block type expanded/highlighted
- Clicking the main button area (the "+" part) still adds a new block as it does today — the ⋯ is a separate click target on the right edge

### 2. Settings page section

A "Focus Enforcement" section in the Settings page. Contains two subsections: Deep Work and Focus Hours. Each shows the toggle list below.

---

## Toggles Per Block Type

### Deep Work

| Toggle | Default | Description shown to user |
|--------|---------|--------------------------|
| Nudge notifications | ON | Show a reminder when you go off-task |
| Screen red shift | ON | Screen gradually shifts red while distracted |
| Auto-redirect | ON | Redirect your browser back to your last work page |
| Blocking overlay | ON | Full-screen block when you can't justify the distraction |
| Intervention exercises | ON | Mandatory focus exercise after 5 min of distraction |
| Background audio detection | ON | Detect distracting sites playing audio in background tabs |

### Focus Hours

| Toggle | Default | Description shown to user |
|--------|---------|--------------------------|
| Nudge notifications | ON | Show a reminder when you go off-task |
| Screen red shift | ON | Screen gradually shifts red while distracted |
| Auto-redirect | OFF | Redirect your browser back to your last work page |
| Blocking overlay | OFF | Full-screen block when you can't justify the distraction |
| Intervention exercises | ON | Mandatory focus exercise after 5 min of distraction |
| Background audio detection | ON | Detect distracting sites playing audio in background tabs |

The key difference: Deep Work defaults to everything on. Focus Hours defaults to auto-redirect and blocking overlay off (these are the most aggressive/disruptive interventions — redirecting a tab and locking the screen). Users can enable them for Focus Hours if they want stricter enforcement.

---

## Settings Page Layout

Inside the Settings page, the Focus Enforcement section should be compact. Two blocks side by side or stacked, each with a header and 6 toggles:

```
FOCUS ENFORCEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  DEEP WORK                           FOCUS HOURS

  ◉ Nudge notifications               ◉ Nudge notifications
  ◉ Screen red shift                   ◉ Screen red shift
  ◉ Auto-redirect                      ○ Auto-redirect
  ◉ Blocking overlay                   ○ Blocking overlay
  ◉ Intervention exercises             ◉ Intervention exercises
  ◉ Background audio detection         ◉ Background audio detection

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If the window is too narrow for side by side, stack them vertically (Deep Work first, then Focus Hours).

### When account is locked

All toggles render as disabled/grayed out. A small lock icon and message appears:

```
FOCUS ENFORCEMENT                                            🔒 Locked
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Settings are locked. Contact your accountability partner to unlock.
  ...grayed out toggles...
```

---

## How Each Toggle Affects Enforcement

When a toggle is OFF, the corresponding mechanism is completely skipped in FocusMonitor. The distraction counter still accumulates (so other mechanisms still trigger at their thresholds), but the disabled mechanism simply doesn't fire.

### Nudge notifications OFF
- No floating nudge cards appear (Level 1, Level 2, red warning — all suppressed)
- The "This is relevant" justification flow is also unavailable (since it lives inside the nudge)
- Other mechanisms (red shift, intervention games) still trigger at their normal thresholds

### Screen red shift OFF
- No gamma shift, no vignette overlay
- Distraction counter still accumulates normally
- Everything else fires as normal

### Auto-redirect OFF
- Browser tab is never programmatically redirected to the last relevant URL
- During Deep Work with redirect off, the browser behavior becomes more like Focus Hours: nudges + red shift + intervention, but no tab hijacking
- The `deepWorkRedirectedSites` instant-redirect-on-revisit system is also disabled

### Blocking overlay OFF
- The full-screen "Back to work" overlay never appears
- For Deep Work: if a "This is relevant" justification is rejected by AI, instead of showing the blocking overlay, show a persistent nudge (Level 2 behavior)
- The intervention game (at 300s) is a separate toggle and still fires independently

### Intervention exercises OFF
- No mandatory game/reflection at the 300s cumulative distraction threshold
- The red warning nudge at 240s ("intervention in 60s") is also suppressed since there's no intervention coming
- Distraction still accumulates but caps out at nudge-level enforcement

### Background audio detection OFF
- macOS app does NOT send `MUTE_BACKGROUND_TAB` to the extension when user switches away from browser
- macOS app does NOT pause distracting apps (Spotify, Apple Music, etc.) via AppleScript
- Background YouTube/Netflix/etc. plays without interruption
- The earned browse pool still deducts (heartbeat-based deduction is separate from enforcement)

### Background audio detection ON (implemented)
- When user switches to a non-browser/non-distracting app during a work block, FocusMonitor calls `muteBackgroundDistractingAudio()`
- Extension receives `MUTE_BACKGROUND_TAB` → uses `chrome.scripting.executeScript` to inject `video.pause()` into all audible distracting tabs (works on any site: YouTube, Netflix, Amazon Prime, Rumble, etc.)
- macOS app pauses known media apps via AppleScript (Spotify, Apple Music, Apple TV, Podcasts)
- `music.youtube.com` is exempted (not paused)
- Re-broadcasts every ~10s via work tick timer (browser tabs only, not apps)
- **Important:** Never uses `chrome.tabs.update({muted: true})` — only `video.pause()`. Tab-level muting causes unrecoverable audio loss.

---

## Persistence

Settings are stored in `focus_settings.json` alongside existing settings. New fields:

```json
{
  "enabled": true,
  "focusEnforcement": true,
  "aiModel": "apple",
  "deepWorkEnforcement": {
    "nudgeNotifications": true,
    "screenRedShift": true,
    "autoRedirect": true,
    "blockingOverlay": true,
    "interventionExercises": true,
    "backgroundAudioDetection": true
  },
  "focusHoursEnforcement": {
    "nudgeNotifications": true,
    "screenRedShift": true,
    "autoRedirect": false,
    "blockingOverlay": false,
    "interventionExercises": true,
    "backgroundAudioDetection": true
  }
}
```

If the keys are missing (existing users upgrading), default to the values in the table above. This ensures backward compatibility — existing users get the same behavior they had before.

---

## Implementation Notes

### FocusMonitor changes
FocusMonitor needs access to the current block type's enforcement settings. Before triggering any mechanism, check the corresponding toggle:

```
Before showing nudge → check enforcementSettings.nudgeNotifications
Before applying red shift → check enforcementSettings.screenRedShift
Before auto-redirecting → check enforcementSettings.autoRedirect
Before showing blocking overlay → check enforcementSettings.blockingOverlay
Before showing intervention → check enforcementSettings.interventionExercises
Before flagging background audio → check enforcementSettings.backgroundAudioDetection
```

The enforcement settings object should be resolved based on the current block type:
- If current block is Deep Work → use `deepWorkEnforcement`
- If current block is Focus Hours (not free) → use `focusHoursEnforcement`
- If current block is Free Time or no block → skip all enforcement (as today)

### Dashboard (Settings page)
- Add "Focus Enforcement" section to Settings page HTML
- Toggles use the same style as existing settings toggles
- Load via `GET_SETTINGS` message, save via `SAVE_SETTINGS` message
- When navigating from the ⋯ menu, pass a query param or message to scroll to the right section

### Dashboard (Today page - three-dot menu)
- Add a ⋯ element inside/adjacent to the `+ Deep Work` and `+ Focus Hours` buttons
- Style: small, subtle, low opacity, brightens on hover
- Click handler: navigate to Settings page with focus on the relevant block type section
- The ⋯ click must NOT trigger the "add block" action — separate click targets

### Settings sync
When enforcement settings change, broadcast `SETTINGS_SYNC` to all connected extensions (existing pattern). FocusMonitor should re-read settings on change.

### Locked state
When `lockMode` is `partner` or `self`, the toggles in the Settings page render as disabled. The three-dot menu on the Today page can still navigate to Settings (so the user can see their config), but all toggles are non-interactive.
