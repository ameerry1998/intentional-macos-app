# Focus Mode Redesign — Design Spec

## Problem

The current focus system is schedule-driven only — users plan time blocks and enforcement follows the schedule. There's no way to trigger focus on-demand, no concept of blocking profiles (reusable lists of blocked apps/sites), and no integration with Puck (physical focus device). Free time is always available as an escape hatch, which undermines enforcement for users who need hard constraints.

## Solution

A blocking profile system with on-demand focus sessions, Puck integration (mocked for now), and an adapted Intentional Mode that removes the free time option during Puck focus.

---

## Blocking Profiles

### Data Model

```json
// blocking_profiles.json
[
  {
    "id": "uuid-1",
    "name": "Distracting Apps & Sites",
    "blockedDomains": ["reddit.com", "twitter.com", "x.com", "youtube.com", "instagram.com", "facebook.com", "tiktok.com", "twitch.tv", "discord.com", "snapchat.com"],
    "blockedAppBundleIds": ["com.spotify.client", "tv.twitch.app", "com.hnc.Discord", "com.valvesoftware.steam"],
    "isDefault": true,
    "isAlwaysActive": false
  }
]
```

- **One built-in preset**: "Distracting Apps & Sites" — ships with common social media, video, entertainment domains and apps. Cannot be deleted (can be edited).
- **Custom profiles**: Users create their own. Each profile has a name, list of blocked domains, list of blocked app bundle IDs.
- **Always-active toggle**: Per-profile `isAlwaysActive` boolean. When ON, the profile is enforced 24/7 regardless of whether a focus session is running. Free time does not override always-active profiles. Only earned browse time or a partner code can temporarily bypass always-active blocks. When OFF (default), the profile only blocks during active focus sessions.
- **Partner-lockable**: When accountability partner is set, profiles can't be edited during focus.
- **Stored in**: `~/Library/Application Support/Intentional/blocking_profiles.json`

### Profile Management UI

Lives in the existing Distractions settings page (replaces the current flat list). Shows:
- List of profiles as cards
- Each card shows name + count of blocked items
- Tap to expand/edit: add/remove domains and apps
- "+ Create Profile" button
- Default profile has a badge, can't be deleted

---

## Focus Sessions

### Active Session State

```json
// focus_session.json — exists only during active focus
{
  "startedAt": "2026-04-14T23:00:00Z",
  "activeProfileIds": ["uuid-1", "uuid-2"],
  "intention": "writing blog post about ADHD",
  "aiScoringEnabled": true,
  "triggeredByPuck": false
}
```

- **Persisted to disk** on session start. Restored on app launch if file exists (survives crashes, daemon relaunch, restarts).
- **Deleted** when focus ends.
- `triggeredByPuck: true` means the session can only be ended by a Puck re-tap (no in-app end button).

### Starting Focus (App-only, no Puck)

User clicks "Start Focus" in the app (menu bar icon or dashboard button):
1. Full-screen overlay appears (dark, KeyableWindow, `.screenSaver` level)
2. Shows list of blocking profiles as selectable chips (multi-select)
3. Text field: "What are you working on?" (for AI intention, optional)
4. Validation: at least one profile selected OR intention typed
5. "Start Focus" button → writes `focus_session.json`, merges all selected profiles' block lists, passes to WebsiteBlocker + FilterManager, sets intention on FocusMonitor, dismisses overlay
6. Enforcement: Deep Work escalation (nudge → redirect → grayscale → intervention)

User clicks "End Focus" (or keyboard shortcut):
1. Deletes `focus_session.json`
2. Restores original distraction list from settings
3. Clears FocusMonitor state, dismisses any active overlays

### Starting Focus (Puck Tap)

1. Puck signal arrives (keyboard shortcut mock for now, backend API later)
2. **Immediately**: default "Distracting Apps & Sites" profile activates. Enforcement starts before the overlay even renders. This is the non-negotiable floor.
3. Full-screen overlay appears: "Distractions are now blocked. Want to plan your focus?"
   - **"Just block distractions"** — dismiss overlay. Default profile enforced. Done.
   - **"Plan my session"** — expand to show: additional profiles to select, AI intention text field, hourly planning
4. `focus_session.json` written with `triggeredByPuck: true`
5. **No free time option exists.** No way to unblock from the Mac. Only Puck re-tap ends the session.

### Ending Focus (Puck Re-tap)

1. Puck signal arrives
2. Delete `focus_session.json`
3. Restore everything
4. Phone also unlocks (handled by Puck backend, not Mac app)

### App Launch During Active Session

