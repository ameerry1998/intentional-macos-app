# Intentional macOS Native App

Companion app for the Intentional browser extension that provides system-level monitoring.

## Features

- **Sleep/Wake Detection**: Detects when computer goes to sleep or wakes up
- **Browser Process Monitoring**: Tracks if Chrome is running
- **Native Messaging**: Communicates with Chrome extension
- **Menu Bar Presence**: Lives in menu bar for easy access
- **Tamper Detection**: Alerts if extension disabled while browser running

## Architecture

```
┌─────────────────────────────────────┐
│   Intentional.app (Swift)           │
│   ├── AppDelegate.swift             │
│   ├── SleepWakeMonitor.swift        │
│   ├── ProcessMonitor.swift          │
│   ├── NativeMessagingHost.swift     │
│   ├── BackendClient.swift           │
│   └── MenuBarController.swift       │
└─────────────────────────────────────┘
         ↕ Native Messaging
┌─────────────────────────────────────┐
│   Chrome Extension                  │
│   └── background.js                 │
└─────────────────────────────────────┘
         ↕ HTTPS
┌─────────────────────────────────────┐
│   Backend (api.intentional.social)  │
└─────────────────────────────────────┘
```

## Development Setup

### Prerequisites
- macOS 13.0+
- Xcode 15.0+
- Swift 5.9+

### Build & Run
```bash
open Intentional.xcodeproj
# Press Cmd+R to build and run
```

## Native Messaging Setup

The app installs a native messaging manifest at:
```
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.intentional.host.json
```

## Distribution

### Code Signing
Required for distribution outside App Store:
```bash
codesign --deep --force --verify --verbose --sign "Developer ID Application: Your Name" Intentional.app
```

### Notarization
Required for macOS Gatekeeper:
```bash
xcrun notarytool submit Intentional.zip --apple-id your@email.com --team-id YOUR_TEAM_ID --wait
```

## License

Proprietary - All rights reserved
