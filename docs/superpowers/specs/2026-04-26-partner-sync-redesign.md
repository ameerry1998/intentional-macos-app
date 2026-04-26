# Partner Sync Redesign — Design

**Date:** 2026-04-26
**Status:** Spec — awaiting user approval before implementation
**Repos affected:** `intentional-backend`, `intentional-macos-app`, `puck-ios`
**Supersedes:** Phase 1 fix on `feat/account-based-partner` + `feat/partner-link-account` (band-aid; see §4)
**Related:** [`2026-04-23-content-safety-lockdown-design.md`](./2026-04-23-content-safety-lockdown-design.md) — the architecture this spec borrows from

---

## 1. What's broken right now

**User-reported symptom (verbatim):** *"The partner screen is still not syncing with the partner info. It just doesn't check on start up. Why is the partner screen showing empty on the phone but not on the macos app."*

### 1.1 Investigation findings

The partner screen on iPhone is empty because **two independent things are true at the same time**, and either one alone is enough to break it:

**Fact 1 — Phase 1 fix is not deployed/installed.**

| Component | Where the fix lives | Where the user is running |
|---|---|---|
| Backend partner sync | `feat/account-based-partner` (commit `7491228`) — pushed but unmerged | `main` at `40cb436` (pre-fix) |
| iOS link-legacy call | `feat/partner-link-account` (commit `90f3100`) — pushed but unmerged | `main` (no `linkLegacyDeviceToAccount` call exists) |

So the iPhone is running code that has no path to discover the Mac's partner. It calls `GET /partner/status` with its own iOS-generated device_id, the backend looks up that row (which has no partner), returns `consent_status: "none"`, and PartnerView renders empty. This is the original bug the investigation doc described, unchanged.

**Fact 2 — Even when Phase 1 deploys, the architecture is fundamentally per-device.** Phase 1 is a band-aid that keeps partner data on the per-device `users` table and uses sibling fan-out to give the appearance of account-scoping. It works, but it's brittle (see §4 for why this is a real problem, not just an aesthetic one).

### 1.2 Today's data flow (broken)

```
            iPhone                                  Backend                              Mac
              │                                        │                                  │
   1. User signs in                                    │                                  │
              │ Supabase auth (no /auth/verify call)   │                                  │
              ├───────────────────────────────────────▶│                                  │
              │                                        │                                  │
   2. User opens Partner tab                           │                                  │
              │                                        │                                  │
              │  GET /partner/status                   │                                  │
              │  X-Device-ID: <ios-random-hex>         │                                  │
              ├───────────────────────────────────────▶│                                  │
              │                                        │                                  │
              │                                        │  SELECT * FROM users             │
              │                                        │   WHERE device_id = ios-hex      │
              │                                        │   → row { partner_email: NULL,   │
              │                                        │           account_id: NULL }     │
              │                                        │                                  │
              │  ◀──── { consent_status: "none" }      │                                  │
              │                                        │                                  │
   3. PartnerView renders empty                        │                                  │
                                                       │                                  │
                                                       │   GET /partner/status            │
                                                       │   X-Device-ID: <mac-hex>         │
                                                       │◀─────────────────────────────────┤
                                                       │                                  │
                                                       │  SELECT * FROM users             │
                                                       │   WHERE device_id = mac-hex      │
                                                       │   → row { partner_email:         │
                                                       │           "friend@x.com",        │
                                                       │           account_id: <set> }    │
                                                       │                                  │
                                                       ├──── { partner_email: "friend"}─▶ │
                                                       │                                  │
                                                       │              Mac dashboard       │
                                                       │              renders partner ✓   │
```

The backend is doing exactly what it's told. The schema makes "Mac and iPhone are the same person" unrepresentable.

### 1.3 Why this is the deeper problem

