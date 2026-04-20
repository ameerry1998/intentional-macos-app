# Strict Mode (App Persistence)

Strict mode is an **independent toggle** (`strictModeEnabled` in UserDefaults), decoupled from lock mode but **gated by accountability partner**. It requires a confirmed accountability partner to enable, and a 6-digit code from the partner to disable.

**Default: OFF.** Existing users upgrading will have strict mode off (UserDefaults returns false for missing keys).

When `strictModeEnabled` is true:
1. **Login item registered** — auto-start on login (macOS 13+, `SMAppService`)
2. **Strict mode flag file** — `~/Library/Application Support/Intentional/strict-mode`
3. **Watchdog LaunchAgent** — relaunches app if force-quit (checks flag file)
4. **SIGTERM handler** — skips no-relaunch marker when strict mode active

## Enabling Strict Mode
- Requires `consentStatus == "confirmed"` (confirmed accountability partner)
- User toggles ON in Accountability tab → confirmation dialog → `SAVE_STRICT_MODE { enabled: true }`
- Swift validates partner status before saving

## Disabling Strict Mode
- Requires partner code (uses the existing `REQUEST_UNLOCK` / `VERIFY_UNLOCK` flow)
- User clicks "Request Code to Disable" → code emailed to partner → inline code entry → verify → strict mode disabled
- Swift validates `temporaryUnlockUntil` is in the future before allowing disable
- Backend `/unlock/request` was modified to allow requests when `lock_mode == "none"` if user has a confirmed partner

## Cmd+Q Behavior

| Strict Mode | Cmd+Q Result |
|-------------|-------------|
| OFF | Quits immediately |
| ON | "Keep Running" only (must disable via dashboard with partner code) |

## Dashboard UI (Accountability Tab)

The "App Persistence" card in `renderLockState()` has four states:
1. **No confirmed partner** → grayed out toggle + info text ("Requires an accountability partner")
2. **Partner confirmed, strict OFF** → toggleable, confirmation dialog on enable
3. **Partner confirmed, strict ON** → checked/disabled toggle + "Request Code to Disable" button
4. **Code entry** → inline 6-digit code input + Verify/Cancel (tracked by `strictDisableState` variable)

## Edge Cases
- **Partner removed** → `handleRemovePartner()` auto-disables strict mode (UserDefaults + settings file + `updateStrictMode()`)
- **Cmd+Q with strict ON** → always blocks quit, regardless of lock mode
