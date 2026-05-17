# Dev Build & Launch — Bypass the PKG / Watchdog

## The Problem

In production the Mac app is installed at `/Applications/Intentional.app` (root-owned, from the PKG installer). Multiple layers fight you when you try to run a fresh Debug build:

1. **`open <new-build>`** doesn't run the new build — LaunchServices resolves the `com.intentional.app` bundle ID and starts `/Applications/Intentional.app` (the OLD one).
2. **The LaunchAgent** at `/Library/LaunchAgents/com.intentional.agent.plist` keeps the OLD app running. `pkill` triggers a respawn within ~10s.
3. **The system-level LaunchDaemon** at `/Library/LaunchDaemons/com.intentional.watchdog.plist` re-installs the LaunchAgent on logout/reboot if you remove it.
4. **`rm -rf /Applications/Intentional.app`** fails without sudo (root-owned).
5. **PKG-built `Intentional.app`** (the one in `/tmp/intentional-pkg-build/`) **cannot be exec'd standalone.** It's Developer-ID-signed; AMFI SIGKILLs it within ~50ms of launch with no crash report, exit code 137. Log shows splash lines then nothing.
6. **The Debug binary from DerivedData** can be exec'd — but `main.swift` has a single-instance check that exits silently as a "duplicate launch" unless one specific env var is set.
7. **Stale DerivedData hash.** This doc previously hard-coded `Intentional-cjpaicwfawcwqgepfrsxstqebhev`, but Xcode picks a new hash on certain project changes (worktree paths, project file edits, derived-data resets). Always discover dynamically.

End result if you skip any of these: you build a new version, the launch appears to succeed, and you STILL see the old sidebar / old behavior because either (a) LaunchServices ran `/Applications`, (b) AMFI killed your binary, or (c) main.swift's duplicate-detect silently exited.

## The Procedure That Actually Works

```bash
# 1. Build Debug (NOT a PKG — PKG binaries get AMFI-killed standalone).
#    Run from the repo root or worktree root.
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5

# 2. Discover the current DerivedData folder dynamically.
#    `ls -dt` sorts newest-first; we want the one xcodebuild just wrote to.
DERIVED_DIR=$(ls -dt /Users/arayan/Library/Developer/Xcode/DerivedData/Intentional-*/Build/Products/Debug 2>/dev/null | head -1)
DERIVED_BINARY="$DERIVED_DIR/Intentional.app/Contents/MacOS/Intentional"
ls -la "$DERIVED_BINARY"  # sanity check + mtime confirms freshness

# 3. THE CRITICAL STEP: set __XCODE_BUILT_PRODUCTS_DIR_PATHS before exec'ing.
#    Xcode sets this env var when running via the Run button. main.swift checks
#    `ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil`
#    (see main.swift:106) to decide whether to take the "Xcode launch — terminate
#    the existing PID, bootout the LaunchAgent + Login Item, take over as the
#    primary instance" branch (main.swift:113-168). Without this env var, your
#    new process takes the `else` branch at main.swift:169 — "Normal duplicate
#    launch — silently exit" — and disappears within 1s. NO error message, NO
#    log line beyond the early NSLog splash. This is THE thing that breaks new
#    sessions trying to figure out why their build "doesn't work."
nohup env __XCODE_BUILT_PRODUCTS_DIR_PATHS="$DERIVED_DIR" "$DERIVED_BINARY" \
  &> /tmp/intentional-fresh.log &
NEW_PID=$!
echo "Launched PID $NEW_PID"
sleep 5

# 4. Verify the new instance is alive AND it took over (the old PIDs are gone).
pgrep -lf "Intentional.app/Contents/MacOS/Intentional" | head -5
tail -20 /tmp/intentional-fresh.log
```

## Reading the launch log to diagnose failures

Expected success signature in `/tmp/intentional-fresh.log`:

```
🚀🚀🚀 MAIN.SWIFT EXECUTING - PID: <new>
📁 NSTemporaryDirectory: ...
🔍 Diagnostic log path: ...
⏰ Launch time: ...
🆔 PID: <new>
📡 Launched via extension: false
🏗️ Creating NSApplication and AppDelegate...
✅ AppDelegate assigned, calling NSApplicationMain...
=== applicationDidFinishLaunching CALLED (NSLog) ===
🌫️ [FORCE] forceRestoreSaturation called
🌫️ [FORCE] ✅ All restored
[DaemonXPC] Connection established to com.intentional.daemon.xpc
```

| Log stops at... | Diagnosis | Fix |
|---|---|---|
| `📡 Launched via extension: false` (no `🏗️ Creating NSApplication`) | AMFI killed it. You ran the PKG-built binary, not the Debug binary. | Re-run from DerivedData path, NOT `/tmp/intentional-pkg-build/`. |
| `applicationDidFinishLaunching CALLED`, then process dies in <2s | `main.swift:169` "Normal duplicate launch — silently exit." Env var missing. | Re-launch with `env __XCODE_BUILT_PRODUCTS_DIR_PATHS="$DERIVED_DIR"` prefix. |
| No log file at all | Bash backgrounding failed or the binary path is wrong. | `ls -la "$DERIVED_BINARY"` to confirm path. |
| `[DaemonXPC] Connection established` | Success — you should see the new build's window. | — |

## Why the env-var trick works