The same schema problem will appear, in identical form, every time we add a new "account-level" thing:
- Schedule blocks (today's plan, focus blocks) — already a Phase B/C item in the schedule sync spec
- Mode metadata (intent text, color, websites) — Phase D in the same spec
- Active session (which device is in deep work) — same spec
- Stats / streaks (focus minutes, recovery count over time)
- User profile (name, avatar)
- Anything else that's "you" rather than "this laptop"

If we band-aid each of these with sibling fan-out, we'll have N copies of the same brittle workaround. The right fix is one architectural primitive that says: **account-scoped data lives once, addressed by account_id, read by any device the user has logged in on.**

---

## 2. The pattern we're applying — Content Safety Lockdown

The Content Safety Lockdown design (Apr 23, [link](./2026-04-23-content-safety-lockdown-design.md)) solves a structurally identical problem: data that "belongs to the user," not "belongs to the laptop," needs to be addressable by account from any device, with the backend as authoritative source. Its full architecture has machinery we don't need (daemon-signed cache, constraint typing, tamper detection, force-correction) because it's an *enforcement* feature — the user is the adversary. **Partner data is not an enforcement feature** — the user freely chooses their partner. So we keep the pattern's spine and drop the parts that exist to defend against the user.

### Pattern spine (keep this)

| Element | Content Safety implementation | Partner sync application |
|---|---|---|
| **Backend authority** | `users.enforced_settings JSONB` | `accounts.partner_email/name + partner_consent.account_id` |
| **Account-scoped, not device-scoped** | enforcement_active computed per `users` row using `lock_mode` (already account-aware via `account_id`) | partner data stored once per account, addressable by JWT |
| **Reconciler with two phases** | Phase A (local cache verify, blocking) + Phase B (backend pull, async) | Phase A (local cache, render immediately) + Phase B (backend pull, refresh UI on diff) |
| **Optimistic local cache** | `enforcement_cache.json` (signed) | `partner_cache.json` (unsigned — see "drop" below) |
| **Periodic refresh** | Every 5 min via heartbeat hook | Same: every 5 min via heartbeat |
| **Push on change** | Reconciler pushes `_enforcementState(...)` to dashboard JS | Push `_partnerState(...)` to both Mac dashboard JS and iOS via NotificationCenter |
| **Server-side marker** | `enforced_settings_updated_at` non-null = "this account has had partner state" | Same: `accounts.partner_set_at` non-null = "this account has had a partner" |

### Pattern parts we drop (for partner specifically)

- **Daemon HMAC signing of the cache.** Defends against the user editing the cache to weaken enforcement. Partner data is not enforcement — if the user edits their cache to show "no partner," the next backend pull overwrites it. No security hole.
- **Constraint typing (`must_be_true`, `min_value`, `must_include_all`).** Used to express ratchet-up-only semantics. Partner data is just `(email, name, status)` — no ratchet logic.
- **Tamper detection + force-correction overlay.** No "tamper" concept exists for partner — the user can change their partner whenever they want.
- **Fail-closed max-strictness fallback.** If the backend is unreachable on first launch, "no partner shown yet" is the right behavior, not max-strictness.
- **Partner-side audit emails.** Already exists for partner consent flow — no new emails needed.

### Net result

Partner sync is **the simpler version of the same pattern.** Account-scoped storage, reconciler-driven reads, periodic refresh, push-on-change. About 30% of the LOC of CS Lockdown, none of the daemon machinery, same architectural shape.

---

## 3. Desired architecture

### 3.1 Schema changes

**Three column additions** to existing `accounts` table:

```sql
-- migrations/006_promote_partner_to_account.sql
ALTER TABLE accounts
  ADD COLUMN partner_email TEXT,
  ADD COLUMN partner_name  TEXT,
  ADD COLUMN partner_set_at TIMESTAMPTZ;  -- "has this account ever had a partner" marker
```

**One column on existing `partner_consent` table** — keep `user_id` for backwards compat, add `account_id`:

```sql
ALTER TABLE partner_consent
  ADD COLUMN account_id UUID REFERENCES accounts(id) ON DELETE CASCADE;

-- Backfill existing rows: for each row, look up users.account_id and copy
UPDATE partner_consent pc
   SET account_id = u.account_id
  FROM users u
 WHERE pc.user_id = u.id AND u.account_id IS NOT NULL;

-- Going forward: queries by account_id when available, fall back to user_id
-- for rows that pre-existed and have no linked account.
CREATE INDEX idx_partner_consent_account ON partner_consent(account_id);
```

**Backfill `accounts` from existing `users.partner_email`:**

```sql
-- 007_backfill_account_partner.sql
UPDATE accounts a
   SET partner_email = sub.partner_email,
       partner_name  = sub.partner_name,
       partner_set_at = COALESCE(sub.last_partner_set, now())
  FROM (
    SELECT DISTINCT ON (account_id)
           account_id, partner_email, partner_name,
           updated_at AS last_partner_set
      FROM users
     WHERE partner_email IS NOT NULL
       AND account_id IS NOT NULL
     ORDER BY account_id, updated_at DESC NULLS LAST
  ) sub
 WHERE a.id = sub.account_id;
```

For users with `partner_email` set on multiple device rows (same account, different timestamps): the most-recently-updated row wins. The `users.partner_email` columns are **left in place** for backwards compat — see §3.4 for why and how.

### 3.2 New endpoints (Bearer auth)

```
GET  /account/partner   → { email, name, consent_status, set_at }   (or all-null if unset)
PUT  /account/partner   → body: { email, name }    (sends consent email if needed)
DELETE /account/partner → {} (clears + revokes consent)
```

Wire format mirrors the current `PartnerResponse`. Auth is Bearer (works for both Mac's intentional-issued token and iOS's Supabase token via existing `_resolve_account_from_token`). No `X-Device-ID` involved.

**Consent flow** is unchanged in spirit — `PUT` creates a `partner_consent` row (now with `account_id`), generates a token, sends an email with the existing Resend templates. `GET /consent/confirm?token=...` and `/consent/decline?token=...` (the partner-clicked HTML pages) update the row by token; they don't change.

### 3.3 Read flow (post-fix)

```
                iPhone                          Backend                          Mac
                  │                                │                              │
     1. iOS app launches (any time)               │                              │
                  │                                │                              │
                  │  GET /account/partner          │                              │
                  │  Authorization: Bearer <jwt>   │                              │
                  ├───────────────────────────────▶│                              │
                  │                                │                              │
                  │                                │  account = resolve(jwt)      │
                  │                                │  SELECT partner_email,       │
                  │                                │         partner_name,        │
                  │                                │         partner_set_at       │
                  │                                │    FROM accounts             │
                  │                                │   WHERE id = account.id      │
                  │                                │                              │
                  │                                │  consent = SELECT * FROM     │
                  │                                │    partner_consent           │
                  │                                │    WHERE account_id =        │
                  │                                │          account.id          │
                  │                                │    ORDER BY created_at DESC  │
                  │                                │    LIMIT 1                   │
                  │                                │                              │
                  │  ◀── { email, name, status }   │                              │
                  │                                │                              │
     2. Cache to disk + render                    │                              │
                  │                                │                              │
                  │                                │   GET /account/partner       │
                  │                                │   Authorization: Bearer <jwt>│
                  │                                │◀──────────────────────────── │
                  │                                │                              │
                  │                                │   (same path; same row)      │
                  │                                │                              │
                  │                                ├─── { email, name, status }─▶ │
                  │                                │                              │
                  │                                │       Mac dashboard renders ✓│
```

Same row, both clients. No fan-out. No legacy-link prerequisite. No race window between login and link.

### 3.4 Backwards compatibility — extension still uses old endpoints

The Chrome extension still calls `PUT /partner` and `GET /partner/status` with `X-Device-ID`. We don't break it.

**Strategy: thin wrappers on the legacy endpoints, delegating to the new account-level logic.**

```python
@app.put("/partner")
async def set_partner_legacy(request, x_device_id: Header(...)):
    # ... existing device_id validation ...
    user = await get_user_by_device_id(x_device_id)
    if user.get("account_id"):
        # Delegate to account-level logic
        return await _set_account_partner(account_id=user["account_id"],
                                          email=request.partner_email,
                                          name=request.partner_name)
    # Pre-account-link extension users: write to users row (existing behavior).
    # Eventually we deprecate this; today some extension installs may not have
    # a linked account.
    return await _set_user_partner_legacy(user_id=user["id"], ...)
```

Same wrapper shape for `GET /partner/status` and `DELETE /partner`. Extension code unchanged. macOS dashboard and iOS PartnerView migrate to the new `/account/partner` endpoints.

The legacy `users.partner_email/name` columns become **a write-through cache** — when account-level partner changes, copy down to all linked `users` rows so existing reads (extension, any cached client logic) keep working without surprise. Eventually deprecate the columns when no clients read them.

### 3.5 Local cache + reconciler

**Cache file location:**
- macOS: `~/Library/Application Support/Intentional/partner_cache.json`
- iOS: `Library/Application Support/partner_cache.json` inside the app sandbox

**Cache shape:**
```json
{
  "email": "friend@example.com",
  "name": "Friend",
  "consent_status": "confirmed",
  "set_at": "2026-04-20T10:00:00Z",
  "cached_at": "2026-04-26T03:30:00Z"
}
```

No signature. The user can edit it freely; the next reconciler pull overwrites it. Cache is purely an "instant render on app launch" performance optimization.

**Reconciler responsibilities (same shape on Mac and iOS):**
1. **Phase A — On app start, blocking.** Read cache from disk, render immediately. <50ms.
2. **Phase B — Async after Phase A.** Hit `GET /account/partner` (Bearer). On response: compare to cache; if different, write new cache, push update to UI.
3. **Periodic refresh** — every 5 min (Mac: existing heartbeat hook; iOS: existing `scenePhase == .active` hook).
4. **Push on change** — Mac: `callJS("window._partnerState(<json>)")`. iOS: `NotificationCenter.default.post(name: .partnerStateDidChange, object: nil, userInfo: ...)`.
5. **Authentication state** — when user logs out, clear cache. When user logs in, run Phase B immediately (don't wait 5 min).

```
┌──────────────────────────────────────────────────────────┐
│   App launch                                             │
└────────┬─────────────────────────────────────────────────┘
         │
         ├─► Phase A: read cache file (~5ms)
         │   ├─ if cache hit → render immediately
         │   └─ if cache miss → render "loading…" / cached "no partner"
         │
         └─► Phase B (async, ~200ms typical):
             GET /account/partner (Bearer)
             ├─ 200 with data    → write cache, push to UI if diff
             ├─ 200 with nulls   → clear cache, push "no partner" to UI
             ├─ 401              → clear cache, push "no partner", trigger re-auth flow
             └─ 5xx / no network → keep cache, retry at next heartbeat tick

┌──────────────────────────────────────────────────────────┐
│   Heartbeat tick (every 5 min, app foregrounded)         │
└────────┬─────────────────────────────────────────────────┘
         │
         └─► Same as Phase B above

┌──────────────────────────────────────────────────────────┐
│   PUT /account/partner (user sets partner from UI)       │
└────────┬─────────────────────────────────────────────────┘
         │
         ├─► Optimistic local update: write cache, push to UI
         │   (UI shows "Invite sent — pending" immediately)
         │
         └─► Backend response:
             ├─ 200 → confirm cache (already updated)
             └─ 4xx/5xx → roll back cache, surface error to UI
```

### 3.6 Write flow — single direction, single source

```
            iPhone                                Backend                            Mac
              │                                      │                                │
   1. User taps "Send invite"                       │                                │
              │ optimistic local cache write         │                                │
              │ render "Invite sent — pending"       │                                │
              │                                      │                                │
              │  PUT /account/partner                │                                │
              │  Authorization: Bearer <jwt>         │                                │
              │  { email: "x@y.com", name: "X" }     │                                │
              ├─────────────────────────────────────▶│                                │
              │                                      │                                │
              │                                      │  account = resolve(jwt)        │
              │                                      │  UPDATE accounts SET           │
              │                                      │    partner_email='x@y.com',    │
              │                                      │    partner_name='X',           │
              │                                      │    partner_set_at = now()      │
              │                                      │  WHERE id = account.id         │
              │                                      │                                │
              │                                      │  INSERT INTO partner_consent   │
              │                                      │   (account_id, partner_email,  │
              │                                      │    consent_token, status,      │
              │                                      │    expires_at)                 │
              │                                      │   VALUES (...)                 │
              │                                      │                                │
              │                                      │  send_consent_email(...)       │
              │                                      │                                │
              │                                      │  -- write-through to legacy    │
              │                                      │  -- users rows for backcompat  │
              │                                      │  UPDATE users SET              │
              │                                      │    partner_email='x@y.com',    │
              │                                      │    partner_name='X'            │
              │                                      │  WHERE account_id = account.id │
              │                                      │                                │
              │  ◀──── { status: "pending" } ────────│                                │
              │                                      │                                │
   2. Cache confirmed.                               │                                │
                                                     │                                │
                                                     │ Mac's next heartbeat tick      │
                                                     │ (≤ 5 min later)                │
                                                     │   GET /account/partner         │
                                                     │◀───────────────────────────────│
                                                     │                                │
                                                     │  ──── { same data } ─────────▶ │
                                                     │                                │
                                                     │              Mac re-renders ✓  │
```

(Or: Mac sees the change immediately if we push a websocket-style notification later. v1 is poll-driven, fine for partner data which changes hours-apart at most.)

---

## 4. Why my Phase 1 fix is the wrong long-term answer

The Phase 1 fix is `feat/account-based-partner` (backend) + `feat/partner-link-account` (iOS), described in [`cross-repo-puck-pivot-2026-04-26.md`](../../cross-repo-puck-pivot-2026-04-26.md). It works once deployed, but it carries four real problems that this redesign eliminates:

| # | Phase 1 problem | Why it matters | How redesign fixes it |
|---|---|---|---|
| 1 | **Requires `/devices/link-legacy` to fire successfully on iOS** before partner ever syncs. The call is fire-and-forget; if it fails (network blip, server hiccup), the iOS row stays unowned and partner stays empty. No retry beyond next sign-in. | Silent failure mode — user reports partner "still empty" days later, very hard to debug. | Bearer auth is the only auth needed. No legacy-link concept. The same JWT that signs you in IS the account identity. |
| 2 | **Consent records are still keyed by `user_id`**, so `GET /partner/status` fallback has to look up sibling rows AND traverse to find the right consent. Convoluted query path. | Hard to reason about. Every new "account-scoped" feature would need similar gymnastics. | Consent rows get `account_id`. Single-table SELECT. |
| 3 | **Doesn't generalize.** Schedule, mode metadata, active session, stats — every future account-scoped feature needs its own fan-out helper or its own "look across siblings" read. | We'd repeat the same workaround N times, accumulating complexity. | The *pattern* generalizes — `accounts.X` columns + Bearer-auth `/account/X` endpoints. Schedule sync, mode sync, etc. all use the same shape. |
| 4 | **Race window during login.** User signs in → iOS calls `/devices/link-legacy` → opens Partner tab. If they're fast (or if link-legacy is slow), Partner tab opens before account_id is set, fallback fails, render empty. Pull-to-refresh fixes it but is a UX wart. | First-login experience is the most important. Empty partner on the very first opens the user's mental model "the app is broken." | No race. JWT works the moment Supabase auth completes. First open of Partner tab returns partner. |

**Summary:** Phase 1 makes the symptom go away most of the time. The redesign makes the symptom impossible.

---

## 5. Approaches considered

Three places we could put the partner data, all in a single table:

### Approach A — Add fields to existing `accounts` table

```sql
ALTER TABLE accounts ADD COLUMN partner_email TEXT, ...;
```

**Pros:**
- Smallest schema change.
- Partner data lives next to its natural owner (the account).
- Reads are a single SELECT, no JOIN.

**Cons:**
- Slight blurring of "identity" (accounts table) and "settings" (which is what partner sort-of is).
- If we later support multiple partners or partner history, we'd want a separate table anyway.

### Approach B — Stick partner inside `account_settings.settings` JSONB blob

The existing `account_settings` table has a JSONB blob used for things like budgets and free-browse limits. Add `partner: {...}` to it.

**Pros:**
- Reuses an existing endpoint family (`PUT /settings/sync`, `GET /settings/sync`). No new endpoint code.
- One endpoint to invalidate / refresh covers many settings at once.

**Cons:**
- Settings sync is JWT-auth and works for the macOS app only today (we'd need iOS support, which is the same lift either way).
- Partner is consequentially different from "budgets" — it has a separate consent state machine, sends emails, can be revoked. Lumping it into a generic blob hides that semantics.
- Partial updates of a JSONB blob are harder to reason about than a single column.
- Harder to evolve (e.g., adding `partner_set_at` later means schema-validating the blob; adding a column on the table is just `ALTER TABLE`).

### Approach C — New table `account_partners`

```sql
CREATE TABLE account_partners (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  partner_email TEXT NOT NULL,
  partner_name TEXT,
  set_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Pros:**
- Cleanest separation.
- Easy to extend to "list of partners" later (drop the PRIMARY KEY constraint).
- Partner-specific indexes / queries don't touch the accounts table.

**Cons:**
- Extra JOIN on every read.
- More moving parts for v1 — extra table, extra migration, extra delete cascade to wire up.
- Premature design for "multiple partners" we don't have evidence we need.

### Recommendation: **Approach A**

Smallest delta, partner naturally belongs to the account, easiest to reason about. If we later need partner history or multiple partners, the migration to a dedicated table is mechanical (move 3 columns, switch the read path). YAGNI on Approach C.

---

## 6. Migration plan

The migration must be safe to run mid-day with no downtime. Backwards compatibility for the extension is the constraint.

```
Step 1: Backend migrations + new endpoints
  ├─ 006_promote_partner_to_account.sql (additive — adds columns, no destructive change)
  ├─ Add account_id to partner_consent (additive — column nullable initially)
  ├─ New endpoints: GET/PUT/DELETE /account/partner
  └─ Legacy endpoints: keep working unchanged

Step 2: Backfill from existing data
  ├─ scripts/backfill_account_partner.py
  │    ├─ for each account with linked users that have partner_email:
  │    │    populate accounts.partner_email + name + set_at (most-recent wins)
  │    └─ for each partner_consent row with NULL account_id:
  │         set account_id = users.account_id where partner_consent.user_id = users.id
  ├─ Idempotent — safe to re-run
  └─ Verify: COUNT of accounts with partner_email should match COUNT of distinct (account_id) in users with partner_email

Step 3: Wire legacy endpoints to delegate to account-level logic
  ├─ PUT /partner: if user has account_id → call _set_account_partner; else legacy
  ├─ GET /partner/status: if user has account_id → call _get_account_partner; else legacy
  ├─ DELETE /partner: same
  └─ Side effect: writes to accounts table, write-through to all sibling users rows
       (so legacy reads keep returning consistent data)

Step 4: Migrate macOS dashboard
  ├─ MainWindow handlers GET_PARTNER_STATE / SET_PARTNER → BackendClient.get/setAccountPartner
  ├─ BackendClient new methods: getAccountPartner(), setAccountPartner(email, name), deleteAccountPartner()
  ├─ Reconciler: PartnerStateReconciler.swift
  └─ Push state to JS via window._partnerState(...)

Step 5: Migrate iOS PartnerView
  ├─ IntentionalAPIClient new methods: getAccountPartner(), setAccountPartner(email, name), deleteAccountPartner()
  ├─ PartnerStateService.swift (Reconciler equivalent for iOS)
  ├─ PartnerView reads from PartnerStateService instead of calling /partner directly
  └─ NotificationCenter notification when state changes

Step 6: Optional — deprecate legacy endpoints
  └─ Once extension and any old clients are confirmed off the legacy endpoints,
     mark them deprecated, eventually remove. Not required for v1.
```

**Rollback at any step:**
- Steps 1-2 are additive only — rollback = ignore the new columns, revert endpoints. No data loss.
- Step 3 — revert wrapper logic; legacy endpoints work standalone again.
- Steps 4-5 — revert the client commits; clients fall back to legacy endpoints which still work.

**The Phase 1 fix branches** (`feat/account-based-partner` + `feat/partner-link-account`) **are abandoned in favor of this redesign.** They're not destructive (additive backend code, additive iOS auth-hook call) and their git history can be discarded without harm. Document this in the cross-repo log.

---

## 7. Comparison with Phase 1 fix

| Dimension | Phase 1 (current branches) | Redesign (this spec) |
|---|---|---|
| Schema change | None | 1 ALTER TABLE adding 3 columns + 1 ALTER TABLE adding 1 column |
| New endpoints | 1 (`POST /devices/link-legacy`) | 3 (`GET/PUT/DELETE /account/partner`) — but legacy 3 retained as wrappers |
| Lines of code (backend) | ~150 | ~200 (new endpoints + wrappers) |
| Lines of code (iOS) | ~50 | ~100 (reconciler + cache + UI integration) |
| Lines of code (macOS) | 0 | ~80 (reconciler + cache + push to dashboard JS) |
| Backwards compatible w/ extension | ✅ Yes | ✅ Yes (legacy endpoints retained as wrappers) |
| Backwards compatible w/ existing data | ✅ Yes (no migration) | ✅ Yes (additive migration + idempotent backfill) |
| Race window between login & first partner read | ⚠️ Yes (link-legacy fire-and-forget) | ✅ No (Bearer is the auth) |
| Generalizable to schedule / modes / sessions | ❌ No (each needs its own fan-out) | ✅ Yes (same `accounts.X` + `/account/X` pattern) |
| Mac required to run for iPhone to see partner | ⚠️ Implicitly (Mac's row is the source of truth via fallback) | ✅ No (`accounts.partner_email` is the source) |
| Reconciler / offline cache | ❌ No | ✅ Yes |
| Failure mode when offline | UI shows empty / cached error | UI shows last-known-state from cache |

Phase 1 was the right thing to ship overnight as an incremental fix. The redesign is the right thing to merge as the canonical answer.

---

## 8. Effort estimate

Each step is independent and reviewable:

| Step | Work | Estimate |
|---|---|---|
| 1 | Migrations + endpoints + tests | 2 hours |
| 2 | Backfill script + dry-run on staging | 1 hour |
| 3 | Wrapper logic for legacy endpoints | 1 hour |
| 4 | macOS dashboard + Swift reconciler | 2-3 hours |
| 5 | iOS PartnerView + Swift reconciler | 2-3 hours |
| 6 | Documentation + cross-repo log update | 1 hour |
| **Total** | | **~10 hours** focused implementation |

Phase 1 took ~2 hours to ship. The redesign is 5x the work but resolves the brittleness for good and unlocks the same pattern for all the other account-scoped features the schedule + session sync spec lists.

---

## 9. Risks & open questions

1. **Backfill ambiguity for accounts with multiple partner_email values across user rows.** The migration picks the most recently updated row — that's the right heuristic when partner data was set on multiple devices, but if the user has stale partner_email on an old device row, it could surface. Mitigation: log the backfill — for each account, log all candidate rows + the chosen one — and audit before flipping legacy endpoints.

2. **Consent records that pre-exist with no `account_id` on partner_consent.** Backfill walks them, but rows where the originating `users.account_id` was NULL at the time can't be linked. Mitigation: those rows stay user_id-keyed; reads check both. Acceptable inconsistency.

3. **What if the same email is on two different accounts** (one user, one partner)? Already handled today — `PUT /partner` rejects setting your own email. Carry that check into the new endpoint.

4. **Cache invalidation on logout.** Must explicitly clear the cache when the user signs out, otherwise the next user on the same device sees a stranger's partner. Mitigation: AuthService logout hook calls `PartnerStateReconciler.clearCache()`.

5. **Is the Reconciler heavyweight for partner specifically?** Could we just call `GET /account/partner` lazily on tab-open and skip the cache entirely? Yes — but the cache is ~30 lines of code and gives instant render. Worth keeping.

6. **Should partner-set notifications go push** (Apple Push or websocket) so Mac sees an iOS-set partner change in <1s instead of <5min? Out of scope for v1. Can add by extending the existing `connected_focus_ws` machinery later.

---

## 10. What ships in v1 vs later

**v1 (this spec):**
- Schema migration + backfill
- New `/account/partner` endpoints
- Legacy endpoint wrappers (delegate to new logic when account exists)
- macOS Reconciler + dashboard wire-up
- iOS PartnerStateService + PartnerView wire-up
- Cache files (unsigned)
- 5-min heartbeat refresh on both clients
- Logout cache clear

**Later (out of scope for v1):**
- Push notifications for partner changes (websocket or APNS)
- Multiple partners (table refactor)
- Partner-side audit log
- Removing legacy `users.partner_email/name` columns (after extension migrates)
- Schedule sync + active session sync — these get the same architectural pattern but each has its own data model and UI; tracked in [`2026-04-26-schedule-and-session-sync.md`](./../plans/2026-04-26-schedule-and-session-sync.md). The redesign here clears the path for them by establishing the `account-scoped column + Bearer endpoint + reconciler` recipe.

---

## 11. Decision summary for the user

If you approve this spec, the next step is the writing-plans skill to break Section 6's migration steps into a concrete plan with file-level tasks. **Implementation does not start until you approve.**

Three things to decide:

1. **Approve Approach A** (columns on `accounts` table) — or push back toward Approach B (settings JSONB) or C (separate table)?
2. **Abandon Phase 1 branches** (`feat/account-based-partner` + `feat/partner-link-account`) — confirm we don't merge them, or you want them merged as an interim?
3. **Effort tradeoff** — willing to spend ~10 hours on the redesign vs ~2 hours on the Phase 1 deploy? (My recommendation: do the redesign — Phase 1 is technical debt by construction.)
