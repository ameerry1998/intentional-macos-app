# Partner Email Registry

Living inventory of every email an accountability partner (e.g., Caity) can receive from the Intentional system. Update any time a new trigger is added or an existing one is modified.

**Goals of this document:** reason about cumulative email volume, decide when consolidation or digests are warranted, avoid surprising the partner with undocumented senders.

---

## Entry format

```markdown
## <Email Name>
- **Trigger:** <when it fires>
- **Sender template:** <Resend template id / hardcoded subject>
- **Rate limit:** <per-device-per-X, or "none">
- **Payload:** <what the email contains>
- **Source:** <backend endpoint + code location>
- **Added:** <YYYY-MM-DD, feature/PR>
```

---

## Registry

## Verification Code (Login)

- **Trigger:** User initiates login with `/auth/login` by entering their email address.
- **Sender template:** Hardcoded subject: `"{code} is your Intentional verification code"`
- **Rate limit:** 3 per email per hour (checked at login time).
- **Payload:** 6-digit OTP code. Expires in 10 minutes. Plain text + HTML email with centered code display.
- **Source:** `intentional-backend/auth.py → auth_login()`, line 85; `email_service.py → send_verification_code_email()`, line 24.
- **Added:** 2025-02 (core auth flow).

## Welcome Email

- **Trigger:** Fires automatically on first successful account creation (when user verifies a new email that has no account in the system).
- **Sender template:** Hardcoded subject: `"Welcome to Intentional"`
- **Rate limit:** Once per account (only on account creation).
- **Payload:** Congratulatory message + reminder that data syncs across devices.
- **Source:** `intentional-backend/auth.py → auth_verify()`, line 164; `email_service.py → send_welcome_email()`, line 902.
- **Added:** 2025-02 (core auth flow).

## Account Deletion Confirmation

- **Trigger:** User initiates account deletion request via `/auth/delete` endpoint.
- **Sender template:** Hardcoded subject: `"Confirm your Intentional account deletion"`
- **Rate limit:** One per 24 hours per account (checked at deletion request time; prevents spam if user refreshes).
- **Payload:** Warning that deletion is permanent + one-time link to confirm. Link expires in 24 hours.
- **Source:** `intentional-backend/auth.py → auth_delete()`, line 399; `email_service.py → send_account_deletion_confirmation_email()`, line 983.
- **Added:** 2025-02 (core auth flow).

## Account Deleted (Partner Notification)

- **Trigger:** Account deletion is confirmed via email link. Notifies any partners linked to the deleted account's devices.
- **Sender template:** Hardcoded subject: `"Intentional account deleted"`
- **Rate limit:** Once per partner email (de-duplicated in deletion code).
- **Payload:** Informs partner that the user has deleted their account and partner will no longer receive unlock requests.
- **Source:** `intentional-backend/auth.py → auth_delete_confirm()`, line 489; `email_service.py → send_account_deleted_partner_email()`, line 1095.
- **Added:** 2025-02 (core auth flow).

## Partner Consent Request

- **Trigger:** User sets or updates their accountability partner via `/partner` endpoint (PUT request). Only fires if partner is a new email and hasn't already confirmed consent.
- **Sender template:** Hardcoded subject: `"{user_name} wants you as their accountability partner"`
- **Rate limit:** None (fires every time a user adds them as a new partner, but only once per unique user-partner pair if consent already exists).
- **Payload:** Invitation to be an accountability partner. Explains they'll receive unlock code requests. Two buttons: "Accept Partnership" and "No thanks" (both link to `/consent/confirm` and `/consent/decline` endpoints). Expires in 7 days.
- **Source:** `intentional-backend/main.py → set_partner()`, line 258; `email_service.py → send_consent_email()`, line 519.
- **Added:** 2025-02 (partner system).

## Settings Unlock Code

- **Trigger:** User requests to change enforced settings while in "partner" lock mode via `/unlock-request` endpoint.
- **Sender template:** Hardcoded subject: `"{user_name} needs your unlock code"`
- **Rate limit:** None (fired each time user requests unlock; partner is the rate limiter).
- **Payload:** Informs partner that user wants to change settings. 6-digit unlock code. Expires in 1 hour.
- **Source:** `intentional-backend/main.py → request_unlock()`, line 607; `email_service.py → send_unlock_code_email()`, line 130.
- **Added:** 2025-02 (partner system).

## Extra Browse Time Request

- **Trigger:** User has exhausted earned browse time and requests additional time via `/extra-time` endpoint. User must have a confirmed accountability partner.
- **Sender template:** Hardcoded subject: `"{user_name} is requesting extra browse time"`
- **Rate limit:** None (fired each time user requests time).
- **Payload:** Notifies partner of the request, specifies how many minutes requested. 6-digit code to approve. Code expires in 15 minutes.
- **Source:** `intentional-backend/main.py → request_extra_time()`, line 889; `email_service.py → send_extra_time_code_email()`, line 263.
- **Added:** 2025-02 (earned browse system).

## AI Override Code

- **Trigger:** User wants to override AI relevance scoring during a work block (Deep Work or Focus Hours) via `/override-request` endpoint. Requires confirmed accountability partner.
- **Sender template:** Hardcoded subject: `"{user_name} wants to override AI scoring"`
- **Rate limit:** None (fired each time user requests override).
- **Payload:** Notifies partner of override request, includes block type (Deep Work / Focus Hours), optional intention/description, and optional page title that was flagged. 6-digit approval code. Code expires in 15 minutes.
- **Source:** `intentional-backend/main.py → request_override()`, line 1051; `email_service.py → send_override_code_email()`, line 388.
- **Added:** 2025-02 (AI override system).

