# Spec 2 — Backend Implementation Plan (Plan A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Add a single weekly recurring synced schedule on the backend. Time Blocks reference Intentions optionally; backend cron-fires Sessions at block start time and ends them at block end time. Reuses Spec 1's `_create_focus_session` machinery + APNs broadcast — no new push paths.

**Architecture:** Migration 019 renames `schedule_blocks` → `time_blocks`, adds `intention_id` (nullable FK→intentions), `intensity` enum, `updated_at` trigger. New `time_block_id` column on `focus_sessions` so the scheduler can match end-events back to blocks. Endpoints: `GET/PUT /time_blocks`. Old `/schedule/blocks` paths return 301 to new ones for one release cycle. Cron loop in `time_block_scheduler.py` runs in a FastAPI startup-event background task — ticks every 60s, scans for blocks-firing-now (per account), creates Sessions via `_create_focus_session`. Same loop ends Sessions whose `time_block_id`'s end-time has passed.

**Tech Stack:** FastAPI (Python 3.9+), Supabase PostgreSQL, asyncio (no new dependencies — avoid `apscheduler`).

**Worktree:** `/Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/time-blocks-spec2` on branch `feat/time-blocks-spec2` from `main`.

**Spec 1 dependency:** This plan REQUIRES Spec 1's `intentions` table + `focus_sessions.intention_id` column to exist in production before merging. Plan A of Spec 1 ships those. The migration in this plan REFERENCES `intentions(id)` as a foreign key.

**Spec reference:** `docs/superpowers/specs/2026-05-04-time-blocks-spec2-handoff.md` (handoff brief; pinned product decisions there are non-negotiable).

**Cross-repo log:** `docs/cross-repo-time-blocks-spec2-2026-05-04.md` (write a NEW log; don't reuse Spec 1's overnight log).

---

## File map

| File | Op | Purpose |
|---|---|---|
| `migrations/019_time_blocks.sql` | CREATE | Rename `schedule_blocks` → `time_blocks`; add `intention_id`, `intensity`, `updated_at`; add `focus_sessions.time_block_id` |
| `models.py` | MODIFY | Rename `ScheduleBlock*` → `TimeBlock*`; add `intention_id`, `intensity` to request/response |
| `main.py` | MODIFY | Add `GET/PUT /time_blocks`; keep `/schedule/blocks` as 301 redirects (for one release cycle); register cron task in startup event; add `_create_focus_session` helper extraction |
| `time_block_scheduler.py` | CREATE | The 60s tick scanner; idempotent firing keyed on `(time_block_id, date)` |
| `tests/test_time_blocks.py` | CREATE | CRUD endpoint tests (mirrors `tests/test_intentions.py`) |
| `tests/test_time_block_scheduler.py` | CREATE | Scanner unit tests + idempotency |
| `tests/test_schedule_blocks_redirects.py` | CREATE | 301 redirect tests for one-release-cycle compat |

---

## Task 0: Worktree setup

**Files:** none (git ops)

- [ ] **Step 0.1:** Create worktree

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
mkdir -p .claude/worktrees
git worktree add -b feat/time-blocks-spec2 .claude/worktrees/time-blocks-spec2 main
cd .claude/worktrees/time-blocks-spec2
```

- [ ] **Step 0.2:** Empty initial commit

```bash
git commit --allow-empty -m "spec2(time-blocks): start backend implementation

Per spec docs/superpowers/specs/2026-05-04-time-blocks-spec2-handoff.md
and plan docs/superpowers/plans/2026-05-04-time-blocks-spec2-plan-a-backend.md
in the intentional-macos-app repo. Depends on Spec 1 backend (intentions table)."
```

---

## Task 1: Migration 019 — `time_blocks` table

**Files:**
- Create: `migrations/019_time_blocks.sql`

- [ ] **Step 1.1:** Write migration

```sql
-- 019_time_blocks.sql
-- Spec 2: Synced recurring weekly schedule. Time Blocks are
-- account-scoped, optionally bound to an Intention.
--
-- Renames schedule_blocks → time_blocks (vocabulary alignment with locked
-- vocab Intention/Time Block/Session/Goal). Adds intention_id (nullable),
-- intensity enum, updated_at trigger. Adds focus_sessions.time_block_id
-- so the cron scanner can match Session end-events back to blocks.

-- Rename
ALTER TABLE IF EXISTS schedule_blocks RENAME TO time_blocks;

-- Add columns. intention_id is NULLABLE — generic blocks (no Intention) work.
ALTER TABLE time_blocks
    ADD COLUMN IF NOT EXISTS intention_id UUID REFERENCES intentions(id) ON DELETE SET NULL;

ALTER TABLE time_blocks
    ADD COLUMN IF NOT EXISTS intensity TEXT NOT NULL DEFAULT 'deep_work'
    CHECK (intensity IN ('deep_work', 'focus_hours'));

