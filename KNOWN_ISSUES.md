# Known Issues — Intentional macOS App

Tracked issues with the macOS app's dashboard and Swift backend. Ordered by severity.

---

## Issue #1: Lock Mode Doesn't Enforce Settings Restrictions — CRITICAL

**Status:** FIXED

**Problem:** The accountability system was purely decorative. When `lockMode = 'partner'` or `'self'`, the Accountability tab correctly showed "Settings Locked", but the YouTube/Instagram/Facebook settings pages remained fully editable.

**Fix applied:**
1. **Dashboard CSS:** `.setting-row.locked` dims and disables interaction, `.locked-banner` shows red-tinted lock notice
2. **Dashboard JS:** `enforceLockMode()` disables 9 protected inputs (platform enables, thresholds, blocking toggles) when lock state is `locked`, `unlock_code_entry`, or `self_countdown`. Shows lock banners with "Request unlock" link on all platform pages.
3. **Swift backend:** `handleSaveSettings()` validates locked fields before saving — rejects if any platform is disabled, threshold lowered, or blocking toggle turned off while locked (unless temporarily unlocked via valid code).

---

## Issue #2: Facebook Platform Data Not Wired — HIGH

**Status:** FIXED

**Fix applied:**
1. `handleGetSettings()` now reads `platforms["facebook"]` and returns `fbResult` with enabled, budget, blockWatch, blockReels, blockMarketplace, hideAds
2. `handleSaveSettings()` now includes Facebook in the platforms dict and saves its budget to TimeTracker
3. `handleGetDashboardData()` now returns Facebook usage (minutesUsed + budget)
4. TimeTracker default budgets now include `"facebook": 30`
5. Dashboard Usage page now has a Facebook usage card (blue theme) in a 3-column grid
6. `broadcastOnboardingToExtensions()` now includes Facebook data
7. `handleSaveOnboarding()` now saves Facebook budget to TimeTracker
8. `getSessionSyncPayload()` now includes Facebook in SESSION_SYNC

---

## Issue #3: Reset Flow Only Clears Local State — HIGH

**Status:** FIXED

**Fix applied:**
1. Calls `setLockMode(mode: "none")` on backend to clear lock state
2. Deletes TimeTracker data files: `daily_usage.json`, `time_settings.json`, `platform_sessions.json`
3. Broadcasts `SETTINGS_RESET` message to all connected extensions via socket relay
4. Still clears UserDefaults and settings file as before

---

## Issue #4: Consent Status Not Persisted During Polling — MEDIUM

**Status:** FIXED

**Fix applied:**
1. `handleGetPartnerStatus()` now calls `updateSettingsFile` to persist consentStatus when it changes (logs the transition)
2. This ensures app restart shows the correct consent state immediately without waiting for startup sync

---

## Issue #5: Onboarding Never Pre-fills Existing Data — LOW-MEDIUM

**Status:** FIXED

**Fix applied:**
1. Onboarding init now sends `GET_SETTINGS` on load
2. Added `_settingsResult` callback in onboarding that pre-fills: platform budgets (stepper display), partner name/email, and lock mode selection
3. Combined with Fix #3, reset now clears backend state so re-onboarding starts clean