## Content Safety Alert — Explicit Content Detected

- **Trigger:** macOS app detects explicit/NSFW content on screen via on-device vision API and POSTs `/content-safety/report`. First report from a user triggers immediate email; subsequent reports are batched.
- **Sender template:** Hardcoded subject: `"Content Safety Alert - Explicit Content Detected"`
- **Rate limit:** First detection → immediate email. Subsequent detections within 30 minutes → batched together; one batched email sent per batch window (server-side cron).
- **Payload:** Blurred screenshot (attached). Detection timestamp. Message that screen was blocked and user was notified. Disclaimer that detection may not be accurate.
- **Source:** `intentional-backend/main.py → report_content_safety()`, line 1208 (immediate) and `cron_batched_content_safety()` (batched); `email_service.py → send_content_safety_alert_email()` (immediate, line 1184) and `send_batched_content_safety_email()` (batched, line 1317).
- **Added:** 2026-04-03 (content safety feature).

## Content Safety — Permission Revoked / Feature Disabled

- **Trigger:** macOS client detects a change to content safety permissions or settings (Screen Recording permission revoked, Sensitive Content Warning disabled, or Content Safety toggle disabled) and POSTs `/content-safety/tamper` with `event_type` and `detail` fields.
- **Sender template:** Hardcoded subject: `"Intentional Alert: {title}"` (title varies by event type).
- **Rate limit:** **1 per hour per device** (server-side, via `users.last_tamper_email_at`).
- **Payload:** High or medium severity alert. Specifies which permission/setting was changed. Advises partner to check in with user. Timestamp of detection.
- **Source:** `intentional-backend/main.py → report_content_safety_tamper()`, line 1281; `email_service.py → send_content_safety_tamper_email()`, line 1488.
- **Added:** 2026-04-23 (Content Safety Lockdown feature).

## Extension Disabled Alert

- **Trigger:** Nightly heartbeat cron job checks for devices with no extension heartbeats in >4 hours. If partner is set and consent is confirmed, sends alert email.
- **Sender template:** Hardcoded subject: `"⚠️ Intentional extension may be disabled"`
- **Rate limit:** One per device per alert (checked via `disabled_alert_sent_at` timestamp; prevents duplicate alerts).
- **Payload:** Informs partner that extension has been inactive for X hours. Lists possible reasons (extension disabled, user hasn't used YouTube/Instagram, browser closed). Alert reason varies:
  - `"extension_inactive"` (default) — general inactivity
  - `"extension_disabled_native_active"` — native app running but extension silent (strong confidence extension was disabled)
  - `"native_app_force_quit"` — native app quit without normal quit event
  - `"native_app_disappeared"` — native app heartbeats stopped with no quit event
- **Source:** `intentional-backend/main.py → check_extension_heartbeats()` (cron job), line 2049; `email_service.py → send_extension_disabled_email()`, line 749.
- **Added:** 2025-06 (tamper detection).

## Extension Uninstalled Warning

- **Trigger:** Browser extension calls `/uninstall` endpoint when user removes the extension while in "partner" lock mode.
- **Sender template:** Hardcoded subject: `"⚠️ Intentional extension was removed"`
- **Rate limit:** One per uninstall (fired immediately).
- **Payload:** Alerts partner that extension was removed while lock mode was active. Suggests user may be attempting to bypass focus lock. No calls to action; informational only.
- **Source:** `intentional-backend/main.py → handle_uninstall()`, line 2349; `email_service.py → send_uninstall_warning_email()`, line 659.
- **Added:** 2025-06 (tamper detection).

---

## Volume & Consolidation Notes

### High-frequency triggers (user action + partner decision required)
- **Unlock Code, Extra Time, Override Code** — fired on demand. Volume depends on user behavior. Partner is the natural rate limiter (they can refuse to share codes). Consider consolidating to a daily digest if complaints arise.

### Automatic tamper alerts (system-generated)
- **Content Safety Tamper, Extension Disabled, Uninstall Warning** — fired by automated monitoring. Should be sent immediately for security transparency. Tamper email is already rate-limited to 1/hour per device.

### One-time or rare triggers (low volume)
- **Verification Code, Welcome, Consent Request, Account Deleted, Account Deletion Confirmation** — auth and account lifecycle events. Low frequency, intentional. No consolidation needed.

### Batched detections (volume control built-in)
- **Content Safety Alerts** — first detection immediate; subsequent detections within 30 minutes batched together. Prevents email spam during acute content detection scenarios.

---

## Open Questions

1. **Should non-urgent events move to a daily digest?** Currently unlock codes, extra time, and overrides fire immediately. If a power user makes many requests in one session, partner could receive 5+ emails in 1 hour. Measure volume after a week of real-world use.

2. **Partner fatigue threshold** — we don't have data on how many partner emails per day cause complaints. Recommend monitoring partner feedback and setting a guideline (e.g., "if >3 action-required emails per day, consolidate to digest").

3. **Should Content Safety Tamper alerts be more aggressive?** Currently 1/hour per device. If a user rapidly disables & re-enables the feature (or revokes & re-grants permission), partner only sees the first one. Consider per-event-type rate limits or per-change tracking.

4. **Silence modes during known resets** — Extension Disabled alerts during app restart cycles (especially on macOS updates or app crashes) could be noisy. Consider: (a) "known quiet window" exceptions (e.g., silence for 15 min after app_crash event), or (b) require 2–3 separate heartbeat gaps before alerting.

