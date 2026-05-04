# Scheduled Intentions Redesign — Backend Implementation Plan (Plan A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Add the strictness preset to Intentions (instant tightening, cool-down softening, partner-locked Strict step-down). Add nullable budget-prep schema for the future weekly budgets feature (D9). Add a 60s scheduler tick that applies pending strictness changes when their time hits.

**Architecture:** Migration 020 extends `intentions` and `time_blocks` (forward-compat seeds for budgets, real strictness column for this spec). New `intention_strictness_changes` table tracks pending softening with cool-down expiry. New endpoints: PUT `/intentions/{id}/strictness` (instant for tighten / queued for soften / partner-required for from-Strict), POST `/intentions/{id}/strictness/cancel`, GET `/intentions/{id}/strictness/pending`. Cron tick reuses the existing `time_block_scheduler.py` infrastructure to apply expired pending changes.

**Tech Stack:** FastAPI, Postgres (Supabase), asyncio (no new dependencies), pytest with `_FakeDB`.

**Worktree:** `/Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/scheduled-intentions-redesign` on branch `feat/scheduled-intentions-redesign` from `main`.

**Spec 1 + 2 dependency:** Migrations 018 (intentions table) + 019 (time_blocks rename) must be applied before 020 runs. The migration's ALTER statements assume `intentions` and `time_blocks` exist.

**Spec reference:** `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md`

**Cross-repo log:** `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md`

---

## File map

| File | Op | Purpose |
|---|---|---|
| `migrations/020_strictness_and_budget_prep.sql` | CREATE | strictness_preset on intentions; nullable budget fields; intention_strictness_changes table |
| `models.py` | MODIFY | Add `strictness_preset` to Intention/IntentionCreate/IntentionUpdate; add StrictnessChangeRequest/Response/Pending |
| `main.py` | MODIFY | New endpoints + active-session check + background task hook |
| `intention_strictness_scheduler.py` | CREATE | Cron tick that applies pending strictness changes when expiry hits |
| `tests/test_intention_strictness.py` | CREATE | Endpoint tests + cool-down behavior + partner-required-from-Strict + active-session-blocked |
| `tests/test_intention_strictness_scheduler.py` | CREATE | Scheduler tick unit tests |

---

## Task 0: Worktree setup + initial commit

- [ ] **Step 0.1** Create worktree (assume Spec 1+2 are or will be merged to main; for now branch from main):

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
mkdir -p .claude/worktrees
git worktree add -b feat/scheduled-intentions-redesign .claude/worktrees/scheduled-intentions-redesign main
cd .claude/worktrees/scheduled-intentions-redesign
```

- [ ] **Step 0.2** If `feat/intentions-spec1` and `feat/time-blocks-spec2` are NOT yet merged to main, merge them into your branch so the migration has a base:

```bash
git merge origin/feat/intentions-spec1 --no-edit 2>&1 | tail -5
git merge origin/feat/time-blocks-spec2 --no-edit 2>&1 | tail -5
```

If conflicts: resolve trivially (most should be additive). If the merges fail in a real way: stop, rebase manually, document in cross-repo log.

- [ ] **Step 0.3** Initial empty commit:

```bash
git commit --allow-empty -m "redesign(intentions): start backend implementation

Per spec docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md"
```

---

## Task 1: Migration 020 — strictness_preset + budget prep + strictness_changes table

**Files:**
- Create: `migrations/020_strictness_and_budget_prep.sql`

- [ ] **Step 1.1** Write migration:

```sql
-- 020_strictness_and_budget_prep.sql
-- Spec: docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md (D5, D6, D9, D10)
--
-- (1) strictness_preset on intentions — controls per-Intention enforcement strictness.
-- (2) Direction-asymmetric softening via intention_strictness_changes table.
-- (3) Forward-compat nullable budget columns (D9 prep — no behavior code yet).

-- Strictness preset (D4, D10)
ALTER TABLE intentions
    ADD COLUMN IF NOT EXISTS strictness_preset TEXT NOT NULL DEFAULT 'standard'
    CHECK (strictness_preset IN ('strict', 'standard', 'soft'));

