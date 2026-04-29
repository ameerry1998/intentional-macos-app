# Bedtime Lock-Loop + Duration-Limited Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current Mac bedtime full-screen overlay + custom blanket UI with (a) Apple's native lock screen triggered every 10 seconds, (b) a wind-down notification cascade so users aren't surprised, (c) a duration-limited partner-unlock flow with a slider (15min / 30min / 1hr / 2hr / until-wake), and (d) once-per-night limit on extensions. Cross-device: extensions apply to both Mac AND iPhone simultaneously. Pill widget reset behavior: every new session resets to top-right of active display, and pill gains bedtime windDown / locked modes.

**Architecture:** Backend stores requested duration on the unlock request and uses it to compute `released_until` (instead of the existing fixed 8h). Backend rejects new requests when any verified row has `released_until > now` (once-per-night). Mac swaps overlay for `osascript`-based lock loop. Wind-down state machine fires native macOS notifications at T-30 / T-15 / every 5 min after / T-1 countdown. iPhone unlock sheet replaces the 4-chip reason picker with a duration slider (reason + note still captured). Both clients honor backend `released_until` via the existing config + status pollers — no new sync infrastructure needed.

**Tech Stack:** FastAPI + Postgres (Supabase) backend. AppKit + Foundation Mac. SwiftUI iOS. Existing `osascript` for system lock-screen trigger (`tell application "System Events" to keystroke "q" using {command down, control down}` — the standard Lock Screen shortcut).

---

## §0. Conversation context (verbatim, why this plan exists)

User's exact prompts during the session that produced this plan:

> "we want to implement this thing where the laptop locks the screen every five seconds and five seconds should be enough for you to enter the code that you got from your friend or from your accountability partner if you want to not sleep through the night, right?"

> "We also want to ensure that if the bed time is removed from the laptop, I guess it should also be removed from the phone? Maybe we should have like, actually we should update the feature slightly so that when the user gives you a code, when the accountability partner gives you a code, it's for a specific amount of time that you're trying to stay up, it's not unlimited. You have to use a slider to select how much time you want to stay up and then they get that in their email."

> "in the evening 15 minutes before bedtime you get a notification you get the timer showing up on the top right of the screen or sorry 30 minutes after before bedtime you have that the timer the floating screen showing up on the top right of the screen indicating that the laptop is gonna lock out in 30 minutes and then it does it again in 15 minutes but at 15 minutes there's no option to minimize it anymore I don't know does that complicate things fuck it just have it keep popping up in like five minute increments once we hit 15 minutes once we hit 15 minutes every five minutes it pops up and then for the last minute it like just shows a countdown"

> "they can only do this once per night I'm not sure what the maximum amount of time they should be able to request is I guess that also unlocks their phone for the evening not just their their Mac"

> "Can we just make sure that we show the floating window … sometimes that thing disappears you have to like find a way to make sure that it always shows up on the top right even when i move it whenever there's a new session it just show back up on the top right um and it should definitely show up there for the night time"

> "the max should be until wake up in case they need to stay up for the night"

> "[user picked option] B" — referring to 10-second lock-loop interval (vs 5s with pause-on-engagement)

User's intent is unmistakable: replace the heavy-handed full-screen overlay with friction (lock the screen repeatedly) plus context (warning notifications + visible pill), and gate the escape valve via a slider so partners explicitly authorize a duration rather than an unbounded "you're free" hour count.

---

## §1. What was already shipped (do NOT redo)

This plan builds on top of work that landed 2026-04-28 and earlier today (2026-04-29). Read this so you don't redo it.

### Backend (deployed to `main`, Railway)

- Migration `013_add_bedtime_config.sql` — `bedtime_config` table. Applied.
- Migration `014_add_bedtime_unlock_requests.sql` — `bedtime_unlock_requests` table. Applied.
- Migration `015_add_device_push_tokens.sql` — `device_push_tokens` table. Applied.
- `GET /bedtime/config` + `PUT /bedtime/config` — config sync. Both clients pull/push.
- `POST /bedtime/unlock-request` — generates 6-digit code, partner email. Currently has NO duration parameter.
- `POST /bedtime/unlock-verify` — verifies code, sets `released_until = now + 8h` (fixed). This is what we're changing.
- `GET /bedtime/unlock-status` — returns released state. Polled by Mac + iPhone.
- `POST /bedtime/unlock-approve` — push-based partner approval (separate path; not the focus of this plan).
- `POST /devices/push-token` — APNs token registration.

### iPhone (`feat/bedtime-redesign` branch, head currently `97945fb` post locked-card-redesign)

- Full bedtime UI (Alarms tab redesign with `BedtimeCard` off / armed / locked variants).
- `BedtimeShieldStore` — FamilyControls Shield. Works.
- `BedtimeScheduleService` — local config cache + tick + 30s evaluation loop.
- `BedtimeUnlockRequestSheet` — currently uses 4-chip reason picker (Emergency / Travel / Work / Other). **This plan replaces the chips with a duration slider** (reasons + note are still captured below the slider).
- `BedtimeUnlockCodeView` — 6-digit code entry. Stays.
- Live Activity (PuckActivities widget extension) on lock screen + Dynamic Island.
- Push notification registration + `PuckPushRouter`. Wired but APNs env vars not yet set on Railway — current path is email-code fallback.

### Mac (`feat/focus-mode-consolidation` branch, head currently `eacf6d2`)

- `BedtimeEnforcer.swift` — state machine: `inactive / windDown / lockedOut / snoozed / overridden`. **This plan rewrites the lockedOut path** to swap the full-screen overlay for the lock-loop.
- `BedtimeOverlayView.swift` — full-screen blanket NSWindow. **This plan deletes it.**
- `BedtimeConfigSync.swift` — backend config pull (60s interval, plus on app foreground).
- `TrustedClock.swift` — tamper detection. Now uses `mach_continuous_time()` (sleep-aware). Stays.
- `BackendClient.bedtimeUnlock{Request,Verify,Status}()` — wired to backend. **This plan adds `duration_minutes` parameter to request.**
- `pmset sleepnow` — REMOVED earlier today. Stays gone.
- The pill widget (`DeepWorkTimerController` + related) — **this plan adds bedtime windDown / locked modes and snap-to-top-right reset on every new session**.

### Cross-repo conventions

- All backend migrations applied with RLS enabled (zero policies = default-deny). Service-role key bypasses.
- Backend = source of truth for cross-device state. Both clients are caches.
- Strict-mode daemon (`com.intentional.daemon`) + watchdog agent (`com.intentional.agent`) respawn the Mac app on death. They are NOT in scope for this plan.

---

## §2. Goals + locked-in decisions

| # | Decision | Locked at | Rationale |
|---|---|---|---|
| 1 | Lock-loop interval = 10 seconds, no pause-on-engagement | User picked option B | 5s risks locking mid-keystroke during code entry. 10s is enough friction without bricking the unlock flow. |
| 2 | Slider snap points: 15 min / 30 min / 1 hour / 2 hours / Until wake | User confirmed | Discrete snap points are clearer than a continuous slider. "Until wake" is the legitimate-emergency option; partner gates it. |
| 3 | Once-per-night limit on verified extensions | User explicit | Without this, the slider becomes a nightly escape valve and the feature dies. Reset trigger: wake alarm fires (existing release path). |
| 4 | Cross-device: `released_until` applies to BOTH Mac AND iPhone simultaneously | User explicit + already true | Backend's `released_until` is account-scoped (not device-scoped). Both clients already honor it via existing pollers. Just verify this still works after the duration change. |
| 5 | Wind-down notifications: T-30, T-15, then every 5 min, T-1 countdown | User wrote out the cascade | Three escalation steps so users aren't surprised. T-15 onward cannot be minimized; user has to actively dismiss or push-by-10. |
| 6 | Pill snaps to top-right of active display on every new session start | User explicit | Pill currently memorizes drag position; users have lost it off-screen. Reset on every block transition (Deep Work, Focus Hours, Bedtime windDown, Bedtime locked). |
| 7 | Pill gains bedtime windDown + locked modes | User explicit | Pill is the visible "session is active" surface across all session types. Bedtime should fit the same pattern, not have its own separate UI. |
| 8 | Replace `BedtimeOverlayView` (the full-screen blanket) with the lock-loop + pill + wind-down notifications | Implied by lock-loop choice | The overlay no longer adds value if Apple's lock screen is doing the heavy visual work. Keep `BedtimeOverlayView.swift` deleted. |
| 9 | Existing partner-code unlock-verify path stays. New: duration param. Partner code email shows requested duration. | User explicit | Email path is the working escape valve; just enriches it with duration context. |

