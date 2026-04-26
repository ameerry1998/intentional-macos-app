# Content Safety Testing Window Playbook

How to temporarily pause Content Safety (CS) detection + partner alert emails for a debugging/testing window, and how to fully restore the lockdown afterward.

Use this **only** when you need to trigger or observe CS detection behaviour without (a) spamming your accountability partner with false-positive alerts and/or (b) having the Reconciler snap the local `contentSafety.enabled` flag back to `true` within seconds.

---

## What "paused" means

**Three** orthogonal switches, all need to be off for CS to be genuinely disabled end-to-end:

| # | Switch | Where | Effect when OFF |
|---|---|---|---|
| 1 | **Email pause** | Backend env var `CS_EMAILS_PAUSED_UNTIL` (ISO-8601 UTC) | All three email paths (detection alert, tamper alert, batched cron) skip sending. Reports still stored. Auto-expires at the timestamp. |
| 2 | **Enforcement constraint** | User row's `enforced_settings` JSONB — remove the `content_safety.enabled` key | Reconciler no longer force-corrects `contentSafety.enabled` back to `true` in `onboarding_settings.json`. |
| 3 | **Partner-lock UI gate** | User row's `lock_mode` column — flip `partner` → `none` | Dashboard UI stops showing the disabled "Get code from accountability partner to unlock" state, so the toggle becomes interactive. **Side effect: unlocks other partner-locked UI too** (this is not a CS-only gate). |

Only the email pause auto-expires. Both DB changes must be reversed explicitly. The `unlock_ui_toggle.py` script snapshots the prior state to `scripts/.backups/user_lock_snapshot.json` so `relock_ui_toggle.py` can restore lock_mode AND the constraint blob atomically (the backend may re-derive the blob when `lock_mode` changes, which would otherwise clobber a manually-edited blob).

### Why three switches, not one

CS "being on" is determined by the intersection of three independent checks:
- The Content Safety Monitor reads `onboarding_settings.json` at app startup and starts capturing if `contentSafety.enabled=true`.
- The Reconciler periodically force-corrects `contentSafety.enabled` to `true` if the enforcement cache says `must_be_true`. This cache is refreshed from the backend's `enforced_settings` blob every ~5 min.
- The dashboard UI decides whether to render the toggle as enabled or as the partner-locked "get a code" state based on `lock_mode`, not on the constraint blob.

So flipping one switch doesn't flip the others, and they have to be reversed separately.

---

## Current paused state (as of 2026-04-24)