-- Budget prep (D9) — nullable, no enforcement code yet
ALTER TABLE intentions
    ADD COLUMN IF NOT EXISTS weekly_budget_hours NUMERIC(4, 2);

ALTER TABLE intentions
    ADD COLUMN IF NOT EXISTS budget_enforcement TEXT
    CHECK (budget_enforcement IS NULL OR budget_enforcement IN ('track', 'nudge', 'auto_schedule', 'strict'));

ALTER TABLE time_blocks
    ADD COLUMN IF NOT EXISTS derived_from_budget BOOLEAN NOT NULL DEFAULT FALSE;

-- Pending strictness change tracking (D5)
CREATE TABLE IF NOT EXISTS intention_strictness_changes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    intention_id UUID NOT NULL REFERENCES intentions(id) ON DELETE CASCADE,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    takes_effect_at TIMESTAMPTZ NOT NULL,
    from_preset TEXT NOT NULL CHECK (from_preset IN ('strict', 'standard', 'soft')),
    to_preset TEXT NOT NULL CHECK (to_preset IN ('strict', 'standard', 'soft')),
    applied_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    -- For Strict step-down: this row is gated on a partner unlock code.
    requires_partner_unlock BOOLEAN NOT NULL DEFAULT FALSE,
    partner_unlocked_at TIMESTAMPTZ,
    UNIQUE (intention_id) DEFERRABLE INITIALLY IMMEDIATE
);

-- Only ONE pending change per intention at a time (the UNIQUE above is on intention_id
-- which would prevent any historical row from coexisting). Better: partial unique index
-- on pending-only rows. Drop the simple UNIQUE and use a filtered index.
ALTER TABLE intention_strictness_changes DROP CONSTRAINT IF EXISTS intention_strictness_changes_intention_id_key;

CREATE UNIQUE INDEX IF NOT EXISTS intention_strictness_changes_one_pending
    ON intention_strictness_changes(intention_id)
    WHERE applied_at IS NULL AND cancelled_at IS NULL;

CREATE INDEX IF NOT EXISTS intention_strictness_changes_pending
    ON intention_strictness_changes(takes_effect_at)
    WHERE applied_at IS NULL AND cancelled_at IS NULL;
```

- [ ] **Step 1.2** Commit:

```bash
git add migrations/020_strictness_and_budget_prep.sql
git commit -m "feat(intentions): migration 020 — strictness_preset + budget prep + strictness_changes table"
```

---

## Task 2: Pydantic models for strictness

**Files:**
- Modify: `models.py`

- [ ] **Step 2.1** Find existing Intention models, add `strictness_preset` field:

```python
# In Intention (response):
class Intention(BaseModel):
    # ... existing fields ...
    strictness_preset: str = "standard"  # 'strict' | 'standard' | 'soft'
    # Budget prep (D9) — nullable, exposed for future use
    weekly_budget_hours: Optional[float] = None
    budget_enforcement: Optional[str] = None  # 'track' | 'nudge' | 'auto_schedule' | 'strict'

# In IntentionCreate:
class IntentionCreate(BaseModel):
    # ... existing fields ...
    strictness_preset: Optional[str] = "standard"

# In IntentionUpdate:
class IntentionUpdate(BaseModel):
    # ... existing fields ...
    strictness_preset: Optional[str] = None  # if provided, validation happens elsewhere
    # NOTE: strictness_preset on PUT /intentions/{id} only applies for tightening.
    # Softening must use PUT /intentions/{id}/strictness which goes through cool-down logic.
```

- [ ] **Step 2.2** Add new strictness change models:

```python
class StrictnessChangeRequest(BaseModel):
    """Body for PUT /intentions/{id}/strictness."""
    to_preset: str  # 'strict' | 'standard' | 'soft'

class StrictnessChangeResponse(BaseModel):
    """Response for PUT /intentions/{id}/strictness."""
    status: str  # 'applied' | 'pending' | 'requires_partner_unlock' | 'rejected'
    message: str
    intention_id: str
    from_preset: Optional[str] = None
    to_preset: str
    takes_effect_at: Optional[str] = None  # ISO8601 if pending
    pending_change_id: Optional[str] = None  # for cancellation
    rejection_reason: Optional[str] = None  # e.g. "session_active"