`main.swift:104-181` implements a single-instance guard. When a second `Intentional` process starts and the lock file points at a live PID:

- **If `__XCODE_BUILT_PRODUCTS_DIR_PATHS` is set** (Xcode-launch detection): the new process terminates the existing PID, bootouts the `com.intentional.agent` LaunchAgent so launchd won't relaunch it, sweeps Login Items via `launchctl list`, then takes over the lock file. This is "Xcode wins."
- **If NOT set:** the new process silently `exit(0)`s. This is the production guard preventing accidental double-launches from the user manually clicking the dock icon while the LaunchAgent has already started the app.

Setting the env var when you're driving the launch from a shell is what tells main.swift "treat me as the Xcode Run button — kick the old one out."

## When the bootouts aren't enough

If the daemon-managed install respawns the OLD `/Applications/Intentional.app` after your takeover (the system-level `/Library/LaunchDaemons/com.intentional.watchdog.plist` survives a logout/login), and you need the dock icon + the watchdog to point at the new build permanently, you have to physically replace `/Applications/Intentional.app`. That requires sudo:

```bash
! sudo launchctl bootout system /Library/LaunchDaemons/com.intentional.watchdog.plist 2>/dev/null
! sudo launchctl bootout system /Library/LaunchDaemons/com.intentional.daemon.plist 2>/dev/null
! sudo pkill -9 -f "/Applications/Intentional.app"
! sudo rm -rf /Applications/Intentional.app
! sudo cp -R "$DERIVED_DIR/Intentional.app" /Applications/
! sudo launchctl bootstrap system /Library/LaunchDaemons/com.intentional.daemon.plist
! sudo launchctl bootstrap system /Library/LaunchDaemons/com.intentional.watchdog.plist
! open /Applications/Intentional.app
```

(The `!` prefix runs the line in the user's shell with their sudo password so Claude Code can drive it via the conversation.)

After this the dock icon, watchdog respawn target, and menu bar all point at the new build until the next PKG install overwrites it.

## Quick reference

| Goal | Command |
|---|---|
| Build new Debug + run alongside old daemon-managed instance | `xcodebuild ... build` → `nohup env __XCODE_BUILT_PRODUCTS_DIR_PATHS=$DERIVED_DIR $DERIVED_BINARY &` |
| Find current DerivedData hash | `ls -dt /Users/arayan/Library/Developer/Xcode/DerivedData/Intentional-*/Build/Products/Debug \| head -1` |
| Make `/Applications` dock icon point at new build (persistent) | sudo `cp` after `bootout` of daemon + watchdog; see above |
| Re-enable watchdog after dev | `sudo launchctl bootstrap system /Library/LaunchDaemons/com.intentional.watchdog.plist` |
| Roll back to daemon-managed `/Applications` build | Just quit the dev instance — LaunchAgent/watchdog respawn the OLD `/Applications/Intentional.app` within ~10s |

## What NOT to do

- ❌ `open /tmp/intentional-pkg-build/Intentional.app` — LaunchServices starts `/Applications/Intentional.app` regardless.
- ❌ Exec `/tmp/intentional-pkg-build/Intentional.app/Contents/MacOS/Intentional` directly — AMFI silent-kills Developer-ID binaries outside the installer. CLAUDE.md "Known Bug Fixes #8."
- ❌ Exec DerivedData Debug binary without `__XCODE_BUILT_PRODUCTS_DIR_PATHS` — process exits as "duplicate" without printing why.
- ❌ Paste a hard-coded DerivedData hash from this doc or memory — hashes drift. Always rediscover.
- ❌ `xcrun simctl install` — that's iOS Simulator only.
- ❌ Disable Gatekeeper — Debug builds are Apple-Development-signed, the issue isn't signing, it's bundle ID resolution and single-instance detection.
- ❌ `sudo rm` the LaunchDaemon plist file directly — without `launchctl bootout` it'll reload on reboot.

## Troubleshooting

- **"Build succeeded, my new code isn't running"** → check `pgrep -lf Intentional` — if PIDs all point at `/Applications/...`, your new process exited. Re-check that you set the env var. Inspect `/tmp/intentional-fresh.log`.
- **"Two Intentional windows open"** → the LaunchAgent respawned the OLD `/Applications` version after your takeover. Click the window opened by the new PID; the old one will respawn but lose focus. Or do the sudo-replace flow above for a clean swap.
- **"My changes aren't in the build"** → wrong branch (`git branch --show-current`) or wrong DerivedData folder (you have multiple `Intentional-*` directories and used the older one). Use the `ls -dt | head -1` trick.
- **"`xcodebuild` fails with codesign errors"** → Apple Development signing; if entitlements changed recently, check `Intentional.entitlements`. Don't strip entitlements (CLAUDE.md item 8).
- **"AMFI Error 163, no crash report"** → you ran the PKG binary, not Debug. CLAUDE.md "Known Bug Fixes #8" — never exec PKG-signed app standalone.

---

**TL;DR:** Build Debug, find the current DerivedData hash dynamically, exec the binary with `__XCODE_BUILT_PRODUCTS_DIR_PATHS` set. Without that env var, `main.swift:169` silently exits your process as a duplicate. Without Debug (i.e., if you exec the PKG-built `/tmp/...` binary), AMFI silent-kills it. The combination of those two failure modes is what makes "just run the new app" feel impossible.
