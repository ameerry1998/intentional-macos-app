# Backend Inventory — `intentional-backend` (2026-05-04)

Snapshot of every HTTP route, DB table, cron job, push-fanout, and auth path in the FastAPI backend at `/Users/arayan/Documents/GitHub/intentional-backend`. Source of truth for product brainstorms.

- Stack: FastAPI · Postgres-via-Supabase (`service_role` key bypasses RLS) · Resend (email) · `aioapns` (push) · Hosted on Railway (Nixpacks).
- Two coexisting auth systems: **X-Device-ID** (anonymous device-level, 64-hex header) and **Bearer JWT** (account-level via email OTP or Supabase JWT). Most newer endpoints accept *either* via `_resolve_account_dual_auth`.
- One FastAPI app (`main.py`, ~4,470 lines) plus one router (`auth.py`, `/auth/*`). One enforcement helper (`enforcement.py`, 62 lines). Two in-process schedulers loop every 60s on app startup.

---

## 1. Endpoint inventory

| Method | Path | Auth | Handler | Purpose | Primary table(s) |
|---|---|---|---|---|---|
| GET    | `/` | none | main.py:249 | Health (returns service+version) | — |
| GET    | `/auth/delete-confirm` | token (query) | auth.py:413 | Confirm account deletion via emailed token, hard-delete account | `account_deletions`, `accounts`, `users`, `auth_codes`, `intentions` |
| POST   | `/auth/delete` | JWT | auth.py:346 | Request account deletion; sends 24h confirmation email | `account_deletions` |
| POST   | `/auth/login` | none | auth.py:46 | Send 6-digit OTP to email (rate-limited 3/hr) | `auth_codes` |
| GET    | `/auth/me` | JWT | auth.py:305 | Get account info + linked devices | `accounts`, `users` |
| POST   | `/auth/logout` | none (refresh token in body) | auth.py:277 | Revoke entire token family | `refresh_tokens` |
| POST   | `/auth/refresh` | none (refresh token in body) | auth.py:204 | Rotate access+refresh; replay → revoke family | `refresh_tokens`, `accounts` |
| POST   | `/auth/verify` | none (OTP in body) | auth.py:99 | Verify OTP, create/find account, optionally link device, return JWT+refresh | `auth_codes`, `accounts`, `users`, `refresh_tokens` |
| GET    | `/bedtime/config` | dual | main.py:3712 | Get bedtime schedule for account; defaults if no row | `bedtime_config` |
| PUT    | `/bedtime/config` | dual | main.py:3750 | Replace bedtime config | `bedtime_config` |
| POST   | `/bedtime/unlock-approve` | dual (must = partner) | main.py:4212 | Partner approves request via push-tap; sets `released_until`, sends APNs to originator | `bedtime_unlock_requests`, `accounts`, `device_push_tokens` |
| POST   | `/bedtime/unlock-request` | dual | main.py:3930 | Generate code, email partner, APNs partner; once-per-night gate | `bedtime_unlock_requests`, `users`, `partner_consent`, `device_push_tokens` |
| GET    | `/bedtime/unlock-status` | dual | main.py:4337 | Polled by devices ~5s while locked; returns `released` + `pending_request` | `bedtime_unlock_requests` |
| POST   | `/bedtime/unlock-verify` | dual | main.py:4085 | Verify 6-digit code; sets `released_until` | `bedtime_unlock_requests`, `bedtime_config` |
| GET    | `/consent/confirm` | token (query) | main.py:2252 | HTML — partner accepts consent | `partner_consent` |
| GET    | `/consent/decline` | token (query) | main.py:2296 | HTML — partner declines consent | `partner_consent` |
| GET    | `/content-safety/batch-send` | CRON_SECRET | main.py:1483 | Cron — batch-email queued NSFW reports per user (every 30 min); cleanup >30d | `content_safety_reports`, `users`, `partner_consent` |
| POST   | `/content-safety/report` | X-Device-ID | main.py:1318 | Mac uploads blurred screenshot; first detect emails immediately, rest queued; 10/hr cap | `content_safety_reports`, `users` |
| POST   | `/content-safety/tamper` | X-Device-ID | main.py:1408 | Tamper alert (CS disabled / permission revoked); 1/hr partner email | `system_events`, `users` |
| GET    | `/device/enforcement` | X-Device-ID | main.py:517 | Authoritative enforcement state for device (lock_mode + `enforced_settings` blob, gated by temp-unlock) | `users` |
| POST   | `/devices/link-legacy` | JWT | main.py:2955 | Link an existing legacy `users.device_id` row to the calling account | `users`, `accounts` |
| POST   | `/devices/push-token` | dual | main.py:3027 | Upsert APNs token on `(account_id, device_id)` | `device_push_tokens` |
| POST   | `/devices/register` | JWT | main.py:3001 | Register a Mac/iOS device for focus relay (separate from legacy `/register`) | `registered_devices` |
| POST   | `/extra-time/request` | X-Device-ID | main.py:994 | Generate code, email partner; partner-gated extra browse minutes | `extra_time_requests`, `users`, `partner_consent` |
| POST   | `/extra-time/verify` | X-Device-ID | main.py:1078 | Verify 6-digit code, return `added_minutes` (Mac applies locally) | `extra_time_requests` |
| GET    | `/focus/active` | dual | main.py:3320 | Current active focus session (TTL-filtered); Mac polls every 2s | `focus_sessions` |
| POST   | `/focus/toggle` | dual | main.py:3244 | Start or stop focus session; APNs to peers; WS broadcast | `focus_sessions`, `system_events`, `device_push_tokens`, `intentions` |
| GET    | `/health` | none | main.py:255 | Load balancer health | — |
| GET    | `/heartbeat/check-stale` | CRON_SECRET | main.py:2068 | Cron — find stale extension heartbeats, cross-correlate w/ system_events, alert partner | `users`, `system_events`, `partner_consent` |
| POST   | `/heartbeat` | X-Device-ID | main.py:1590 | Extension 5-min heartbeat; clears `disabled_alert_sent_at` | `users` |
| POST   | `/intentions/{id}/strictness/cancel` | dual | main.py:3692 | Cancel any pending strictness change (idempotent) | `intention_strictness_changes` |
| GET    | `/intentions/{id}/strictness/pending` | dual | main.py:3668 | Get currently-pending strictness change (404 if none) | `intention_strictness_changes` |
| PUT    | `/intentions/{id}/strictness` | dual | main.py:3568 | Change preset (tighten = instant; soften = 24h cooldown; strict-step-down requires unlock) | `intentions`, `intention_strictness_changes`, `focus_sessions` |
| DELETE | `/intentions/{id}` | dual | main.py:3533 | Soft-delete (`deleted_at`); preserves session history | `intentions` |
| GET    | `/intentions/{id}` | dual | main.py:3442 | Single Intention by id (incl. soft-deleted) | `intentions` |
| PUT    | `/intentions/{id}` | dual | main.py:3489 | Update Intention (optimistic: client must include current `version`) | `intentions` |
| GET    | `/intentions` | dual | main.py:3422 | List Intentions for account; auto-seeds Day-1 default "Focus" if zero rows | `intentions` |
| POST   | `/intentions` | dual | main.py:3458 | Create new Intention (server assigns id+version=1) | `intentions` |
| DELETE | `/partner` | X-Device-ID | main.py:419 | Remove partner; resets lock; sibling-fans the clear | `users` |
| GET    | `/partner/dashboard/content-safety` | JWT (partner) | main.py:2771 | CS detection log for partner's monitored devices | `content_safety_reports`, `users` |
| GET    | `/partner/dashboard/heartbeats` | JWT (partner) | main.py:2651 | Heartbeat timeline (today hourly + 6 prev days summary) | `system_events`, `users` |
| GET    | `/partner/dashboard/status` | JWT (partner) | main.py:2557 | Real-time status (app/CS/lock/strict) for monitored devices | `users`, `system_events` |
| GET    | `/partner/dashboard/tamper-log` | JWT (partner) | main.py:2837 | Tamper events + unlock history for monitored devices | `system_events`, `users` |
| GET    | `/partner/status` | dual | main.py:452 | Get partner+consent across all sibling devices on the account | `users`, `partner_consent` |
| PUT    | `/partner` | X-Device-ID | main.py:310 | Set/update partner; sends 7-day consent email; sibling-fans the write | `users`, `partner_consent` |
| POST   | `/override/request` | X-Device-ID | main.py:1164 | AI-relevance override request (5-min bypass); generate code + email partner | `override_requests`, `users`, `partner_consent` |
| POST   | `/override/verify` | X-Device-ID | main.py:1242 | Verify override code | `override_requests` |
| POST   | `/register` | none (device_id in body) | main.py:263 | Anonymous device registration (extension first install). 200 if existing, 201 if new | `users` |
| GET    | `/schedule/blocks` | none | main.py:3798 | **Deprecated 301** → `/time_blocks` | — |
| PUT    | `/schedule/blocks` | none | main.py:3805 | **Deprecated 301** → `/time_blocks` | — |
| GET    | `/sessions/journal` | X-Device-ID | main.py:1728 | Per-day session journal (account-keyed when logged in) | `sessions` |
| POST   | `/sessions` | X-Device-ID | main.py:1685 | Record completed browsing session | `sessions` |
| GET    | `/settings/sync` | JWT | main.py:1917 | Get account settings JSON blob | `account_settings` |
| PUT    | `/settings/sync` | JWT | main.py:1868 | Save settings (50KB cap); re-derives `enforced_settings` if partner-locked | `account_settings`, `users` |
| POST   | `/system-event` | X-Device-ID | main.py:1622 | Native app + extension structured events (sleep/wake, browser open/close, app_quit, native_app_heartbeat, etc.) | `system_events` |
| POST   | `/telemetry/selector-broken` | X-Device-ID | main.py:2001 | DOM selector breakage report from extension's FallbackManager | `system_events` |
| GET    | `/time_blocks` | dual | main.py:3828 | List Time Blocks (recurring schedule, optionally Intention-bound) | `time_blocks` |
| PUT    | `/time_blocks` | dual | main.py:3842 | Atomic replace of all Time Blocks for account | `time_blocks` |
| GET    | `/uninstall` | device_id (query) | main.py:2504 | HTML — extension uninstall warning; emails partner if was partner-locked | `users` |
| POST   | `/unlock/request` | X-Device-ID | main.py:651 | Request unlock; partner mode emails code, self mode sets 24h timer | `users`, `partner_consent` |
| GET    | `/unlock/status` | X-Device-ID | main.py:945 | Read lock+temp-unlock state | `users`, `partner_consent` |
| POST   | `/unlock/verify` | X-Device-ID | main.py:810 | Verify code (constant-time); grants 5-min temp-unlock or permanent (sentinel year-9999) | `users` |
| GET    | `/usage/history` | X-Device-ID | main.py:1829 | 7–90 day daily aggregates (account-keyed when possible) | `daily_usage` |
| POST   | `/usage/sync` | X-Device-ID | main.py:1787 | Upsert one row per (user, platform, date); called every 60s | `daily_usage` |
| GET    | `/user/unprotected-browsers` | X-Device-ID | main.py:1945 | Browsers detected w/o extension (24h–168h window) | `system_events` |
| WS     | `/ws/focus` | JWT (in first message) | main.py:4391 | WebSocket relay for focus signals; not load-bearing (Mac polls instead) | `registered_devices` |

