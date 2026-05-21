# Content Safety (ContentSafetyMonitor)

Opt-in on-device screen monitoring for explicit/nude content. Independent of the focus schedule — always-on when enabled.

## How It Works
1. Polls every 2s via Timer
2. **Two-pass capture strategy:**
   - **Pass 1**: `CGWindowListCreateImage(CGRect.null, ...)` captures ALL screens as one composite → downscale to 1920px → classify
   - **Pass 2**: If composite doesn't trigger, captures up to 5 individual visible windows via `CGWindowListCreateImage(.optionIncludingWindow, windowID)` → downscale to 1280px → classify each. This catches content in background windows that gets diluted in the full composite.
3. Classifies via `SensitiveContentAnalysis` framework (macOS 14+, Apple's on-device classifier)
4. On detection: blocks all screens with overlay, blurs screenshot, emails partner

**Window-server contention note:** This 2s poll and `RelevanceScorer`'s OCR capture both use the window-server screenshot path (`CGWindowListCreateImage` here, `ScreenCapture().captureFrontmostWindow()` over there). To avoid starving this cadence, the scorer captures serially and only when the OCR verification branch actually fires — no parallel pre-capture runs during metadata scoring.

## Detection Limitations & Improvement Plan
**Apple's `SensitiveContentAnalysis` has a HIGH threshold** — designed for Communication Safety (kids), not aggressive porn detection. It misses:
- Sexual content where nudity isn't full-frontal
- Partially clothed sexual content
- Small images in large composite screenshots (mitigated by per-window capture)

**Planned improvements:**
- **Secondary CoreML NSFW model** (e.g., OpenNSFW ~5MB) as a second classifier. Either model triggers → detection fires.
- **Porn domain blocklist** — URL-level blocking of known adult domains (catches 90% before screenshot analysis needed)
- **Incognito window detection** — detect when Chrome opens incognito (AppleScript can read window properties)

## Requirements
- **Screen Recording permission** — requested via `CGRequestScreenCaptureAccess()` when user enables the feature
- **Sensitive Content Warning** — user must enable in System Settings > Privacy & Security for analysis to work
- `analyzer.analysisPolicy != .disabled` is checked before each analysis

## Enforcement
- Full-screen blocking overlay on ALL monitors (`NSScreen.screens` loop, `.screenSaver` level)
- 10-second mandatory wait before "I understand" dismiss button activates
- 3-second grace period after dismiss (prevents instant re-trigger, not enough to browse)
- 5-minute email cooldown between partner notifications

## Settings
- Stored in `onboarding_settings.json` under `contentSafety.enabled`
- Dashboard toggle in Settings tab with confirmation dialog
- Cannot be disabled when settings are locked (same pattern as strict mode)
- Status pushed to dashboard via `pushContentSafetyStatus()` on MainWindow

## Backend Integration
- `POST /content-safety/report` with `{ timestamp, blurred_image_base64 }` + `X-Device-ID` header
- Rate limited: max 10 reports per device per hour (429 if exceeded)
- Partner email includes blurred screenshot as inline base64 image
- `content_safety_reports` table for audit trail (no image stored server-side)

## Persistence
- Local log: `~/Library/Application Support/Intentional/content_safety_log.jsonl`
- Entries: `{ timestamp, emailSent, screenCount }`

## Integration Points
- **AppDelegate**: init at step ~15.5 (after FocusMonitor, before SocketRelayServer); `ContentSafetyStateGuard.performStartupDivergenceCheck` runs immediately before `onSettingsChanged(enabled:)`. Clean-shutdown snapshot written in `applicationWillTerminate`.
- **SleepWakeMonitor**: calls `onSleep()`/`onWake()` to pause/resume polling
- **MainWindow**: `handleGetSettings`/`handleSaveSettings` include `contentSafety` key
- **BackendClient**: `reportContentSafety(blurredImageBase64:timestamp:)` method, plus `reportContentSafetyTamper(eventType:detail:)` used by both `ContentSafetyMonitor` and `ContentSafetyStateGuard` startup check

## OpenNSFW (Developer ID Builds)

Apple's `SensitiveContentAnalysis` is not available in Developer ID builds. The app uses **OpenNSFW** (Yahoo's binary NSFW classifier, 24MB CoreML model) as the detection backend:
- Scores images 0-1 (NSFW probability), threshold 0.90
- Per-window capture catches content in individual app windows (composite full-screen dilutes the signal)
- Temporal voting: 3 of 5 frames must trigger before showing blocking overlay
- Model has BGR mean subtraction preprocessing baked into the spec