If `focus_session.json` exists on launch:
- Restore session immediately
- Re-merge block lists from active profile IDs
- Re-set intention on FocusMonitor
- Skip the picker overlay — go straight to enforcement
- If `triggeredByPuck: true`, disable in-app end button

---

## Intentional Mode Integration

### Three states:

| Setting | Behavior |
|---------|----------|
| **Off** | No hourly planning overlays. Always-active profiles still enforce. Manual focus start/stop available. |
| **On (no Puck)** | Unplanned hour → full-screen overlay, must plan or pick free time. Free time is an option (but does NOT override always-active profiles). |
| **On + Puck active** | Same overlay each hour, but NO free time option. Choices: pick additional blocking profile, set AI intention, or "Continue with default blocking" (dismiss and keep working, distractions still blocked). |

### Toggle

Settings > Intentional Mode: On / Off. Behavior adapts automatically based on whether a Puck session is active. No extra setting needed — Puck presence removes free time, that's it.

---

## AI Scoring Integration

### Settings toggle

Settings > AI Relevance Scoring: On / Off (labeled "Experimental")

### When ON + intention provided:

- RelevanceScorer receives the intention text
- Scores all content not already on the block list
- Deep Work escalation applies to AI-flagged irrelevant content
- Existing logic unchanged — same prompts, same MLX model, same keyword pre-filter

### When OFF or no intention:

- Only block list enforcement. No AI scoring.
- Apps/sites not on the block list are freely accessible.

---

## Puck Signal (Mock for Now)

### Keyboard shortcut trigger

- Global hotkey: `Cmd+Shift+P` (configurable)
- Toggles Puck focus: first press starts, second press ends
- Identical behavior to what Puck hardware tap will do

### Menu bar

- When Puck focus active: menu bar icon changes (e.g., filled circle vs outline)
- Click menu bar → "End Focus" option (only visible when `triggeredByPuck: false`)

### Future Puck integration (not built now, PRD written)

- Puck iOS app → `POST /focus/toggle` → backend → WebSocket to Mac app
- Mac app listens for focus signal via persistent WebSocket connection to `api.intentional.social`
- Signal payload: `{ "action": "start" | "stop", "deviceId": "..." }`

---

## Enforcement Priority

**Schedules are stripped.** Puck on/off is the primary model. There is no daily schedule planning. The enforcement model is:

```
Always-active profiles (enforced 24/7, independent of sessions)
    ↓ cannot be bypassed by
Free Time / idle state (only earned browse or partner code can bypass)

Puck focus session (if active)
    ↓ adds
Session-only profiles (non-always-active, enforced during focus sessions only)

Bedtime (independent, always wins over everything)
```

- **Always-active profiles** block 24/7. Free time does not override them. Only earned browse or a partner code can temporarily bypass.
- **Non-always-active profiles** only enforce during an active focus session (Puck tap or app-initiated).
- **Earned browse** is the pressure valve for always-active blocks — gives users controlled access without disabling the profile.
- Puck focus = Deep Work enforcement level, always
- Bedtime always wins — if bedtime activates during Puck focus, bedtime overlay takes over

---

## Architecture

### New files:
- `Intentional/BlockingProfileManager.swift` — CRUD for blocking profiles, merging, persistence
- `Intentional/FocusSessionManager.swift` — start/stop/restore focus sessions, writes focus_session.json
- `Intentional/FocusStartOverlay.swift` — SwiftUI view for the "start focus" picker overlay

### Modified files:
- `AppDelegate.swift` — instantiate new managers, wire Puck signal
- `MainWindow.swift` — add profile management UI handlers, focus start/stop handlers
- `WebsiteBlocker.swift` — accept merged block list from FocusSessionManager
- `FocusMonitor.swift` — accept intention + enforcement level from FocusSessionManager
- `IntentionalModeController.swift` — remove free time option when Puck session active

### NOT modified:
- `RelevanceScorer.swift` — existing logic is sufficient
- `ScheduleManager.swift` — schedules are stripped for now; Puck on/off is the primary model
- `BedtimeEnforcer.swift` — independent system
- `DaemonXPCProtocol.swift` — no new daemon calls needed

---

## Deliverables

1. **Mac app changes** — blocking profiles, focus session manager, start overlay, mock Puck trigger, Intentional Mode adaptation
2. **PRDs** — detailed specs for Puck backend repo and Puck iOS repo describing the focus signal flow, API contract, and required changes

---

## Testing Strategy (TDD)

1. `BlockingProfileManager` — CRUD operations, merging multiple profiles, default profile behavior
2. `FocusSessionManager` — start/stop/restore, persistence, Puck vs app-triggered behavior
3. Enforcement priority — Puck overrides schedule, bedtime overrides Puck
4. Intentional Mode — free time hidden during Puck, visible without Puck