Total: **57 HTTP routes** + 1 WebSocket. Of those: 6 partner-resource (none used by current clients), 2 deprecated 301 redirects.

---

## 2. Endpoints grouped by feature

### Auth & Account (8)
- `POST /register` — anonymous device-id registration
- `POST /auth/login`, `POST /auth/verify`, `POST /auth/refresh`, `POST /auth/logout`
- `GET /auth/me`, `POST /auth/delete`, `GET /auth/delete-confirm`

### Devices & Push (3)
- `POST /devices/register` — focus-relay registration
- `POST /devices/link-legacy` — link `users.device_id` to calling account
- `POST /devices/push-token` — APNs token upsert

### Partner Pairing & Lock (8)
- `PUT /partner`, `GET /partner/status`, `DELETE /partner`
- `GET /consent/confirm`, `GET /consent/decline`
- `PUT /lock`, `POST /unlock/request`, `POST /unlock/verify`, `GET /unlock/status`

### Partner Dashboard (4) — **see §8 dead/unused**
- `GET /partner/dashboard/{status,heartbeats,content-safety,tamper-log}`

### Intentions (Spec 1, May 2026) (5)
- `GET /intentions`, `POST /intentions`, `GET /intentions/{id}`, `PUT /intentions/{id}`, `DELETE /intentions/{id}`

