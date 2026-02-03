# Quick Start - Build and Test

## 1. Open in Xcode

```bash
cd ~/Documents/GitHub/intentional-macos-app
open Intentional.xcodeproj
```

## 2. Configure Signing (Required)

1. In Xcode, select the **Intentional** project in the navigator
2. Select the **Intentional** target
3. Go to **Signing & Capabilities** tab
4. Under **Team**, select your Apple Developer account
   - If you don't see your account, go to Xcode → Settings → Accounts and add it
   - A free Apple ID works for local development

## 3. Update Backend URL (Optional for Testing)

In [BackendClient.swift](Intentional/BackendClient.swift#L16), you can change:

```swift
init(baseURL: String) {
    self.baseURL = baseURL
```

Default in [AppDelegate.swift](Intentional/AppDelegate.swift#L23):
```swift
let backendClient = BackendClient(baseURL: "https://api.intentional.social")
```

For local testing, change to: `"http://localhost:8080"`

## 4. Build and Run

Press **⌘R** or click the ▶️ button in Xcode.

Expected console output:
```
✅ Intentional app launched
📱 Device ID: 202e41d6ae048dff...
✅ Sleep/wake notifications registered
✅ Process monitoring started
✅ All monitors initialized
```

## 5. Test System Events

### Test Sleep Detection
1. Close your laptop lid
2. Wait 5 seconds
3. Open it back up
4. Check console:
   - Should see: `💤 Computer going to sleep`
   - Then: `👁️ Computer woke up`

### Test Chrome Detection
1. Open Chrome browser
2. Check console: `🌐 Chrome started`
3. Quit Chrome (⌘Q)
4. Check console: `🚫 Chrome closed`

## 6. Verify Backend Receives Events

Check your backend logs or database:

```sql
SELECT * FROM system_events
ORDER BY created_at DESC
LIMIT 10;
```

You should see events like:
- `computer_sleeping`
- `computer_waking`
- `chrome_started`
- `chrome_closed`

## Troubleshooting

### "Developer cannot be verified" Error
1. System Settings → Privacy & Security
2. Scroll down and click "Open Anyway"

### No events appearing in backend
1. Check the Device ID in console matches your database
2. Verify backend URL is correct
3. Check network connectivity
4. Look for error messages in console (lines starting with ❌)

### Build errors about signing
1. Make sure you selected a Team in Signing & Capabilities
2. Try changing Bundle Identifier to something unique (e.g., `com.yourname.intentional`)

## Next Steps

Once verified working:

1. **Run database migration** (if not already done):
   ```sql
   -- Run in Supabase SQL Editor
   -- See migrations/001_add_system_events.sql in intentional-backend repo
   ```

2. **Set to launch at login**:
   - System Settings → General → Login Items
   - Click +, add Intentional.app

3. **Monitor for a few days** to verify accuracy improvement

## Architecture Overview

```
┌─────────────────────────────────────────┐
│   Intentional.app (Menu Bar)            │
│                                         │
│   ┌─────────────────────────────────┐  │
│   │  SleepWakeMonitor               │  │
│   │  - Listens to NSWorkspace       │  │
│   │  - Detects sleep/wake           │  │
│   └─────────────────────────────────┘  │
│                                         │
│   ┌─────────────────────────────────┐  │
│   │  ProcessMonitor                 │  │
│   │  - Polls every 30 seconds       │  │
│   │  - Detects Chrome start/stop    │  │
│   └─────────────────────────────────┘  │
│                                         │
│   ┌─────────────────────────────────┐  │
│   │  BackendClient                  │  │
│   │  - POST /system-event           │  │
│   │  - Includes X-Device-ID header  │  │
│   └─────────────────────────────────┘  │
└─────────────────────────────────────────┘
                  │
                  │ HTTPS
                  ▼
┌─────────────────────────────────────────┐
│   Backend API (api.intentional.social)  │
│                                         │
│   POST /system-event                    │
│   - Receives events                     │
│   - Stores in system_events table       │
│   - Uses for intelligent alerting       │
└─────────────────────────────────────────┘
```

## Development Workflow

1. Make changes to Swift files
2. Build and test locally (⌘R)
3. Commit and push to GitHub
4. For distribution, archive and export:
   - Product → Archive
   - Distribute App → Copy App
   - Share .app file or create installer

For full implementation details, see [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md).
