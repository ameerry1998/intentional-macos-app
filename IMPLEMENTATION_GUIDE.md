# Implementation Guide - Intentional macOS Native App

## Step-by-Step Build Instructions

### Phase 1: Create Xcode Project (10 minutes)

1. **Open Xcode** → Create a new project
2. **Choose template:** macOS → App
3. **Project settings:**
   - Product Name: `Intentional`
   - Team: Your Apple Developer account
   - Organization Identifier: `com.intentional`
   - Interface: Swift UI (or AppKit - either works)
   - Language: Swift
   - Bundle Identifier: `com.intentional.app`

4. **Copy files into project:**
   ```bash
   cd ~/Documents/GitHub/intentional-macos-app

   # Drag these files into Xcode:
   # - AppDelegate.swift
   # - SleepWakeMonitor.swift
   # - ProcessMonitor.swift
   # - BackendClient.swift
   # - Info.plist
   ```

5. **Update project settings:**
   - Deployment Target: macOS 13.0 or later
   - Enable "App Sandbox" capability
   - Add "Network" entitlement (for backend communication)

### Phase 2: Add Backend Endpoint (30 minutes)

Update your backend to handle system events:

```python
# backend/main.py

from enum import Enum

class SystemEvent(str, Enum):
    APP_STARTED = "app_started"
    APP_QUIT = "app_quit"
    COMPUTER_SLEEPING = "computer_sleeping"
    COMPUTER_WAKING = "computer_waking"
    SCREEN_LOCKED = "screen_locked"
    SCREEN_UNLOCKED = "screen_unlocked"
    CHROME_STARTED = "chrome_started"
    CHROME_CLOSED = "chrome_closed"

@app.post("/system-event")
async def handle_system_event(
    event: dict,
    x_device_id: str = Header(..., alias="X-Device-ID")
):
    """
    Receive system events from native macOS app.

    This gives us definitive signals about:
    - When computer goes to sleep (normal - don't alert)
    - When Chrome closes (normal - don't alert)
    - When extension disabled while Chrome running (suspicious - DO alert)
    """
    event_type = event.get("event_type")
    timestamp = event.get("timestamp")

    # Look up user
    db = get_db()
    result = db.table("users").select("*").eq("device_id", x_device_id).execute()

    if not result.data:
        raise HTTPException(status_code=404, detail="User not found")

    user = result.data[0]

    # Store event
    db.table("system_events").insert({
        "user_id": user["id"],
        "event_type": event_type,
        "timestamp": timestamp,
        "details": event
    }).execute()

    print(f"[System Event] {user['id']}: {event_type}")

    return {"success": True, "event_type": event_type}
```

**Add database table:**
```sql
CREATE TABLE system_events (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES users(id),
    event_type TEXT NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_system_events_user_id ON system_events(user_id);
CREATE INDEX idx_system_events_timestamp ON system_events(timestamp);
```

### Phase 3: Update Heartbeat Logic (15 minutes)

Now that we have system events, update the heartbeat checker:

```python
# backend/main.py - update check_stale_heartbeats

@app.get("/heartbeat/check-stale")
async def check_stale_heartbeats(...):
    # ... existing code ...

    for user in result.data:
        last_heartbeat = datetime.fromisoformat(
            user["last_heartbeat_at"].replace("Z", "+00:00")
        )

        # NEW: Check for system events that explain the gap
        last_system_event = await get_last_system_event(user["id"])

        # If last event was computer sleeping, DON'T alert
        if last_system_event and last_system_event["event_type"] == "computer_sleeping":
            print(f"[Skip] User {user['id']} - computer is sleeping")
            continue

        # If last event was chrome_closed, DON'T alert
        if last_system_event and last_system_event["event_type"] == "chrome_closed":
            print(f"[Skip] User {user['id']} - Chrome closed normally")
            continue

        # If Chrome is running but extension silent, ALERT
        if last_system_event and last_system_event["event_type"] == "chrome_started":
            hours_since_chrome_started = (now - last_system_event["timestamp"]).total_seconds() / 3600

            if hours_since_chrome_started > 0.5:  # Chrome been running 30+ min but no heartbeats
                print(f"[ALERT] User {user['id']} - Extension appears disabled!")
                await send_alert_to_partner(user)
                alerts_sent += 1
```

### Phase 4: Test It (30 minutes)

1. **Build and run the native app:**
   ```bash
   # In Xcode: Cmd+R
   ```

2. **Check console output:**
   ```
   ✅ Intentional app launched
   📱 Device ID: 202e41d6ae048dff...
   ✅ Sleep/wake notifications registered
   ✅ Process monitoring started
   ✅ All monitors initialized
   ```

3. **Test sleep detection:**
   - Close laptop lid → open it
   - Check logs: Should see "💤 Computer going to sleep" and "👁️ Computer woke up"

4. **Test Chrome detection:**
   - Open Chrome → check logs: "🌐 Chrome started"
   - Quit Chrome → check logs: "🚫 Chrome closed"

5. **Verify backend receives events:**
   ```bash
   # Check Railway logs or local backend
   curl https://api.intentional.social/...
   ```

### Phase 5: Install for Daily Use (15 minutes)

1. **Build release version:**
   - Xcode → Product → Archive
   - Export as macOS app

2. **Move to /Applications:**
   ```bash
   cp -r ~/Library/Developer/Xcode/DerivedData/.../Intentional.app /Applications/
   ```

3. **Set launch at login:**
   - System Settings → General → Login Items
   - Add Intentional.app

4. **Grant permissions if needed:**
   - System Settings → Privacy & Security
   - Allow Intentional to run

## Complexity Estimate

### For someone WITH Swift experience:
- ✅ **Phase 1 (Xcode setup):** 10 min
- ✅ **Phase 2 (Backend):** 30 min
- ✅ **Phase 3 (Logic):** 15 min
- ✅ **Phase 4 (Testing):** 30 min
- ✅ **Phase 5 (Install):** 15 min
- **TOTAL:** ~1.5 hours for MVP

### For someone LEARNING Swift:
- Add 2-3 hours for Swift basics
- Add 1-2 hours for debugging Xcode issues
- **TOTAL:** ~5-7 hours for MVP

## What's NOT Included in This MVP

- Native messaging bridge (extension ↔ app communication)
- Fancy UI/settings panel
- Auto-updater
- Code signing / notarization
- Windows version
- Advanced tamper detection

These can be added later. The MVP proves the concept works.

## Alternative: Electron App (Cross-Platform)

If you want Windows/Linux support, consider Electron instead of Swift:

**Pros:**
- JavaScript/TypeScript (you already know this)
- Cross-platform (one codebase for all OS)
- Easier to build

**Cons:**
- ~100 MB app size (vs ~5 MB Swift)
- Uses more RAM (~50 MB vs ~10 MB)
- Less "native" feel

**Time to build:** ~2-3 hours (faster than Swift if you don't know Swift)

Would you like me to create the Electron version instead?

## Next Steps

1. ✅ Create Xcode project
2. ✅ Copy Swift files into project
3. ✅ Build and run
4. ✅ Test sleep/wake detection
5. ✅ Add backend endpoint
6. ✅ Deploy backend changes
7. ✅ Test end-to-end
8. ✅ Install on your machine
9. ✅ Monitor for a few days
10. ✅ Share with beta users

Let me know which part you want help with next!