class PendingStrictnessChange(BaseModel):
    """Response for GET /intentions/{id}/strictness/pending."""
    id: str
    intention_id: str
    from_preset: str
    to_preset: str
    requested_at: str
    takes_effect_at: str
    requires_partner_unlock: bool
    partner_unlocked_at: Optional[str] = None
```

- [ ] **Step 2.3** Sanity import + commit:

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/scheduled-intentions-redesign
python3 -c "from models import StrictnessChangeRequest, StrictnessChangeResponse, PendingStrictnessChange; print('OK')"
git add models.py
git commit -m "feat(strictness): pydantic models for change request/response/pending"
```

---

## Task 3: Update GET /intentions to return strictness_preset (TDD)

**Files:**
- Create: `tests/test_intention_strictness.py`
- Modify: `main.py`

- [ ] **Step 3.1** Write failing test:

```python
# tests/test_intention_strictness.py
"""Tests for strictness preset on intentions + strictness change endpoints."""
import os
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

os.environ.setdefault("JWT_SECRET", "test-intentional-secret")
os.environ.setdefault("SUPABASE_JWT_SECRET", "test-supabase-secret")
os.environ.setdefault("TESTING", "1")

from fastapi.testclient import TestClient  # noqa
from tests.test_intentions import _FakeDB, _supabase_jwt, _client


def _intention_row(id_="i-1", account_id="acct-1", name="Coding", strictness="standard", **extra):
    base = {
        "id": id_, "account_id": account_id, "name": name,
        "description": None, "color_hex": None, "icon": None,
        "mac_websites": [], "mac_bundle_ids": [],
        "ios_app_tokens": None, "ios_category_tokens": None,
        "version": 1,
        "created_at": "2026-05-01T00:00:00+00:00",
        "updated_at": "2026-05-01T00:00:00+00:00",
        "deleted_at": None,
        "strictness_preset": strictness,
        "weekly_budget_hours": None,
        "budget_enforcement": None,
    }
    base.update(extra)
    return base


def test_get_intentions_returns_strictness_preset():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1", "email": "u@e.com"}]
    intentions = [_intention_row(strictness="strict")]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        with patch("main._maybe_seed_default_intention", return_value=None):
            r = _client().get("/intentions",
                headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 200
    body = r.json()
    assert body["intentions"][0]["strictness_preset"] == "strict"
```

- [ ] **Step 3.2** Run — should already pass (Pydantic model has the field, server-side mapping needs adjusting). If fails, adjust `_row_to_intention` helper:

```python
# In main.py, inside _row_to_intention():
return Intention(
    # ... existing fields ...
    strictness_preset=row.get("strictness_preset", "standard"),
    weekly_budget_hours=row.get("weekly_budget_hours"),
    budget_enforcement=row.get("budget_enforcement"),
)
```

Run: `pytest tests/test_intention_strictness.py::test_get_intentions_returns_strictness_preset -v`

- [ ] **Step 3.3** Commit:

```bash
git add main.py tests/test_intention_strictness.py
git commit -m "feat(strictness): GET /intentions returns strictness_preset"
```

---

## Task 4: PUT /intentions/{id}/strictness — instant tighten path (TDD)

**Files:**
- Modify: `tests/test_intention_strictness.py`, `main.py`

- [ ] **Step 4.1** Write failing tests for instant tighten:

```python
def test_strictness_change_soft_to_standard_is_instant():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1"}]
    intentions = [_intention_row(strictness="soft")]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions, focus_sessions=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/intentions/i-1/strictness",
            json={"to_preset": "standard"},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "applied"
    assert body["from_preset"] == "soft"
    assert body["to_preset"] == "standard"
    # Intention row should be updated immediately
    assert intentions[0]["strictness_preset"] == "standard"


def test_strictness_change_standard_to_strict_is_instant():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1"}]
    intentions = [_intention_row(strictness="standard")]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions, focus_sessions=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/intentions/i-1/strictness",
            json={"to_preset": "strict"},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200
    assert r.json()["status"] == "applied"
    assert intentions[0]["strictness_preset"] == "strict"


def test_strictness_change_no_op_returns_applied():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1"}]
    intentions = [_intention_row(strictness="standard")]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions, focus_sessions=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/intentions/i-1/strictness",
            json={"to_preset": "standard"},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200
    assert r.json()["status"] == "applied"
```

