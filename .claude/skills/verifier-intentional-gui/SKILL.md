---
name: verifier-intentional-gui
description: Use when verifying Intentional macOS app changes at runtime — driving the real dashboard or pill GUI, clicking buttons, capturing screenshot evidence, or proving a fix works before claiming done
---

# Intentional GUI Verifier

## Overview

Every claim about app behavior is backed by a screenshot of the running app. Plan comprehensive manual tests BEFORE implementing; run them after. For bug fixes, capture the broken behavior on the unfixed build first (before/after evidence).

## Launch

- Verify a CHANGE → dev build: `./scripts/dev-launch.sh` (logs → `/tmp/intentional-fresh.log`). Production app keeps running; both may coexist.
- Verify CURRENT behavior → production instance already running (`pgrep -lf Intentional.app`).
- App state files: `~/Library/Application Support/Intentional/` (`focus_mode_state.json`, `daily_schedule.json`, `relevance_log.jsonl`…). Inject state BEFORE launch (app reads at startup, doesn't watch files).

## Locate (windows move — query live, every time)

Never hardcode or reuse coordinates. The user moves/resizes windows between runs.

```bash
# main window position+size
osascript -e 'tell application "System Events" to tell process "Intentional" to get {position, size} of window 1'
# live position of a sidebar/web element by its text
osascript -e 'tell application "System Events" to tell process "Intentional" to get {position, name} of every static text of scroll area 1 of group 1 of group 1 of window 1'
# floating windows (pill, overlays) are windows of the same process:
osascript -e 'tell application "System Events" to tell process "Intentional" to get {name, position, size} of every window'
```

Screen is 4K at 2x: screenshots are 3840×2160 pixels, clicks use logical 1920×1080 coords (pixel/2). AX positions are already logical.

## Click

Background clicking does NOT work — `CGEvent.postToPid` reaches the process but the WKWebView dashboard ignores non-window-server events (verified 2026-06-10). Don't retry it. Foreground burst with focus restore:

```bash
PREV=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true')
osascript -e 'tell application "Intentional" to activate'; sleep 1
swift scripts/dev-tools/click.swift <x> <y>     # real CGEvent click at logical coords
sleep 1; screencapture -x /tmp/verify-step-N.png
osascript -e "tell application \"$PREV\" to activate"   # give focus back
```

- Web-view elements: click at AX-queried text coordinates. Native windows (pill, ritual, overlays): try `click button "Name" of window X of process "Intentional"` first — native buttons expose real press actions; coordinates are the fallback.
- Click didn't land (after-screenshot unchanged)? Re-query position, retry once ±6px. Two misses → report it, don't loop.
- An AX "click at" that returns an element name is NOT proof the UI reacted — only the after-screenshot is.

## Verify

1. Screenshot BEFORE, action, screenshot AFTER — Read both, state what visibly changed.
2. No visible change = the step FAILED, even if commands returned success.
3. Corroborate pixels with the AX tree: query the window's static texts after the action — the old view's texts should be GONE (torn down), not merely covered.
4. Also read the dev log + relevant state files for the internal side of the story.
5. Probe beyond the happy path (per the built-in verify skill: at least one 🔍 step).

## Safety (the user is at this machine)

- Announce click bursts in your text BEFORE doing them; keep each burst under ~10s; always restore the user's frontmost app.
- Navigation and read-only clicks are fair game. NEVER click without explicit user approval in the current task: Start/Stop session, sweep confirm/close-all, any Delete, Strict-mode/bedtime/Content-Safety toggles.
- Never send keystrokes unless you just verified focus is in a field you put it in. **Verified means**: after the click, read the process's `attribute "AXFocusedUIElement"` (or the field's `focused` attribute) and confirm it matches the field you aimed at. A click that "succeeded" is NOT focus proof — a mis-aimed click focuses ANOTHER APP and your keystrokes go into the user's terminal/browser (happened 2026-06-10).
- Query form elements ONE AT A TIME (`text field 1`, `text field 2`) — bulk `{position, size} of every text field` returns flattened lists that mis-parse into garbage coordinates (caused the 2026-06-10 stray-keystroke incident).
- Sanity-bound every computed click: it must fall INSIDE the app window's rect (position+size you queried earlier). Outside → abort the burst, re-query.
- Only open/close YOUR OWN browser tabs (`open -ga "Google Chrome" <url>`); never touch the user's tabs.
- Focus-session tests engage real blocking — warn the user, keep sessions ≤3 min, end them when done.

## Common mistakes

| Mistake | Fix |
|---|---|
| Cached coordinates from an earlier run | Window moved. Re-query position+size every burst. |
| "Command succeeded" = "UI changed" | Only the after-screenshot proves it. |
| AX `click at` on web content silently no-ops | Use `scripts/dev-tools/click.swift` (real CGEvents). |
| Clicking while another app is frontmost | Activate + verify frontmost first; first click may only focus. |
| Pixel coords from screenshot used as click coords | Divide by 2 (retina). |
| Leaving focus stolen from the user | Restore `$PREV` frontmost app after every burst. |
