# Partner sync investigation — macOS ↔ iOS — 2026-04-26

**Reported symptom:** "I just logged in, for example, and I'm still not seeing the partner syncing across the macOS and the iOS accountability partner."

**Status:** Root cause identified. **No fix applied.** Decision needed before implementation.

---

## TL;DR

Partner data is stored on the **per-device** `users` table row, scoped by `device_id`. macOS and iOS each generate their own random `device_id` on first install. Logging into the same email account on both does **not** sync partner data, because:

1. The backend `/partner` endpoints (`PUT`, `GET`, `DELETE`) all read/write the row matching the caller's `X-Device-ID` only — there is no account-scoped read or write.
2. iOS never even links its legacy `users` row to the logged-in account (it logs in via Supabase directly, not via the backend's `/auth/verify`), so even an account-aware read couldn't find the iOS row to update.
3. macOS's partner-set call writes to the macOS device's row; iOS's `GET /partner/status` reads from a separate (empty) iOS device row.

The bug is **architectural**, not a transient sync glitch. It will reproduce 100% of the time across any pair of devices that haven't been wired through a shared device_id (which they can't be, by design).

---

## Evidence

### 1. Backend `/partner` endpoints are device-scoped

`intentional-backend/main.py:205-367`. All three partner routes accept `X-Device-ID: str = Header(...)` and resolve the user via `get_user_by_device_id(x_device_id)`. They write to / read from a single `users` row — there is no fan-out across other rows for the same account.

```python
# main.py:236
db.table("users").update({
    "partner_email": partner_email,
    "partner_name": partner_name
}).eq("id", user_id).execute()
```

```python
# main.py:334
user = await get_user_by_device_id(x_device_id)
...
partner_email = user.get("partner_email")
```

`account_id` is only consulted at write time to forbid setting your own email as partner (`main.py:230-233`). It is never used to find sibling devices.

### 2. macOS uses one device_id, persisted in UserDefaults under `"deviceId"`

`intentional-macos-app/Intentional/BackendClient.swift:45-52`:

```swift
if let stored = UserDefaults.standard.string(forKey: "deviceId") {
    self.deviceId = stored
} else {
    let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let random = String((0..<32).map { _ in /* hex */ })
    self.deviceId = (uuid + random).prefix(64).lowercased()
    UserDefaults.standard.set(self.deviceId, forKey: "deviceId")
}
```

All partner calls set `request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")` (BackendClient.swift:121, 153, 539, 578, …).

### 3. iOS has **two** device IDs, neither shared with macOS

iOS uses two unrelated registration systems:

**(a) Legacy device_id for `/partner`** — `puck-ios/Puck/Core/Network/IntentionalAPIClient.swift:194-263`:

```swift
actor IntentionalLegacyDeviceID {
    private let storageKey = "intentional_legacy_device_id"
    ...
    private func currentDeviceId() -> String {
        if let stored = UserDefaults.standard.string(forKey: storageKey), stored.count == 64 {
            return stored
        }
        // Generate a fresh random 64-char hex
        let uuid1 = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let uuid2 = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let deviceId = String((uuid1 + uuid2).prefix(64)).lowercased()
        UserDefaults.standard.set(deviceId, forKey: storageKey)
        return deviceId
    }
}
```

This ID is generated **independently on iOS first run**. It has nothing to do with the macOS device_id; the two are separate random 64-char hex strings.

**(b) Bearer-auth device_id for `/devices/register`** — `puck-ios/Puck/Core/Network/IntentionalDeviceRegistration.swift`:

After Supabase login, iOS calls `POST /devices/register` (Bearer auth) and stores the backend-returned device_id under `"intentional_backend_device_id"`. **This is a totally separate row** from the legacy `users` row, in a different account-keyed table family. Partner endpoints do not touch it.

### 4. iOS login does **not** link the legacy device_id to the account

`puck-ios/Puck/Core/Auth/AuthService.swift:153-176` — iOS verifies OTP via Supabase directly:

```swift
let response = try await supabaseClient.auth.verifyOTP(
    email: email, token: code, type: .email
)
...
triggerPostAuthBackendCalls()  // calls IntentionalDeviceRegistration.registerIfNeeded()
```

It never calls the backend's `POST /auth/verify`. So the backend code at `auth.py:171-177` that sets `users.account_id` for the legacy device row never fires for iOS:

```python
# auth.py:171
if request.device_id:
    device = db.table("users").select("*").eq("device_id", request.device_id).execute()
    if device.data:
        db.table("users").update({"account_id": account_id}).eq("device_id", request.device_id).execute()
```

By contrast, macOS's `BackendClient.authVerify` (BackendClient.swift:956-994) explicitly does pass `device_id`:

```swift
let payload: [String: Any] = ["email": email, "code": code, "device_id": deviceId]
```

**Net effect after the user "just logged in" on both clients:**