- [ ] **Step 4.2** Implement endpoint in `main.py` after the existing intentions endpoints:

```python
# Strictness preset ordering: lower index = softer
_STRICTNESS_ORDER = {"soft": 0, "standard": 1, "strict": 2}
_COOL_DOWN_HOURS = 24  # D5: standard → soft cool-down

def _is_softening(from_p: str, to_p: str) -> bool:
    return _STRICTNESS_ORDER.get(to_p, 1) < _STRICTNESS_ORDER.get(from_p, 1)

def _is_strict_step_down(from_p: str, to_p: str) -> bool:
    return from_p == "strict" and to_p != "strict"


@app.put("/intentions/{intention_id}/strictness", response_model=StrictnessChangeResponse)
async def change_intention_strictness(
    intention_id: str,
    request: StrictnessChangeRequest,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """Change an Intention's strictness preset.

    Tightening (going harder) = instant.
    Softening Standard → Soft = 24h cool-down.
    Softening from Strict = partner unlock required (creates a row that's not
    eligible to apply until partner_unlocked_at is set).
    Active session of this intention = rejected (D6).
    """
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    if request.to_preset not in _STRICTNESS_ORDER:
        raise HTTPException(status_code=400, detail="to_preset must be 'strict', 'standard', or 'soft'")

    db = get_db()

    # Fetch current
    rows = db.table("intentions").select(
        "id,strictness_preset,deleted_at"
    ).eq("id", intention_id).eq("account_id", account_id).limit(1).execute().data or []
    if not rows:
        raise HTTPException(status_code=404, detail="Intention not found")
    if rows[0].get("deleted_at"):
        raise HTTPException(status_code=410, detail="Intention deleted")

    from_preset = rows[0].get("strictness_preset", "standard")
    to_preset = request.to_preset
    now = datetime.now(timezone.utc)

    # No-op
    if from_preset == to_preset:
        return StrictnessChangeResponse(
            status="applied", message="No change needed",
            intention_id=intention_id, from_preset=from_preset, to_preset=to_preset,
        )

    # D6: refuse if session of this intention is active
    active = db.table("focus_sessions").select("id").eq(
        "intention_id", intention_id
    ).eq("status", "active").gt("expires_at", now.isoformat()).limit(1).execute().data or []
    if active:
        return StrictnessChangeResponse(
            status="rejected", message="Cannot change strictness while a session is running",
            intention_id=intention_id, from_preset=from_preset, to_preset=to_preset,
            rejection_reason="session_active",
        )

    # Tightening = instant (D5)
    if not _is_softening(from_preset, to_preset):
        db.table("intentions").update({"strictness_preset": to_preset}).eq("id", intention_id).execute()
        return StrictnessChangeResponse(
            status="applied", message="Strictness tightened immediately",
            intention_id=intention_id, from_preset=from_preset, to_preset=to_preset,
        )

    # Softening = goes through pending-change logic (Tasks 5 + 6)
    # For this task we just return a placeholder — Task 5 implements the queue.
    # NOTE: This branch is exercised by Task 5's tests; for now leaving as TODO is fine.
    return StrictnessChangeResponse(
        status="pending", message="Softening queued; will take effect after cool-down",
        intention_id=intention_id, from_preset=from_preset, to_preset=to_preset,
        takes_effect_at=(now + timedelta(hours=_COOL_DOWN_HOURS)).isoformat(),
    )
```

- [ ] **Step 4.3** Run + commit:

```bash
pytest tests/test_intention_strictness.py -v
git add main.py tests/test_intention_strictness.py
git commit -m "feat(strictness): PUT /intentions/{id}/strictness — instant tighten path + active-session block"
```

---

## Task 5: PUT /intentions/{id}/strictness — softening cool-down path (TDD)

**Files:**
- Modify: `tests/test_intention_strictness.py`, `main.py`

- [ ] **Step 5.1** Tests:

