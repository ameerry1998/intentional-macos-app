# Agent Prompt: Build the Partner Dashboard

## Task

Build the accountability partner dashboard for Puck/Intentional — a web app at `dashboard.getpuck.co` where an accountability partner can monitor a user's Mac usage, focus sessions, content safety detections, and app health.

## Context

Puck is a physical NFC device + iOS app + macOS app for blocking distractions and building focus. The macOS app (Intentional) tracks focus sessions, blocks distracting sites, detects NSFW content on screen, and enforces accountability via a partner lock system.

The partner currently only gets email alerts (NSFW detections, unlock code requests). This dashboard gives them a full historical view — including detecting when the user turned off their internet or killed the app (heartbeat gaps).

## Architecture

**Single Next.js repo** (App Router) deployed to Vercel:
- `/app` — React frontend (dashboard UI)
- `/app/api` — API route handlers (backend)
- Database: Supabase (Postgres) or PlanetScale (MySQL) — your choice based on what's simpler
- Image storage: S3 (or Supabase Storage) for blurred NSFW screenshots
- Auth: Email OTP only (no passwords, no OAuth)
- Domain: `dashboard.getpuck.co`

## Existing Backend

There's an existing backend at `api.intentional.social` (Node.js) that the macOS app already talks to. The dashboard backend needs to either:
- **Option A**: Add dashboard API routes to the existing backend (avoids data duplication)
- **Option B**: Be a separate service that reads from the same database

I'd suggest **Option A** for simplicity — add the partner dashboard endpoints to the existing `api.intentional.social` backend, and have the Next.js frontend at `dashboard.getpuck.co` call those APIs. The Next.js API routes would just be thin proxies or the frontend calls the existing backend directly.

But if you go Option B (fully separate), the Next.js API routes become the full backend and need their own database connection to the same DB.

**Decision for the agent: Ask Arayan which approach he prefers before building.**

## Design Spec

The full spec is in this file: `docs/PARTNER_DASHBOARD.md` (in the intentional-macos-app repo). Read it thoroughly — it contains:
- All 7 dashboard sections with detailed descriptions
- Data flow (what the macOS app sends, what endpoints to query)
- Complete security requirements (NSFW image handling, encryption, headers, auth flow)
- Threat model
- Data retention policy
- Implementation priority (phases 1-6)

## Key Security Requirements (non-negotiable)

1. **NSFW images**: Blurred images served via signed, expiring URLs (5 min). `Cache-Control: no-store`. Encrypted at rest. Auto-deleted after 30 days.
2. **Auth**: Email OTP only. 6-digit code, 10 min expiry, rate limited (3 attempts/hour). HttpOnly + Secure + SameSite=Strict cookies.
3. **Headers**: HSTS, CSP (no inline scripts), X-Frame-Options: DENY, no-cache on all responses.
4. **Access control**: Partner can ONLY see data for devices they're linked to. Enforce server-side on every query.
5. **No raw screenshots**: Only blurred images ever leave the Mac. Never store unblurred content.

## Auth Flow

```
1. Partner enters email at dashboard.getpuck.co
2. POST /partner/auth/login { email } → sends 6-digit OTP
3. Partner enters OTP
4. POST /partner/auth/verify { email, code } → returns session cookie
5. All subsequent requests use session cookie
6. Session: 30 days, HttpOnly, Secure, SameSite=Strict
```

## Dashboard Sections (build in this order)

### Phase 1: Status + Heartbeat
- Top status bar (app running? content safety on? settings locked?)
- 24-hour heartbeat timeline (green = active, gray = asleep, red = suspicious gap)
- 7-day heartbeat overview

### Phase 2: Content Safety + Tamper Log
- Detection list with timestamps and blurred thumbnails
- Tamper events (permissions revoked, hosts file edited, app killed)
- Unlock request/verify history

### Phase 3: Today View + Focus
- Today's focus timeline (color-coded blocks with scores)
- Stats: total focus time, avg score, blocks completed
- Recent events feed

### Phase 4: Focus History
- Weekly focus score chart (4-week view)
- Block breakdown table (title, type, score, self-rating, duration)
- Trends (week-over-week, best times, common distractions)

### Phase 5: Settings
- Read-only current settings snapshot
- Settings change log with timestamps

### Phase 6: Weekly Email
- Opt-in weekly summary email from the dashboard

## Visual Style

- Dark theme (match the macOS app aesthetic)
- Colors: indigo (#6366f1) primary, emerald (#34d399) for good, amber (#fbbf24) for warning, red (#ef4444) for bad
- Font: system font stack (-apple-system, BlinkMacSystemFont, Inter)
- Clean, minimal, data-dense
- Mobile-first (partner often checks from phone)

## What You DON'T Need to Build

- The macOS app (already exists)
- The event-sending code from the macOS app (we'll add that separately)
- Email sending (the existing backend handles this)
- The partner invitation flow (already exists in the macOS app)

## Repo Setup

Create a new repo: `ameerry1998/puck-partner-dashboard` (or similar). Standard Next.js setup:
```
npx create-next-app@latest puck-partner-dashboard --typescript --tailwind --app --src-dir
```

## Questions to Ask Arayan Before Starting

1. Option A (add endpoints to existing api.intentional.social) or Option B (separate backend in Next.js API routes)?
2. Database preference: Supabase or PlanetScale? Or connect to the existing backend's DB?
3. Do you want real data integration from day 1 (needs access to existing backend), or mock data first to nail the UI?
