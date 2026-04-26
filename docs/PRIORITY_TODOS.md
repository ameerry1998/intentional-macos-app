# Priority TODOs

Implementation backlog for features that are designed but not yet built.

---

## Intentional Mode (Screen Lock Until You Plan)
Full-screen blocking overlay when there's no active intention/block. The laptop is unusable until the user plans what they're doing (even "Free Time" counts). See [ROADMAP.md](ROADMAP.md) "Intentional Mode" section for full design.

**Key implementation points:**
- New `IntentionalModeController` — manages overlay lifecycle and state
- Uses `KeyableWindow` at `.screenSaver` level (same as BlockRitualController) with interactive SwiftUI planning form
- Cover ALL screens via `NSScreen.screens` loop (same as ContentSafetyMonitor)
- Planning form: block type picker (Deep Work/Focus Hours/Free Time), intention text field, duration picker, Start button
- 3-minute warning in pill when current block is about to end and no next block is scheduled
- Triggers: always-on, custom schedule, manual toggle, Puck tap (future)
- Settings: `intentionalModeEnabled`, `intentionalModeSchedule` (always/custom/puck-only), `intentionalModeGracePeriod` (1/3/5 min)
- Respects partner lock (can't disable when settings locked)
- **Puck integration is separate** — build with manual/schedule triggers first, wire Puck later

---

## Content Safety: Permission Monitoring & Partner Notification
The Content Safety Monitor requires TWO macOS system permissions:
1. **Screen Recording** — System Settings > Privacy & Security > Screen & System Audio Recording
2. **Sensitive Content Warning** — System Settings > Privacy & Security > Sensitive Content Warning

**Current problem**: If either permission is missing or revoked, the feature silently does nothing. No user feedback.

**Required behavior**:
- **On toggle enable**: Check both permissions. If either is missing, show a clear prompt explaining which permission is needed and how to enable it (with a button to open the relevant System Settings pane). Don't just silently fail.
- **Continuous monitoring**: Poll permission status periodically while Content Safety is enabled. If a previously-granted permission is revoked, show an in-app alert.
- **Partner notification on revocation**: If the user HAD both permissions granted (i.e., Content Safety was fully active) and then revokes either permission, notify the accountability partner via the backend API. This is a tamper detection signal.
- **Do NOT notify partner if permissions were never granted** — only notify on revocation of previously-active permissions.
- **Track permission state**: Store `contentSafety.permissionsGrantedAt` timestamp in settings when both permissions are first confirmed. Use this to distinguish "never granted" from "revoked."

**Implementation notes**:
- `CGPreflightScreenCaptureAccess()` checks Screen Recording permission
- `SCSensitivityAnalyzer().analysisPolicy != .disabled` checks Sensitive Content Warning
- Open Screen Recording settings: `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)`
- ContentSafetyMonitor.swift already has `pushPermissionStatus()` that sends status to the dashboard — extend this to also check for revocation

---

## Settings Persistence: Remove Global Debounce
The 800ms debounce on `onSettingChange()` causes settings to be lost if the user navigates away or quits quickly. Options:
- Reduce debounce to 100ms (less likely to lose changes, still batches rapid toggles)
- Save immediately on every toggle change (most reliable, slightly more disk writes)
- Add `beforeunload` / page visibility change handler that flushes pending saves immediately

---

## Network Extension (NEFilterDataProvider) Integration
- FilterExtension target and FilterManager.swift are created but not yet wired into AppDelegate
- Need to call `filterManager.activateFilter()` on app launch to install the System Extension
- Need to connect the distracting sites blocklist to the filter's App Group shared container
- This replaces the AppleScript-based WebsiteBlocker with system-level blocking across all browsers

---

## Content Safety: Secondary NSFW Classifier
Apple's `SensitiveContentAnalysis` has a high threshold and misses a lot of sexual content. Need a secondary classifier:
- **CoreML NSFW model** (OpenNSFW or similar, ~5MB) as second pass
- Either classifier triggers → detection fires
- Specifically trained for adult content detection, much more sensitive than Apple's general-purpose classifier

---

## Content Safety: Porn Domain Blocklist
URL-level blocking of known adult domains — catches 90% of porn before screenshot analysis is needed:
- Maintain a blocklist of known adult domains (thousands of entries)
- Block at WebsiteBlocker/NEFilterDataProvider level
- Update periodically from a maintained list

---

## Anti-Tamper: MUST FIX BEFORE SHIPPING (Inspired by Covenant Eyes)

**Current vulnerability:** Strict mode can be bypassed in 3 Terminal commands:
1. `rm ~/Library/Application Support/Intentional/strict-mode` (removes flag file)
2. `defaults write ... strictModeEnabled false` (flips UserDefaults)
3. `pkill Intentional` (kills the app, watchdog won't relaunch without flag file)

**Root cause:** Flag file and UserDefaults are in user-writable paths. Watchdog is a LaunchAgent (user-level), not a LaunchDaemon (root-level).

**Required fix (pre-ship):**
1. **PKG installer** — installs to `/Library/LaunchDaemons/` and `/usr/local/libexec/` (system paths, requires admin password to modify). Runs for ALL macOS user accounts.
2. **LaunchDaemon** (root) with `KeepAlive: true` — replaces the current LaunchAgent watchdog. `launchd` restarts the process instantly if killed (not 10s polling).
3. **Flag file in `/private/var/`** — root-owned, user can't delete without `sudo`.
4. **Hosts file watcher** — detects if someone adds `127.0.0.1 api.intentional.social` to `/etc/hosts` to bypass backend.
5. **Uninstall requires partner code** — PKG uninstaller app (like CE's) that requires the accountability partner's approval code.

**Reference implementation:** Covenant Eyes VictoryShield DMG analyzed — see their LaunchDaemon plists:
- `com.Cvnt.daemon.plist`: root daemon with `KeepAlive` + `WatchPaths`
- `com.Cvnt.start.plist`: LaunchAgent with `KeepAlive: true` + `RunAtLoad: true`
- `com.cvnt.ceclassifierd.plist`: separate root classifier Mach service
- `com.cvnt.cehostsd.plist`: watches `/etc/hosts` for DNS tampering