| Row | `device_id` | `account_id` | `partner_email` |
|-----|-------------|--------------|-----------------|
| Mac's `users` row | `<mac-random-hex>` | `<account>` (set on login) | `<partner from Mac UI>` |
| iOS's legacy `users` row | `<ios-random-hex>` | `NULL` (never linked) | `NULL` (or whatever iOS set, which is independent) |

iOS's `PartnerView.refreshPartnerStatus()` calls `GET /partner/status` and reads the iOS row → `consent_status: "none"` → the UI shows "no partner."

### 5. iOS `PartnerView` flow confirms the read path

`puck-ios/Puck/Views/Partner/PartnerView.swift:269-307`:

```swift
private func refreshPartnerStatus() async {
    let status = try await IntentionalAPIClient.shared.getPartnerStatus()
    applyStatus(status)  // mirrors server response into @AppStorage
}
```

The view is correct. The request is correct. The server response is just the wrong row.

---

## Why this isn't fixable on the client alone

If iOS started calling `/auth/verify` with the legacy device_id, the backend would set `users.account_id` on the iOS row. But:

- `GET /partner/status` would still return the iOS row's `partner_email` (empty), not the Mac row's.
- `PUT /partner` from iOS would still only write to the iOS row.

To make partner sync, the **backend** has to either (a) read across sibling devices for the same account, or (b) move partner storage off the `users` table to an account-level table.

---

## Fix options (for user decision — not implemented)

### Option A — Account-scoped read fallback (smallest backend change)

**Backend:**
- `GET /partner/status`: if the device's own `users.partner_email IS NULL` but `users.account_id IS NOT NULL`, look up sibling devices with the same `account_id` and return the most recently set partner (e.g., from the device with the most recent `last_heartbeat_at`).
- `PUT /partner`: if `users.account_id IS NOT NULL`, write `partner_email` / `partner_name` to **all** sibling rows with the same account_id (and recreate consent records appropriately).
- `DELETE /partner`: clear partner from all sibling rows.

**iOS:**
- After Supabase login, call `POST /auth/verify` (with the legacy device_id) — or add a new `POST /devices/link-legacy` endpoint that just sets `users.account_id` for the given legacy device_id, given a Bearer token.

**Pros:** Smallest delta. No data migration. Backwards compatible with the device-only model (devices not linked to an account keep working as before).

**Cons:** Doubled writes. Race between iOS-set and Mac-set partner could overwrite each other in a confusing way. Still leaves "partner" as a per-device concept under the hood.

### Option B — Promote partner to the `accounts` table (architecturally cleaner)

**Backend:**
- Add `accounts.partner_email`, `accounts.partner_name`, and migrate partner consent records to be keyed by `account_id` instead of `user_id` (or add a separate `account_partners` table).
- Rewrite `/partner` endpoints to be Bearer-authed and operate on the account, not the device. Keep `X-Device-ID` versions as a deprecated wrapper that delegates to the account flow when a linked account exists.
- Backfill: copy partner data from `users` → `accounts` for all devices that have a non-null `account_id`. (Conflict resolution: pick most-recently-updated row.)

**iOS / macOS:**
- Switch partner calls to Bearer auth. Drop the legacy `IntentionalLegacyDeviceID` flow for partner specifically.

**Pros:** Conceptually correct — partner is a property of the user, not the laptop. Clean future for multi-device. No more "two iOS device IDs" awkwardness.

**Cons:** Bigger change. Requires migration. Breaks any client that hasn't logged in (extension still uses device-only). Need to decide what "no account but has partner" means going forward.

### Option C — Reject the symptom (do nothing)

Document that partner is intentionally per-device and require the user to set it on each device separately. **Not recommended** — this contradicts the user's clearly-stated mental model and the user-facing language ("your accountability partner," singular).

---

## Reproduction recipe (if the user wants to verify)

1. On macOS app → log in with `email-A`. Set partner to `friend@example.com` from dashboard.
2. Run against backend: `curl -H "X-Device-ID: <mac-device-id>" https://api.intentional.social/partner/status` → returns `{partner_email: "friend@example.com", consent_status: "pending"}`.
3. On iOS Puck app → log in with `email-A`. Open Partner tab.
4. Run against backend: `curl -H "X-Device-ID: <ios-device-id>" https://api.intentional.social/partner/status` → returns `{consent_status: "none"}`.
5. Verify in Supabase: `SELECT device_id, account_id, partner_email FROM users WHERE account_id IS NULL OR partner_email = 'friend@example.com';` — you'll see two rows for the same person, one with partner, one without; the iOS row likely has `account_id IS NULL`.

To find the device IDs: macOS reads `defaults read com.intentional.app deviceId`; iOS reads from the app's UserDefaults under key `intentional_legacy_device_id` (visible via Xcode → Devices → app container).

---

## Recommendation

Option A is the smallest viable change — about 30 lines of backend logic plus a single iOS call to link the legacy device. It doesn't require migration and keeps the extension flow working unchanged. Option B is the right long-term answer if there's appetite for the migration; otherwise A buys time without painting into a corner. Either way, **iOS must learn to link its legacy device_id to the account** — that fix is required by both A and B, and is small.

Awaiting decision before any code changes.
