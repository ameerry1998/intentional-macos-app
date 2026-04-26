# PKG Build Guide

Technical reference for building, signing, and debugging the Intentional PKG installer.

## Overview

Intentional uses a PKG installer (not DMG) to install a root-level daemon alongside the app. This provides tamper-resistant persistence: the daemon runs as root, monitors whether the app is running, and relaunches it if the user force-quits while strict mode is enabled. A user cannot disable this without `sudo` access or their accountability partner's code.

## What the PKG Installs

| File | Install Path | Owner | Purpose |
|------|-------------|-------|---------|
| `syspolicyd_helper` | `/usr/local/libexec/syspolicyd_helper` | `root:wheel` | Root daemon binary. Watches for app force-quit, monitors `/etc/hosts` tampering, reports heartbeats. |
| LaunchDaemon plist | `/Library/LaunchDaemons/com.intentional.daemon.plist` | `root:wheel` | Keeps the daemon alive via `launchd`. `KeepAlive: true`, `RunAtLoad: true`, watches `/etc/hosts`. |
| LaunchAgent plist | `/Library/LaunchAgents/com.intentional.agent.plist` | `root:wheel` | Launches the app in the user's GUI session. `RunAtLoad: true`, `KeepAlive.SuccessfulExit: false` (relaunches on non-zero exit). |
| `Intentional.app` | `/Applications/Intentional.app` | standard | The main application. |
| Config directory | `/private/var/intentional/` | `root:wheel`, mode `700` | Root-owned config storage. User cannot modify without `sudo`. |

## Build Process

Run `scripts/build-pkg.sh` from the repo root. It performs 7 steps:

1. **Archive the app** -- `xcodebuild archive` with automatic signing. Produces a signed `Intentional.app` with all nested components (FilterExtension.systemextension, frameworks) properly signed by Xcode.
2. **Build the daemon** -- Builds the `syspolicyd_helper` target separately, then signs it with Developer ID Application + hardened runtime.
3. **Create payloads** -- Assembles two directory trees: one for the app (`/Applications/`), one for the daemon binary + both plists.
4. **Build component packages** -- `pkgbuild` creates `IntentionalApp.pkg` and `IntentionalDaemon.pkg`. The daemon package includes `postinstall.sh` which sets ownership and loads the daemon.
5. **Create Distribution.xml** -- Defines the installer UI, welcome page, and component choices (both mandatory, not user-visible).
6. **Build final PKG** -- `productbuild` combines components + distribution + resources into the final `.pkg`. Signed with Developer ID Installer if the cert is available.
7. **Notarize** -- Submits to Apple's notary service and staples the ticket. Skipped if the PKG is unsigned.

```bash
./scripts/build-pkg.sh
# Output: /tmp/intentional-pkg-build/Intentional-{VERSION}.pkg
```

## Critical: Do NOT Re-Sign the App Bundle

This is the single most important thing to understand about this build pipeline.

The Xcode archive step (step 1) signs `Intentional.app` with Developer ID Application using automatic signing. This correctly signs the entire bundle hierarchy:

```
Intentional.app/
  Contents/
    MacOS/Intentional              (signed with app entitlements)
    PlugIns/
      FilterExtension.appex/
        Contents/
          PlugIns/
            FilterExtension.systemextension/  (signed with ITS OWN entitlements)
    Frameworks/
      *.framework                  (each signed independently)
```

**If you re-sign after archiving** with something like:

```bash
# DO NOT DO THIS
codesign --deep --force --entitlements Intentional.entitlements --sign "Developer ID Application: ..." Intentional.app
```

You will break the app. Here is why:

- `--deep` recursively signs ALL nested bundles (frameworks, extensions, system extensions).
- `--entitlements` applies the PARENT app's entitlements file to EVERY nested component.
- The `FilterExtension.systemextension` has its own, different entitlements (network extension capabilities, system extension point). Overwriting them with the parent's entitlements produces an invalid signature chain.
- On launch, macOS's **amfid** (Apple Mobile File Integrity Daemon) validates the signature chain. It detects that the nested system extension's entitlements don't match what the provisioning profile expects.
- amfid sends `SIGKILL` to the process.

**Symptoms of this failure:**

- The app launches and instantly dies.
- Exit code is **137** (128 + 9 = SIGKILL).
- There is NO crash report in `~/Library/Logs/DiagnosticReports/`.
- There is NO error output on stderr.
- `Console.app` shows amfid messages about signature validation failure.
- The only clue is exit code 137 and silence.