```python
def test_strictness_change_standard_to_soft_creates_pending_with_cooldown():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1"}]
    intentions = [_intention_row(strictness="standard")]
    pending_rows = []
    fake_db = _FakeDB(accounts=accounts, intentions=intentions, focus_sessions=[],
                       intention_strictness_changes=pending_rows)
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/intentions/i-1/strictness",
            json={"to_preset": "soft"},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "pending"
    assert body["from_preset"] == "standard"
    assert body["to_preset"] == "soft"
    assert body["takes_effect_at"]  # ISO8601 string
    # Intention NOT yet updated (still standard)
    assert intentions[0]["strictness_preset"] == "standard"
    # Pending row created
    assert len(pending_rows) == 1
    assert pending_rows[0]["from_preset"] == "standard"
    assert pending_rows[0]["to_preset"] == "soft"
    assert pending_rows[0]["requires_partner_unlock"] is False


def test_strictness_change_strict_to_standard_requires_partner_unlock():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1"}]
    intentions = [_intention_row(strictness="strict")]
    pending_rows = []
    fake_db = _FakeDB(accounts=accounts, intentions=intentions, focus_sessions=[],
                       intention_strictness_changes=pending_rows)
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/intentions/i-1/strictness",
            json={"to_preset": "standard"},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "requires_partner_unlock"
    # Intention NOT updated
    assert intentions[0]["strictness_preset"] == "strict"
    # Pending row marked partner-unlock-required
    assert len(pending_rows) == 1
    assert pending_rows[0]["requires_partner_unlock"] is True


def test_strictness_change_replaces_existing_pending():
    """Asking for a softening when there's already a pending one cancels the old + creates new."""
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1"}]
    intentions = [_intention_row(strictness="standard")]
    existing_pending = {
        "id": "pc-old", "account_id": "acct-1", "intention_id": "i-1",
        "requested_at": "2026-05-01T00:00:00+00:00",
        "takes_effect_at": "2026-05-02T00:00:00+00:00",
        "from_preset": "standard", "to_preset": "soft",
        "applied_at": None, "cancelled_at": None,
        "requires_partner_unlock": False, "partner_unlocked_at": None,
    }
    pending_rows = [existing_pending]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions, focus_sessions=[],
                       intention_strictness_changes=pending_rows)
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/intentions/i-1/strictness",
            json={"to_preset": "soft"},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200
    # Old row should now have cancelled_at set
    assert existing_pending["cancelled_at"] is not None
```

- [ ] **Step 5.2** Update the softening branch in the endpoint:

In `main.py`, replace the softening placeholder branch with:

```python
    # Softening — create a pending change row
    # First cancel any existing pending change for this intention
    db.table("intention_strictness_changes").update({
        "cancelled_at": now.isoformat()
    }).eq("intention_id", intention_id).is_("applied_at", "null").is_("cancelled_at", "null").execute()

    requires_partner = _is_strict_step_down(from_preset, to_preset)
    takes_effect_at = now + timedelta(hours=_COOL_DOWN_HOURS)

    insert_payload = {
        "account_id": account_id,
        "intention_id": intention_id,
        "requested_at": now.isoformat(),
        "takes_effect_at": takes_effect_at.isoformat(),
        "from_preset": from_preset,
        "to_preset": to_preset,
        "requires_partner_unlock": requires_partner,
    }
    insert_result = db.table("intention_strictness_changes").insert(insert_payload).execute()
    pending_id = insert_result.data[0]["id"] if insert_result.data else None

    if requires_partner:
        return StrictnessChangeResponse(
            status="requires_partner_unlock",
            message="Stepping down from Strict requires a code from your accountability partner",
            intention_id=intention_id, from_preset=from_preset, to_preset=to_preset,
            takes_effect_at=takes_effect_at.isoformat(), pending_change_id=pending_id,
        )

    return StrictnessChangeResponse(
        status="pending",
        message="Softening queued; will take effect after cool-down",
        intention_id=intention_id, from_preset=from_preset, to_preset=to_preset,
        takes_effect_at=takes_effect_at.isoformat(), pending_change_id=pending_id,
    )
```

- [ ] **Step 5.3** Run + commit:

```bash
pytest tests/test_intention_strictness.py -v
git add main.py tests/test_intention_strictness.py
git commit -m "feat(strictness): softening creates pending change with cool-down or partner-required flag"
```

---