ALTER TABLE time_blocks
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Auto-bump updated_at trigger (mirrors bedtime_config + intentions pattern)
CREATE OR REPLACE FUNCTION time_blocks_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS time_blocks_touch_updated_at ON time_blocks;
CREATE TRIGGER time_blocks_touch_updated_at
    BEFORE UPDATE ON time_blocks
    FOR EACH ROW EXECUTE FUNCTION time_blocks_touch_updated_at();

-- Indexes
CREATE INDEX IF NOT EXISTS time_blocks_account_active_idx
    ON time_blocks(account_id) WHERE enabled = TRUE;
CREATE INDEX IF NOT EXISTS time_blocks_intention_idx
    ON time_blocks(intention_id) WHERE intention_id IS NOT NULL;

-- focus_sessions.time_block_id — set when the cron scheduler creates a session.
ALTER TABLE focus_sessions
    ADD COLUMN IF NOT EXISTS time_block_id UUID
    REFERENCES time_blocks(block_id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS focus_sessions_time_block_idx
    ON focus_sessions(time_block_id) WHERE time_block_id IS NOT NULL;
```

NOTE: column name in `time_blocks` for the PK is `block_id` (carried over from `schedule_blocks`). The FK on `focus_sessions.time_block_id` references `time_blocks(block_id)` — verify by checking 017_schedule_blocks.sql.

- [ ] **Step 1.2:** Commit

```bash
git add migrations/019_time_blocks.sql
git commit -m "feat(time-blocks): migration 019 — rename schedule_blocks → time_blocks + intention_id + intensity"
```

---

## Task 2: Pydantic models

**Files:**
- Modify: `models.py`

- [ ] **Step 2.1:** Find existing `ScheduleBlock*` classes

```bash
grep -n "ScheduleBlock\|schedule_block" models.py | head -20
```

- [ ] **Step 2.2:** Add Time Block models (alongside existing for one release cycle)

Append to `models.py`:

```python
# ==================== Time Blocks (Spec 2) ====================

TimeBlockIntensity = str  # "deep_work" | "focus_hours"

class TimeBlockDTO(BaseModel):
    """Single time block payload — used in PUT /time_blocks body and GET responses."""
    block_id: str
    title: str
    block_type: str  # legacy: kept identical to existing schedule_blocks for one cycle
    intention_id: Optional[str] = None
    intensity: str = "deep_work"  # NEW: deep_work | focus_hours
    start_hour: int = Field(..., ge=0, le=23)
    start_minute: int = Field(..., ge=0, le=59)
    end_hour: int = Field(..., ge=0, le=23)
    end_minute: int = Field(..., ge=0, le=59)
    active_days: list[int] = Field(default_factory=lambda: [1, 2, 3, 4, 5, 6, 7])
    enabled: bool = True
    updated_at: Optional[str] = None


class TimeBlocksRequest(BaseModel):
    blocks: list[TimeBlockDTO] = Field(default_factory=list, max_length=50)


class TimeBlocksResponse(BaseModel):
    blocks: list[TimeBlockDTO]
```

- [ ] **Step 2.3:** Sanity import

```bash
python3 -c "from models import TimeBlockDTO, TimeBlocksRequest, TimeBlocksResponse; print('OK')"
```

- [ ] **Step 2.4:** Commit

```bash
git add models.py
git commit -m "feat(time-blocks): pydantic models (TimeBlockDTO, TimeBlocksRequest/Response)"
```

---

## Task 3: `GET /time_blocks` endpoint (TDD)

**Files:**
- Create: `tests/test_time_blocks.py`
- Modify: `main.py`

- [ ] **Step 3.1:** Write failing tests

```python
# tests/test_time_blocks.py
"""Integration tests for /time_blocks GET + PUT endpoints."""
import os
from datetime import datetime, timedelta, timezone
from unittest.mock import patch, MagicMock

import jwt

os.environ.setdefault("JWT_SECRET", "test-intentional-secret")
os.environ.setdefault("SUPABASE_JWT_SECRET", "test-supabase-secret")

from fastapi.testclient import TestClient  # noqa
from tests.test_intentions import _FakeDB, _supabase_jwt, _client


def test_get_time_blocks_returns_empty_for_new_account():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1", "email": "u@e.com"}]
    fake_db = _FakeDB(accounts=accounts, time_blocks=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/time_blocks",
            headers={"Authorization": f"Bearer {_supabase_jwt(email='u@e.com', sub='sb-sub-1')}"})
    assert r.status_code == 200, r.text
    assert r.json() == {"blocks": []}


def test_get_time_blocks_returns_only_owned_account_blocks():
    accounts = [{"id": "acct-mine", "supabase_user_id": "sb-mine", "email": "u@e.com"}]
    time_blocks = [
        {"block_id": "tb-1", "account_id": "acct-mine", "title": "Coding",
         "block_type": "deep_work", "intention_id": None, "intensity": "deep_work",
         "start_hour": 9, "start_minute": 0, "end_hour": 11, "end_minute": 0,
         "active_days": [1, 2, 3, 4, 5], "enabled": True,
         "updated_at": "2026-05-04T00:00:00+00:00"},
        {"block_id": "tb-other", "account_id": "acct-other", "title": "Spy",
         "block_type": "focus_hours", "intention_id": None, "intensity": "focus_hours",
         "start_hour": 9, "start_minute": 0, "end_hour": 10, "end_minute": 0,
         "active_days": [1], "enabled": True,
         "updated_at": "2026-05-04T00:00:00+00:00"},
    ]
    fake_db = _FakeDB(accounts=accounts, time_blocks=time_blocks)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/time_blocks",
            headers={"Authorization": f"Bearer {_supabase_jwt(email='u@e.com', sub='sb-mine')}"})
    assert r.status_code == 200
    body = r.json()
    titles = [b["title"] for b in body["blocks"]]
    assert titles == ["Coding"]