## Startup Divergence Check (`ContentSafetyStateGuard`)

**Threat:** `contentSafety.enabled` lives in plain JSON at `~/Library/Application Support/Intentional/onboarding_settings.json`. A user can edit that file to set `enabled = false` and on next launch CS starts already disabled. The existing `ContentSafetyMonitor.onSettingsChanged(enabled:false)` tamper path only fires when `isMonitoring == true` at the moment of the call, so flipping the JSON before launch produces zero tamper signal.

**Defense:** A separate signed file `~/Library/Application Support/Intentional/cs-state.json` records the last-known intended state, signed with HMAC-SHA256. The HMAC key is a per-device 32-byte secret stored in the macOS Keychain (`com.intentional.auth/cs_hmac_secret`), generated lazily on first access.

**File format:**
```json
{ "enabled": true, "updatedAt": "2026-04-25T10:00:00Z", "hmac": "<64-hex>" }
```
HMAC is computed over `"<enabled>|<updatedAt>|<deviceId>"`.

**Lifecycle:**
1. **Startup** (`AppDelegate` step 15c, just before `ContentSafetyMonitor` is loaded): `ContentSafetyStateGuard.performStartupDivergenceCheck(deviceId:)` reads onboarding JSON + cs-state.json and decides:
   - **Both consistent** → refresh `cs-state.json` timestamp, continue.
   - **Signed says ON, JSON says OFF** → fire tamper event `settings_divergence_at_startup`, force-rewrite JSON to `enabled = true`, continue with CS enabled.
   - **Signed says OFF, JSON says ON** → fire tamper event `settings_divergence_at_startup`, re-baseline to ON (user being more protective is logged but accepted).
   - **Signature invalid** → fire `cs_state_signature_invalid_at_startup`. If the signed file claimed ON and JSON now says OFF, also force-enable.
   - **File corrupt** → fire `cs_state_corrupt_at_startup`, re-baseline to current JSON.
   - **File missing** (fresh install or wiped state) → no tamper, baseline to current JSON.
   - **Unverifiable** (Keychain unavailable or `hmac == ""`) → if signed says ON / JSON says OFF, treat as suspicious and force-enable; otherwise log and accept.
2. **Legitimate UI toggle** (`ContentSafetyMonitor.onSettingsChanged(enabled:)`): writes a fresh signed snapshot so the new state becomes the next baseline. Always runs regardless of whether a transition occurred.
3. **Clean shutdown** (`AppDelegate.applicationWillTerminate`): writes a fresh signed snapshot from the on-disk JSON so the next launch's baseline is current.

**Tamper event reasons** (sent via `BackendClient.reportContentSafetyTamper`):
- `settings_divergence_at_startup`
- `cs_state_signature_invalid_at_startup`
- `cs_state_corrupt_at_startup`
- `cs_state_unverifiable_divergence_at_startup`

**Limitations (this is a quick-win, not a complete fix):**
- A user with code-signing access can still write valid HMACs if they know how to extract the Keychain secret. The defence is against casual JSON edits, not against an attacker with full local access.
- This does not prevent the bypass — it only makes it noisy. A complete fix needs the backend-authoritative lock state described in `project_content_safety_bypass.md` root cause #1.
- The Keychain secret is in the user's login keychain, so it survives across launches but is accessible to any process running as the user. Hardening to a system keychain would require the helper daemon.

**Files:**
- `Intentional/ContentSafetyStateGuard.swift` — read/write/HMAC logic + startup decision tree.
- `Intentional/AppDelegate.swift` — wired in `setupMonitors()` (around the `ContentSafetyMonitor` init) and in `applicationWillTerminate`.
- `Intentional/ContentSafetyMonitor.swift` — `onSettingsChanged(enabled:)` writes a snapshot on every legitimate toggle.