- `CS_EMAILS_PAUSED_UNTIL=2026-04-25T18:15:00Z` — auto-expires 2026-04-25 ~18:15 UTC.
- `content_safety.enabled` constraint removed from user row `d8141baa-dd2b-4b64-906a-361631369403` (device `b114f383...` — Ameer's Mac; the orphaned `account_id=null` row). The Reconciler on this Mac will no longer force `contentSafety.enabled=true`. 11 other constraints on that row are untouched.
- `lock_mode` flipped `partner` → `none` on the same row. Dashboard UI toggle for CS (and everything else previously partner-locked) is now interactive. Snapshot saved to `intentional-backend/scripts/.backups/user_lock_snapshot.json` for clean restoration.

**Note on the orphan row**: the Mac's `device_id` is still bound to a user row with `account_id=null` from before the account-linking system existed. The account-linked row (`905e9ccf-...`, `lock_mode=none`, empty blob) has a different device_id and is not the source of enforcement for this Mac. Keep this in mind when running the paired scripts — they target the orphan row by `device_id`, not `account_id`.

---

## To REVERSE now (restore full lockdown)

Run all three in the order below. Steps 1 and 2 are independent; step 3 auto-expires but can be forced.

### 1. Restore `lock_mode` and the snapshotted blob

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
railway run --service intentional-backend python3 scripts/relock_ui_toggle.py
```

Expected output: `AFTER: lock_mode=partner constraints=11 ... OK — lock_mode and enforced_settings restored from snapshot.`

This restores `lock_mode=partner` and the 11-constraint blob as they were right before `unlock_ui_toggle.py` ran. The snapshot file is archived (renamed with a timestamp) so the reversal can only run once cleanly.

**Important:** this restores the blob to its state *at snapshot time*, which was 11 constraints (no CS) — step 2 is still required to get back to the full 12-constraint lockdown.

### 2. Restore the CS enforcement constraint

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
railway run --service intentional-backend python3 scripts/resume_cs_constraint.py
```

Expected output: `AFTER: constraints=12 ... OK — content_safety.enabled=must_be_true restored.`

Within one Reconciler tick (≤5 min, or immediately on Heartbeat), the Mac re-fetches, re-signs `enforcement_cache.json`, and force-corrects `contentSafety.enabled` back to `true` in `onboarding_settings.json`.

### 3. Un-pause emails (optional — they auto-expire)

If `CS_EMAILS_PAUSED_UNTIL` is in the past already, no-op. To force-unpause earlier:

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
railway variables --set "CS_EMAILS_PAUSED_UNTIL="
```

(Empty string → `_cs_emails_paused()` returns `False`. Railway auto-redeploys.)

### 4. Verify lockdown is back

On the Mac:
- Quit Intentional, edit `~/Library/Application Support/Intentional/onboarding_settings.json` to set `contentSafety.enabled=false`, relaunch.
- Expected: within ≤5 min, the Reconciler flips it back to `true` in the JSON (and tamper email fires to Caity if consent is still confirmed — which it is).
- Dashboard Settings → Content Safety should show the disabled "Get code from accountability partner to unlock" state again.

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

This targets the orphan user row by device_id. If the user-row situation changes (e.g. account-linking consolidates devices), update `TARGET_DEVICE_ID` at the top of all four scripts (`pause_cs_constraint.py`, `resume_cs_constraint.py`, `unlock_ui_toggle.py`, `inspect_enforcement.py`). `relock_ui_toggle.py` operates off the snapshot so doesn't need updating.

### 3. Unlock the dashboard UI toggle (only if needed)

If you want the in-app toggle to be interactive instead of showing the partner-lock UI, flip `lock_mode` → `none`:

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
railway run --service intentional-backend python3 scripts/unlock_ui_toggle.py
```

This snapshots prior state to `scripts/.backups/user_lock_snapshot.json` so `relock_ui_toggle.py` can put you back exactly where you started.

**Skip this step if you just want CS off and don't care about the UI state** — the feature is already disabled after steps 1+2 plus a local app restart. Unlocking `lock_mode` has broader side effects (all partner-lock UI becomes interactive).

### 4. Quit + relaunch the Intentional app

The Content Safety Monitor reads `contentSafety.enabled` at process start, so a live toggle edit doesn't stop a running CSM. Quit and relaunch:

- Menu bar → Intentional → Quit (or Cmd+Q from a foreground window).
- Relaunch. Expect: no "Intentional is capturing your screen" pill in the menu bar.

If you skipped step 3 (UI toggle is still showing partner-lock), edit the setting file directly instead:

```bash
python3 -c "
import json
p = '/Users/arayan/Library/Application Support/Intentional/onboarding_settings.json'
with open(p) as f: d = json.load(f)
d.setdefault('contentSafety', {})['enabled'] = False
d.setdefault('content_safety', {})['enabled'] = False
with open(p, 'w') as f: json.dump(d, f, indent=2)
"
```

Both the camelCase (`contentSafety`) and snake_case (`content_safety`) keys exist in the file — flip both to be safe.

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
- `intentional-backend/scripts/unlock_ui_toggle.py` — flip `lock_mode` partner→none (snapshots prior state)
- `intentional-backend/scripts/relock_ui_toggle.py` — restore `lock_mode` + blob from snapshot
- `intentional-backend/scripts/inspect_enforcement.py` — read-only diagnostic (check current state)
- `intentional-backend/scripts/.backups/user_lock_snapshot.json` — snapshot file (gitignored); only exists between unlock and relock

On the Mac (referenced, not modified by scripts):
- `~/Library/Application Support/Intentional/enforcement_cache.json` — Reconciler's local cache
- `~/Library/Application Support/Intentional/enforcement_cache.sig` — HMAC signature
- `~/Library/Application Support/Intentional/onboarding_settings.json` — where `contentSafety.enabled` lives

## Do I need to rebuild the app?

**No.** This playbook does not touch any Swift code or any resource bundled into the app binary. The three switches operate on:
- Backend env var (Railway auto-redeploys the backend, not the Mac app).
- Backend JSONB columns (read at runtime via HTTP — no client change needed).
- Local JSON files (read at runtime via `FileManager` — no client change needed).

All that's needed on the Mac is a **quit + relaunch** of the already-installed Intentional build. The CS Monitor reads `contentSafety.enabled` at process start; on relaunch it will see `false` and skip starting the capture pipeline. Reconciler behaviour takes effect without any restart (periodic re-fetch every ~5 min).

A rebuild would only be needed if we were changing the Swift code itself — e.g. removing the partner-lock UI gate in the dashboard, or changing the Reconciler's cadence. None of that is in play here.