### Strictness (Scheduled Intentions Redesign, May 2026) (3 implemented, partner-unlock pair DEFERRED)
- `PUT /intentions/{id}/strictness`
- `GET /intentions/{id}/strictness/pending`
- `POST /intentions/{id}/strictness/cancel`
- *(referenced-but-not-on-backend: `POST /intention_strictness_unlock_requests`, `POST /intention_strictness_unlock_requests/{id}/verify`)*

### Focus Sessions (2 + WS)
- `POST /focus/toggle`, `GET /focus/active`, `WS /ws/focus`

### Time Blocks / Schedule (2 + 2 deprecated)
- `GET /time_blocks`, `PUT /time_blocks`
- `GET /schedule/blocks` (301), `PUT /schedule/blocks` (301)

### Bedtime (5)
- `GET /bedtime/config`, `PUT /bedtime/config`
- `POST /bedtime/unlock-request`, `POST /bedtime/unlock-verify`, `POST /bedtime/unlock-approve`, `GET /bedtime/unlock-status`

### Content Safety (3)
- `POST /content-safety/report`, `POST /content-safety/tamper`
- `GET /content-safety/batch-send` (cron)

### Earn-Your-Browse / Extra Time (2)
- `POST /extra-time/request`, `POST /extra-time/verify`

### AI Override (2)
- `POST /override/request`, `POST /override/verify`

### Sessions / Usage / Settings (6)
- `POST /sessions`, `GET /sessions/journal`
- `POST /usage/sync`, `GET /usage/history`
- `PUT /settings/sync`, `GET /settings/sync`

### Tamper & Telemetry (4)
- `POST /heartbeat`, `GET /heartbeat/check-stale` (cron)
- `POST /system-event`, `GET /user/unprotected-browsers`
- `POST /telemetry/selector-broken`

