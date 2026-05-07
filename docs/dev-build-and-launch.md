# Dev Build & Launch — Bypass the PKG / Watchdog

## The Problem

In production the Mac app is installed at `/Applications/Intentional.app` (root-owned, from the PKG installer) and a launch agent at `/Library/LaunchAgents/com.intentional.agent.plist` (also root-owned) keeps it running. So during dev:

1. **`open <new-build>`** doesn't run the new build — LaunchServices resolves the `com.intentional.app` bundle ID and starts `/Applications/Intentional.app` (the OLD one).
2. **`pkill`** kills the running app, but the watchdog respawns the OLD one within seconds.
3. **`rm -rf /Applications/Intentional.app`** fails without sudo because the bundle is root-owned.
4. The user clicks the dock icon to verify changes — and the dock launches `/Applications/...` (the OLD one) too.

End result: you build a new version, run `open`, and STILL see the old sidebar / old behavior. Hours of confusion.

## The Fix — launch the binary directly

The Debug build lives in DerivedData. Instead of `open`-ing the bundle (which goes through LaunchServices), execute the binary directly. This bypasses both the registered-bundle resolution AND avoids needing sudo.

```bash
# 1. Kill the old running app (the one from /Applications)
pkill -9 -f "/Applications/Intentional.app"

# 2. (Optional but recommended) Rebuild from your current branch
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -3

# 3. Launch the binary DIRECTLY (NOT via `open`).
#    The path uses the DerivedData folder Xcode picks for the project.
DERIVED_BINARY="/Users/arayan/Library/Developer/Xcode/DerivedData/Intentional-cjpaicwfawcwqgepfrsxstqebhev/Build/Products/Debug/Intentional.app/Contents/MacOS/Intentional"
"$DERIVED_BINARY" &> /tmp/intentional-fresh.log &
echo "running at PID $!"
```

(The DerivedData folder name `Intentional-cjpaicwfawcwqgepfrsxstqebhev` is project-specific and stable — Xcode uses the same folder until you rename the project. If a project rename ever happens, find the current folder via `ls /Users/arayan/Library/Developer/Xcode/DerivedData/ | grep Intentional`.)

## Why this works

- The watchdog daemon respawns the binary at `/Applications/Intentional.app/Contents/MacOS/Intentional`. Killing that process triggers a respawn — but the respawn is the OLD binary, NOT the one we just launched from DerivedData. Our new process runs alongside it, with full window access.
- LaunchServices DOES NOT relink the bundle ID just because we ran a different binary — it stays mapped to `/Applications`. But that's fine: we don't go through LaunchServices, we exec the binary directly.
- The new process has its own NSWindow and shows up as a separate dock icon (if multiple instances are visible). The user clicks the new one.

## When this isn't enough

If you need the dock icon (the persistent one users click) to point at the new build instead of the old, you need to physically replace `/Applications/Intentional.app`. This requires sudo:

```
! sudo launchctl bootout system /Library/LaunchDaemons/com.intentional.watchdog.plist
! sudo pkill -9 -f Intentional
! sudo rm -rf /Applications/Intentional.app
! sudo cp -R /Users/arayan/Library/Developer/Xcode/DerivedData/Intentional-cjpaicwfawcwqgepfrsxstqebhev/Build/Products/Debug/Intentional.app /Applications/
! open /Applications/Intentional.app
```

(The `!` prefix runs the line in your shell with your sudo password, so Claude Code can drive it.)

After this:
- The dock icon launches the new build
- The watchdog respawns the new build (because its target path `/Applications/Intentional.app/Contents/MacOS/Intentional` now points to the Debug binary)
- Future "click the dock to test" works as expected

## Quick reference

| Goal | Command |
|---|---|
| Run new build once, see your changes | `pkill -9 -f "/Applications/Intentional.app"` then exec `…/Debug/Intentional.app/Contents/MacOS/Intentional` directly |
| Make `/Applications` dock icon point at new build (persistent) | sudo `cp` over `/Applications/Intentional.app` after killing the watchdog |
| Disable watchdog so old binary stops respawning | `sudo launchctl bootout system /Library/LaunchDaemons/com.intentional.watchdog.plist` |
| Re-enable watchdog after you're done dev'ing | `sudo launchctl bootstrap system /Library/LaunchDaemons/com.intentional.watchdog.plist` |

## What NOT to do

- **Don't `open <bundle-path>`** — LaunchServices ignores your path and starts the registered `/Applications` version.
- **Don't `xcrun simctl install`** — that's iOS Simulator only.
- **Don't try to disable Gatekeeper** — Debug builds are signed with Apple Development which is trusted; the issue isn't signing, it's bundle ID resolution.
- **Don't kill the watchdog plist file directly** — without `launchctl bootout`, it'll just reload on reboot.

## Troubleshooting

- **"I clicked the dock icon and still see old sidebar"** → you clicked `/Applications`. Either run the binary directly per above, OR sudo-replace `/Applications`.
- **"My changes aren't in the build"** → check that you're on the right branch (`git branch --show-current`). Build before launch.
- **"`xcodebuild` fails with codesign errors"** → it's signing with Apple Development; if entitlements changed recently, check `Intentional.entitlements`. Don't strip entitlements (per CLAUDE.md item 8).
- **"Two Intentional windows open"** → both the old (PID from `/Applications`) and new (PID from DerivedData) are running. Kill the old one with `pkill -9 -f "/Applications/Intentional.app"` and the watchdog respawn won't matter — your new process keeps running.

---

**TL;DR:** Don't `open` the bundle — exec the DerivedData binary directly. Watchdog respawns the OLD `/Applications` version but your new one runs alongside. To make the dock icon permanently point at new build, sudo-replace `/Applications/Intentional.app`.
