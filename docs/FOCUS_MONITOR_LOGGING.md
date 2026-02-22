# Focus Monitor: Always-Allowed App Logging & Configuration

## Overview

`FocusMonitor.swift` maintains a set of ~76 "always-allowed" bundle IDs (terminals, IDEs, password managers, etc.) that bypass AI relevance scoring. These apps automatically earn work ticks during focus blocks.

**Current problem**: Always-allowed apps are never logged to `relevance_log.jsonl`, making them invisible in the block assessment popover. A user working in VS Code + iTerm all morning sees only browser tab assessments.

## Changes Required

### 1. Log Always-Allowed Apps

In `FocusMonitor.swift`, the always-allowed branch (~line 557) currently returns without calling `logAssessment()`. Add the log call:

```swift
if Self.alwaysAllowedBundleIds.contains(bid) {
    // ... existing code ...

    // NEW: Log the assessment
    logAssessment(
        title: appName,
        intention: currentIntention ?? "",
        relevant: true,
        confidence: 100,
        reason: "Always-allowed app",
        action: "none"
    )

    startWorkTickTimer(appName: appName)
    return
}
```

Also update the work tick timer's periodic callback to log each tick while the always-allowed app stays active.

### 2. Make the List User-Configurable

**Storage**: `~/Library/Application Support/Intentional/always_allowed_apps.json`

```json
{
  "bundleIds": ["com.apple.Terminal", "com.googlecode.iterm2", ...],
  "customAdded": ["com.example.CustomApp"],
  "removedFromDefaults": ["com.apple.Notes"]
}
```

**Effective set**: `(defaults - removedFromDefaults) + customAdded`

This allows shipping new defaults in app updates without overwriting user customizations.

**Dashboard messages**:
- `GET_ALLOWED_APPS` → returns current effective set + metadata
- `SET_ALLOWED_APPS` → saves changes (customAdded/removedFromDefaults)
- `_allowedAppsResult` → callback with data

### 3. MLX Parse Error: Fail Closed

In `RelevanceScorer.swift`, when MLX model returns unparseable JSON, change the default from `relevant: true` to `relevant: false`:

```swift
// Before:
return Result(relevant: true, confidence: 0, reason: "MLX response parse error")

// After:
return Result(relevant: false, confidence: 0, reason: "Could not assess - AI model error")
```

Rationale: Fail-closed is safer. Users can click "5 More Minutes" for false negatives.

## Current Always-Allowed Bundle IDs

See `/Users/arayan/Documents/GitHub/intentional-extension/docs/focus-monitoring-improvements.md` for the complete categorized list of all 76 bundle IDs.

## Impact on Assessment Popover

After this change, the block assessment popover (`GET_BLOCK_ASSESSMENTS` in MainWindow.swift) will automatically include always-allowed app entries since they'll be present in `relevance_log.jsonl`. No changes needed to the popover code itself.