### Enforcement Constraints (1)
- `GET /device/enforcement` (Mac's `EnforcementReconciler` consumes this)

### Misc (3)
- `GET /`, `GET /health`, `GET /uninstall`

---

## 3. Database tables

Schema reconstructed from `migrations/001..020`. Tables marked **RLS** have row-level security enabled with zero policies; backend uses `service_role` to bypass.

### `users` (the device row, despite the name)
Columns: `id` (uuid), `device_id` (text 64-hex unique), `account_id` (uuid → accounts, nullable), `lock_mode` ('none'|'partner'|'self'), `partner_email`, `partner_name`, `pending_unlock_code_hash`, `pending_unlock_requested_at`, `self_unlock_available_at`, `temporary_unlock_until`, `last_heartbeat_at`, `last_platform`, `disabled_alert_sent_at`, `enforced_settings` (jsonb, mig 010), `enforced_settings_updated_at`, `last_tamper_email_at`, `display_name?`.
- INSERT: `POST /register`.
- UPDATE: `PUT /partner`, `DELETE /partner`, `PUT /lock`, `POST /unlock/{request,verify}`, `POST /heartbeat`, `POST /content-safety/tamper`, `POST /auth/verify` (sets `account_id`), `POST /devices/link-legacy`, `PUT /settings/sync` (re-derives blob), `GET /heartbeat/check-stale` (sets `disabled_alert_sent_at`), `GET /auth/delete-confirm` (clears `account_id`).
- DELETE: never.
- Retention: forever; CASCADE on partner_consent, system_events, sessions, daily_usage, override_requests, extra_time_requests, content_safety_reports.

### `accounts` (mig 002, 011)
`id`, `email` UNIQUE, `name?`, `supabase_user_id?` (mig 011), `created_at`, `updated_at`.
- INSERT: `POST /auth/verify` first time, or `_resolve_account_from_token` auto-provisioning Supabase users.
- UPDATE: `_resolve_account_from_token` backfilling `supabase_user_id`.
- DELETE: `GET /auth/delete-confirm` (CASCADE through refresh_tokens, account_deletions, focus_sessions, intentions, bedtime_config, bedtime_unlock_requests, account_settings, registered_devices, device_push_tokens, intention_strictness_changes, time_blocks, schedule_blocks).

### `auth_codes` (mig 002)
`id`, `email`, `code_hash`, `attempts` (max 5), `expires_at` (10 min), `used`, `created_at`.
- INSERT: `POST /auth/login`.
- UPDATE: `POST /auth/verify` (`attempts++`, `used=true`).
- DELETE: `GET /auth/delete-confirm`.

### `refresh_tokens` (mig 002)
`id`, `account_id` CASCADE, `device_id?`, `token_hash`, `token_family` (replay detection chain), `revoked`, `expires_at` (30d), `created_at`.
- INSERT: `POST /auth/{verify,refresh}`.
- UPDATE: `POST /auth/{refresh,logout}` set `revoked=true`; refresh-replay revokes entire family.
- DELETE: never explicit; CASCADE only.

### `account_deletions` (mig 003)
`id`, `account_id` CASCADE, `token` UNIQUE, `expires_at` (24h), `confirmed`, `created_at`.
- INSERT: `POST /auth/delete`. UPDATE: `GET /auth/delete-confirm`.

### `partner_consent`
`id`, `user_id` FK, `partner_email`, `consent_token`, `status` ('pending'|'confirmed'|'declined', expired = pending+past `expires_at`), `created_at`, `expires_at` (7d), `confirmed_at?`.
- INSERT: `PUT /partner` (after deleting any existing pending).
- UPDATE: `GET /consent/{confirm,decline}`.

### `system_events` (mig 001)
`id`, `user_id` CASCADE, `event_type`, `timestamp` (client-supplied ISO), `source` ('native_app_macos'|'extension'|'backend'), `details` (jsonb), `created_at`.
- INSERT: `POST /system-event`, `POST /telemetry/selector-broken` (`event_type='selector_broken'`), `POST /content-safety/tamper`, `POST /focus/toggle` (start+end audit).
- UPDATE: never. DELETE: never (CASCADE only). Indexes: `(user_id)`, `(created_at desc)`, `(user_id, created_at desc)`.

### `sessions` (mig 004)
Per-completed-browsing-session row. Columns: `id`, `user_id` CASCADE, `account_id?`, `platform`, `browser?`, `intent?`, `free_browse`, `started_at`, `ended_at?`, `duration_seconds`, `planned_duration_seconds?`, `video_seconds`, `created_at`.
- INSERT: `POST /sessions`. Read: `GET /sessions/journal`.
- Indexes: `(user_id, started_at desc)`, `(account_id, started_at desc)`, `(user_id, platform, started_at desc)`.

### `daily_usage` (mig 004)
`id`, `user_id` CASCADE, `account_id?`, `platform`, `date`, `minutes_used` double, `video_minutes`, `free_browse_minutes`, `session_count`, `updated_at`, `created_at`. UNIQUE `(user_id, platform, date)` for upsert.
- UPSERT: `POST /usage/sync` (every 60s from Mac TimeTracker). Read: `GET /usage/history`.

### `account_settings` (mig 004)
`id`, `account_id` UNIQUE FK CASCADE, `settings` jsonb (`{budgets, freeBrowseBudgets, ...}`), `updated_at`, `created_at`. 50KB cap server-side.
- UPSERT: `PUT /settings/sync`. Read: `GET /settings/sync`, `PUT /lock` (re-derives enforcement blob).

### `extra_time_requests` (mig 005)
`id`, `user_id` CASCADE, `minutes`, `code_hash`, `status` ('pending'|'verified'|'expired'), `created_at`, `verified_at?`. Implicit 15-min expiry computed at verify time (no cron).
- INSERT: `POST /extra-time/request`. UPDATE: `POST /extra-time/verify`.

### `override_requests` (mig 006)
`id`, `user_id` CASCADE, `block_type`, `page_title?`, `intention?`, `code_hash`, `status`, `created_at`, `verified_at?`. Same 15-min implicit TTL.
- INSERT: `POST /override/request`. UPDATE: `POST /override/verify`.

### `content_safety_reports` (mig 007 + 008)
`id`, `user_id` CASCADE, `timestamp`, `email_sent`, `partner_email?`, `image_base64?` (mig 008), `batch_sent_at?` (mig 008), `created_at`.
- INSERT: `POST /content-safety/report` (rate-limit 10/hr). UPDATE: `POST /content-safety/report` (immediate-send path), `GET /content-safety/batch-send` (cron).
- DELETE: `GET /content-safety/batch-send` cleans up rows w/ `batch_sent_at < now-30d`.

### `focus_sessions` (mig 009 + 012 + 018 + 019)
`id`, `account_id` CASCADE, `started_at`, `ended_at?`, `triggered_by` ('puck'|'mac_manual'|'ios_manual'|'ios_nfc'|'schedule'|'schedule_ended'|...), `status` ('active'|'ended'), `expires_at` (mig 012, TTL `started_at + 12h`), `intention_id?` FK SET NULL (mig 018), `time_block_id?` FK SET NULL (mig 019).
- INSERT: `_create_focus_session` (called from `POST /focus/toggle` and `time_block_scheduler`).
- UPDATE: `_end_focus_session` (called from `POST /focus/toggle` stop-action and `time_block_scheduler`).
- Retention: forever (history). Zombie prevention: `/focus/active` filters `expires_at > now`.
- Indexes: `(account_id)`, `(account_id, status) WHERE status='active'`, `(account_id, status, expires_at) WHERE status='active'`, `(intention_id) WHERE NOT NULL`, `(time_block_id) WHERE NOT NULL`.

### `registered_devices` (mig 009)
`id`, `account_id` CASCADE, `device_type` ('mac'|'ios'), `device_name`, `push_token?`, `last_seen`, `created_at`. UNIQUE `(account_id, device_type, device_name)`.
- INSERT/UPDATE: `POST /devices/register` (upsert).
- UPDATE: `WS /ws/focus` on `focus_heartbeat` message.

### `bedtime_config` (mig 013) **RLS**
`account_id` PK CASCADE, `enabled`, `bedtime_start_{hour,minute}`, `wake_{hour,minute}`, `active_days` int[] (ISO 1..7), `allowlist_bundle_ids` text[], `partner_locked`, `updated_at` (trigger-bumped).
- UPSERT: `PUT /bedtime/config`. Read: `GET /bedtime/config`, `_resolve_until_wake_until`, `/bedtime/unlock-{request,verify}` for "until-wake" duration.

### `bedtime_unlock_requests` (mig 014 + 016) **RLS**
`id`, `account_id` CASCADE, `requested_at`, `partner_email`, `code_hash`, `expires_at` (30 min after request), `status` ('pending'|'verified'|'expired'|'consumed'), `attempts` (5 strikes → expired), `used_at?`, `released_until?`, `reason?`, `note?`, `requested_duration_minutes` (15/30/60/120/-1, default 30; mig 016).
- INSERT: `POST /bedtime/unlock-request`.
- UPDATE: `POST /bedtime/unlock-{verify,approve}`, expiry checks throughout.
- DELETE: `POST /bedtime/unlock-request` rolls back row on email send failure.
- Indexes: `(account_id, status, expires_at) WHERE pending`, `(account_id, released_until) WHERE verified`.

### `device_push_tokens` (mig 015) **RLS**
`id`, `account_id` CASCADE, `device_id` text, `apns_token`, `bundle_id`, `environment` ('sandbox'|'production'), `created_at`, `updated_at`. UNIQUE `(account_id, device_id)`.
- UPSERT: `POST /devices/push-token`. Read: `send_push_to_account` fanout helper. Index: `(account_id)`.

### `time_blocks` (mig 017 → renamed in 019; was `schedule_blocks`) **RLS**
`block_id` PK uuid (client-supplied), `account_id` CASCADE, `title`, `block_type` ('deep_work'|'focus_hours' check), `start_{hour,minute}`, `end_{hour,minute}`, `active_days` int[] default `{1..7}`, `enabled`, `created_at`, `updated_at` (trigger), `intention_id?` FK SET NULL (mig 019), `intensity` ('deep_work'|'focus_hours' check, default `deep_work`; mig 019), `derived_from_budget` (mig 020 — D9 prep, no behavior).
- DELETE-ALL + INSERT: `PUT /time_blocks` (atomic replace).
- Read: `GET /time_blocks`, `time_block_scheduler` (every 60s).
- Indexes: `(account_id)`, `(account_id) WHERE enabled`, `(intention_id) WHERE NOT NULL`.

### `intentions` (mig 018 + 020) **RLS**
`id`, `account_id` CASCADE, `name`, `description?`, `color_hex?`, `icon?`, `mac_websites` text[], `mac_bundle_ids` text[], `ios_app_tokens?` bytea, `ios_category_tokens?` bytea, `version` (optimistic concurrency), `created_at`, `updated_at` (trigger), `deleted_at?` (soft delete), `strictness_preset` ('strict'|'standard'|'soft', default `standard`; mig 020), `weekly_budget_hours?` numeric (mig 020 — prep, unused), `budget_enforcement?` ('track'|'nudge'|'auto_schedule'|'strict'; mig 020 — prep, unused).
- INSERT: `POST /intentions`, `_maybe_seed_default_intention` (Day-1 seeded "Focus" with curated Mac websites for fresh accounts).
- UPDATE: `PUT /intentions/{id}` (bumps version), `PUT /intentions/{id}/strictness` (instant tighten), `intention_strictness_scheduler` (apply on cool-down expiry).
- DELETE: `DELETE /intentions/{id}` is a soft delete (`deleted_at`); only hard-deleted by `GET /auth/delete-confirm`.
- Indexes: `(account_id) WHERE deleted_at IS NULL`, `(account_id)`.

### `intention_strictness_changes` (mig 020) **RLS**
`id`, `account_id` CASCADE, `intention_id` CASCADE, `requested_at`, `takes_effect_at`, `from_preset`, `to_preset`, `applied_at?`, `cancelled_at?`, `requires_partner_unlock`, `partner_unlocked_at?`. UNIQUE `(intention_id) WHERE applied_at IS NULL AND cancelled_at IS NULL` — at most one pending change per intention.
- INSERT: `PUT /intentions/{id}/strictness` softening path.
- UPDATE: `POST /intentions/{id}/strictness/cancel`, `intention_strictness_scheduler` (sets `applied_at`).
- *(Never set: `partner_unlocked_at` — partner-unlock endpoints are NOT implemented backend-side.)*

---

## 4. Cross-device propagation

| Trigger | Recipients | Mechanism | Payload | Client behavior on receipt |
|---|---|---|---|---|
| `POST /focus/toggle` start | All `device_push_tokens` rows for account | APNs background, priority 10 | `{aps:{content-available:1}, session_id, intention_id, started_at, action:"start", triggered_by}` | iOS: refetch active session, apply Intention shield. Mac: 2s `/focus/active` poller picks up regardless. |
| `POST /focus/toggle` stop | All `device_push_tokens` rows for account | APNs background | `{aps:{content-available:1}, session_id, intention_id, action:"stop", triggered_by}` | iOS lifts shield. Mac poller picks up. |
| `time_block_scheduler` start (cron 60s) | All `device_push_tokens` for account | APNs background via `_create_focus_session` | Same as `/focus/toggle` start, `triggered_by:"schedule"` | Same. |
| `time_block_scheduler` end (cron 60s) | All `device_push_tokens` for account | APNs background via `_end_focus_session` | Same as `/focus/toggle` stop, `triggered_by:"schedule_ended"` | Same. |
| `POST /bedtime/unlock-request` | Partner's `device_push_tokens` (lookup by partner email → account_id) | APNs alert, default priority, `collapse_id="bedtime-request-<id>"` | `{aps:{alert:{title,body}, sound, category:"bedtime.unlock_request"}, type:"bedtime.unlock_requested", request_id, requester_name, reason, note, expires_at_iso}` | Partner iOS shows actionable push → opens PartnerApprovalView. |
| `POST /bedtime/unlock-approve` | Originator's `device_push_tokens` | APNs alert, `collapse_id="bedtime-approved-<id>"` | `{aps:{alert:{title,body},sound}, type:"bedtime.unlock_approved", request_id, released_until_iso}` | Originator's iOS (and Mac via 5s `/bedtime/unlock-status` poll) drops bedtime takeover. |
| `POST /focus/toggle` (start or stop) | Active `WS /ws/focus` connections for account | WebSocket `send_json` | `{type:"focus_signal", action:"start|stop", session_id, timestamp, triggered_by}` | Mac (when connected) picks up. Not load-bearing. |

APNs is best-effort throughout (graceful degrade to no-op if env vars missing; no_op returns success). Email is the source-of-truth fallback for bedtime.

---

## 5. Cron jobs / background tasks

| Schedule | Where | What it does | Tables touched |
|---|---|---|---|
| Every 60s (in-process asyncio loop, started in `@app.on_event("startup")`) | `time_block_scheduler.run_scheduler_loop` | Scan enabled `time_blocks`. For blocks whose `start_{hour,minute}` == current minute AND today's ISO weekday in `active_days` AND no existing focus_session bound to that block today → call `_create_focus_session`. For blocks whose `end_{hour,minute}` matches AND have an active session → call `_end_focus_session`. | `time_blocks`, `focus_sessions`, `device_push_tokens` (via APNs in `_create/_end_focus_session`) |
| Every 60s (in-process asyncio loop) | `intention_strictness_scheduler.run_scheduler_loop` | Find `intention_strictness_changes` rows where `applied_at IS NULL AND cancelled_at IS NULL AND takes_effect_at <= now` AND (NOT requires_partner_unlock OR partner_unlocked_at IS NOT NULL). Apply via `intentions.strictness_preset = to_preset` + stamp `applied_at`. | `intentions`, `intention_strictness_changes` |
| Every 30 min (external cron-job.org or GitHub Actions hitting `?secret=...`) | `GET /heartbeat/check-stale` | Find users with stale extension heartbeat (>1h default) but recent activity (<24h ago) and confirmed partner; cross-correlate `system_events` (`native_app_heartbeat`, `app_quit`, `computer_sleeping`, etc.) to determine `alert_reason`; email partner; mark `disabled_alert_sent_at` to prevent spam. | `users`, `system_events`, `partner_consent` |
| Every 30 min (external cron) | `GET /content-safety/batch-send` | Group unsent `content_safety_reports` by user, send one batched email per user with all blurred screenshots, mark sent. Cleanup: delete sent reports older than 30 days. | `content_safety_reports`, `users`, `partner_consent` |

Implicit "expiry as a query filter" mechanisms (no cron):
- `focus_sessions.expires_at` — `/focus/active` filters; zombie sessions self-evict after 12h.
- `extra_time_requests` / `override_requests` — `created_at + 15min` checked at verify time, mark `status='expired'`.
- `auth_codes` — `expires_at` 10min, checked at verify.
- `partner_consent` — 7d expiry, computed `expired` status when read.
- `bedtime_unlock_requests` — `expires_at` 30min, checked at verify; 5 wrong attempts also expires.
- `account_deletions` — `expires_at` 24h, checked at confirm.

---

## 6. Auth flows

### Email OTP → JWT (`auth.py`)
1. `POST /auth/login {email}` → `auth_codes` row inserted with SHA-256 hash, 10min TTL, max 5 attempts. Resend email. Always returns 200 (enumeration prevention).
2. `POST /auth/verify {email, code, device_id?}` → constant-time `secrets.compare_digest`. On match: find/create `accounts`, link `users.account_id` if device_id given, send welcome email (new account only), issue HS256 JWT (15min) + 30d refresh token (token_family UUID).
3. `POST /auth/refresh {refresh_token}` → if revoked: revoke entire `token_family` (replay detection); else mark current revoked + issue new pair in same family.
4. `POST /auth/logout {refresh_token}` → revoke entire family.
5. `POST /auth/delete` (JWT) → `account_deletions` row + email link (24h). `GET /auth/delete-confirm?token=...` does hard delete: unlink users, delete auth_codes, delete intentions, delete account (CASCADE handles refresh_tokens, account_deletions, sessions, daily_usage etc), notify partners.

### Device-ID Auth (X-Device-ID)
- Header is 64-char hex; validated by `validate_device_id` (length + hex parse).
- Used by extension and Mac for legacy device-level endpoints.
- Mac uses it specifically for `/focus/active` polling (every 2s) to avoid 15-min JWT TTL refresh races.
- `_resolve_account_dual_auth(authorization, x_device_id)` — Bearer wins; X-Device-ID requires the row's `account_id` to be linked (else 401 with hint to call `/devices/link-legacy`).

### Supabase JWT federation (`_resolve_account_from_token`)
- Backend accepts both Intentional-issued JWTs (`token_source: "intentional"`, `sub` = account_id) and Supabase-issued JWTs (resolved by `email` claim → `accounts` row).
- First time we see a Supabase user, `accounts.supabase_user_id` is backfilled. New email = auto-create account.
- iOS uses Supabase tokens exclusively; Mac uses Intentional-OTP tokens; bedtime/focus endpoints accept either.

### Partner consent (`PUT /partner` → email → `GET /consent/{confirm,decline}?token=`)
- 32-byte URL-safe `consent_token` with 7-day expiry.
- `PUT /lock {mode:"partner"}` requires `consent_status=="confirmed"` (409 otherwise).
- `_account_partner_via_siblings` reads partner across all sibling `users` rows on the same account so iOS+Mac agree even when one device's row was created before partner was set.

### Partner code generation (unlock / extra-time / override / bedtime-unlock)
- 6-digit `secrets.randbelow(10)` per digit → SHA-256 hash stored, plaintext in email only.
- Verification via `secrets.compare_digest(input_hash, stored_hash)`.
- One-time use: hash cleared on success.

### Intent-strictness unlock (Strict-step-down softening)
- Backend creates `intention_strictness_changes` row with `requires_partner_unlock=true`, but **no endpoint exists to set `partner_unlocked_at`**. The Mac & iOS clients reference `POST /intention_strictness_unlock_requests` and `/intention_strictness_unlock_requests/{id}/verify` (Mac) or `intentions/strictness-unlock-request` (iOS) — both 404 against this backend. See §8.

### Partner-dashboard JWT
- `require_partner_auth` extracts `payload.email` from the standard access token; the partner is anyone whose email matches `users.partner_email`. There is no separate "partner account" model — they sign in via the same OTP path on a partner-side webapp.

---

## 7. Constraints / enforcement state

The Mac's `EnforcementReconciler` consumes one endpoint:

`GET /device/enforcement` — request: `X-Device-ID` header. Response (`EnforcementResponse`):
```
{
  success: bool,
  device_id: str,
  lock_mode: "none" | "partner",
  enforcement_active: bool,
  constraints: { [key: string]: ConstraintSpec },   // empty {} when not active
  temporary_unlock_until: str | null,                // ISO 8601
  updated_at: str | null
}
```

`enforcement_active` rules (main.py:537-547):
- `lock_mode != "partner"` → `false`, `constraints={}`.
- `temporary_unlock_until > now` → `false`, `constraints={}` (window open). Same response shape but enforcement paused.
- Else `true`, `constraints = users.enforced_settings` (jsonb, mig 010).

The blob is **derived from `account_settings.settings`** by `enforcement.derive_enforcement_blob` (enforcement.py:27) on every `PUT /settings/sync` (when partner-locked) and on `PUT /lock` mode-transition.

Constraint key naming uses snake_case dot-paths. The derivation:

| Source field (camelCase, in `account_settings.settings`) | Constraint key (snake_case) | Constraint type |
|---|---|---|
| `contentSafety.enabled == true` | `content_safety.enabled` | `must_be_true` |
| `platforms.youtube.enabled` (etc, +`blockShorts`/`blockReels`/`blockWatch`/`blockGaming`/`blockSponsored`/`blockSuggested`) | `platforms.<platform>.{enabled,block_shorts,block_reels,block_watch,block_gaming,block_sponsored,block_suggested}` | `must_be_true` (only emitted when the field is `true`) |
| `platforms.<platform>.threshold` (int) | `platforms.<platform>.threshold` | `min_value` (with `value`) |
| `distractingSites` (list) | `distracting_sites` | `must_include_all` (with `values`, deduped + sorted) |

`ConstraintSpec` shape:
```
{ "type": "must_be_true" | "must_be_false" | "min_value" | "must_include_all" | "unknown",
  "value": float?, "values": list[str]? }
```

**Key semantics:** the blob is **ratchet-up only**. `derive_enforcement_blob` only emits constraints for fields that are currently `true` (or has a numeric value); turning a setting *off* in `account_settings` simply omits the key from the next derive — but a partner-locked client refuses to turn it off locally (the constraint is the floor). The user can only *strengthen* while partner-locked.

**`content_safety.enabled` constraint** — once present, any local Mac toggle of CS off violates the constraint; `EnforcementReconciler` re-flips it on. The `pause_cs_constraint.py` script removes this single key from a target user's blob for debugging windows; `resume_cs_constraint.py` restores it.

Mac dashboard reads `account_settings` in camelCase; backend converts to snake_case constraint keys. **The mapping lives client-side** (dashboard JSON is camelCase, blob keys are snake_case) — there is no server-side normalization layer; clients must read `enforcement.py` to understand the contract.

---

## 8. Suspected dead/unused

### Endpoints not called by any client (Mac, iOS, extension, partner-dashboard)
| Endpoint | Status | Notes |
|---|---|---|
| `GET /partner/dashboard/status` | DEAD | No client searched references this. Built for a partner web dashboard that hasn't been wired. |
| `GET /partner/dashboard/heartbeats` | DEAD | Same. |
| `GET /partner/dashboard/content-safety` | DEAD | Same. |
| `GET /partner/dashboard/tamper-log` | DEAD | Same. The `puck-partner-dashboard` Next.js app currently only references `/auth/*`. |
| `GET /uninstall` | UNVERIFIED | Set as `chrome.runtime.setUninstallURL(...)` in extension `background.js:3415`. Triggered by Chrome on extension uninstall — never explicit-called by a JS path. Effectively used. |
| `WS /ws/focus` | LOW USE | Mac has Mac path uses 2s polling; backend keeps WS for "parallel optimization." Probably never connected by current shipping clients. |

### Endpoints clients reference but backend does NOT implement (DEFERRED, will 404)
- `POST /intention_strictness_unlock_requests` — Mac calls in `BackendClient.swift:1753`. **Not on backend.** Per Mac CLAUDE.md note 14: backend deferred per Plan A.
- `POST /intention_strictness_unlock_requests/{id}/verify` — Mac calls in `BackendClient.swift:1785`. Not on backend.
- `POST /intentions/strictness-unlock-request` — iOS `IntentionalIntentionsClient.swift:208`. Not on backend.
- `GET /intentions/{id}/active-session` — iOS `IntentionalIntentionsClient.swift:170`. Not on backend.
- Effect: any "soften from Strict" attempt fails at request stage with "Couldn't reach partner". Tightening + Standard→Soft cool-down work end-to-end.

### Tables / columns that look orphaned or always-null
- `users.display_name` — referenced in `_resolve_bedtime_unlock_partner` but never written anywhere in backend code. Defaults to `"Your friend"` everywhere. Effectively unused.
- `intentions.weekly_budget_hours`, `intentions.budget_enforcement`, `time_blocks.derived_from_budget` — all added in mig 020 D9 prep. **No code path writes them; no code path reads them for behavior.** Pure forward-compat schema.
- `bedtime_unlock_requests.status='consumed'` — declared in CHECK constraint (mig 014) but never set; `released_until` filtering does the equivalent job.
- `partner_consent` always-pending records past `expires_at` — kept forever. No cleanup cron.
- `content_safety_reports` — *only* sent rows are deleted by `/content-safety/batch-send` cleanup. Unsent rows older than 30 days never get cleaned.
- `users.disabled_alert_sent_at`, `users.last_tamper_email_at` — written but only used as rate-limiters; no observability surface.
- `auth_codes` — never deleted except on account-delete (by email match). Used codes accumulate forever.

### Deprecated route aliases retained for migration
- `GET /schedule/blocks` and `PUT /schedule/blocks` — both 301-redirect to `/time_blocks`. Renamed in mig 019. Old iOS extension test `BlockingServiceActivateTests.swift` still references `schedule/blocks`. CLAUDE.md says "one release cycle."

### Legacy `*_PROJECT_*` paths
- Searched: backend has zero `project_*` or `_project` endpoints. The legacy `*_PROJECT_*` aliases mentioned in the brief live exclusively in **dashboard JS bridge messages** (NativeMessagingHost.swift, dashboard.html), not in HTTP routes. The HTTP layer was always Intention-shaped (Spec 1).

---

## 9. Open observations

1. **JSON casing mismatch (already known).** `/device/enforcement` and `enforcement.py` use snake_case constraint keys (`content_safety.enabled`, `platforms.youtube.block_shorts`). `account_settings.settings` is camelCase as written by Mac dashboard (`contentSafety.enabled`, `platforms.youtube.blockShorts`). The translation lives **only** in `enforcement.derive_enforcement_blob`. Any new constraint-eligible field must be added there or it silently drops out of the enforcement contract.

2. **Mixed auth on similar endpoints.**
   - `/partner` (PUT, DELETE) — X-Device-ID only.
   - `/partner/status` (GET) — dual.
   - `/lock` (PUT) — X-Device-ID only.
   - `/unlock/{request,verify,status}` — X-Device-ID only.
   - `/bedtime/{config,unlock-*}` — dual.
   - `/intentions/*` — dual.
   - `/focus/*` — dual.
   - `/sessions`, `/usage/*`, `/extra-time/*`, `/override/*`, `/heartbeat`, `/system-event`, `/content-safety/*`, `/telemetry/*`, `/user/unprotected-browsers`, `/device/enforcement` — X-Device-ID only.
   - `/settings/sync`, `/auth/*` — JWT only.
   This means iOS (which is JWT-only via Supabase) cannot call `/lock`, `/unlock/*`, or `/extra-time/*` directly. The legacy device-only endpoints lock iOS out of those flows.

3. **Two "device" tables, two "register" endpoints, two purposes.**
   - `users` table is the legacy device table (extension-style). `POST /register` creates rows here.
   - `registered_devices` table is the focus-relay device table. `POST /devices/register` creates rows here.
   - `device_push_tokens` is yet a third table for APNs tokens (mig 015) because `registered_devices` only has a generic `push_token` column, no `environment` or `bundle_id`.
   - Linkage between the three is *only* via `account_id`. `users.id`, `registered_devices.id`, `device_push_tokens.id` are independent UUIDs. There is no schema-level FK between the three "device" concepts.

4. **`focus_sessions.account_id` cascades; `intention_id` SET NULL.** Soft-deleting an Intention (mig 018) leaves session history intact (intention_id → null). Hard-deleting an account wipes everything. Asymmetric; matches the user-facing model (intentions are mutable, accounts are terminal).

5. **APNs key resolution path is permissive.** `APNS_AUTH_KEY` env var can be either a path (filesystem) OR inline PEM contents. If `Path(raw_key).is_file()` evaluates true, it reads the file; otherwise treats as PEM. A user-controlled env var that *happens* to look like a valid path could load wrong-file PEM. Probably benign for Railway but worth flagging.

6. **Once-per-night bedtime is by `released_until`, not by date.** `POST /bedtime/unlock-request` rejects when an existing `verified` row has `released_until > now()`. There is no calendar-day or wake-time gating; technically two requests *could* succeed if one's release window naturally expires before the user retries.

7. **Strict-step-down requires partner unlock but no row marker exists.** `intention_strictness_changes.requires_partner_unlock` is set, but `partner_unlocked_at` is never set anywhere in backend code. The `intention_strictness_scheduler.strictness_tick` (line 43) explicitly skips rows where `requires_partner_unlock` is true and `partner_unlocked_at` is null. Result: **any strict-step-down change is permanently stuck pending until the deferred endpoints land.**

8. **`/intentions` auto-seeds on every list call.** `_maybe_seed_default_intention` runs on every `GET /intentions` for accounts with zero rows (live + deleted). If a user explicitly deletes-all then revisits the list, the curated default reappears with the same name. Idempotency is by "any rows including deleted," so soft-deleted rows prevent re-seed — but only soft-deleted, not absent. Edge: a user who deletes the seed and never undoes it gets the seed back the next time the list is empty (e.g. after another delete cascade-bug or test reset).

9. **Two `block_type` enums, one schema.** `time_blocks.block_type` is one CHECK constraint (`'deep_work', 'focus_hours'`), and `time_blocks.intensity` (added mig 019) is another with the same enum. Both columns are mandatory NOT NULL with default `'deep_work'`. Spec 2 promised `intensity` would replace `block_type`, but `block_type` stayed for the legacy column. Net effect: every row carries duplicate-purpose enums.

10. **`triggered_by` on `focus_sessions` is free-text.** No CHECK constraint. Values seen: `puck`, `mac_manual`, `ios_manual`, `ios_nfc`, `schedule`, `schedule_ended`. Drift is possible.

11. **`/system-event` accepts arbitrary `event_type` strings.** No enum, no schema. The cron's `check_stale_heartbeats` and `partner/dashboard/*` consumers query specific values (`computer_sleeping`, `app_quit`, `native_app_heartbeat`, `selector_broken`, `content_safety_disabled`, etc.). New event types added by clients silently work but never appear anywhere unless cron/dashboards are updated.

12. **`UnlockResponse.temporary_unlock_until` semantics.** `auto_relock=false` returns `temporary_unlock_until=null` to the client even though the row stores the year-9999 sentinel. `GET /unlock/status` then derives `auto_relock` from `temp_until.year >= 9000`. The sentinel is internal but leaks via `enforcement_active` calculation if any client looks at the raw `users.temporary_unlock_until`. (Mac's `EnforcementResponse` exposes `temporary_unlock_until` directly — the year-9999 string.)

13. **CORS is `allow_origins=["*"]`.** `app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, ...)`. Comment promises tightening later. Combined with `allow_credentials=True`, this is technically invalid per CORS spec — most browsers reject. Mac/iOS clients are not browsers so it works in practice; partner-dashboard browser uses Next.js server-side fetches so it dodges this. Real risk only if a true browser-side caller appears.

14. **Cron secrets are query-param.** `?secret=...` for both `check-stale` and `batch-send`. Visible in HTTP logs / Railway logs. Should be a header.

15. **`accounts.id` is one of the UUIDs `device_push_tokens.device_id` falls back to** when only Bearer auth is presented (no X-Device-ID). This means the same account_id appears as both `account_id` and `device_id` in the same row — UNIQUE `(account_id, device_id)` is satisfied but the "one row per device" semantic is muddy for JWT-only callers. iOS users with multiple iPhones on one account but only Supabase auth would collide here.

16. **Partner-dashboard JWT model is implicit.** `require_partner_auth` accepts any JWT and matches its email against `users.partner_email`. There is no partner-account vs user-account distinction at the schema level; the same account row can be both "user" (via `accounts.email`) and "partner" (via someone else's `users.partner_email` matching). Account deletion of a partner-only account is technically not handled — the partner's email lookups silently 404.

17. **`bedtime_unlock_requests.partner_email` is the email at request-time, not a foreign key.** If the partner changes their `accounts.email` (no UI for this exists), historical rows will not match. `_account_id_for_email` lookups would drop pushes. Low risk today; brittle for future "change partner email" workflow.

---

End of inventory.
