# Debugging the Intentional macOS App

## Changes Made to Fix Window/Logging Issues

### 1. Created Explicit `main.swift`
- **Why:** Bypasses the `@main` attribute which may be failing silently
- **Location:** [Intentional/main.swift](Intentional/main.swift)
- **What it does:** Explicitly creates NSApplication and sets AppDelegate

### 2. Removed `@main` from AppDelegate
- **Why:** Can't have both @main and explicit main.swift
- **Location:** [Intentional/AppDelegate.swift](Intentional/AppDelegate.swift)

### 3. Added Comprehensive Logging
Multiple logging methods to ensure we see output:
- `print()` statements
- `NSLog()` calls (shows in Console.app)
- **File logging** to `/tmp/intentional-debug.log`

## How to Test

1. **Clean Build** in Xcode: `Product` → `Clean Build Folder` (⇧⌘K)

2. **Rebuild and Run** (⌘R)

3. **Check Console Output** in Xcode
   - Should now see "=== MAIN.SWIFT EXECUTING ===" first
   - Then "=== APP DELEGATE SET ==="
   - Then "=== applicationDidFinishLaunching CALLED ==="

4. **Check File Log** if Xcode console still doesn't show output:
   ```bash
   cat /tmp/intentional-debug.log
   ```

   This will show timestamps of when each part executed.

5. **Check System Console** (Console.app):
   - Open `/Applications/Utilities/Console.app`
   - Filter for "Intentional"
   - NSLog output will appear here even if Xcode doesn't show it

## Expected Behavior

If working correctly, you should see:

**In Xcode Console:**
```
=== MAIN.SWIFT EXECUTING ===
=== APP DELEGATE SET ===
=== applicationDidFinishLaunching CALLED ===
=== applicationDidFinishLaunching CALLED (NSLog) ===
📱 Device ID: abc123...
✅ Intentional app launched
🔗 Backend URL: https://api.intentional.social
🪟 Main window created
🔝 Menu bar icon added
...
```

**A window should appear** with:
- Title: "Intentional - System Monitor"
- Two-panel split view (Events + Console Log)
- Size: 800x600 pixels

## Diagnostic Log File

The file `/tmp/intentional-debug.log` contains timestamped entries showing:
- When main.swift executed
- When AppDelegate was set
- When applicationDidFinishLaunching() was called

This helps diagnose if code is running but Xcode console isn't showing output.

## If It Still Doesn't Work

If the window still doesn't appear AND the log file is empty:

1. **Check target selection** in Xcode scheme
2. **Verify Info.plist** has `NSPrincipalClass = NSApplication`
3. **Check for crash logs** in Console.app
4. **Run from Terminal:**
   ```bash
   cd /Users/arayan/Documents/GitHub/intentional-macos-app
   xcodebuild -project Intentional.xcodeproj -scheme Intentional build
   open build/Release/Intentional.app
   ```

## File Locations

- Main entry point: [Intentional/main.swift](Intentional/main.swift)
- App delegate: [Intentional/AppDelegate.swift](Intentional/AppDelegate.swift)
- Main window: [Intentional/MainWindow.swift](Intentional/MainWindow.swift)
- Project config: [Intentional.xcodeproj/project.pbxproj](Intentional.xcodeproj/project.pbxproj)
- Diagnostic log: `/tmp/intentional-debug.log`