def test_get_time_blocks_includes_intention_id_when_set():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1", "email": "u@e.com"}]
    time_blocks = [
        {"block_id": "tb-coding", "account_id": "acct-1", "title": "Coding",
         "block_type": "deep_work", "intention_id": "intent-coding", "intensity": "deep_work",
         "start_hour": 9, "start_minute": 0, "end_hour": 11, "end_minute": 0,
         "active_days": [1, 2, 3, 4, 5], "enabled": True,
         "updated_at": "2026-05-04T00:00:00+00:00"},
    ]
    fake_db = _FakeDB(accounts=accounts, time_blocks=time_blocks)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/time_blocks",
            headers={"Authorization": f"Bearer {_supabase_jwt(email='u@e.com', sub='sb-1')}"})
    assert r.status_code == 200
    blocks = r.json()["blocks"]
    assert blocks[0]["intention_id"] == "intent-coding"
    assert blocks[0]["intensity"] == "deep_work"
```

- [ ] **Step 3.2:** Run — fail

```bash
pytest tests/test_time_blocks.py::test_get_time_blocks_returns_empty_for_new_account -v
```

- [ ] **Step 3.3:** Implement endpoint in main.py

Find the existing `/schedule/blocks` GET endpoint (around line 3271) and below it, add:

```python
# ==================== Time Blocks (Spec 2) ====================

def _row_to_time_block(row: dict) -> TimeBlockDTO:
    return TimeBlockDTO(
        block_id=str(row["block_id"]),
        title=row["title"],
        block_type=row.get("block_type", "deep_work"),
        intention_id=row.get("intention_id"),
        intensity=row.get("intensity", "deep_work"),
        start_hour=row["start_hour"], start_minute=row["start_minute"],
        end_hour=row["end_hour"], end_minute=row["end_minute"],
        active_days=row.get("active_days") or [1, 2, 3, 4, 5, 6, 7],
        enabled=row.get("enabled", True),
        updated_at=row.get("updated_at"),
    )


