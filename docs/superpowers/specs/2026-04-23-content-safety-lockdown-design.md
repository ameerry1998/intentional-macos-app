# Content Safety Lockdown — Design

**Date:** 2026-04-23
**Status:** In progress (brainstorming → spec)
**Repos affected:** `intentional-macos-app`, `intentional-backend`, intentional daemon codebase
**Motivation:** Partner-locked settings today are enforced only by the dashboard UI. Anyone with filesystem access (including the user themselves via shell, or Claude via tools) can bypass by editing `~/Library/Application Support/Intentional/onboarding_settings.json`. The "lock" is cosmetic. This design makes it real.

---

## 1. Problem & goals

**Problem.** `contentSafety.enabled` (and every other "locked" setting) lives in a user-owned JSON file. The app reads the file on startup and trusts whatever's there. The only enforcement is a check in `MainWindow.swift:1040-1100` that fires when the dashboard tries to save — direct file edits bypass it entirely. PKG-installed binary, root daemon, strict mode — none of these protect the state the app reads.

**Goals (v1 scope).**
1. When the backend says a setting is locked, the macOS app enforces it regardless of local filesystem state.
2. A user with shell access (non-root) cannot disable a locked setting by editing JSON, replacing the binary (dev build), or blocking the backend.
3. Fail-closed when the backend is unreachable AND the device has ever had a lock configured.
4. Preserve the existing first-run / registration flow — brand-new users are not blocked.
5. Partner is notified of tamper attempts (rate-limited to avoid flooding).

