# Partner Dashboard — Design Spec

## What Is This?

A web dashboard (`partner.intentional.social`) where the accountability partner (e.g., Caity) can see a complete picture of the user's Mac usage: focus sessions, enforcement events, content safety detections, app health, and settings changes. The partner doesn't need to install anything — it's a web app authenticated via email.

## Why Not Just Emails?

Emails are push-only — they work when the system is working. The dashboard is pull — the partner can check anytime. The critical feature is that **absence of data is itself a signal**. If there's no heartbeat data from 2-6 PM on a Tuesday, that's visible as a red gap, even though no email was sent.

Emails are still sent for urgent events (NSFW detection, tamper alerts, unlock requests). The dashboard is for context, history, and at-a-glance status.

## Who Sees What

- **Partner** sees the dashboard (read-only, no control over the user's settings)
- **User** does NOT see the dashboard (it's for the partner's eyes only)
- The partner can request features like "send me a weekly summary email" from the dashboard

## Authentication

Partner logs in via email verification (6-digit code, same flow as the app). No password needed. Session lasts 30 days. The backend already has `partner_email` linked to `device_id`.

---

## Dashboard Sections

### 1. Status Bar (always visible at top)

Real-time health check. Answers: "Is everything working right now?"

| Indicator | Green | Yellow | Red |
|-----------|-------|--------|-----|
| App Running | Heartbeat received in last 5 min | Last heartbeat 5-15 min ago | No heartbeat for 15+ min |
| Content Safety | Enabled, permissions granted | Enabled but permission issue | Disabled |
| Intentional Mode | Active (within schedule) | Enabled but outside schedule | Disabled |
| Settings Lock | Locked | — | Unlocked |
| Strict Mode | Active | — | Inactive |

### 2. Today View (default landing page)

Quick summary of today. Answers: "How's their day going?"

- **Focus timeline** — horizontal bar showing today's blocks color-coded by type:
  - Deep Work (red), Focus Hours (indigo), Free Time (green), Unscheduled (gray gap)
  - Current block highlighted with a "now" marker
  - Blocks show title, duration, focus score (% on-task)
- **Stats row:**
  - Total focused time today
  - Average focus score
  - Blocks completed
  - Earned browse minutes used
- **Recent events feed** (last 10):
  - "Started Deep Work: Build auth module (9:00 AM)"
  - "Block completed: 87% focus score (11:30 AM)"
  - "Content Safety: detection blocked (2:15 PM)" [with blurred thumbnail]
  - "Unlock code requested (3:00 PM)"
  - "Settings unlocked for 5 min (3:02 PM)"

### 3. Heartbeat Timeline

Answers: "Were there any suspicious gaps?"

- **24-hour bar chart** — one bar per hour, colored by status:
  - Green: heartbeats received, app running normally
  - Gray: computer asleep or off (detected via sleep/wake events)
  - Red: computer awake but no heartbeats (suspicious — app was killed or internet cut)
  - Blue: app running but no internet (offline period)
- **7-day view** — same visualization but one row per day
- **Hover/click** for details: "14 heartbeats received this hour" or "Gap: 47 minutes, computer was awake"

The distinction between "computer asleep" (gray, fine) and "computer awake but no heartbeat" (red, suspicious) is critical. The backend knows the difference because the daemon sends sleep/wake events.

### 4. Focus History

Answers: "How are they doing with focus over time?"

- **Weekly focus chart** — bar chart, average focus score per day, 4-week view
- **Block breakdown table** — each completed block with:
  - Date, time, duration
  - Block title and type
  - Focus score (% on-task)
  - Self-rating (the emoji they chose in the end ritual)
  - Recovery count (how many times they self-corrected from distraction)
  - Top apps used during the block
- **Trends:**
  - Average focus score this week vs last week
  - Most productive time of day
  - Most common distraction apps

### 5. Content Safety Log

Answers: "Were there any content safety detections?"

- **Detection list** — each event with:
  - Timestamp
  - Blurred screenshot thumbnail (click to expand — still blurred)
  - Whether email was sent
  - User's dismiss time (how long overlay was shown)
- **Permission status history** — log of when Screen Recording / Sensitive Content Warning permissions were granted or revoked
- **Feature status** — current on/off state, when it was last toggled

### 6. Settings & Tamper Log

Answers: "Has anything been changed or tampered with?"

- **Settings change log** — timestamped list:
  - "Content Safety disabled (2:15 PM)" — this would be flagged red if done while locked
  - "Strict Mode enabled (9:00 AM)"
  - "Added pornhub.com to distracting sites (10:00 AM)"
  - "Removed reddit.com from distracting sites (10:05 AM)" — flagged if locked
- **Tamper events:**
  - "/etc/hosts modified — api.intentional.social blocked"
  - "App killed — restarted by daemon in 1.2s"
  - "Permission revoked: Screen Recording"
- **Unlock history:**
  - "Unlock code requested (3:00 PM)"
  - "Code verified — settings unlocked for 5 min (3:02 PM)"
  - "Settings auto-relocked (3:07 PM)"

### 7. Settings Snapshot

Answers: "What's currently configured?"

Read-only view of the user's current settings:
- Distracting sites list
- Distracting apps list
- Always-relevant sites list (partner should review this!)
- Enforcement settings (which toggles are on/off for each mode)
- Intentional Mode schedule
- Content Safety on/off
- Strict Mode on/off

This lets the partner spot configurations like "they added pornhub.com to always-relevant sites" — which would bypass AI scoring.

---

## Data Flow: macOS App → Backend → Dashboard

### What the app already sends:
- **Heartbeat** (every 60s from daemon): `POST /system-event` with `{ type: "heartbeat", strict_mode, partner_locked }`
- **Content Safety detection**: `POST /content-safety/report` with `{ timestamp, blurred_image_base64 }`
- **Content Safety tamper**: `POST /content-safety/tamper` with `{ event_type, detail, timestamp }`
- **Unlock requests/verifies**: `POST /unlock/request`, `POST /unlock/verify`

### What needs to be added (new events from app → backend):

| Event | Endpoint | Payload | When |
|-------|----------|---------|------|
| Block started | `POST /focus/event` | `{ type: "block_started", block_title, block_type, start_time, end_time }` | ScheduleManager adds block |
| Block completed | `POST /focus/event` | `{ type: "block_completed", block_title, block_type, focus_score, self_rating, earned_minutes, duration }` | Block ends, stats captured |
| Settings changed | `POST /settings/event` | `{ type: "settings_changed", changes: [{ key, old_value, new_value }] }` | SAVE_SETTINGS handler |
| Enforcement triggered | `POST /focus/event` | `{ type: "enforcement", level: "nudge|overlay|intervention", app_or_url, block_title }` | FocusMonitor enforcement |
| Sleep/wake | `POST /system-event` | `{ type: "sleep" }` or `{ type: "wake" }` | SleepWakeMonitor |
| App launched | `POST /system-event` | `{ type: "app_launched", version }` | AppDelegate init |
| Intentional Mode locked | `POST /system-event` | `{ type: "intentional_mode_locked" }` | Overlay shown |

### Backend changes needed:
1. **New tables**: `focus_events`, `settings_events`, `system_events` (append-only logs)
2. **API endpoints** for the dashboard to query:
   - `GET /partner/dashboard/today` — today's summary
   - `GET /partner/dashboard/heartbeats?days=7` — heartbeat timeline
   - `GET /partner/dashboard/focus?days=30` — focus history
   - `GET /partner/dashboard/content-safety` — detection log
   - `GET /partner/dashboard/settings-log` — settings/tamper changes
   - `GET /partner/dashboard/settings-snapshot` — current settings
3. **Partner auth**: `POST /partner/auth/login` (email code), `POST /partner/auth/verify`
4. **Heartbeat gap detection**: Backend cron that checks for gaps where computer was awake but no heartbeat, flags them in the timeline

### Frontend:
- React or plain HTML/JS (TBD)
- Hosted at `partner.intentional.social`
- Mobile-responsive (partner checks from phone)
- Dark theme matching the app aesthetic

---

## Email Notifications (keep these)

The dashboard doesn't replace emails — it supplements them. Keep sending emails for:
- Content Safety detections (with blurred screenshot)
- Tamper alerts (permissions revoked, hosts file edited, app killed repeatedly)
- Unlock code requests
- Weekly summary (new — opt-in from dashboard)

Don't email for:
- Every focus block start/end (too noisy)
- Heartbeat gaps (partner checks dashboard for this)
- Settings changes (logged in dashboard, not urgent enough for email)

---

## Implementation Priority

| Phase | What | Why first |
|-------|------|-----------|
| 1 | Status bar + heartbeat timeline | Answers "is it working?" and "were there gaps?" — the two most critical questions |
| 2 | Content Safety log + tamper log | The accountability core |
| 3 | Today view + focus timeline | Focus coaching visibility |
| 4 | Focus history + trends | Long-term view |
| 5 | Settings snapshot + change log | Configuration visibility |
| 6 | Weekly summary email | Passive monitoring for partners who don't check often |