**The fix:** Let Xcode handle all signing during the archive step. The build script extracts the `.app` from the archive via `ditto` and packages it as-is. No re-signing.

## macOS Launch Identity Cache Issue

When repeatedly installing PKGs during development (especially with different code signatures), macOS caches the old "launch identity" for the bundle ID. This causes a maddening failure mode:

**Symptoms:**

```bash
$ launchctl kickstart gui/501/com.intentional.agent
# Reports success, but process fails to spawn

$ open -a /Applications/Intentional.app
# LSOpenURLsWithRole() failed with error -54 for the file
# or: RBSRequestErrorDomain Code=5

$ /Applications/Intentional.app/Contents/MacOS/Intentional
# Killed: 9  (exit code 137)
```

The process is killed immediately by amfid because macOS still has the old signature cached in its launch identity database. Even running the binary directly fails.

**The fix:**

- **Restart the Mac.** This clears the launch identity cache. After reboot, the newly installed binary runs fine.
- **Alternative (sometimes works):** Boot out and re-bootstrap the agent:
  ```bash
  sudo launchctl bootout system /Library/LaunchDaemons/com.intentional.daemon.plist
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.intentional.daemon.plist
  launchctl bootout gui/$(id -u) /Library/LaunchAgents/com.intentional.agent.plist
  launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.intentional.agent.plist
  ```

**For development:** Use Xcode debug builds for day-to-day development. Only build the PKG when testing the actual install flow. Avoid repeatedly installing PKGs with different signatures over the same bundle ID without rebooting between installs.

## Daemon Relaunch Strategy

`AppWatchdog.swift` in the daemon checks every 5 seconds whether the app is running (via `pgrep -x Intentional`). If strict mode is enabled and the app is not found, it attempts relaunch using a 3-method fallback:

1. **`launchctl kickstart`** (preferred) -- Kicks the `com.intentional.agent` LaunchAgent in the console user's GUI session (`gui/{UID}/com.intentional.agent`). This is the cleanest method because `launchd` manages the process lifecycle.

2. **`open -a`** (fallback) -- Uses Launch Services to open the app. Works when the LaunchAgent is in a bad state but the app binary is valid.

3. **Direct binary launch via `su`** (last resort) -- Runs the binary directly as the console user: `su -l {username} -c "/Applications/Intentional.app/Contents/MacOS/Intentional &"`. Bypasses both `launchd` and Launch Services.

After each method, the watchdog waits 2 seconds and verifies the app actually started before trying the next method. If all three fail, it logs the failure and will retry on the next 5-second cycle.

The watchdog also detects app deletion (`Intentional.app` missing from `/Applications/`) and reports it as a tamper event to the backend.

## Developer ID Installer Certificate

Two different Apple certificates are involved:

| Certificate | Used For | Where |
|------------|----------|-------|
| Developer ID Application | Signing the `.app` bundle and daemon binary | Xcode archive + `codesign` |
| Developer ID Installer | Signing the `.pkg` file for distribution | `productbuild --sign` |

These are separate certificates. Having one does not give you the other.

To create the Installer certificate:
1. Go to [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
2. Create a new certificate of type "Developer ID Installer"
3. Install it in your Keychain

The build script currently has `INSTALLER_SIGNING_IDENTITY=""` (unsigned PKG for testing). Uncomment the line with your identity for production builds. Unsigned PKGs trigger Gatekeeper warnings and cannot be notarized.

## Testing Checklist

After installing the PKG and restarting:

```bash
# Verify daemon is running
pgrep -x syspolicyd_helper
# Should print a PID

# Verify app is running
pgrep -x Intentional
# Should print a PID

# Check daemon logs
cat /var/log/intentional-daemon.log

# Test force-quit recovery (strict mode must be enabled in the app)
pkill -9 -x Intentional
# Wait ~10 seconds, then:
pgrep -x Intentional
# Should print a new PID — daemon relaunched it

# Test from Activity Monitor
# Force Quit Intentional from Activity Monitor → should relaunch

# Verify LaunchDaemon is loaded
sudo launchctl list | grep intentional
# Should show com.intentional.daemon

# Verify LaunchAgent is loaded
launchctl list | grep intentional
# Should show com.intentional.agent

# Check daemon plist ownership (must be root:wheel)
ls -la /Library/LaunchDaemons/com.intentional.daemon.plist
ls -la /Library/LaunchAgents/com.intentional.agent.plist
ls -la /usr/local/libexec/syspolicyd_helper
```