**Non-goals (out of scope for v1).**
- Partner-side granular configuration of what to lock (blob is derived from user's own settings + lock_mode).
- Multi-device partner locks (single-device today).
- Daemon binary tamper detection (separate concern; tracked in prior audit).
- Protection of settings that aren't in the existing "lockable" set.

---

## 2. Architecture overview

```
Partner dashboard (web)
        │
        │ (partner confirms consent, user sets lockMode=partner,
        │  user turns on CS / raises threshold / etc.)
        ▼
┌─────────────────┐     GET /device/enforcement     ┌──────────────────┐
│  Backend (Py)   │ ───────────────────────────────▶│  macOS app       │
│  - Supabase DB  │     (returns constraint blob)   │  - AppDelegate   │
│  - users.       │                                 │  - Enforcement   │
│    enforced_    │                                 │    Reconciler    │
│    settings    │◀──── POST /content-safety/tamper │  - Dashboard UI  │
│    (JSONB)      │         (force-corrected)       └────────┬─────────┘
└─────────────────┘                                          │ XPC
                                                             │ signBlob()
                                                             │ verifyBlob()
                                                             ▼
                                                    ┌──────────────────┐
                                                    │ Root daemon      │
                                                    │ - HMAC key in    │
                                                    │   /var/root/     │
                                                    │ - signs/verifies │
                                                    │   enforcement    │
                                                    │   cache          │
                                                    └──────────────────┘
```

**Trust chain:**
- Backend is authoritative about WHAT is locked (the constraint blob).
- Root daemon is the only entity that can produce a cache whose signature the app will accept.
- The app enforces whichever side (live backend, signed cache) it currently has, and force-corrects local state on any violation.

**Failure modes are explicit:** see §9 for the full scenario table.

---

## 3. The constraint-typed blob

Partner lock captures a "minimum strictness floor" — a ratchet-up-only semantic that matches what `MainWindow.swift:1040-1100` already checks today (can't disable, can't lower threshold, can't remove sites). The blob is a map of `key → constraint`, where constraint is a typed rule:

| Constraint type | Meaning | Example |
|---|---|---|
| `must_be_true` | Boolean must equal true | `content_safety.enabled` |
| `must_be_false` | Boolean must equal false | (symmetric, unlikely in v1) |
| `min_value` | Numeric must be ≥ value | `platforms.youtube.threshold` |
| `must_include_all` | List must be a superset | `distracting_sites` |
| `unknown` | Forward-compat: client fails closed, blocks startup with update-required overlay, fires tamper event `unknown_constraint_type`, does not force-correct | — |

**Example blob:**
```json
{
  "content_safety.enabled":          { "type": "must_be_true" },
  "platforms.youtube.enabled":       { "type": "must_be_true" },
  "platforms.youtube.block_shorts":  { "type": "must_be_true" },
  "platforms.youtube.threshold":     { "type": "min_value", "value": 7 },
  "distracting_sites": {
    "type": "must_include_all",
    "values": ["reddit.com", "x.com", "youtube.com"]
  }
}
```

**Adding a new locked setting later** = just emit a new key with an existing constraint type. No backend schema change. No client reconciliation-code change. Code only changes when a genuinely-new CONSTRAINT TYPE is needed.

**Unknown constraint types** (forward-compat): if the client encounters a constraint type it doesn't recognize, it fails closed — blocks startup with an "update required" overlay, fires a tamper event of type `unknown_constraint_type`, does NOT force-correct (can't, rule is unknown). Forces users onto a version that understands the new rule before enforcement continues.

---

## 4. Backend changes (intentional-backend)

### 4.1 Schema

Single migration file: `010_add_enforcement.sql`

```sql
ALTER TABLE users
  ADD COLUMN enforced_settings JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN enforced_settings_updated_at TIMESTAMPTZ,
  ADD COLUMN last_tamper_email_at TIMESTAMPTZ;
```

No new tables. Audit-log table for tamper events is a follow-up.

### 4.2 New endpoint: `GET /device/enforcement`

**Auth:** `X-Device-ID` header (same as `/lock`, `/partner/status`).

**Response:**
```json
{
  "success": true,
  "device_id": "b114f383…",
  "lock_mode": "partner",
  "enforcement_active": true,
  "constraints": { "content_safety.enabled": {"type":"must_be_true"}, … },
  "temporary_unlock_until": null,
  "updated_at": "2026-04-23T14:32:00Z"
}
```

**Response logic (computed server-side, no write race):**
- `lock_mode != 'partner'` → `enforcement_active=false`, `constraints={}`
- `temporary_unlock_until > now()` → `enforcement_active=false`, `constraints={}`, `temporary_unlock_until=ts` (existing unlock code window pauses enforcement but preserves the blob for when the window expires)
- Otherwise → `enforcement_active=true`, `constraints=users.enforced_settings`

### 4.3 Blob write triggers

`enforced_settings` is rewritten at these points:
- `PUT /settings/sync` when the user has `lock_mode='partner'` → re-derive from incoming settings, upsert.
- `PUT /lock` with `mode='partner'` → re-derive from last-known `account_settings.settings` for this user.
- `PUT /lock` with `mode!='partner'` → clear to `{}`.
- Successful `/unlock/verify` → blob unchanged; enforcement endpoint responds with empty constraints while `temporary_unlock_until` is open, then resumes on expiry.

### 4.4 Derivation function

Single source of truth, reused by all write triggers:

```python
def derive_enforcement_blob(settings: dict) -> dict:
    b = {}
    if settings.get("contentSafety", {}).get("enabled") is True:
        b["content_safety.enabled"] = {"type": "must_be_true"}
    for p in ("youtube", "instagram", "facebook"):
        ps = settings.get("platforms", {}).get(p, {})
        if ps.get("enabled") is True:
            b[f"platforms.{p}.enabled"] = {"type": "must_be_true"}
        if ps.get("blockShorts") is True:
            b[f"platforms.{p}.block_shorts"] = {"type": "must_be_true"}
        if ps.get("blockReels") is True:
            b[f"platforms.{p}.block_reels"] = {"type": "must_be_true"}
        if isinstance(ps.get("threshold"), int):
            b[f"platforms.{p}.threshold"] = {"type": "min_value", "value": ps["threshold"]}
        # Facebook has more sub-flags (blockWatch, blockGaming, blockSponsored, blockSuggested);
        # same pattern.
    sites = settings.get("distractingSites", [])
    if sites:
        b["distracting_sites"] = {"type": "must_include_all", "values": sorted(set(sites))}
    return b
```

### 4.5 Tamper email rate-limiting

`POST /content-safety/tamper` gains:

```python
user = await get_user_by_device_id(x_device_id)
last = user.get("last_tamper_email_at")
now = datetime.now(timezone.utc)
if last is None or (now - parse(last)) > timedelta(hours=1):
    await send_tamper_email(user["partner_email"], event_type, detail)
    db.table("users").update({"last_tamper_email_at": now.isoformat()}).eq("id", user["id"]).execute()
# always return 200 — client doesn't need to know whether we sent
```

Events still fire every time from the client (useful for future audit); backend just throttles the email side.

### 4.6 `/register` response extended with enforcement state

On first launch of a reinstalled or fresh app, `/register` becomes the point at which we learn enforcement state. Response gains an `enforcement` field with the same shape as `GET /device/enforcement`. This is the server-side marker mechanism (see §6.3) — if the device had a prior enforcement state in the DB, the new install inherits it immediately.

### 4.7 TLS certificate pinning (ops contract)

Backend's production TLS cert fingerprint is committed in Swift as a constant. Cert rotation plan: ~2 weeks before expiry, ship an app update pinning BOTH old + new cert fingerprints. Drop old after client adoption.

---

## 5. Client changes (intentional-macos-app)

### 5.1 New Swift components

| File | Purpose | Est. LOC |
|---|---|---|
| `EnforcementReconciler.swift` | Orchestrator: drives Phase A + Phase B, handles heartbeat, publishes state to UI | ~300 |
| `EnforcementCache.swift` | Reads/writes the signed cache file at canonical path | ~80 |
| `EnforcementDaemonClient.swift` | Wraps XPC calls to daemon (sign/verify) | ~100 |
| `ConstraintEvaluator.swift` | Pure-function typed constraint evaluation | ~150 |
| `TamperOverlayController.swift` + view | Overlay shown on detected tamper | ~200 |
| `BackendClient.swift` extension | `fetchEnforcement()` with cert pinning, `verifyUnlock` reconciler refresh hook | ~80 additions |

### 5.2 AppDelegate init-order update

New step `15b` inserted before `ContentSafetyMonitor`:

```
15a. BlockRitualController
15b. EnforcementReconciler          ← NEW
       Phase A (blocking, ~100–500ms, no network):
         • read cached blob from disk
         • XPC to daemon → verify signature
         • evaluate cached constraints against onboarding_settings.json
         • force-correct any violations (rewrite JSON, collect for overlay)
       Phase B (async, fire-and-forget):
         • backend GET /device/enforcement (TLS cert-pinned)
         • compare to cache; if changed: XPC to daemon → re-sign cache → write
         • if new constraints violate local: force-correct, re-fire overlay
15c. ContentSafetyMonitor            ← reads state verified by 15b
15d. SwitchInterventionCoordinator
```

Phase A is fast and local; it must complete before CS starts so CS reads a verified state. Phase B is async and never blocks startup.

### 5.3 Heartbeat integration

The existing 2-min heartbeat (AppDelegate step 21) gains an `EnforcementReconciler.refreshIfDue()` call. Default reconcile interval: every 5 min (independent of the 2-min heartbeat). One HTTP call, one XPC call, one disk write if the blob changed.

### 5.4 Post-unlock integration

`BackendClient.verifyUnlock` completion handler calls `reconciler.refresh()` on success. Caity's unlock reflects immediately, no wait for next heartbeat tick.

### 5.5 Cache file format

**Location:** `/Library/Application Support/Intentional/enforcement_cache.json`
**Permissions:** `0644` (user-readable for debugging; forgery blocked by HMAC).

```json
{
  "device_id": "b114f383…",
  "enforcement_active": true,
  "constraints": { … },
  "temporary_unlock_until": null,
  "updated_at": "2026-04-23T14:32:00Z",
  "cached_at": "2026-04-23T14:32:10Z",
  "signature": "base64-hmac-sha256"
}
```

Signature covers a canonical JSON encoding of everything except `signature` itself. Daemon produces and verifies via XPC.

### 5.6 Constraint evaluator

```swift
enum Constraint {
    case mustBeTrue
    case mustBeFalse
    case minValue(Double)
    case mustIncludeAll([String])
    case unknown(String)
}

enum ConstraintResult {
    case satisfied
    case violated(correction: Any)
    case cannotAutoCorrect
}

func evaluate(key: String, constraint: Constraint, currentValue: Any?) -> ConstraintResult
```

Produces the minimum-change correction:
- `mustBeTrue` violating → correction: `true`
- `minValue(N)` violating (current < N) → correction: `N`
- `mustIncludeAll([a,b,c])` violating → correction: current ∪ {missing items}
- `unknown` → `cannotAutoCorrect`, triggers update-required overlay

**Ratchet-up-only semantic:** correction never weakens the user's current state. If the user has distracting_sites=[a,b,c,d] and constraint says `must_include_all: [a,b,c]`, no correction needed — they're already above the floor.

### 5.7 Force-correction + tamper event batching

On any Phase A or Phase B run that finds ≥1 violation:
1. Batch all violations into one list.
2. Read `onboarding_settings.json`, apply corrections in-memory.
3. Atomic write-back (write to `.tmp`, rename).
4. For each affected runtime service, call its reload hook:
   - `content_safety.enabled` → `contentSafetyMonitor.onSettingsChanged(enabled: true)`
   - `distracting_sites` → re-read, trigger re-blocking
   - `platforms.*` → push update to dashboard, no Swift-side service to reload
5. Show ONE tamper overlay listing ALL corrections (not one per key).
6. POST ONE tamper event to backend with `detail: JSON of violations`.

---

## 6. Daemon changes

### 6.1 New XPC methods

Added to the existing `IntentionalDaemonXPC` protocol:

```swift
func signEnforcement(payload: Data, reply: @escaping (Data?) -> Void)
func verifyEnforcement(payload: Data, signature: Data, reply: @escaping (Bool) -> Void)
```

Only two methods — the has-seen-lock marker is server-side (§6.3), not daemon-side.

### 6.2 Key storage

Path: `/var/root/intentional/enforcement_hmac_key` (`0600`, root-only).
Generation: 32 random bytes via `SecRandomCopyBytes`. Created lazily on first `signEnforcement` call if absent.
Never transmitted over XPC.

### 6.3 Server-side marker (no local marker file)

Decision: the "has this device ever seen a lock?" marker lives **on the backend**, not locally.

Reasoning: anything stored locally is ultimately reachable (escalation, recovery scenarios). Server-side avoids the attack of "delete local marker + block network = looks like first run."

How it works:
- `users.enforced_settings_updated_at` serves as the implicit marker — when it's non-null, this device has had enforcement state at least once.
- `/register` response includes current enforcement state, bootstrapping devices on reinstall.
- Edge case "cache missing AND backend unreachable" resolves naturally because `/register` requires network anyway; if the device can't reach the network, it can't get past the registration screen, which is existing behavior.

### 6.4 Daemon-required-for-unlock policy (ratchet-up-only mode)

When daemon is present → full flow works: enforce, verify, sign, apply unlocks, change `lock_mode`.

When daemon is absent → app runs in **ratchet-up-only mode**:
- Current enforcement state stays in force (using live backend or in-memory cached state).
- The app REFUSES to:
  - Apply a new `temporary_unlock_until` window (even with a valid code from Caity).
  - Change `lock_mode` from `partner` → anything else.
  - Remove any constraint from the active blob.
- UI banner in Accountability section: "⚠️ Daemon unreachable — lockdown changes paused until daemon is restored."
- App stays functional for normal use; it just can't get any LESS strict.

**Daemon dies mid-unlock-window:** honor the existing in-memory window to its natural expiry (don't yank legitimately-earned time), but don't allow a new window to start until daemon recovers.

### 6.5 Dev builds (no daemon)

Debug builds run without a daemon. Treatment:
- Log at startup: `"⚠️ Enforcement: daemon unreachable. Running in degraded mode — lockdown not enforceable without PKG install."`
- Cache is stored unsigned (plaintext) — weaker.
- Backend fetch still runs; violations still force-correct.
- Accountability UI shows a persistent banner: `"⚠️ Lockdown not fully protected — install production build for full protection."`
- Ratchet-up-only rules from §6.4 STILL APPLY: unlocks won't take effect, lock_mode can't be relaxed, until daemon is present.

This means dev builds can NEVER weaken enforcement — a consistency win. They just can't cryptographically guarantee strength against a determined file-editor.

---

## 7. Security properties

| Attack | Defense |
|---|---|
| Edit `onboarding_settings.json` to disable CS | Reconciler Phase A reads cached blob, detects violation, force-corrects on startup. Visible overlay. Caity emailed (rate-limited). |
| Block backend, restart app | Cached blob (daemon-signed) still verified. Enforcement continues. |
| Block backend + delete cache | Cache missing, signature absent. Server-side marker present → fail-closed, force max-strictness, overlay. |
| Replace daemon binary | Out of scope — covered by separate binary-verification concern. |
| MITM backend (local cert injection, mitmproxy) | Cert pinning in Swift rejects non-matching leaf certs on `/device/enforcement`. |
| Replay old cache | Cache `cached_at` vs backend `updated_at` — if backend response has a newer `updated_at`, cache is stale and replaced. |
| Kill daemon to lift enforcement | Ratchet-up-only mode (§6.4) — daemon absence freezes current state, can't be used to loosen. |
| Downgrade to old app binary that doesn't enforce | Partial: binary verification separately; in this design, old app would just not know about the cache and would be vulnerable. Flagged as future work. |

---

## 8. User-facing behavior

### 8.1 Tamper overlay

**Visual style:** matches `InterventionOverlayController` — full-screen blur backdrop, centered card, `KeyableWindow` at `.screenSaver` level. One window per `NSScreen.screens` for multi-display consistency.

**Content layout:**
```
Content Safety was turned off outside the dashboard.

It has been re-enabled. Caity has been notified.

[For each corrected violation, one line:]
  • Content Safety: re-enabled
  • YouTube threshold: raised from 3 back to 7
  • Distracting sites: re-added reddit.com, x.com

  [ Got it — keep working ]
```

**Behavior:**
- No countdown. User reads, clicks "Got it" (or Esc) to dismiss.
- Fires ONCE per reconciliation cycle. If Reconciler found 5 violations, one overlay lists all 5.
- Heartbeat-detected tampers (while app is running) show the same overlay with identical treatment.
- Dismissal doesn't suppress future checks; the next heartbeat or restart re-fires if re-tampered.
- No "undo" button — the partner has been told, corrections are committed.

**Copy variants:**
- Single `content_safety.enabled`: "Content Safety was turned off outside the dashboard."
- Other single violation: "A partner-locked setting was changed outside the dashboard."
- Multiple: "Partner-locked settings were changed outside the dashboard."

**Overlay stacking priority:** when the Reconciler fires an overlay AND another overlay is already visible (`FocusOverlayWindow`, `InterventionOverlayController`, `BlockRitualController`), the TAMPER overlay takes precedence — dismiss the other first, show tamper, then let the user re-enter the previous flow by re-activating the relevant block. Rationale: enforcement integrity must be visible before any other UX continues.

### 8.2 Dashboard locked-toggle UI

**General rule:** any setting covered by a current active constraint renders as a greyed/disabled row with secondary label: **"Get code from accountability partner to unlock"**.

**Per-setting treatments:**

| Setting | Lock-visible component | Greyed subtext |
|---|---|---|
| Content Safety → Screen monitoring | Toggle greyed, reads ON | "Get code from accountability partner to unlock" |
| YouTube/Instagram/Facebook `enabled` | Toggle greyed, reads ON | "Get code from accountability partner to unlock" |
| Threshold slider (any platform) | Slider shows locked value, disabled | "Threshold can be raised but not lowered. Get code from accountability partner to change." |
| blockShorts/blockReels/blockWatch/blockGaming/blockSponsored/blockSuggested | Toggle greyed, reads ON | "Get code from accountability partner to unlock" |
| Distracting sites list | Sites with ✕ button get a lock icon instead of ✕ | Hover/tap: "This site is partner-locked. Can't be removed." |
| Add site to distracting list | Still fully interactive | (adding is always allowed — ratchet-up) |

**UI state propagation:**
- `EnforcementReconciler` publishes current blob via existing WKWebView bridge: `callJS("window._enforcementState(<json>)")`.
- Dashboard registers `window._enforcementState` handler at load, stashes into a reactive state, re-renders all lockable rows on update.
- Reconciler pushes on: app load, every state change (backend heartbeat → new blob, unlock window opened/closed).

**Temp-unlock window UX:** when Reconciler receives `temporary_unlock_until`, it pushes `constraints={}` to the dashboard, toggles go interactive. When the window expires, Reconciler pushes the restored blob, toggles re-lock. Known minor UX gap: if the user is mid-edit when the window expires, unsaved edits get wiped out by the re-render. **Future polish:** "Unlock expires in 60s" warning banner. Accepted v1 limitation.

### 8.3 Partner email registry

**New file:** `docs/PARTNER_EMAIL_REGISTRY.md`

Living inventory of every partner-bound email, enabling reasoning about cumulative noise and consolidation decisions. Updated any time an email trigger is added or modified.

**Entry shape:**

```markdown
## <Email name>
- **Trigger:** <when it fires>
- **Sender template:** <Resend template id or hardcoded subject>
- **Rate limit:** <per-device-per-X, or "none">
- **Payload:** <what's in the email>
- **Source:** <backend endpoint + code location in email_service.py>
- **Added:** <YYYY-MM-DD, feature/PR>
```

**Initial inventory** (enumerated at plan-time by reading `intentional-backend/email_service.py`):
- Partner consent confirmation
- Partner removed confirmation
- Content Safety detection (NSFW flag) — rate-limited via `/content-safety/batch-send`
- **Content Safety TAMPER (NEW — this feature, 1/hour/device)**
- Unlock code requested
- Extra-time request / verification
- Override request / verification
- Stale heartbeat / extension tamper
- Session milestone / daily summary (if applicable — plan-time to verify)

**Open questions section (at bottom of the registry file):**
- Should non-urgent events (detections, daily summaries) move to a daily digest while keeping urgent events (tamper, unlock requests) real-time?
- What's our threshold for "overwhelming"? Instrument email-sent counts per Caity-per-day, use real data to inform threshold.
- Should content-safety detections be aggressively batched into larger windows (e.g., 1 email per 30 min max)?

## 9. Failure modes / backend-outage playbook

| # | Scenario | Behavior |
|---|---|---|
| 1 | Backend down, app running, valid cache | Heartbeat fails silently, keeps using cache. Logged. No user impact. |
| 2 | Backend down, cold startup, valid cache | Phase A verifies cache, CS starts with cached state. Phase B fails silently, retries at heartbeat. No impact. |
| 3 | Backend down, cold startup, invalid/missing cache, device has `consentStatus=confirmed` locally | Fail-closed: assume tamper, force-enable max-strictness defaults (CS on, platforms blocking, known distracting sites). Overlay: "Can't verify enforcement — reconnect to sync." App functional in max-restriction mode. |
| 4 | Backend down, BRAND NEW install | Same as today — `/register` fails, app shows "waiting for connection" screen. Not a new failure mode. |
| 5 | Backend down, user clicks "Request Unlock Code" | Button disabled or shows "Server unreachable, try again." Unlocks impossible during outage — this is a deliberate design constraint (can't authorize loosening without backend). |
| 6 | Backend down, temp-unlock active | Honor the window (stored in cache) until expiry. No new window can start until backend returns. |
| 7 | Backend down, user saves settings | Settings save locally; `/settings/sync` retries in the background. When backend returns, blob recomputes from latest settings. |
| 8 | Backend down at `/register` | Same as #4 — existing behavior. |
| 9 | Backend permanently sunsets | Every cached device keeps working forever (enforcement frozen at last-known-state, ratchet-up-only). Unlocks impossible — ops failure, not code bug. Hotfix app update would be needed. |

**Net: no bricking scenarios.** Worst case (#3) is a tamper scenario by construction, and max-strictness is the correct response.

---

## 10. Partner email registry

See §8.3. New file `docs/PARTNER_EMAIL_REGISTRY.md` created during implementation. This feature adds one new email trigger (tamper-detected, 1/hour/device).

---

## 11. Migration / rollout

### 11.1 Backfill migration (CRITICAL — not optional)

**Problem:** existing users with `lock_mode='partner'` today have `enforced_settings=NULL` (default). On first launch of the new client, the blob would be empty → no constraints → lockdown silently ceases to enforce. That's a regression for every currently-locked user.

**Solution:** backfill migration runs after `010_add_enforcement.sql`. Script:

```sql
-- 007_backfill_enforced_settings.sql
-- Populate enforced_settings for every user currently in partner lock mode,
-- derived from their most recent saved settings.
```

Because `derive_enforcement_blob` is Python (not SQL-expressible cleanly), the backfill runs as a Python one-shot script invoked during deployment:

```python
# scripts/backfill_enforcement.py
# 1. SELECT * FROM users WHERE lock_mode = 'partner'
# 2. For each user: SELECT settings FROM account_settings WHERE account_id = user.account_id
# 3. blob = derive_enforcement_blob(settings)
# 4. UPDATE users SET enforced_settings = blob, enforced_settings_updated_at = now() WHERE id = user.id
# 5. Log: backfilled N users, K total constraints
```

Script is idempotent (re-running does nothing destructive — computes same blob, same update).

### 11.2 Rollout order

The client and backend can ship independently, but ordering matters for safety:

1. **Backend migration (006) + `/device/enforcement` endpoint deploys first.** Endpoint returns `enforcement_active=false` for everyone until users have `enforced_settings` populated. Safe: old clients don't call the endpoint, new clients get "no enforcement" which matches pre-feature behavior.
2. **Backfill script (007) runs.** Every currently-partner-locked user gets their `enforced_settings` computed. Endpoint now returns real constraints for those users.
3. **Daemon update ships.** New XPC methods added. Old clients don't call them.
4. **Client (macOS app) update ships.** PKG build with new reconciler + new Swift code + daemon-required-for-unlock policy. On first launch, client fetches `/device/enforcement`, gets real constraints (thanks to step 2), daemon signs cache, ratchet-up behavior engages.

Steps 1 and 2 are safe to do immediately. Steps 3 and 4 ship together in one PKG release — a client without a compatible daemon would enter "degraded mode" and we want to skip that friction for users who get both.

### 11.3 Rollback plan

If something goes wrong post-ship:

- **Backend bug surfaces:** revert `main.py` changes, keep migration (harmless — column exists, endpoint 404s, old clients don't call it, new clients treat as "no constraints").
- **Client bug surfaces:** revert PKG to prior version. Users keep any existing backfilled state in DB; nothing breaks.
- **Daemon bug surfaces:** daemon service rollback via PKG update. Clients in degraded mode until daemon is restored — they don't lose enforcement (backend fetch still works), just the cache-signing layer.
- **Data corruption (unlikely, but):** `enforced_settings` column is additive and derivable from `account_settings.settings`. Re-running backfill is always safe.

### 11.4 Testing checklist (for implementation plan)

Server side:
- [ ] Unit test `derive_enforcement_blob` across all input shapes (empty, partial, full).
- [ ] Integration test `GET /device/enforcement` for each of: unlocked, partner-locked, partner-locked-with-temp-unlock-open, partner-locked-with-temp-unlock-expired.
- [ ] Integration test tamper rate-limit: 5 POSTs in 10 minutes → 1 email.
- [ ] Run backfill script against a staging DB snapshot; verify constraints match source settings.

Client side:
- [ ] Phase A unit tests: cache verify pass, cache verify fail, violations detected correctly.
- [ ] Phase B: mock backend, verify fetch → sign → cache write path.
- [ ] End-to-end: edit onboarding_settings.json manually, restart, verify overlay + correction + tamper POST.
- [ ] Daemon-absent path: stub XPC failure, verify degraded-mode banner and ratchet-up behavior.
- [ ] Offline cold start with valid cache: verify CS starts with cached state.
- [ ] TLS cert pinning: feed fake cert, verify request rejected.
- [ ] Temp-unlock flow: verify window open → toggles interactive → window close → toggles re-lock.

### 11.5 Monitoring after ship

- Track count of `POST /content-safety/tamper` events per-day (total + unique devices). Spike = feature's being exercised; unexpected absence = maybe silently failing.
- Track `GET /device/enforcement` error rate per-client-version. Elevated 5xx on one version = client bug.
- Email send rate to Caity (and all partners) — sanity check against the registry's expected volume.

---

## 12. Open questions (parked for follow-up)

- **Daily digest vs real-time emails.** User flagged they may eventually prefer consolidated digests over real-time per-event emails. Not resolving now — revisit when the registry is populated and we can see the actual volume.
- **Audit log of tamper events.** No server-side event table in v1. Add if we need the history for product reasons.
- **Constraint types beyond v1.** `max_value` (for upper-bounded numerics), `must_equal` (rigid equality), regex matchers. Add as needed.
- **Partner-explicit granular control.** Today's blob is derived from user settings + lock_mode. Future: partner dashboard might let Caity directly control individual constraints. Separate feature.
- **Daemon binary verification.** Ensures only the expected daemon binary can serve XPC. Separate concern, tracked in prior tamper audit.

---

## Notes for future sessions

- This spec will be the entry point for a writing-plans handoff. Changes after user review trigger a spec self-review cycle per the brainstorming skill.
- Puck integration (scheduled for later today) will touch `puck-ios`, `intentional-backend`, `intentional-macos-app`. Backend has registration, partner-status, lock, content-safety endpoints (see main.py). iOS app at `~/Documents/GitHub/puck-ios`. Tap-to-focus will need a new endpoint for "signal focus start" and probably reuse device registration.
