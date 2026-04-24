# Content Safety Testing Window Playbook

How to temporarily pause Content Safety (CS) detection + partner alert emails for a debugging/testing window, and how to fully restore the lockdown afterward.

Use this **only** when you need to trigger or observe CS detection behaviour without (a) spamming your accountability partner with false-positive alerts and/or (b) having the Reconciler snap the local `contentSafety.enabled` flag back to `true` within seconds.

---

## What "paused" means

Two orthogonal switches, both need to be off for CS to be genuinely disabled end-to-end:

| Switch | Where | Effect when OFF |
|---|---|---|
| **Email pause** | Backend env var `CS_EMAILS_PAUSED_UNTIL` (ISO-8601 UTC) | All three email paths (detection alert, tamper alert, batched cron) skip sending. Reports still stored. |
| **Enforcement constraint** | User row's `enforced_settings` JSONB column in Postgres | Reconciler no longer force-corrects `contentSafety.enabled` back to `true` in `onboarding_settings.json`. Local toggle in the app sticks. |

The email pause auto-expires (set a timestamp and forget). The enforcement constraint change is a manual JSONB edit and must be reversed explicitly.

---

## Current paused state (as of 2026-04-24)

- `CS_EMAILS_PAUSED_UNTIL=2026-04-25T18:15:00Z` — auto-expires 2026-04-25 ~18:15 UTC.
- `content_safety.enabled` constraint removed from user row `d8141baa-dd2b-4b64-906a-361631369403` (device `b114f383...` — Ameer's Mac; the orphaned `account_id=null` row). The Reconciler on this Mac will no longer force `contentSafety.enabled=true`. 11 other constraints on that row are untouched.

**Note on the orphan row**: the Mac's `device_id` is still bound to a user row with `account_id=null` from before the account-linking system existed. The account-linked row (`905e9ccf-...`, `lock_mode=none`, empty blob) has a different device_id and is not the source of enforcement for this Mac. Keep this in mind when running the paired scripts — they target the orphan row by `device_id`, not `account_id`.

---

## To REVERSE now (restore full lockdown)

Run both, in either order:

### 1. Restore the enforcement constraint

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
railway run --service intentional-backend python3 scripts/resume_cs_constraint.py
```

Expected output: `AFTER: constraints=12 ... OK — content_safety.enabled=must_be_true restored.`

Within one Reconciler tick (≤5 min, or immediately on Heartbeat), the Mac re-fetches, re-signs `enforcement_cache.json`, and force-corrects `contentSafety.enabled` back to `true` in `onboarding_settings.json`.

### 2. Un-pause emails (optional — they auto-expire)

If `CS_EMAILS_PAUSED_UNTIL` is in the past already, no-op. To force-unpause earlier:

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
railway variables --set "CS_EMAILS_PAUSED_UNTIL="
```

(Empty string → `_cs_emails_paused()` returns `False`.)

### 3. Verify lockdown is back

On the Mac:
- Quit Intentional, edit `~/Library/Application Support/Intentional/onboarding_settings.json` to set `contentSafety.enabled=false`, relaunch.
- Expected: within ≤5 min, the Reconciler flips it back to `true` in the JSON (and tamper email fires to Caity if consent is still confirmed — which it is).

---

## To REDO in the future (pause again for a new testing window)

### 1. Pause emails

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
# Compute an ISO-8601 UTC timestamp for when pause should end
PAUSE_UNTIL=$(date -u -v+24H +"%Y-%m-%dT%H:%M:%SZ")  # macOS syntax, 24h from now
railway variables --set "CS_EMAILS_PAUSED_UNTIL=${PAUSE_UNTIL}"
```

Railway auto-redeploys. No code change needed — the gate is already in `main.py` (see `_cs_emails_paused()` helper).

### 2. Remove the enforcement constraint

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
railway run --service intentional-backend python3 scripts/pause_cs_constraint.py
```

This targets the orphan user row by device_id. If the user-row situation changes (e.g. account-linking consolidates devices), update `TARGET_DEVICE_ID` at the top of both scripts.

### 3. Toggle CS off locally

With the app running, toggle `contentSafety.enabled` off in settings. Since the Reconciler no longer has the constraint in its cache, the change sticks.

If the Reconciler hasn't re-fetched yet (cached from before), either wait up to 5 min for `refreshIfDue()` or quit+relaunch the app to force a Phase B refresh.

---

## When this is the wrong approach

This playbook is for **Ameer's personal Mac** using the partner-locked orphan row. For a production support scenario (different user complaining about CS) you'd need to:

- Target by their `device_id` or `account_id`, not the hard-coded `b114f383...`
- Respect that removing an enforcement constraint on someone else's device is a real bypass of their accountability agreement and should require a documented reason + consent

Don't generalize these scripts without a safer targeting mechanism.

---

## Files touched by this playbook

- `intentional-backend/main.py` — `_cs_emails_paused()` helper + guards on three send sites
- `intentional-backend/scripts/pause_cs_constraint.py` — remove CS constraint
- `intentional-backend/scripts/resume_cs_constraint.py` — restore CS constraint
- `intentional-backend/scripts/inspect_enforcement.py` — read-only diagnostic (check current state)

On the Mac (referenced, not modified by scripts):
- `~/Library/Application Support/Intentional/enforcement_cache.json` — Reconciler's local cache
- `~/Library/Application Support/Intentional/enforcement_cache.sig` — HMAC signature
- `~/Library/Application Support/Intentional/onboarding_settings.json` — where `contentSafety.enabled` lives