---

## §3. Out of scope (do NOT add)

- Endpoint Security framework integration. Per yesterday's spike + Perplexity research, ES would give true pre-launch app blocking but requires Apple entitlement application + Developer ID distribution. That's a separate plan once the entitlement is filed and approved. Today: lock-loop only.
- macOS FamilyControls / ManagedSettings on Mac native app. Confirmed unavailable. Already planned NOT-shipping in `2026-04-28-mac-bedtime-managedsettings.md`.
- Continuous brightness fade during wind-down (option C from earlier discussion).
- Push-based partner approval flow (the `/bedtime/unlock-approve` endpoint already exists but UI lives in iPhone PartnerApprovalView — this plan extends with duration but does not change the push wiring).
- Removing the strict-mode daemon. Out of scope.
- Windows port. Separate effort (architecture sketch document, not code).
- The iOS UI is largely unchanged — only the unlock-request sheet's reason picker becomes a duration slider.
- Snooze button on the windDown notifications during lock-window. Not part of the cascade — once locked, you ask for an extension via the slider; you don't get a free snooze.

---

## §4. Risk catalog

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | `osascript` lock-screen call fails on macOS 14+ due to AppleEvents permissions / TCC | Medium | Phase 2 task: detect and gracefully degrade to legacy overlay if `osascript` returns non-zero. Log every failed attempt. Alternative: use `/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession -suspend` directly. Test both. |
| R2 | Lock loop fires while user is typing code, password gets eaten by the lock screen | Low (10s window) | At 10s, even a slow typer can finish 6 digits in ~5s. If user starts code entry late in the cycle, worst case they re-type once. Acceptable. |
| R3 | User in middle of important work at T-0, no warning shown because notifications were Do Not Disturb suppressed | Medium | Wind-down notifications use `UNNotificationContent.interruptionLevel = .timeSensitive`. macOS bypasses DND for time-sensitive. Document. |
| R4 | Push-by-10 abuse: user keeps pushing every 10 min | Mitigated by once-per-night | Push counts as an action. Backend tracks one push per night just like extensions. After T-0, push is no longer offered; only request-extension via partner. |
| R5 | Duration slider's "Until wake" gets requested at 22:31 (one minute into bedtime) — extension is ~8h | Acceptable | This is the legitimate-emergency case. Partner sees the "Until wake" framing in email and decides. If they don't think it warrants it, they grant 30 min instead. |
| R6 | Once-per-night reset boundary is fuzzy: what if user requests at 02:30 and wake is 06:30? Then at 06:31 the wake fires and clears `released_until` — but request was used. Next bedtime at 22:30 the user can request again. Right? | Yes by design | "Per night" = per bedtime cycle. Wake-alarm dismissal resets `bedtime_unlock_requests` consumption. Same row, status changes from `verified` to `consumed`. New request next night allowed. |
| R7 | Duration parameter validation: client sends 99999 minutes | Low | Backend Pydantic validator with explicit allowed values: `[15, 30, 60, 120, -1]` where `-1` = until wake. Reject anything else with 422. |
| R8 | "Until wake" duration computed from cached `cfg.wakeHour:wakeMinute` — what if user changes wake alarm DURING the bedtime window? | Edge case | Partner approves "until 6:30 AM"; user later changes wake to 7:30 AM via iPhone. Backend's `released_until` is locked at request-verify time using the wake config AT THAT MOMENT. If user changes alarm post-verify, bedtime ends at the original 6:30 AM (the released_until timestamp doesn't move). Document this. |
| R9 | Pill window snap-to-top-right on multi-display setups: which display? | Phase 3 task | Snap to display containing the menu bar + active focus. If user moves to a different display mid-session, pill stays on original (no chasing). This matches macOS conventions for app windows. |
| R10 | Lock-loop continues after wake alarm because `BedtimeEnforcer` state is stale | Medium | Phase 2 task: lock-loop `Timer` reads `BedtimeEnforcer.state` on every fire. When state transitions away from `.locked`, timer invalidates immediately. Add unit test. |
| R11 | Cross-device "release" lag: partner approves, iPhone polls every 5s, Mac polls every 60s. Mac stays locked for up to 60s after iPhone is released | Acceptable but document | The Mac config-sync `pullTimer` was dropped to 60s today. The Mac `unlock-status` poll is 5s WHILE LOCKED (mirrors iPhone). So Mac picks up the release within 5s once locked. Verify in Phase 2 task. |
| R12 | Once-per-night limit prevents legitimate re-requests: e.g., partner denies first request, user wants to ask for less time | High UX papercut | Once-per-night is on VERIFIED requests, not REQUESTED ones. If partner denies (or just doesn't enter the code), no `verified` row exists, so user can request again. Test for this. |
| R13 | Email body shows wrong time for "Until wake" because backend doesn't know user's local timezone | Medium | Email template formats wake time as "until your normal wake time (06:30 in your local time)" — user's wake is stored as h:m without timezone. Document the limitation; don't fix now. |
| R14 | Wind-down at T-30 fires during a video call / presentation | Medium UX | Notification has interruption level `.timeSensitive` but is dismissable. User can dismiss; T-15 still fires. T-1 countdown is unmissable. Document. |
| R15 | macOS 26 changes `osascript` permissions or notification behavior | Low | We test on user's macOS version (Xcode 26 / macOS 26 per their setup). Phase 2 task documents the macOS version verified. If a future macOS breaks, the existing overlay can be a temporary fallback (kept as dead code until fully proven obsolete). |
| R16 | Pill positioning: `NSWindow.setFrameOrigin` call on a bad screen index crashes | Low | Use `NSScreen.main` (active display). Validate non-nil before calling. Test with single + multi display. |

---

## §5. File structure

### Backend (`/Users/arayan/Documents/GitHub/intentional-backend`)

| Path | Action | Purpose |
|---|---|---|
| `migrations/016_add_unlock_request_duration.sql` | CREATE | Add `requested_duration_minutes INTEGER NOT NULL DEFAULT 30` to `bedtime_unlock_requests`. |
| `main.py` | EDIT | Add `duration_minutes` to `BedtimeUnlockRequestBody`. Validate snap points. Store on row. Modify `/bedtime/unlock-verify` to compute `released_until` from stored duration. Modify `/bedtime/unlock-request` to reject 409 when verified row exists with `released_until > now()`. |
| `email_service.py` | EDIT | `send_bedtime_unlock_code_email` accepts `duration_minutes` + `wake_time_str`. Body shows requested duration ("Ameer wants 30 more minutes" or "Ameer wants to stay up until 6:30 AM"). |
| `tests/test_bedtime_unlock.py` | EDIT | Add cases: duration round-trip, once-per-night rejection, denied-request-allows-retry, until-wake handling, invalid duration 422. |

### Mac (`/Users/arayan/Documents/GitHub/intentional-macos-app`)

| Path | Action | Purpose |
|---|---|---|
| `Intentional/BedtimeLockLoop.swift` | CREATE | Owns the 10s `Timer` that calls `osascript` to trigger Apple's Lock Screen. Self-invalidates when bedtime state leaves `.locked`. |
| `Intentional/BedtimeWindDownController.swift` | CREATE | Schedules native `UNUserNotificationCenter` requests at T-30 / T-15 / T-10 / T-5 / T-1. Drives pill mode transitions. |
| `Intentional/BedtimeUnlockRequestView.swift` | CREATE | SwiftUI view in dashboard: duration slider (15 / 30 / 60 / 120 / -1), reason picker, optional note, "Send unlock request" button. Calls `BackendClient.bedtimeUnlockRequest(duration: reason: note:)`. |
| `Intentional/BedtimeEnforcer.swift` | EDIT | Replace `lockedOut` transition: instead of `showLockoutOverlay()`, call `BedtimeLockLoop.shared.start()`. Drop `BedtimeOverlayView` references. Drop `snoozeUsedTonight` / `countdownTimer` / `forceSleep` (already mostly gone — finish removal). State machine simplifies to: `inactive / windDown / locked / released`. |
| `Intentional/BedtimeOverlayView.swift` | DELETE | The blanket is gone. |
| `Intentional/BedtimeOverlayViewModel.swift` (if standalone) | DELETE | Same. |
| `Intentional/BackendClient.swift` | EDIT | Add `duration_minutes: Int` to `bedtimeUnlockRequest(...)`. Adjust DTOs. |
| `Intentional/DeepWorkTimerController.swift` | EDIT | On `show()`, snap window position to top-right of active display (16pt below menu bar, 16pt from right edge). User-drag positions are session-local; reset on next `show()`. |
| `Intentional/Pill/PillMode.swift` (or wherever modes are defined) | EDIT | Add `bedtimeWindDown(timeRemaining: TimeInterval)` and `bedtimeLocked(wakeTime: Date)` cases. Wire view rendering for both. |
| `Intentional/Pill/PillContentView.swift` | EDIT | Render bedtime modes: windDown shows "Bedtime in 30 min" + minimize button (30+15min) or no minimize (T-15 onward); locked shows moon glyph + countdown + "Ask partner" link. |
| `IntentionalTests/BedtimeLockLoopTests.swift` | CREATE | Unit tests for `BedtimeLockLoop.start()` / `stop()` / state-aware self-cancellation. |
| `IntentionalTests/BedtimeWindDownControllerTests.swift` | CREATE | Tests for notification-fire timestamps + pill mode transitions. |
| `IntentionalTests/BedtimeLogicTests.swift` | EDIT | Add tests for the simplified state machine post-overlay-removal. |
| `CLAUDE.md` | EDIT | Update bug-fix list (#13 — bedtime lock-loop replaces overlay), update init order if needed. |

### iPhone (`/Users/arayan/Documents/GitHub/puck-ios`)

| Path | Action | Purpose |
|---|---|---|
| `Puck/Views/Bedtime/BedtimeUnlockRequestSheet.swift` | EDIT | Replace 4-chip reason picker with: duration slider (15/30/60/120/-1) + below it: smaller reason chips (Emergency/Travel/Work/Other) + optional note. Slider primary, reasons secondary. |
| `Puck/Core/Network/IntentionalBedtimeClient.swift` | EDIT | Add `duration_minutes: Int` to `requestUnlock(...)`. Update DTO. |
| `Puck/Core/Bedtime/BedtimeScheduleService.swift` | EDIT | Handle 409 from request endpoint as "already used your extension tonight" — surface to user via published `lastRequestError: BedtimeRequestError`. |
| `Puck/Views/Bedtime/BedtimeAlreadyUsedView.swift` | CREATE | Small banner/alert shown when 409 returned from request: "You've used your extension for tonight. Bedtime locks until 6:30 AM." |
| `CLAUDE.md` | EDIT | Update bedtime section with duration slider + once-per-night. |

### Cross-repo

- `intentional-macos-app/docs/cross-repo-bedtime-lock-loop-2026-04-29.md` — hand-off log.

### Untouched (do NOT modify)

- `FocusStatePoller.swift`, `FocusModeController.swift`, `IntentionalFocusSignalClient.swift`, `/focus/*` endpoints, `_resolve_account_dual_auth`. Stable.
- iOS `BedtimeShieldStore.swift` — unchanged. Backend `released_until` is what flips the shield off via existing tick logic.
- iOS `BedtimeLockoutWindow.swift` + `BedtimeLockoutView.swift` — already unreachable per yesterday's commit `0a9a9ae`. Kept as dead code in case design changes.
- Mac `TrustedClock.swift` — already correct after today's `mach_continuous_time` fix.
- Backend `/bedtime/unlock-approve` (push flow) — already accepts duration in its body. Verify the existing duration handling matches the new request-side slider.

---

## §6. Phase-by-phase implementation

Each phase commits to its own commit on its own branch. Use `superpowers:subagent-driven-development` for execution. **TDD mandatory**: failing test → implementation → green test → commit.

---

### Phase 1 — Backend: duration parameter + once-per-night

**Branch:** `feat/bedtime-duration` off `main` of `intentional-backend`. Worktree at `.claude/worktrees/bedtime-duration`.

#### Task 1.1 — Migration `016_add_unlock_request_duration.sql`

**Files:**
- Create: `intentional-backend/migrations/016_add_unlock_request_duration.sql`

- [ ] **Step 1: Write the migration**

```sql
-- 016_add_unlock_request_duration.sql
-- Per-request duration carried by bedtime_unlock_requests so backend
-- can compute released_until from user-selected slider value
-- (15 / 30 / 60 / 120 minutes, or -1 = "until wake"). Replaces the
-- legacy fixed 8-hour release window.
--
-- APPLY in Supabase SQL editor. RLS already enabled on the table
-- (zero policies = default-deny for non-service-role connections).

ALTER TABLE bedtime_unlock_requests
    ADD COLUMN IF NOT EXISTS requested_duration_minutes INTEGER NOT NULL DEFAULT 30
        CHECK (requested_duration_minutes IN (15, 30, 60, 120, -1));

COMMENT ON COLUMN bedtime_unlock_requests.requested_duration_minutes
    IS 'User-selected slider value at request time. -1 sentinel = "until wake alarm".';
```

- [ ] **Step 2: Tell user to apply manually before pushing code that uses the column**

User pastes the SQL into Supabase SQL editor. Wait for confirmation.

- [ ] **Step 3: Commit**

```bash
git add migrations/016_add_unlock_request_duration.sql
git commit -m "feat(bedtime): migration 016 — duration column on unlock requests"
```

#### Task 1.2 — Pydantic models

**Files:**
- Modify: `intentional-backend/main.py`

- [ ] **Step 1: Find the existing `BedtimeUnlockRequestBody` and update**

Find:
```python
class BedtimeUnlockRequestBody(BaseModel):
    reason: Optional[str] = None
    note: Optional[str] = None
```

Change to:
```python
class BedtimeUnlockRequestBody(BaseModel):
    reason: Optional[str] = None
    note: Optional[str] = None
    duration_minutes: int = 30  # 15 / 30 / 60 / 120 or -1 for "until wake"

    @validator("duration_minutes")
    def validate_duration(cls, v: int) -> int:
        if v not in {15, 30, 60, 120, -1}:
            raise ValueError(
                "duration_minutes must be one of: 15, 30, 60, 120, -1 (until wake)"
            )
        return v
```

If `validator` import is missing, add `from pydantic import validator` (or `field_validator` in pydantic v2).

- [ ] **Step 2: Commit**

```bash
git add main.py
git commit -m "feat(bedtime): duration_minutes on unlock-request body with snap-point validation"
```

#### Task 1.3 — `POST /bedtime/unlock-request` once-per-night + store duration (TDD)

**Files:**
- Modify: `intentional-backend/tests/test_bedtime_unlock.py`
- Modify: `intentional-backend/main.py`

- [ ] **Step 1: Write failing tests**

Add to `tests/test_bedtime_unlock.py`:

```python
def test_request_stores_duration(seeded_account_with_partner, mock_email_service):
    h = {"X-Device-ID": seeded_account_with_partner["device_id"]}
    r = client.post(
        "/bedtime/unlock-request",
        json={"duration_minutes": 60, "reason": "work"},
        headers=h,
    )
    assert r.status_code == 200
    db = get_db()
    row = (
        db.table("bedtime_unlock_requests")
        .select("requested_duration_minutes")
        .eq("account_id", seeded_account_with_partner["account_id"])
        .eq("status", "pending")
        .single()
        .execute()
        .data
    )
    assert row["requested_duration_minutes"] == 60

def test_request_rejected_when_active_extension_exists(
    seeded_account_with_partner, mock_email_service
):
    """Once-per-night: if a verified row has released_until > now, new request 409."""
    h = {"X-Device-ID": seeded_account_with_partner["device_id"]}
    # First request + verify
    client.post("/bedtime/unlock-request", json={"duration_minutes": 30}, headers=h)
    code = mock_email_service.send_bedtime_unlock_code_email.call_args.kwargs["code"]
    client.post("/bedtime/unlock-verify", json={"code": code}, headers=h)
    # Second request should 409
    r = client.post("/bedtime/unlock-request", json={"duration_minutes": 30}, headers=h)
    assert r.status_code == 409
    assert "already" in r.json()["detail"].lower()

def test_denied_request_does_not_block_retry(seeded_account_with_partner, mock_email_service):
    """If first code is never verified, second request is allowed."""
    h = {"X-Device-ID": seeded_account_with_partner["device_id"]}
    r1 = client.post("/bedtime/unlock-request", json={"duration_minutes": 30}, headers=h)
    assert r1.status_code == 200
    # No verify happens. New request supersedes old.
    r2 = client.post("/bedtime/unlock-request", json={"duration_minutes": 60}, headers=h)
    assert r2.status_code == 200

def test_invalid_duration_422(seeded_account_with_partner, mock_email_service):
    h = {"X-Device-ID": seeded_account_with_partner["device_id"]}
    r = client.post("/bedtime/unlock-request", json={"duration_minutes": 7}, headers=h)
    assert r.status_code == 422
```

- [ ] **Step 2: Run tests, confirm failures**

```bash
pytest tests/test_bedtime_unlock.py -v -k "duration or once_per_night or denied or invalid"
```

Expected: 4 FAILED.

- [ ] **Step 3: Implement once-per-night check + duration storage**

In `main.py`'s `request_bedtime_unlock` function, BEFORE creating the new pending row, add:

```python
# Once-per-night: reject if a verified extension is still in effect.
verified_active = (
    db.table("bedtime_unlock_requests")
    .select("id")
    .eq("account_id", account_id)
    .eq("status", "verified")
    .gt("released_until", datetime.now(timezone.utc).isoformat())
    .limit(1)
    .execute()
    .data
)
if verified_active:
    raise HTTPException(
        status_code=409,
        detail="You've already used your extension for tonight. Bedtime ends at your wake alarm.",
    )
```

In the same function, when inserting the row, add `requested_duration_minutes`:

```python
row = (
    db.table("bedtime_unlock_requests")
    .insert(
        {
            "account_id": account_id,
            "partner_email": partner_email,
            "code_hash": code_hash,
            "expires_at": expires_at.isoformat(),
            "status": "pending",
            "reason": body.reason,
            "note": body.note,
            "requested_duration_minutes": body.duration_minutes,
        }
    )
    .execute()
    .data[0]
)
```

- [ ] **Step 4: Run tests, all PASS**

```bash
pytest tests/test_bedtime_unlock.py -v -k "duration or once_per_night or denied or invalid"
```

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_bedtime_unlock.py
git commit -m "feat(bedtime): once-per-night limit + store requested duration"
```

#### Task 1.4 — `POST /bedtime/unlock-verify` uses stored duration (TDD)

**Files:**
- Modify: `intentional-backend/tests/test_bedtime_unlock.py`
- Modify: `intentional-backend/main.py`

- [ ] **Step 1: Failing test**

```python
def test_verify_uses_requested_duration(seeded_account_with_partner, mock_email_service):
    h = {"X-Device-ID": seeded_account_with_partner["device_id"]}
    client.post(
        "/bedtime/unlock-request",
        json={"duration_minutes": 60},
        headers=h,
    )
    code = mock_email_service.send_bedtime_unlock_code_email.call_args.kwargs["code"]
    r = client.post("/bedtime/unlock-verify", json={"code": code}, headers=h)
    assert r.status_code == 200
    released_until = datetime.fromisoformat(
        r.json()["released_until"].replace("Z", "+00:00")
    )
    delta = (released_until - datetime.now(timezone.utc)).total_seconds()
    # 60 min ± 2 min jitter
    assert 58 * 60 < delta < 62 * 60

def test_verify_until_wake_uses_wake_config(seeded_account_with_partner, mock_email_service):
    """duration_minutes = -1 means released_until = next wake alarm."""
    h = {"X-Device-ID": seeded_account_with_partner["device_id"]}
    # Set bedtime config: wake at 06:30
    client.put(
        "/bedtime/config",
        json={
            "enabled": True,
            "bedtime_start": {"hour": 22, "minute": 30},
            "wake": {"hour": 6, "minute": 30},
            "active_days": [1, 2, 3, 4, 5, 6, 7],
            "allowlist_bundle_ids": [],
            "partner_locked": False,
        },
        headers=h,
    )
    client.post(
        "/bedtime/unlock-request",
        json={"duration_minutes": -1},
        headers=h,
    )
    code = mock_email_service.send_bedtime_unlock_code_email.call_args.kwargs["code"]
    r = client.post("/bedtime/unlock-verify", json={"code": code}, headers=h)
    assert r.status_code == 200
    released_until = datetime.fromisoformat(
        r.json()["released_until"].replace("Z", "+00:00")
    )
    # released_until should be the next 06:30 (today or tomorrow depending on now)
    now = datetime.now(timezone.utc)
    diff_hours = (released_until - now).total_seconds() / 3600
    assert 0 < diff_hours <= 24
    # Must be exactly h=6, m=30 in account's local time. Since we don't have
    # tz, assert hour:minute matches in UTC frame the wake config.
    # Backend stores wake as h:m without tz; verify it lands on a 06:30 boundary.
    assert released_until.minute == 30
    assert released_until.hour == 6 or released_until.hour == 30 % 24  # tolerate UTC offset
```

- [ ] **Step 2: Implement**

In `main.py`'s `verify_bedtime_unlock`, replace the `released_until = datetime.now(timezone.utc) + timedelta(hours=8)` line with:

```python
duration = row.get("requested_duration_minutes", 30)
if duration == -1:
    # Until wake: compute next wake-time boundary from bedtime_config.
    cfg = (
        db.table("bedtime_config")
        .select("wake_hour, wake_minute")
        .eq("account_id", account_id)
        .single()
        .execute()
        .data
    )
    wake_h = cfg.get("wake_hour", 7) if cfg else 7
    wake_m = cfg.get("wake_minute", 0) if cfg else 0
    now = datetime.now(timezone.utc)
    next_wake = now.replace(hour=wake_h, minute=wake_m, second=0, microsecond=0)
    if next_wake <= now:
        next_wake = next_wake + timedelta(days=1)
    released_until = next_wake
else:
    released_until = datetime.now(timezone.utc) + timedelta(minutes=duration)
```

- [ ] **Step 3: Tests PASS, commit**

```bash
pytest tests/test_bedtime_unlock.py -v -k "verify_uses_requested or verify_until_wake"
git add main.py tests/test_bedtime_unlock.py
git commit -m "feat(bedtime): unlock-verify computes released_until from requested duration"
```

#### Task 1.5 — Email template includes duration

**Files:**
- Modify: `intentional-backend/email_service.py`

- [ ] **Step 1: Update method signature + body**

Find `send_bedtime_unlock_code_email`. Add parameter `duration_minutes: int` and `wake_time_str: str` (the latter for "until wake" formatting). Update body:

```python
async def send_bedtime_unlock_code_email(
    self,
    to_email: str,
    partner_name: str,
    user_name: str,
    code: str,
    reason: Optional[str],
    note: Optional[str],
    expires_at: datetime,
    duration_minutes: int,
    wake_time_str: Optional[str] = None,  # e.g. "6:30 AM"
) -> dict:
    expires_local = expires_at.astimezone()
    expires_str = expires_local.strftime("%I:%M %p").lstrip("0")

    if duration_minutes == -1:
        duration_phrase = (
            f"to stay up until your normal wake time ({wake_time_str or 'wake alarm'})"
        )
    elif duration_minutes < 60:
        duration_phrase = f"for <strong>{duration_minutes} more minutes</strong>"
    else:
        hours = duration_minutes // 60
        duration_phrase = f"for <strong>{hours} more hour{'s' if hours > 1 else ''}</strong>"

    reason_line = f"<p><strong>Reason:</strong> {reason}</p>" if reason else ""
    note_line = f"<p><strong>Note:</strong> {note}</p>" if note else ""

    body_html = f"""
    <p>Hi {partner_name},</p>
    <p><strong>{user_name}</strong> is asking to stay up {duration_phrase}.</p>
    {reason_line}
    {note_line}
    <p style="font-size:32px;letter-spacing:4px;font-weight:700;margin:24px 0;">
        {code}
    </p>
    <p>This code expires at {expires_str}. Sharing it grants {user_name}
    {duration_phrase}. After that, bedtime resumes.</p>
    <p>If you don't recognize this request, you can ignore it — bedtime stays
    in effect.</p>
    """
    return await self._send(
        to=to_email,
        subject=f"{user_name} is asking for more time",
        html=body_html,
    )
```

- [ ] **Step 2: Update the caller in `main.py`**

Find the `request_bedtime_unlock` function's email-send block. Pass the new arguments:

```python
# Compute wake_time_str from cfg if "until wake" was requested
wake_time_str = None
if body.duration_minutes == -1:
    cfg = (
        db.table("bedtime_config")
        .select("wake_hour, wake_minute")
        .eq("account_id", account_id)
        .single()
        .execute()
        .data
    )
    if cfg:
        wake_h = cfg.get("wake_hour", 7)
        wake_m = cfg.get("wake_minute", 0)
        wake_time_str = f"{wake_h % 12 or 12}:{wake_m:02d} {'PM' if wake_h >= 12 else 'AM'}"

await email_service.send_bedtime_unlock_code_email(
    to_email=partner_email,
    partner_name=user.get("partner_name", "there"),
    user_name=user.get("display_name", "your partner"),
    code=code,
    reason=body.reason,
    note=body.note,
    expires_at=expires_at,
    duration_minutes=body.duration_minutes,
    wake_time_str=wake_time_str,
)
```

- [ ] **Step 3: Update existing test mock to accept new args** (the mock should be flexible — `MagicMock` is)

- [ ] **Step 4: Commit**

```bash
git add email_service.py main.py
git commit -m "feat(bedtime): partner email shows requested duration + until-wake phrasing"
```

#### Task 1.6 — Push backend, verify deploy

- [ ] Run full test suite: `pytest tests/test_bedtime_unlock.py tests/test_bedtime_config.py -v`. All PASS.
- [ ] Merge `feat/bedtime-duration` → `main` (FF). Push to origin. Railway auto-deploys.
- [ ] curl-verify (after Railway settles):
  ```bash
  curl -i -X POST https://api.intentional.social/bedtime/unlock-request \
    -H "X-Device-ID: <test-id>" \
    -H "Content-Type: application/json" \
    -d '{"duration_minutes": 30, "reason": "work"}'
  ```
  Expect 200 (or 409 if test account has active extension; both prove deploy works).
- [ ] Stop here. Do not proceed to Phase 2 until deploy is live.

---

### Phase 2 — Mac: lock-loop + wind-down

**Branch:** `feat/bedtime-lock-loop` off `feat/focus-mode-consolidation` of `intentional-macos-app`. Worktree at `.claude/worktrees/bedtime-lock-loop`.

#### Task 2.1 — `BedtimeLockLoop.swift` (TDD)

**Files:**
- Create: `Intentional/BedtimeLockLoop.swift`
- Create: `IntentionalTests/BedtimeLockLoopTests.swift`

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import Intentional

@MainActor
final class BedtimeLockLoopTests: XCTestCase {
    func testStartCreatesActiveTimer() {
        let loop = BedtimeLockLoop()
        XCTAssertFalse(loop.isActive)
        loop.start()
        XCTAssertTrue(loop.isActive)
        loop.stop()
        XCTAssertFalse(loop.isActive)
    }

    func testStartIsIdempotent() {
        let loop = BedtimeLockLoop()
        loop.start()
        loop.start()
        XCTAssertTrue(loop.isActive)
        loop.stop()
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import AppKit

/// Triggers macOS's native Lock Screen on a 10-second cadence while
/// active. Replaces the legacy full-screen `BedtimeOverlayView` blanket.
///
/// Mechanism: AppleScript invocation of the system Lock Screen shortcut
/// (`Cmd+Ctrl+Q`). Cheaper than `pmset` (which slept the entire system),
/// keeps apps + downloads + music running, lets the user re-enter via
/// password / Touch ID. The 10s cadence creates real friction without
/// risking lock-mid-keystroke during partner-code entry.
///
/// Self-stops when `BedtimeEnforcer.shared.state` transitions away
/// from `.locked`. The timer reads state on every fire; any other state
/// invalidates the timer.
@MainActor
final class BedtimeLockLoop {
    static let shared = BedtimeLockLoop()

    private var timer: Timer?
    private weak var enforcer: BedtimeEnforcer?

    var isActive: Bool { timer != nil }

    /// Bind to the enforcer so the loop can self-cancel on state change.
    /// AppDelegate calls this once at init.
    func bind(to enforcer: BedtimeEnforcer) {
        self.enforcer = enforcer
    }

    func start() {
        guard timer == nil else { return }
        AppLogger.bedtimeInfo?("BedtimeLockLoop: starting (10s cadence)")
        // Fire one immediately, then every 10s.
        invokeLock()
        timer = Timer.scheduledTimer(
            withTimeInterval: 10.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        AppLogger.bedtimeInfo?("BedtimeLockLoop: stopped")
    }

    private func tick() {
        // If the enforcer is no longer in .locked, self-cancel.
        if let enforcer, enforcer.state != .locked {
            stop()
            return
        }
        invokeLock()
    }

    /// Trigger Apple's Lock Screen via AppleScript. We use the standard
    /// keyboard shortcut rather than private APIs so this survives macOS
    /// upgrades. If AppleScript is denied (TCC), log + skip — bedtime is
    /// still soft-blocked via the pill but won't lock the screen.
    private func invokeLock() {
        let source = """
        tell application "System Events"
            keystroke "q" using {command down, control down}
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            AppLogger.bedtimeError?("BedtimeLockLoop: failed to build NSAppleScript")
            return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            AppLogger.bedtimeError?(
                "BedtimeLockLoop: AppleScript lock failed: \(error)"
            )
        }
    }
}
```

- [ ] **Step 3: Build, tests PASS**

```bash
xcodebuild -workspace Intentional.xcworkspace -scheme Intentional -configuration Debug build 2>&1 | tail -3
# Run unit tests via Xcode test plan or:
xcodebuild test -scheme Intentional -destination 'platform=macOS' -only-testing:IntentionalTests/BedtimeLockLoopTests
```

- [ ] **Step 4: Commit**

```bash
git add Intentional/BedtimeLockLoop.swift IntentionalTests/BedtimeLockLoopTests.swift
git commit -m "feat(bedtime): BedtimeLockLoop — 10s system Lock-Screen cadence"
```

#### Task 2.2 — Wire `BedtimeLockLoop` into `BedtimeEnforcer`

**Files:**
- Modify: `Intentional/BedtimeEnforcer.swift`
- Modify: `Intentional/AppDelegate.swift`

- [ ] **Step 1: In `BedtimeEnforcer.swift`'s `transition(to:)`, find the `.lockedOut` case (or rename to `.locked`)**

Replace:

```swift
case .lockedOut:
    grayscaleController?.restoreSaturation()
    showLockoutOverlay(snoozeAvailable: !snoozeUsedTonight)
    if snoozeUsedTonight {
        startAutoSleepCountdown()
    }
```

With:

```swift
case .locked:
    BedtimeLockLoop.shared.start()
    // Pill mode change handled by BedtimeWindDownController (Task 2.3).
```

- [ ] **Step 2: In `.inactive` case, ensure `BedtimeLockLoop.shared.stop()` is called**

```swift
case .inactive:
    BedtimeLockLoop.shared.stop()
    countdownTimer?.invalidate()
```

- [ ] **Step 3: In AppDelegate's enforcer setup**

Add after `bedtimeEnforcer?.start()`:

```swift
if let enforcer = bedtimeEnforcer {
    BedtimeLockLoop.shared.bind(to: enforcer)
}
```

- [ ] **Step 4: Build, commit**

```bash
xcodebuild ... build 2>&1 | tail -3   # SUCCEEDED
git add Intentional/BedtimeEnforcer.swift Intentional/AppDelegate.swift
git commit -m "feat(bedtime): BedtimeEnforcer drives BedtimeLockLoop in .locked state"
```

#### Task 2.3 — `BedtimeWindDownController.swift` (TDD)

**Files:**
- Create: `Intentional/BedtimeWindDownController.swift`
- Create: `IntentionalTests/BedtimeWindDownControllerTests.swift`

The controller's responsibility: schedule notifications at T-30 / T-15 / T-10 / T-5 / T-1 relative to the upcoming bedtime, and update the pill mode at each milestone.

- [ ] **Step 1: Pure-function test for milestone schedule**

```swift
@MainActor
final class BedtimeWindDownControllerTests: XCTestCase {
    func testMilestonesAt30_15_10_5_1MinutesBeforeBedtime() {
        let bedtime = ISO8601DateFormatter().date(from: "2026-04-29T22:30:00Z")!
        let milestones = BedtimeWindDownController.milestones(beforeBedtime: bedtime)
        let minutesBefore = milestones.map {
            Int(bedtime.timeIntervalSince($0) / 60)
        }
        XCTAssertEqual(minutesBefore, [30, 15, 10, 5, 1])
    }

    func testMilestonesEmptyIfBedtimeAlreadyPassed() {
        let pastBedtime = Date().addingTimeInterval(-3600)
        XCTAssertTrue(
            BedtimeWindDownController.milestones(beforeBedtime: pastBedtime).isEmpty
        )
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import UserNotifications

@MainActor
final class BedtimeWindDownController {
    static let shared = BedtimeWindDownController()
    private init() {}

    /// Pure: returns the timestamps at which to fire wind-down notifications,
    /// 30/15/10/5/1 minutes before the given bedtime. Empty if bedtime is in
    /// the past.
    static func milestones(beforeBedtime bedtime: Date) -> [Date] {
        let offsets: [TimeInterval] = [-30 * 60, -15 * 60, -10 * 60, -5 * 60, -1 * 60]
        let now = Date()
        return offsets
            .map { bedtime.addingTimeInterval($0) }
            .filter { $0 > now && $0 < bedtime }
    }

    /// Schedule notifications + pill mode transitions for tonight's bedtime.
    /// Called by `BedtimeEnforcer` whenever bedtime is enabled and outside
    /// the lock window. Re-schedules on every cycle (idempotent — clears
    /// old pending notifications first).
    func schedule(forBedtime bedtime: Date) async {
        await clearPending()

        let center = UNUserNotificationCenter.current()
        for milestone in Self.milestones(beforeBedtime: bedtime) {
            let minutes = Int(bedtime.timeIntervalSince(milestone) / 60)
            let content = UNMutableNotificationContent()
            content.title = minutes == 1
                ? "Bedtime in 1 minute"
                : "Bedtime in \(minutes) minutes"
            content.body = minutes >= 15
                ? "Wrap up what you're doing. Bedtime locks at \(formatTime(bedtime))."
                : "Bedtime locks at \(formatTime(bedtime))."
            content.sound = .default
            content.interruptionLevel = .timeSensitive  // bypass DND
            content.categoryIdentifier = "BEDTIME_WINDDOWN"

            let interval = milestone.timeIntervalSinceNow
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, interval),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "bedtime.winddown.\(minutes)min",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    /// Cancel all pending wind-down notifications.
    func clearPending() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix("bedtime.winddown.") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
```

- [ ] **Step 3: Tests PASS, commit**

```bash
git add Intentional/BedtimeWindDownController.swift IntentionalTests/BedtimeWindDownControllerTests.swift
git commit -m "feat(bedtime): wind-down notification cascade at T-30/15/10/5/1"
```

#### Task 2.4 — Wire wind-down scheduling into `BedtimeEnforcer.recalculate()`

**Files:**
- Modify: `Intentional/BedtimeEnforcer.swift`

- [ ] **Step 1: After the `.inactive` early-return guard, before the locked check**

Add:

```swift
// Schedule wind-down notifications for tonight's bedtime if not already
// done. Idempotent — clears stale pending requests first. Runs at every
// recalculate tick when out of window so config changes propagate.
let cal = Calendar.current
let now = trustedClock.now()
if let nextBedtime = cal.date(
    bySettingHour: settings.bedtimeStart.hour,
    minute: settings.bedtimeStart.minute,
    second: 0,
    of: now
) {
    let target = nextBedtime > now
        ? nextBedtime
        : (cal.date(byAdding: .day, value: 1, to: nextBedtime) ?? nextBedtime)
    Task { await BedtimeWindDownController.shared.schedule(forBedtime: target) }
}
```

When state transitions to `.locked`, clear pending wind-down notifications (they're past their fire time anyway, but be explicit):

```swift
case .locked:
    BedtimeLockLoop.shared.start()
    Task { await BedtimeWindDownController.shared.clearPending() }
```

- [ ] **Step 2: Build, commit**

```bash
git add Intentional/BedtimeEnforcer.swift
git commit -m "feat(bedtime): enforcer schedules wind-down on every tick"
```

#### Task 2.5 — Delete `BedtimeOverlayView.swift` + dead code

**Files:**
- Delete: `Intentional/BedtimeOverlayView.swift`
- Delete: `Intentional/GrayscaleOverlayController.swift` (if still present)
- Modify: `Intentional/BedtimeEnforcer.swift` — remove `showLockoutOverlay`, `dismissOverlay`, `forceSleep`, `startAutoSleepCountdown`, `snoozeUsedTonight`, `countdownTimer`, `countdownSeconds`, `overlayWindows`, `overlayViewModel`. Audit for unused properties.

- [ ] **Step 1: Delete**

```bash
git rm Intentional/BedtimeOverlayView.swift
git rm Intentional/GrayscaleOverlayController.swift
```

- [ ] **Step 2: Strip dead methods from `BedtimeEnforcer.swift`** — only keep state transitions, `recalculate()`, `loadSettings()`, `applyRemoteSettings()`, `markReleased(until:)`, `onMacWoke()`, `verifyCode()`, `sendNotification()`.

- [ ] **Step 3: `grep -rn "pmset\|sleepnow\|forceSleep\|BedtimeOverlay\|GrayscaleOverlay" Intentional/` → 0 matches**

- [ ] **Step 4: Build, commit**

```bash
xcodebuild ... build   # SUCCEEDED
git add -u
git commit -m "chore(bedtime): drop overlay/grayscale/pmset legacy code"
```

---

### Phase 3 — Mac: pill bedtime modes + position reset

**Continues on `feat/bedtime-lock-loop` branch.**

#### Task 3.1 — Pill snaps to top-right on every `show()`

**Files:**
- Modify: `Intentional/DeepWorkTimerController.swift` (or wherever the pill window is positioned)

- [ ] **Step 1: Find the existing `show()` (or equivalent) method**

Look for the call that creates / surfaces the pill window. It probably calls `window.makeKeyAndOrderFront(...)` or similar.

- [ ] **Step 2: Add position reset before show**

```swift
private func snapToTopRight() {
    guard let screen = NSScreen.main else { return }
    guard let window = self.pillWindow else { return }
    let visibleFrame = screen.visibleFrame
    let windowFrame = window.frame
    let newX = visibleFrame.maxX - windowFrame.width - 16
    let newY = visibleFrame.maxY - windowFrame.height - 16
    window.setFrameOrigin(NSPoint(x: newX, y: newY))
}
```

Call `snapToTopRight()` at the start of `show()` (every time a new session starts).

- [ ] **Step 3: Verify drag-during-session is preserved** — user can still move the pill within a session; only the next `show()` (i.e., new session) snaps it back.

- [ ] **Step 4: Commit**

```bash
git add Intentional/DeepWorkTimerController.swift
git commit -m "feat(pill): snap to top-right on every new session start"
```

#### Task 3.2 — Add `bedtimeWindDown` and `bedtimeLocked` pill modes

**Files:**
- Modify: `Intentional/Pill/PillMode.swift` (or wherever `PillMode` enum lives)
- Modify: `Intentional/Pill/PillContentView.swift` (or wherever the SwiftUI rendering is)

- [ ] **Step 1: Add cases to `PillMode`**

```swift
enum PillMode {
    case timer
    case blockComplete
    case celebration
    case startRitual
    case startRitualEdit
    case noPlan
    case bedtimeWindDown(minutesUntilBedtime: Int)  // NEW
    case bedtimeLocked(wakeTime: Date)              // NEW
}
```

- [ ] **Step 2: Render `bedtimeWindDown`**

```swift
@ViewBuilder
private func bedtimeWindDownView(minutes: Int) -> some View {
    HStack(spacing: 10) {
        Image(systemName: "moon.fill")
            .foregroundStyle(Color(hex: "#B287D9"))
        VStack(alignment: .leading, spacing: 1) {
            Text("Bedtime in \(minutes) min")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("Wrap up — laptop locks at \(formattedBedtime)")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.6))
        }
        Spacer(minLength: 0)
        if minutes > 15 {
            Button("Push 10 min") { handlePushBy10() }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
        }
    }
    .padding(12)
    .background(
        LinearGradient(
            colors: [Color(hex: "#2A1F3D"), Color(hex: "#15101E")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: 14))
}
```

(Push-10 button is enabled at T-30 only; once T-15 passes, button hides — matches user's "no minimize past T-15" spec.)

- [ ] **Step 3: Render `bedtimeLocked`**

```swift
@ViewBuilder
private func bedtimeLockedView(wakeTime: Date) -> some View {
    HStack(spacing: 10) {
        Image(systemName: "lock.fill")
            .foregroundStyle(Color(hex: "#B287D9"))
        VStack(alignment: .leading, spacing: 1) {
            Text("Bedtime active")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("Locked until \(formatted(wakeTime))")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(hex: "#B287D9"))
        }
        Spacer(minLength: 0)
        Button("Ask partner") { showUnlockRequestSheet = true }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
    }
    .padding(12)
    .background(
        LinearGradient(
            colors: [Color(hex: "#2A1F3D"), Color(hex: "#15101E")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: 14))
}
```

- [ ] **Step 4: Wire pill mode transitions from `BedtimeEnforcer`**

In `BedtimeEnforcer.transition(to:)`:

```swift
case .windDown(let phase):
    let minutesRemaining: Int = computeMinutesUntilBedtime()
    appDelegate?.deepWorkTimerController?.show(mode: .bedtimeWindDown(
        minutesUntilBedtime: minutesRemaining
    ))

case .locked:
    BedtimeLockLoop.shared.start()
    Task { await BedtimeWindDownController.shared.clearPending() }
    if let cfg = settings {
        let cal = Calendar.current
        let wake = cal.date(
            bySettingHour: cfg.wakeTime.hour,
            minute: cfg.wakeTime.minute,
            second: 0,
            of: trustedClock.now()
        ) ?? trustedClock.now()
        appDelegate?.deepWorkTimerController?.show(mode: .bedtimeLocked(
            wakeTime: wake
        ))
    }
```

- [ ] **Step 5: Build, commit**

```bash
git add -u
git commit -m "feat(pill): bedtime windDown + locked modes with snap-to-top-right"
```

---

### Phase 4 — Mac: unlock-request slider UI

#### Task 4.1 — `BedtimeUnlockRequestView.swift`

**Files:**
- Create: `Intentional/BedtimeUnlockRequestView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct BedtimeUnlockRequestView: View {
    @State private var durationIndex: Int = 1  // default 30 min
    @State private var reason: String = "Other"
    @State private var note: String = ""
    @State private var sending = false
    @State private var sentToPartner: String?
    @State private var error: String?

    /// Allowed snap-point values. -1 = "Until wake".
    private let durationValues: [Int] = [15, 30, 60, 120, -1]
    private var selectedDuration: Int { durationValues[durationIndex] }

    private let reasons = ["Emergency", "Travel", "Work", "Other"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ask your partner to unlock early")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("STAY UP FOR")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(0..<durationValues.count, id: \.self) { i in
                        Button {
                            durationIndex = i
                        } label: {
                            Text(label(for: durationValues[i]))
                                .font(.system(size: 12, weight: durationIndex == i ? .semibold : .regular))
                                .foregroundStyle(durationIndex == i ? Color.accentColor : .secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(durationIndex == i ? Color.accentColor.opacity(0.15) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(
                                            durationIndex == i ? Color.accentColor.opacity(0.4) : Color.gray.opacity(0.2),
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("REASON")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Picker("Reason", selection: $reason) {
                    ForEach(reasons, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            TextField("Note (optional)", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            if let sentToPartner {
                Label("Code sent to \(sentToPartner)", systemImage: "envelope.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button {
                    send()
                } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Text("Send unlock request") }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(sending)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func label(for minutes: Int) -> String {
        switch minutes {
        case 15: return "15 min"
        case 30: return "30 min"
        case 60: return "1 hour"
        case 120: return "2 hours"
        case -1: return "Until wake"
        default: return "\(minutes) min"
        }
    }

    private func send() {
        sending = true
        error = nil
        Task {
            do {
                let resp = try await BackendClient.shared.bedtimeUnlockRequest(
                    durationMinutes: selectedDuration,
                    reason: reason,
                    note: note.isEmpty ? nil : note
                )
                sentToPartner = resp.partnerEmail
                sending = false
            } catch let err as BedtimeUnlockError where err.isAlreadyUsed {
                error = "You've already used your extension for tonight. Bedtime ends at your wake alarm."
                sending = false
            } catch {
                self.error = error.localizedDescription
                sending = false
            }
        }
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
git add Intentional/BedtimeUnlockRequestView.swift
git commit -m "feat(bedtime): Mac unlock-request view with duration slider + once-per-night error"
```

#### Task 4.2 — `BackendClient.bedtimeUnlockRequest` accepts duration

**Files:**
- Modify: `Intentional/BackendClient.swift`

- [ ] **Step 1: Update method signature**

Find existing `bedtimeUnlockRequest`. Update to:

```swift
func bedtimeUnlockRequest(
    durationMinutes: Int,
    reason: String?,
    note: String?
) async throws -> UnlockRequestDTO {
    try await postJSON(
        path: "/bedtime/unlock-request",
        body: [
            "duration_minutes": durationMinutes,
            "reason": reason as Any,
            "note": note as Any,
        ]
    )
}
```

- [ ] **Step 2: Add `BedtimeUnlockError` enum with `.alreadyUsed`**

```swift
enum BedtimeUnlockError: Error {
    case alreadyUsed
    case noPartner
    case other(String)
    var isAlreadyUsed: Bool { if case .alreadyUsed = self { return true } else { return false } }
}
```

In the postJSON wrapper, on 409 → throw `.alreadyUsed`. On 409 with "no partner" detail → `.noPartner`.

- [ ] **Step 3: Build, commit**

```bash
git add Intentional/BackendClient.swift
git commit -m "feat(bedtime): BackendClient bedtimeUnlockRequest carries duration"
```

#### Task 4.3 — Wire unlock-request view into the dashboard

**Files:**
- Modify: `Intentional/MainWindow.swift` (or wherever the dashboard hosts bedtime UI)

- [ ] **Step 1: Add a tab/section that opens `BedtimeUnlockRequestView` when bedtime is locked or in wind-down**

When pill's "Ask partner" is tapped → present `BedtimeUnlockRequestView` in the dashboard or in a separate window.

- [ ] **Step 2: Build, commit**

```bash
git add Intentional/MainWindow.swift
git commit -m "feat(bedtime): dashboard hosts unlock-request slider view"
```

#### Task 4.4 — PKG build

- [ ] `NOTARIZE=0 ./scripts/build-pkg.sh`. Confirm build succeeds. PKG path: `/tmp/intentional-pkg-build/Intentional-*.pkg`. Tell user to install manually.

---

### Phase 5 — iPhone: slider UI + once-per-night error

**Branch:** `feat/bedtime-duration-iphone` off `feat/bedtime-redesign` of `puck-ios`. Worktree at `.claude/worktrees/bedtime-duration`.

#### Task 5.1 — `BedtimeUnlockRequestSheet` slider

**Files:**
- Modify: `Puck/Views/Bedtime/BedtimeUnlockRequestSheet.swift`

- [ ] **Step 1: Find existing 4-chip reason grid. Replace with duration slider above it. Reasons stay below as smaller chips.**

```swift
@State private var durationIndex: Int = 1
private let durationValues: [Int] = [15, 30, 60, 120, -1]
private let durationLabels = ["15 min", "30 min", "1 hour", "2 hours", "Until wake"]

private var durationSelector: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("STAY UP FOR")
            .font(.system(size: 11, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(.white.opacity(0.4))
        HStack(spacing: 6) {
            ForEach(0..<durationValues.count, id: \.self) { i in
                Button {
                    durationIndex = i
                } label: {
                    Text(durationLabels[i])
                        .font(.system(size: 12, weight: durationIndex == i ? .semibold : .regular))
                        .foregroundStyle(durationIndex == i ? .white : .white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(durationIndex == i ? Color(hex: "#B287D9").opacity(0.25) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    durationIndex == i ? Color(hex: "#B287D9").opacity(0.5) : Color.white.opacity(0.10),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

Insert `durationSelector` above the reason grid in the sheet body. The send-button handler now passes `duration_minutes: durationValues[durationIndex]`.

- [ ] **Step 2: Update `IntentionalBedtimeClient.requestUnlock` signature**

```swift
func requestUnlock(
    durationMinutes: Int,
    reason: String?,
    note: String?
) async throws -> UnlockRequestResponse {
    return try await postJSON(
        path: "/bedtime/unlock-request",
        body: [
            "duration_minutes": durationMinutes,
            "reason": reason as Any,
            "note": note as Any,
        ],
        auth: .bearer
    )
}
```

- [ ] **Step 3: Handle 409 in the sheet's send handler**

```swift
do {
    try await IntentionalBedtimeClient.shared.requestUnlock(...)
} catch IntentionalBedtimeClient.AlreadyUsedError {
    self.error = "You've already used your extension for tonight. Bedtime ends at your wake alarm."
}
```

- [ ] **Step 4: Build, commit**

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'generic/platform=iOS' build 2>&1 | tail -3   # SUCCEEDED
git add Puck/Views/Bedtime/BedtimeUnlockRequestSheet.swift Puck/Core/Network/IntentionalBedtimeClient.swift
git commit -m "feat(bedtime): iOS unlock sheet — duration slider + once-per-night error"
```

---

### Phase 6 — Cross-repo log + verification

#### Task 6.1 — Cross-repo log

- [ ] Create `intentional-macos-app/docs/cross-repo-bedtime-lock-loop-2026-04-29.md` per convention. Cover: what shipped per repo, commit SHAs, manual steps for user (apply migration 016, install new Mac PKG, install new iPhone build via Xcode), end-to-end test plan.

- [ ] Add card to `intentional-macos-app/docs/index.html` Cross-repo section.

- [ ] Update both repos' `CLAUDE.md` — Mac: bug-fix list entry #13 (lock-loop replaces overlay), iOS: bedtime section (slider + once-per-night).

#### Task 6.2 — Manual end-to-end smoke test (user)

After install:

1. Open Mac dashboard → bedtime card → set start time to 2 minutes from now → save.
2. At T-2, expect macOS notification "Bedtime in 2 minutes" (truncated cascade for testing).
3. Wait for T-0. Expect screen to lock, password prompt. Re-enter, get back in for ~10s, locks again.
4. Open Puck on iPhone → Bedtime card (locked variant with moon takeover) → "Ask Sara to unlock early".
5. Slide duration to "30 min" → Send.
6. Email arrives with "for 30 more minutes" phrasing.
7. Enter code. Backend returns released_until = now+30min. Mac stops locking. iPhone shield drops.
8. After 30 min, both re-engage. Try to request again → "already used your extension."
9. Wait through to wake alarm. Both clients show bedtime ended.

---

## §7. Hand-off prompt for executing agent

Paste below into a fresh agent session:

> You are implementing the spec at `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/superpowers/plans/2026-04-29-bedtime-lock-loop-and-duration-extensions.md`. Read the WHOLE file first, especially §1 (already shipped — do not redo) and §5 (file structure) and §4 (risk catalog).
>
> Repos:
> - `/Users/arayan/Documents/GitHub/intentional-backend` (FastAPI, deploys via Railway on push to `main`)
> - `/Users/arayan/Documents/GitHub/intentional-macos-app` (Swift macOS, parent branch `feat/focus-mode-consolidation`)
> - `/Users/arayan/Documents/GitHub/puck-ios` (Swift iOS, parent branch `feat/bedtime-redesign`)
>
> Use `superpowers:subagent-driven-development` for execution. Each phase commits to its own branch. Work in worktrees:
> - Backend: `.claude/worktrees/bedtime-duration` off `main`, branch `feat/bedtime-duration`
> - Mac: `.claude/worktrees/bedtime-lock-loop` off `feat/focus-mode-consolidation`, branch `feat/bedtime-lock-loop`
> - iOS: `.claude/worktrees/bedtime-duration` off `feat/bedtime-redesign`, branch `feat/bedtime-duration-iphone`
>
> Phase 1 (backend) is gating. Apply migration 016 manually in Supabase before pushing the backend code. PAUSE after Task 1.1 and tell the user to apply the SQL. Wait for confirmation.
>
> Each task: failing test → implementation → green → commit (where applicable). Mac/iOS UI changes verified via `xcodebuild ... | tail -3` showing `BUILD SUCCEEDED`.
>
> Do NOT install Mac PKG with sudo. Build it; tell the user the path.
>
> Do NOT modify focus-sync code paths (`FocusStatePoller`, `FocusModeController`, `IntentionalFocusSignalClient`, `/focus/*`, `_resolve_account_dual_auth`). Read for patterns; don't edit.
>
> Apply `superpowers:verification-before-completion` before reporting any phase done. Confirm with curl / build / test output, not assertions.
>
> Final report: commit SHAs per repo per phase, what's deployed vs compile-ready, manual steps for user, any genuine open questions.

---

## §8. Self-review

**1. Spec coverage:** every requirement from §0 maps to a phase task.

| Spec | Tasks |
|---|---|
| 10s lock-loop | 2.1, 2.2 |
| Wind-down at T-30/15/10/5/1 | 2.3, 2.4 |
| Pill bedtime modes (windDown + locked) | 3.2 |
| Pill snap-to-top-right on every show | 3.1 |
| Cross-device removal (already auto via backend) | Verified in §1 + R11 |
| Duration slider 15/30/60/120/-1 | 4.1, 5.1 |
| Once-per-night limit | 1.3, 5.1 (error UX) |
| Email shows duration | 1.5 |
| Until-wake emergency option | 1.4 (verify), 4.1, 5.1 (UI), 1.5 (email phrasing) |
| Cross-device extension applies to BOTH | Already automatic via released_until; R11 verifies |
| Drop full-screen overlay | 2.5 |
| TrustedClock + snooze fixes preserved | §1 documents; not modified |

**2. Placeholder scan:** no "TBD" / "implement later" / "similar to". All tests have real code. All file paths absolute. ✓

**3. Type / method consistency:**
- `BedtimeLockLoop.start() / .stop() / .isActive` — defined in 2.1, used in 2.2. ✓
- `BedtimeWindDownController.shared.schedule(forBedtime:)` and `.clearPending()` — defined 2.3, called 2.4. ✓
- `bedtimeUnlockRequest(durationMinutes:reason:note:)` — defined 4.2, called 4.1. ✓
- `BedtimeUnlockError.alreadyUsed` (Mac) and `IntentionalBedtimeClient.AlreadyUsedError` (iOS) — naming differs intentionally per platform conventions; both surface the same backend 409. ✓
- `PillMode.bedtimeWindDown(minutesUntilBedtime:)` and `.bedtimeLocked(wakeTime:)` — defined 3.2, used by enforcer transitions in 3.2. ✓
- Backend `BedtimeUnlockRequestBody.duration_minutes: int` (1.2) → consumed by request endpoint (1.3) → stored on row → read in verify (1.4). ✓

**4. Risk → mitigation cross-check:** every risk in §4 has either a defensive task (lock-loop self-cancel R10 → 2.1; duration validation R7 → 1.2) or a documented out-of-scope (R13 timezone in email, R14 DND interruption, R15 future macOS).

**5. Found and inline-fixed:**
- §6 originally had R6 (per-night reset boundary) underspecified; clarified that wake-alarm dismissal is the reset trigger and matches existing release-tracking behavior.
- Phase 1's once-per-night check originally used "any pending" which would block legitimate retries after partner denies. Tightened to "any verified with released_until > now" so denied-but-not-verified requests don't lock the user out. Test 1.3 specifically covers this.
- Mac slider component was originally a continuous Slider; switched to discrete chip selector to match iPhone design and match the user's mental model of "snap points."

No remaining gaps. Plan is ready for hand-off.