@app.get("/time_blocks", response_model=TimeBlocksResponse)
async def list_time_blocks(
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """List all Time Blocks for the authenticated account (live + disabled both returned)."""
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    rows = db.table("time_blocks").select("*").eq(
        "account_id", account_id
    ).order("start_hour", desc=False).execute().data or []
    return TimeBlocksResponse(blocks=[_row_to_time_block(r) for r in rows])
```

Add the import:
```python
from models import (
    # ... existing imports ...
    TimeBlockDTO, TimeBlocksRequest, TimeBlocksResponse,
)
```

- [ ] **Step 3.4:** Run — pass

```bash
pytest tests/test_time_blocks.py -v
```

- [ ] **Step 3.5:** Commit

```bash
git add main.py tests/test_time_blocks.py
git commit -m "feat(time-blocks): GET /time_blocks (account-scoped, includes intention_id)"
```

---

## Task 4: `PUT /time_blocks` atomic-replace (TDD)

**Files:**
- Modify: `tests/test_time_blocks.py`, `main.py`

- [ ] **Step 4.1:** Write failing tests

```python
def test_put_time_blocks_replaces_all_for_account():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1", "email": "u@e.com"}]
    time_blocks = [
        {"block_id": "tb-old", "account_id": "acct-1", "title": "Old",
         "block_type": "deep_work", "intention_id": None, "intensity": "deep_work",
         "start_hour": 9, "start_minute": 0, "end_hour": 11, "end_minute": 0,
         "active_days": [1, 2, 3], "enabled": True,
         "updated_at": "2026-05-04T00:00:00+00:00"},
    ]
    fake_db = _FakeDB(accounts=accounts, time_blocks=time_blocks)
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/time_blocks",
            json={"blocks": [
                {"block_id": "tb-new-1", "title": "Coding", "block_type": "deep_work",
                 "intention_id": "intent-coding", "intensity": "deep_work",
                 "start_hour": 9, "start_minute": 0, "end_hour": 11, "end_minute": 0,
                 "active_days": [1, 2, 3, 4, 5], "enabled": True},
                {"block_id": "tb-new-2", "title": "Reading", "block_type": "focus_hours",
                 "intention_id": None, "intensity": "focus_hours",
                 "start_hour": 11, "start_minute": 0, "end_hour": 12, "end_minute": 0,
                 "active_days": [1, 2, 3, 4, 5], "enabled": True},
            ]},
            headers={"Authorization": f"Bearer {_supabase_jwt(email='u@e.com', sub='sb-1')}"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    titles = [b["title"] for b in body["blocks"]]
    assert "Coding" in titles
    assert "Reading" in titles
    assert "Old" not in titles


def test_put_time_blocks_validates_active_days_range():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1", "email": "u@e.com"}]
    fake_db = _FakeDB(accounts=accounts, time_blocks=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/time_blocks",
            json={"blocks": [
                {"block_id": "tb-1", "title": "Bad", "block_type": "deep_work",
                 "start_hour": 9, "start_minute": 0, "end_hour": 11, "end_minute": 0,
                 "active_days": [0, 1, 2, 8],  # 0 and 8 invalid
                 "enabled": True},
            ]},
            headers={"Authorization": f"Bearer {_supabase_jwt(email='u@e.com', sub='sb-1')}"},
        )
    assert r.status_code == 400
```

- [ ] **Step 4.2:** Run — fail

- [ ] **Step 4.3:** Implement endpoint

Add to main.py after `list_time_blocks`:

```python
@app.put("/time_blocks", response_model=TimeBlocksResponse)
async def replace_time_blocks(
    request: TimeBlocksRequest,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """Atomic replace: deletes all existing Time Blocks for the account,
    then inserts the new set. Validates active_days range."""
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)

    # Validate
    for b in request.blocks:
        for d in b.active_days:
            if d < 1 or d > 7:
                raise HTTPException(status_code=400,
                    detail=f"active_days must contain ISO 1..7; got {d} on block {b.block_id}")
        # Reject zero-length / negative blocks
        start = b.start_hour * 60 + b.start_minute
        end = b.end_hour * 60 + b.end_minute
        if end <= start:
            raise HTTPException(status_code=400,
                detail=f"Block {b.block_id}: end_time must be after start_time")

    db = get_db()
    # Delete old + insert new in one logical transaction.
    db.table("time_blocks").delete().eq("account_id", account_id).execute()
    if request.blocks:
        rows_to_insert = []
        for b in request.blocks:
            rows_to_insert.append({
                "block_id": b.block_id,
                "account_id": account_id,
                "title": b.title,
                "block_type": b.block_type,
                "intention_id": b.intention_id,
                "intensity": b.intensity,
                "start_hour": b.start_hour, "start_minute": b.start_minute,
                "end_hour": b.end_hour, "end_minute": b.end_minute,
                "active_days": b.active_days,
                "enabled": b.enabled,
            })
        db.table("time_blocks").insert(rows_to_insert).execute()

    rows = db.table("time_blocks").select("*").eq(
        "account_id", account_id
    ).order("start_hour", desc=False).execute().data or []
    return TimeBlocksResponse(blocks=[_row_to_time_block(r) for r in rows])
```

- [ ] **Step 4.4:** Run — pass

- [ ] **Step 4.5:** Commit

```bash
git add main.py tests/test_time_blocks.py
git commit -m "feat(time-blocks): PUT /time_blocks (atomic replace, validates active_days + non-zero duration)"
```

---

## Task 5: 301 redirects from `/schedule/blocks` → `/time_blocks` (one release cycle)

**Files:**
- Create: `tests/test_schedule_blocks_redirects.py`
- Modify: `main.py`

- [ ] **Step 5.1:** Write tests

```python
# tests/test_schedule_blocks_redirects.py
import os
os.environ.setdefault("JWT_SECRET", "test-intentional-secret")
os.environ.setdefault("SUPABASE_JWT_SECRET", "test-supabase-secret")

from fastapi.testclient import TestClient
from tests.test_intentions import _client


def test_get_schedule_blocks_redirects_to_time_blocks():
    r = _client().get("/schedule/blocks", follow_redirects=False)
    # Either 301 or 308. The auth check may also fire first; allow 401 with a Location header.
    assert r.status_code in (301, 308) or "location" in {k.lower() for k in r.headers.keys()}
    if r.status_code in (301, 308):
        assert r.headers["location"].endswith("/time_blocks")


def test_put_schedule_blocks_redirects_to_time_blocks():
    r = _client().put("/schedule/blocks", json={"blocks": []}, follow_redirects=False)
    assert r.status_code in (301, 308) or "location" in {k.lower() for k in r.headers.keys()}
    if r.status_code in (301, 308):
        assert r.headers["location"].endswith("/time_blocks")
```

- [ ] **Step 5.2:** Replace existing `/schedule/blocks` handlers with redirects

Find the existing `@app.get("/schedule/blocks", ...)` and `@app.put("/schedule/blocks", ...)` (around line 3271 and 3302). REPLACE both endpoints with:

```python
from fastapi.responses import RedirectResponse


@app.get("/schedule/blocks", deprecated=True)
async def get_schedule_blocks_redirect():
    """Deprecated — use /time_blocks. 301 for one release cycle."""
    return RedirectResponse(url="/time_blocks", status_code=301)


@app.put("/schedule/blocks", deprecated=True)
async def put_schedule_blocks_redirect():
    """Deprecated — use PUT /time_blocks. 301 for one release cycle."""
    return RedirectResponse(url="/time_blocks", status_code=301)
```

- [ ] **Step 5.3:** Run

```bash
pytest tests/test_schedule_blocks_redirects.py tests/test_time_blocks.py -v
```

- [ ] **Step 5.4:** Commit

```bash
git add main.py tests/test_schedule_blocks_redirects.py
git commit -m "feat(time-blocks): /schedule/blocks → /time_blocks 301 redirects (one release cycle)"
```

---

## Task 6: Extract `_create_focus_session` helper from `/focus/toggle`

**Files:**
- Modify: `main.py`

This helper will be reused by the cron scheduler in Task 8. Extract without changing existing /focus/toggle behavior.

- [ ] **Step 6.1:** Write the helper

Find the start branch of `toggle_focus` (around line 3094). Above it, add:

```python
async def _create_focus_session(
    db,
    account_id: str,
    intention_id: Optional[str] = None,
    triggered_by: str = "puck",
    time_block_id: Optional[str] = None,
) -> Optional[str]:
    """Internal helper: end any active session, insert a new one, fire APNs.
    Returns the new session_id (or None on insert failure)."""
    now = datetime.now(timezone.utc)
    # End existing active sessions
    db.table("focus_sessions").update({
        "status": "ended", "ended_at": now.isoformat()
    }).eq("account_id", account_id).eq("status", "active").execute()
    # Insert new
    expires_at = now + timedelta(hours=FOCUS_SESSION_TTL_HOURS)
    payload = {
        "account_id": account_id,
        "started_at": now.isoformat(),
        "triggered_by": triggered_by,
        "status": "active",
        "expires_at": expires_at.isoformat(),
        "intention_id": intention_id,
    }
    if time_block_id is not None:
        payload["time_block_id"] = time_block_id
    result = db.table("focus_sessions").insert(payload).execute()
    if not result.data:
        return None
    session_id = str(result.data[0]["id"])
    # APNs push to peer iOS devices
    try:
        await send_push_to_account(
            db, account_id,
            payload={
                "aps": {"content-available": 1},
                "session_id": session_id,
                "intention_id": intention_id,
                "started_at": now.isoformat(),
                "action": "start",
                "triggered_by": triggered_by,
            },
            priority=10, push_type="background",
        )
    except Exception as exc:
        logging.getLogger(__name__).warning("APNs push failed in _create_focus_session: %s", exc)
    return session_id


async def _end_focus_session(
    db,
    session_id: str,
    account_id: str,
    triggered_by: str = "schedule_ended",
) -> None:
    """Internal helper: mark a session ended + fire APNs stop."""
    now = datetime.now(timezone.utc)
    # Look up intention_id for the push payload
    existing = db.table("focus_sessions").select("intention_id").eq("id", session_id).limit(1).execute().data
    intention_id = existing[0].get("intention_id") if existing else None

    db.table("focus_sessions").update({
        "status": "ended", "ended_at": now.isoformat()
    }).eq("id", session_id).execute()
    try:
        await send_push_to_account(
            db, account_id,
            payload={
                "aps": {"content-available": 1},
                "session_id": session_id,
                "intention_id": intention_id,
                "action": "stop",
                "triggered_by": triggered_by,
            },
            priority=10, push_type="background",
        )
    except Exception as exc:
        logging.getLogger(__name__).warning("APNs push failed in _end_focus_session: %s", exc)
```

- [ ] **Step 6.2:** Refactor `toggle_focus` to use the helpers

In the start branch of `toggle_focus`, replace the inline insert + push logic with:

```python
    if request.action == "start":
        triggered_by = request.triggered_by or "puck"
        session_id = await _create_focus_session(
            db, account_id,
            intention_id=request.intention_id,
            triggered_by=triggered_by,
        )
        if session_id is None:
            raise HTTPException(status_code=500, detail="Failed to create focus session")
        # ... existing system_events log + broadcast_focus_signal stays the same ...
        return FocusToggleResponse(session_id=session_id, status="started",
                                   started_at=datetime.now(timezone.utc).isoformat(),
                                   message="Focus session started")
```

For the stop branch, similarly use `_end_focus_session`.

- [ ] **Step 6.3:** Re-run tests to confirm no regression

```bash
pytest tests/ -v
```

All Spec 1 tests should still pass.

- [ ] **Step 6.4:** Commit

```bash
git add main.py
git commit -m "refactor(focus): extract _create_focus_session + _end_focus_session helpers (reusable by Spec 2 cron)"
```

---

## Task 7: Cron scheduler module (`time_block_scheduler.py`)

**Files:**
- Create: `time_block_scheduler.py`

- [ ] **Step 7.1:** Write the module

```python
# time_block_scheduler.py
"""
Spec 2 — backend cron scanner for Time Blocks.

Tick every 60 seconds. For each account with `enabled` Time Blocks:
- Find blocks whose start_hour:start_minute matches the current minute AND
  whose active_days contains today's ISO weekday AND that haven't already
  fired today (idempotency tracked via focus_sessions.time_block_id +
  date check).
- For each match: create a focus_session via _create_focus_session.
- Find blocks whose end_hour:end_minute matches the current minute AND
  whose Session is still active. End them via _end_focus_session.

Runs as an asyncio task launched from FastAPI's startup event. No
new dependencies — uses asyncio.sleep for the tick.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone, timedelta
from typing import Optional

logger = logging.getLogger(__name__)

# Module-level flag so we can stop the loop in tests
_running = False


async def time_block_tick(db_factory) -> None:
    """One iteration of the scanner. Public for testability.

    `db_factory` is a zero-arg callable that returns a Supabase client.
    """
    from main import _create_focus_session, _end_focus_session  # late import avoids cycle

    db = db_factory()
    now = datetime.now(timezone.utc)
    iso_weekday = now.isoweekday()  # 1=Mon..7=Sun
    cur_minute_of_day = now.hour * 60 + now.minute
    today_iso = now.date().isoformat()

    # Fetch all enabled blocks active today
    rows = db.table("time_blocks").select(
        "block_id,account_id,intention_id,intensity,start_hour,start_minute,end_hour,end_minute,active_days,enabled"
    ).eq("enabled", True).execute().data or []

    blocks_active_today = [
        r for r in rows if iso_weekday in (r.get("active_days") or [])
    ]

    # === START events ===
    starting = [
        r for r in blocks_active_today
        if (r["start_hour"] * 60 + r["start_minute"]) == cur_minute_of_day
    ]
    for block in starting:
        # Idempotency: did we already fire this block on this date?
        already = db.table("focus_sessions").select("id").eq(
            "time_block_id", block["block_id"]
        ).gte("started_at", f"{today_iso}T00:00:00+00:00").limit(1).execute().data
        if already:
            continue
        try:
            session_id = await _create_focus_session(
                db, block["account_id"],
                intention_id=block.get("intention_id"),
                triggered_by="schedule",
                time_block_id=block["block_id"],
            )
            if session_id:
                logger.info("time-block fired: account=%s block=%s session=%s",
                            block["account_id"], block["block_id"], session_id)
        except Exception as exc:  # noqa: BLE001
            logger.exception("time-block start failed: %s", exc)

    # === END events ===
    ending = [
        r for r in blocks_active_today
        if (r["end_hour"] * 60 + r["end_minute"]) == cur_minute_of_day
    ]
    for block in ending:
        # Find the active session for this block
        sessions = db.table("focus_sessions").select(
            "id,account_id"
        ).eq("time_block_id", block["block_id"]).eq("status", "active").execute().data or []
        for s in sessions:
            try:
                await _end_focus_session(db, s["id"], s["account_id"],
                                         triggered_by="schedule_ended")
                logger.info("time-block ended: account=%s block=%s session=%s",
                            block["account_id"], block["block_id"], s["id"])
            except Exception as exc:  # noqa: BLE001
                logger.exception("time-block end failed: %s", exc)


async def run_scheduler_loop(db_factory) -> None:
    """Run the tick loop forever (until cancelled)."""
    global _running
    _running = True
    logger.info("Time-block scheduler loop started (60s tick)")
    try:
        while _running:
            try:
                await time_block_tick(db_factory)
            except Exception as exc:  # noqa: BLE001
                logger.exception("Time-block tick crashed: %s", exc)
            await asyncio.sleep(60.0)
    except asyncio.CancelledError:
        logger.info("Time-block scheduler loop cancelled")
        raise


def stop_loop() -> None:
    """For test cleanup."""
    global _running
    _running = False
```

- [ ] **Step 7.2:** Sanity import

```bash
python3 -c "import time_block_scheduler; print('OK')"
```

- [ ] **Step 7.3:** Commit

```bash
git add time_block_scheduler.py
git commit -m "feat(time-blocks): cron scheduler module (60s tick, idempotent fire-by-date, end events)"
```

---

## Task 8: Wire scheduler into FastAPI startup event

**Files:**
- Modify: `main.py`

- [ ] **Step 8.1:** Find existing startup event handler

```bash
grep -n "@app.on_event\|startup\|shutdown" main.py | head
```

- [ ] **Step 8.2:** Add the scheduler launcher

If there's no `@app.on_event("startup")` yet, add at top-level near other app config:

```python
import time_block_scheduler

_scheduler_task = None

@app.on_event("startup")
async def _start_time_block_scheduler():
    global _scheduler_task
    # Skip in test environments (set TESTING=1 in conftest if you want)
    if os.environ.get("TESTING") == "1":
        return
    _scheduler_task = asyncio.create_task(
        time_block_scheduler.run_scheduler_loop(get_db)
    )

@app.on_event("shutdown")
async def _stop_time_block_scheduler():
    global _scheduler_task
    if _scheduler_task and not _scheduler_task.done():
        _scheduler_task.cancel()
        try:
            await _scheduler_task
        except asyncio.CancelledError:
            pass
```

If a startup handler already exists, ADD the `asyncio.create_task` line into the existing function rather than declaring a second handler.

- [ ] **Step 8.3:** Confirm tests still pass (the TESTING=1 guard prevents the scheduler from interfering with TestClient runs)

```bash
TESTING=1 pytest tests/ -v
```

- [ ] **Step 8.4:** Commit

```bash
git add main.py
git commit -m "feat(time-blocks): launch scheduler loop on FastAPI startup (TESTING=1 guard for tests)"
```

---

## Task 9: Scheduler unit tests (idempotency + start/end matching)

**Files:**
- Create: `tests/test_time_block_scheduler.py`

- [ ] **Step 9.1:** Write tests

```python
# tests/test_time_block_scheduler.py
"""Unit tests for time_block_scheduler.time_block_tick."""
import os
import asyncio
from datetime import datetime, timezone
from unittest.mock import patch

os.environ.setdefault("JWT_SECRET", "test-intentional-secret")
os.environ.setdefault("SUPABASE_JWT_SECRET", "test-supabase-secret")
os.environ.setdefault("TESTING", "1")

from tests.test_intentions import _FakeDB

import time_block_scheduler


def test_tick_creates_session_when_block_starts_now():
    now = datetime.now(timezone.utc)
    accounts = [{"id": "acct-1"}]
    time_blocks = [{
        "block_id": "tb-1", "account_id": "acct-1", "intention_id": "intent-coding",
        "intensity": "deep_work",
        "start_hour": now.hour, "start_minute": now.minute,
        "end_hour": (now.hour + 2) % 24, "end_minute": now.minute,
        "active_days": [now.isoweekday()],
        "enabled": True,
    }]
    focus_sessions = []
    fake_db = _FakeDB(accounts=accounts, time_blocks=time_blocks,
                       focus_sessions=focus_sessions, users=[])

    async def run():
        with patch("apns_client.send_push_to_account", return_value=0):
            await time_block_scheduler.time_block_tick(lambda: fake_db)

    asyncio.run(run())
    # Should have inserted a focus_sessions row
    assert len(focus_sessions) == 1
    assert focus_sessions[0]["intention_id"] == "intent-coding"
    assert focus_sessions[0]["time_block_id"] == "tb-1"


def test_tick_does_not_double_fire_same_block_same_day():
    now = datetime.now(timezone.utc)
    accounts = [{"id": "acct-1"}]
    time_blocks = [{
        "block_id": "tb-1", "account_id": "acct-1", "intention_id": None,
        "intensity": "deep_work",
        "start_hour": now.hour, "start_minute": now.minute,
        "end_hour": (now.hour + 1) % 24, "end_minute": now.minute,
        "active_days": [now.isoweekday()],
        "enabled": True,
    }]
    # Already-fired session for this block today
    focus_sessions = [{
        "id": "sess-existing", "account_id": "acct-1", "time_block_id": "tb-1",
        "status": "active", "started_at": now.isoformat(),
        "triggered_by": "schedule",
    }]
    fake_db = _FakeDB(accounts=accounts, time_blocks=time_blocks,
                       focus_sessions=focus_sessions, users=[])

    async def run():
        with patch("apns_client.send_push_to_account", return_value=0):
            await time_block_scheduler.time_block_tick(lambda: fake_db)

    asyncio.run(run())
    # No new session — only the pre-existing one
    assert len(focus_sessions) == 1


def test_tick_does_not_fire_when_today_not_in_active_days():
    now = datetime.now(timezone.utc)
    other_day = ((now.isoweekday() % 7) + 1)  # any day != today
    accounts = [{"id": "acct-1"}]
    time_blocks = [{
        "block_id": "tb-weekend", "account_id": "acct-1", "intention_id": None,
        "intensity": "deep_work",
        "start_hour": now.hour, "start_minute": now.minute,
        "end_hour": (now.hour + 1) % 24, "end_minute": now.minute,
        "active_days": [other_day],  # NOT today
        "enabled": True,
    }]
    focus_sessions = []
    fake_db = _FakeDB(accounts=accounts, time_blocks=time_blocks,
                       focus_sessions=focus_sessions, users=[])

    async def run():
        with patch("apns_client.send_push_to_account", return_value=0):
            await time_block_scheduler.time_block_tick(lambda: fake_db)

    asyncio.run(run())
    assert len(focus_sessions) == 0
```

- [ ] **Step 9.2:** Run

```bash
pytest tests/test_time_block_scheduler.py -v
```

- [ ] **Step 9.3:** Commit

```bash
git add tests/test_time_block_scheduler.py
git commit -m "test(time-blocks): scheduler tick — start, no-double-fire, weekday filtering"
```

---

## Task 10: Generic block fallback (intention_id = NULL → use seeded "Focus" Intention)

**Files:**
- Modify: `main.py` (`_create_focus_session`)

Per spec acceptance criterion #5: generic blocks (no Intention) work using a default fallback. If `_create_focus_session` is called with `intention_id=None`, look up the seeded "Focus" Intention for the account and use its id.

- [ ] **Step 10.1:** Modify `_create_focus_session`

In `main.py`, find the helper. Just after the function signature, add:

```python
async def _create_focus_session(
    db,
    account_id: str,
    intention_id: Optional[str] = None,
    triggered_by: str = "puck",
    time_block_id: Optional[str] = None,
) -> Optional[str]:
    # Generic-block fallback: when no intention_id, try to bind to the
    # account's seeded default "Focus" Intention so iPhone has tokens to apply.
    if intention_id is None:
        try:
            seed_check = db.table("intentions").select("id").eq(
                "account_id", account_id
            ).is_("deleted_at", "null").order("created_at").limit(1).execute().data
            if seed_check:
                intention_id = seed_check[0]["id"]
        except Exception:
            pass  # Stay with NULL — backwards compat
    # ... rest of function unchanged ...
```

- [ ] **Step 10.2:** Add a test

In `tests/test_time_block_scheduler.py`:

```python
def test_tick_with_null_intention_id_falls_back_to_seeded_focus():
    now = datetime.now(timezone.utc)
    accounts = [{"id": "acct-1"}]
    intentions = [
        {"id": "intent-focus", "account_id": "acct-1", "name": "Focus",
         "deleted_at": None, "version": 1,
         "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None},
    ]
    time_blocks = [{
        "block_id": "tb-generic", "account_id": "acct-1",
        "intention_id": None,  # generic block
        "intensity": "deep_work",
        "start_hour": now.hour, "start_minute": now.minute,
        "end_hour": (now.hour + 1) % 24, "end_minute": now.minute,
        "active_days": [now.isoweekday()],
        "enabled": True,
    }]
    focus_sessions = []
    fake_db = _FakeDB(accounts=accounts, intentions=intentions,
                       time_blocks=time_blocks,
                       focus_sessions=focus_sessions, users=[])

    async def run():
        with patch("apns_client.send_push_to_account", return_value=0):
            await time_block_scheduler.time_block_tick(lambda: fake_db)

    asyncio.run(run())
    # Session should have been created and bound to the seeded Focus intention
    assert len(focus_sessions) == 1
    assert focus_sessions[0]["intention_id"] == "intent-focus"
```

- [ ] **Step 10.3:** Run + commit

```bash
pytest tests/test_time_block_scheduler.py -v
git add main.py tests/test_time_block_scheduler.py
git commit -m "feat(time-blocks): generic block fallback to seeded Focus intention"
```

---

## Task 11: Final integration + push

- [ ] **Step 11.1:** Run full test suite

```bash
pytest tests/ -v --tb=short 2>&1 | tail -25
```

Expected: all new tests pass; pre-existing failures unchanged (test_focus_active_no_session + test_partner_status_no_account_returns_none — same as Spec 1 Plan A).

- [ ] **Step 11.2:** Push

```bash
git push -u origin feat/time-blocks-spec2
```

- [ ] **Step 11.3:** Append report to cross-repo log

In `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-time-blocks-spec2-2026-05-04.md` (CREATE if missing), add a `### Phase 2 — Backend report` section with status, files changed, action required from user (apply migration 019, deploy).

---

## Out of scope (deferred)

- Effective-date / one-off blocks (only weekly recurring in this spec).
- Calendar sync with external (Google/iCal).
- Templates library.
- Per-block iOS app blocklist (uses the bound Intention's tokens; if NULL, falls back to seeded Focus).
- Automatic conflict detection on `PUT /time_blocks` (overlap allowed by current shape; backend just stores them — UI prevents overlap).

## Required env vars

None new. Reuses APNS_*, SUPABASE_*, JWT_SECRET, SUPABASE_JWT_SECRET.