## Task 6: GET /intentions/{id}/strictness/pending + POST cancel (TDD)

**Files:**
- Modify: `tests/test_intention_strictness.py`, `main.py`

- [ ] **Step 6.1** Tests:

```python
def test_get_pending_strictness_change():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1"}]
    intentions = [_intention_row(strictness="standard")]
    pending = [{
        "id": "pc-1", "account_id": "acct-1", "intention_id": "i-1",
        "requested_at": "2026-05-04T10:00:00+00:00",
        "takes_effect_at": "2026-05-05T10:00:00+00:00",
        "from_preset": "standard", "to_preset": "soft",
        "applied_at": None, "cancelled_at": None,
        "requires_partner_unlock": False, "partner_unlocked_at": None,
    }]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions,
                       intention_strictness_changes=pending)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get(
            "/intentions/i-1/strictness/pending",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200
    body = r.json()
    assert body["from_preset"] == "standard"
    assert body["to_preset"] == "soft"
    assert body["requires_partner_unlock"] is False


def test_get_pending_returns_404_when_none():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1"}]
    fake_db = _FakeDB(accounts=accounts, intentions=[_intention_row()],
                       intention_strictness_changes=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().get(
            "/intentions/i-1/strictness/pending",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 404


def test_cancel_pending_strictness_change():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-1"}]
    pending = [{
        "id": "pc-1", "account_id": "acct-1", "intention_id": "i-1",
        "requested_at": "2026-05-04T10:00:00+00:00",
        "takes_effect_at": "2026-05-05T10:00:00+00:00",
        "from_preset": "standard", "to_preset": "soft",
        "applied_at": None, "cancelled_at": None,
        "requires_partner_unlock": False, "partner_unlocked_at": None,
    }]
    fake_db = _FakeDB(accounts=accounts, intentions=[_intention_row()],
                       intention_strictness_changes=pending)
    with patch("main.get_db", return_value=fake_db):
        r = _client().post(
            "/intentions/i-1/strictness/cancel",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 204
    assert pending[0]["cancelled_at"] is not None
```

- [ ] **Step 6.2** Implement:

```python
@app.get("/intentions/{intention_id}/strictness/pending", response_model=PendingStrictnessChange)
async def get_pending_strictness_change(
    intention_id: str,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    rows = db.table("intention_strictness_changes").select("*").eq(
        "intention_id", intention_id
    ).eq("account_id", account_id).is_("applied_at", "null").is_("cancelled_at", "null").limit(1).execute().data or []
    if not rows:
        raise HTTPException(status_code=404, detail="No pending strictness change")
    r = rows[0]
    return PendingStrictnessChange(
        id=str(r["id"]), intention_id=str(r["intention_id"]),
        from_preset=r["from_preset"], to_preset=r["to_preset"],
        requested_at=r["requested_at"], takes_effect_at=r["takes_effect_at"],
        requires_partner_unlock=r.get("requires_partner_unlock", False),
        partner_unlocked_at=r.get("partner_unlocked_at"),
    )


@app.post("/intentions/{intention_id}/strictness/cancel", status_code=204)
async def cancel_pending_strictness_change(
    intention_id: str,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    now_iso = datetime.now(timezone.utc).isoformat()
    db.table("intention_strictness_changes").update({
        "cancelled_at": now_iso
    }).eq("intention_id", intention_id).eq("account_id", account_id).is_("applied_at", "null").is_("cancelled_at", "null").execute()
    from fastapi import Response
    return Response(status_code=204)
```

- [ ] **Step 6.3** Run + commit:

```bash
pytest tests/test_intention_strictness.py -v
git add main.py tests/test_intention_strictness.py
git commit -m "feat(strictness): GET pending + POST cancel endpoints"
```

---

## Task 7: Background scheduler — apply pending changes when expiry hits

**Files:**
- Create: `intention_strictness_scheduler.py`

- [ ] **Step 7.1** Write scheduler module:

```python
# intention_strictness_scheduler.py
"""
Scheduled Intentions Redesign — apply pending strictness changes.

Tick every 60s. For each pending row where takes_effect_at <= now AND not cancelled
AND (not requires_partner_unlock OR partner_unlocked_at is set), update the
intention's strictness_preset and stamp applied_at on the row.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone

logger = logging.getLogger(__name__)
_running = False


async def strictness_tick(db_factory) -> None:
    """One iteration of the scheduler. Public for testability."""
    db = db_factory()
    now_iso = datetime.now(timezone.utc).isoformat()

    pending = db.table("intention_strictness_changes").select("*").lte(
        "takes_effect_at", now_iso
    ).is_("applied_at", "null").is_("cancelled_at", "null").execute().data or []

    for row in pending:
        # Skip rows that require partner unlock if not yet unlocked
        if row.get("requires_partner_unlock") and not row.get("partner_unlocked_at"):
            continue
        try:
            # Apply: update intention.strictness_preset
            db.table("intentions").update({
                "strictness_preset": row["to_preset"]
            }).eq("id", row["intention_id"]).execute()
            # Stamp applied_at
            db.table("intention_strictness_changes").update({
                "applied_at": now_iso
            }).eq("id", row["id"]).execute()
            logger.info("Applied strictness change: intention=%s %s → %s",
                        row["intention_id"], row["from_preset"], row["to_preset"])
        except Exception as exc:  # noqa: BLE001
            logger.exception("Failed to apply strictness change %s: %s", row.get("id"), exc)


async def run_scheduler_loop(db_factory) -> None:
    global _running
    _running = True
    logger.info("Strictness scheduler loop started (60s tick)")
    try:
        while _running:
            try:
                await strictness_tick(db_factory)
            except Exception as exc:  # noqa: BLE001
                logger.exception("Strictness tick crashed: %s", exc)
            await asyncio.sleep(60.0)
    except asyncio.CancelledError:
        raise


def stop_loop() -> None:
    global _running
    _running = False
```

- [ ] **Step 7.2** Wire into `main.py` startup (add alongside the time_block_scheduler):

```python
import intention_strictness_scheduler

_strictness_scheduler_task = None

@app.on_event("startup")
async def _start_strictness_scheduler():
    global _strictness_scheduler_task
    if os.environ.get("TESTING") == "1":
        return
    _strictness_scheduler_task = asyncio.create_task(
        intention_strictness_scheduler.run_scheduler_loop(get_db)
    )

@app.on_event("shutdown")
async def _stop_strictness_scheduler():
    global _strictness_scheduler_task
    if _strictness_scheduler_task and not _strictness_scheduler_task.done():
        _strictness_scheduler_task.cancel()
        try:
            await _strictness_scheduler_task
        except asyncio.CancelledError:
            pass
```

If `@app.on_event("startup")` already exists from the time_block_scheduler, just ADD the new `asyncio.create_task` line into the same function rather than declaring a second handler.

- [ ] **Step 7.3** Commit:

```bash
git add intention_strictness_scheduler.py main.py
git commit -m "feat(strictness): background scheduler applies pending changes when expiry hits"
```

---

## Task 8: Scheduler unit tests

**Files:**
- Create: `tests/test_intention_strictness_scheduler.py`

- [ ] **Step 8.1** Write tests:

