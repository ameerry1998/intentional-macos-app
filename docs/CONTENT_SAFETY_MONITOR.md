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
- **AppDelegate**: init at step ~15.5 (after FocusMonitor, before SocketRelayServer)
- **SleepWakeMonitor**: calls `onSleep()`/`onWake()` to pause/resume polling
- **MainWindow**: `handleGetSettings`/`handleSaveSettings` include `contentSafety` key
- **BackendClient**: `reportContentSafety(blurredImageBase64:timestamp:)` method

## OpenNSFW (Developer ID Builds)

Apple's `SensitiveContentAnalysis` is not available in Developer ID builds. The app uses **OpenNSFW** (Yahoo's binary NSFW classifier, 24MB CoreML model) as the detection backend:
- Scores images 0-1 (NSFW probability), threshold 0.90
- Per-window capture catches content in individual app windows (composite full-screen dilutes the signal)
- Temporal voting: 3 of 5 frames must trigger before showing blocking overlay
- Model has BGR mean subtraction preprocessing baked into the spec