```python
import os
import asyncio
from datetime import datetime, timezone, timedelta
from unittest.mock import patch

os.environ.setdefault("TESTING", "1")
os.environ.setdefault("JWT_SECRET", "test-intentional-secret")
os.environ.setdefault("SUPABASE_JWT_SECRET", "test-supabase-secret")

from tests.test_intentions import _FakeDB
import intention_strictness_scheduler


def test_tick_applies_pending_change_past_expiry():
    past = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    intentions = [{"id": "i-1", "strictness_preset": "standard"}]
    pending = [{
        "id": "pc-1", "account_id": "a-1", "intention_id": "i-1",
        "requested_at": past, "takes_effect_at": past,
        "from_preset": "standard", "to_preset": "soft",
        "applied_at": None, "cancelled_at": None,
        "requires_partner_unlock": False, "partner_unlocked_at": None,
    }]
    fake_db = _FakeDB(intentions=intentions, intention_strictness_changes=pending)
    asyncio.run(intention_strictness_scheduler.strictness_tick(lambda: fake_db))
    assert intentions[0]["strictness_preset"] == "soft"
    assert pending[0]["applied_at"] is not None


def test_tick_does_not_apply_future_pending():
    future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    intentions = [{"id": "i-1", "strictness_preset": "standard"}]
    pending = [{
        "id": "pc-1", "account_id": "a-1", "intention_id": "i-1",
        "requested_at": future, "takes_effect_at": future,
        "from_preset": "standard", "to_preset": "soft",
        "applied_at": None, "cancelled_at": None,
        "requires_partner_unlock": False, "partner_unlocked_at": None,
    }]
    fake_db = _FakeDB(intentions=intentions, intention_strictness_changes=pending)
    asyncio.run(intention_strictness_scheduler.strictness_tick(lambda: fake_db))
    assert intentions[0]["strictness_preset"] == "standard"
    assert pending[0]["applied_at"] is None


def test_tick_skips_partner_required_without_unlock():
    past = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    intentions = [{"id": "i-1", "strictness_preset": "strict"}]
    pending = [{
        "id": "pc-1", "account_id": "a-1", "intention_id": "i-1",
        "requested_at": past, "takes_effect_at": past,
        "from_preset": "strict", "to_preset": "standard",
        "applied_at": None, "cancelled_at": None,
        "requires_partner_unlock": True, "partner_unlocked_at": None,
    }]
    fake_db = _FakeDB(intentions=intentions, intention_strictness_changes=pending)
    asyncio.run(intention_strictness_scheduler.strictness_tick(lambda: fake_db))
    assert intentions[0]["strictness_preset"] == "strict"
    assert pending[0]["applied_at"] is None


def test_tick_applies_partner_required_when_unlocked():
    past = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    intentions = [{"id": "i-1", "strictness_preset": "strict"}]
    pending = [{
        "id": "pc-1", "account_id": "a-1", "intention_id": "i-1",
        "requested_at": past, "takes_effect_at": past,
        "from_preset": "strict", "to_preset": "standard",
        "applied_at": None, "cancelled_at": None,
        "requires_partner_unlock": True,
        "partner_unlocked_at": (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat(),
    }]
    fake_db = _FakeDB(intentions=intentions, intention_strictness_changes=pending)
    asyncio.run(intention_strictness_scheduler.strictness_tick(lambda: fake_db))
    assert intentions[0]["strictness_preset"] == "standard"
```

- [ ] **Step 8.2** Run + commit:

```bash
pytest tests/test_intention_strictness_scheduler.py -v
git add tests/test_intention_strictness_scheduler.py
git commit -m "test(strictness): scheduler — applies past-expiry, skips future, respects partner-unlock gate"
```

---

## Task 9: Final integration + push

- [ ] **Step 9.1** Run full test suite, expect green:

```bash
pytest tests/ -v --tb=short 2>&1 | tail -30
```

Pre-existing failures from Spec 1/2 (`test_focus_active_no_session`, `test_partner_status_no_account_returns_none`) remain — NOT regressions, NOT your bugs.

- [ ] **Step 9.2** Push:

```bash
git push -u origin feat/scheduled-intentions-redesign
```

- [ ] **Step 9.3** Append report to cross-repo log

In `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md` (CREATE if missing — assume sibling agents have created it), add `### Phase 3 — Backend report` with:
- Status, branch, head commit, test counts
- Migration 020 must be applied via Supabase SQL editor
- Endpoints summary
- Pre-existing test failures (not your bugs)

---

## What this plan does NOT do (deferred)

- **Partner unlock flow for strictness step-down** — the `requires_partner_unlock` gate exists, but the actual partner-code request/verify endpoints are NOT in this plan. Reuse the existing bedtime unlock infrastructure (`/bedtime/unlock-request`, `/bedtime/unlock-verify`) — wire that in a follow-up. For now, the pending row sits there indefinitely until SOMETHING flips `partner_unlocked_at`.
- **Budget enforcement logic** (auto-fill, behind-budget partner notification, Sunday ritual) — D9 only adds nullable schema columns. No behavior code.
- **Active-session real-time block** — the active-session check happens at the moment of the change request. If a session starts AFTER a pending change is queued and before its expiry, the scheduler still applies it. Future improvement: scheduler also checks active sessions at apply time.

## Required env vars (none new)

Reuses existing.
