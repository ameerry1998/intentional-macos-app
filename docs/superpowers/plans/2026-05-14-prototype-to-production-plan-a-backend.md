# Prototype → Production — Backend Implementation Plan (Plan A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the backend to support the May 2026 prototype's Weekly-Goal-vocab + Monthly-Goal hierarchy. Add new columns to `intentions` (`outcome`, `status`, `weekly_target_hours`, `intent_text`, `ai_scoring_enabled`, `allow_websites`, `allow_bundle_ids`, `monthly_goal_id`, `week_of`), create a new `monthly_goals` table + endpoints, and surface week/month filtering. Do NOT rename the underlying `intentions` table — the user-facing label change to "Weekly Goal" is purely a Mac/dashboard concern.

**Architecture:** Mirrors the existing `intentions` pattern: account-scoped (sibling-shared via `account_id`), dual auth (`Bearer` JWT or `X-Device-ID`), soft delete with tombstones, optimistic concurrency via `version`. Monthly Goals get their own table with FK → accounts and a nullable `month_of DATE` column for filtering. Weekly goals (= intentions) gain a `monthly_goal_id UUID NULLABLE REFERENCES monthly_goals(id) ON DELETE SET NULL` plus `week_of DATE` for week filtering. Endpoints follow the existing alias pattern (`/intentions` + `/focus_modes` both work; we add `/weekly_goals` as a third alias).

**Tech Stack:** FastAPI (Python 3.9+), Supabase Postgres, Pydantic v2, supabase-py, pytest with the existing `_FakeDB` mock pattern.

**Source-of-truth brief:** See `docs/prototype-to-production-2026-05-14.md`.

**Worktree:** `/Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/prototype-to-production` on branch `feat/prototype-to-production` from `main`.

**Cross-repo log to append:** `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-prototype-to-production-2026-05-14.md` (created by Plan B Task 0).

---

## Open questions for the user (consolidated)

These do NOT block start of Phase 1 (schema is forward-compatible regardless), but must be answered before Phase 2/3 ship:

1. **Monthly-window definition.** Is `month_of` a calendar month (`YYYY-MM-01`) or a rolling 30-day anchor? Default in this plan: **calendar month**, `DATE` truncated to first-of-month. Confirm or override.
2. **Week-window definition.** ISO week (Mon-start) or US week (Sun-start)? Default: **Mon-start**, persisted as the Monday `DATE`. Confirm or override.
3. **Goal carry-over.** When a new week begins, do `in_progress` goals auto-roll to the new week? Default in this plan: **no roll** — they remain in their original week, user manually re-creates / re-links. Roll-over is an explicit Phase-4 follow-up.
4. **`status` enum.** Prototype uses `in-progress | planned | done` (Today) AND `done | slipped | dropped` (Plan history). Are these the same enum or two enums? Default: **single enum** `planned | in_progress | done | slipped | dropped`. Confirm.
5. **Cross-device sync.** Monthly Goals follow the same pattern as Intentions: pull on launch/foreground/60s timer, push silent APNs on update? Default: **yes, same**. Confirm.
6. **AI scoring per goal.** Currently `description` (free text) drives relevance scoring globally. Prototype adds per-goal `intent_text` + `ai_scoring_enabled`. When `ai_scoring_enabled=false`, what falls back — keyword-only? Skip scoring entirely (allow all)? Default: **skip scoring entirely (treat as always-relevant)**. Confirm.
7. **Allow-list semantics on Mac.** Per spec brief item E (block-conflict warning), the prototype noted that goal-allow may override a globally-blocking Time Block during that goal's session. Confirm: backend just stores the lists; **conflict resolution stays on Mac** (no server-side conflict computation in this plan).

---

## What this plan does NOT do

- Does not rename the `intentions` table to `weekly_goals`. (User-facing label only — keep table for sibling-sync continuity and to avoid breaking iOS clients still using `/intentions`.)
- Does not implement AI scoring behavior (Mac plan owns that — backend just stores `intent_text`).
- Does not deliver weekly-goal carry-over between weeks.
- Does not implement monthly-goal session analytics rollups.
- Does not change `/focus/toggle` or `/focus/active` (still keyed on `intention_id`; `monthly_goal_id` is derived via FK at read time).
- Does not introduce a feature flag — schema is purely additive, all new columns nullable, all new endpoints additive.

---

## File map

| File | Op | Purpose |
|---|---|---|
| `migrations/026_weekly_monthly_goals.sql` | CREATE | Add columns to `intentions`; create `monthly_goals` + indexes + triggers |
| `models.py` | MODIFY | Extend `Intention*` with new fields (tolerant decoding); add `MonthlyGoal*` models |
| `main.py` | MODIFY | Add 4 monthly-goal endpoints + 2 weekly-filtered intention endpoints; extend `IntentionCreate`/`IntentionUpdate` handlers to accept the new fields |
| `auth.py` | MODIFY | Extend account-deletion cascade to include `monthly_goals` (FK CASCADE already handles, just verify) |
| `tests/test_monthly_goals.py` | CREATE | CRUD + sibling-sync + 409 conflict + month-filter tests |
| `tests/test_intention_extensions.py` | CREATE | New-field round-trip + week-filter + monthly_goal_id FK + null-FK-on-delete tests |

---

## Phase 1: Schema migration (independently mergable — purely additive)

### Task 1: Worktree + initial commit

- [ ] **Step 1.1: Create worktree**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
mkdir -p .claude/worktrees
git worktree add -b feat/prototype-to-production .claude/worktrees/prototype-to-production main
cd .claude/worktrees/prototype-to-production
git status
```

Expected: clean worktree on `feat/prototype-to-production`.

- [ ] **Step 1.2: Initial empty commit**

```bash
git commit --allow-empty -m "feat(goals): start backend prototype-to-production work

Per docs/prototype-to-production-2026-05-14.md and
docs/superpowers/plans/2026-05-14-prototype-to-production-plan-a-backend.md
in the intentional-macos-app repo."
```

---

### Task 2: Migration 026 — extend intentions + create monthly_goals

**Files:**
- Create: `migrations/026_weekly_monthly_goals.sql`

- [ ] **Step 2.1: Write migration**

```sql
-- 026_weekly_monthly_goals.sql
-- May 2026 prototype → production. See:
--   docs/prototype-to-production-2026-05-14.md (intentional-macos-app)
--
-- (1) Extends `intentions` with weekly-goal-specific fields the prototype exposes.
-- (2) Adds nullable allow_websites + allow_bundle_ids (per-goal "Allow" rules).
-- (3) Adds nullable monthly_goal_id FK (weekly_goal links to monthly_goal).
-- (4) Adds nullable week_of DATE for week filtering.
-- (5) Creates monthly_goals table.

-- ---------- Intentions extensions ----------

ALTER TABLE intentions
    ADD COLUMN IF NOT EXISTS outcome TEXT,                 -- "done looks like" free text
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'planned'
        CHECK (status IN ('planned', 'in_progress', 'done', 'slipped', 'dropped')),
    ADD COLUMN IF NOT EXISTS weekly_target_hours NUMERIC(4, 2),
    ADD COLUMN IF NOT EXISTS intent_text TEXT,             -- ≤140 chars, drives AI relevance
    ADD COLUMN IF NOT EXISTS ai_scoring_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS allow_websites TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    ADD COLUMN IF NOT EXISTS allow_bundle_ids TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    ADD COLUMN IF NOT EXISTS week_of DATE;                 -- Monday-of-week the goal belongs to; NULL = unscheduled

-- intent_text length guard at app level (Pydantic enforces). DB allows longer for safety.

CREATE INDEX IF NOT EXISTS intentions_week_idx
    ON intentions(account_id, week_of)
    WHERE deleted_at IS NULL AND week_of IS NOT NULL;

-- ---------- Monthly goals ----------

CREATE TABLE IF NOT EXISTS monthly_goals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    outcome TEXT,
    color_hex TEXT,
    month_of DATE NOT NULL,                                 -- first-of-month (YYYY-MM-01) by convention
    status TEXT NOT NULL DEFAULT 'planned'
        CHECK (status IN ('planned', 'in_progress', 'done', 'slipped', 'dropped')),
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS monthly_goals_account_active_idx
    ON monthly_goals(account_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS monthly_goals_account_month_idx
    ON monthly_goals(account_id, month_of) WHERE deleted_at IS NULL;

CREATE OR REPLACE FUNCTION monthly_goals_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS monthly_goals_touch_updated_at ON monthly_goals;
CREATE TRIGGER monthly_goals_touch_updated_at
    BEFORE UPDATE ON monthly_goals
    FOR EACH ROW EXECUTE FUNCTION monthly_goals_touch_updated_at();

ALTER TABLE monthly_goals ENABLE ROW LEVEL SECURITY;

-- ---------- Weekly→Monthly FK ----------

ALTER TABLE intentions
    ADD COLUMN IF NOT EXISTS monthly_goal_id UUID
    REFERENCES monthly_goals(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS intentions_monthly_goal_idx
    ON intentions(monthly_goal_id) WHERE monthly_goal_id IS NOT NULL;
```

- [ ] **Step 2.2: Verify SQL syntax** (optional local PG)

```bash
psql -h localhost -U postgres -d intentional_dev -c "BEGIN; \i migrations/026_weekly_monthly_goals.sql; ROLLBACK;" 2>&1 | tail -5
```

Expected: no errors. Skip if no local PG — Supabase SQL editor validates at deploy time.

- [ ] **Step 2.3: Commit**

```bash
git add migrations/026_weekly_monthly_goals.sql
git commit -m "feat(goals): migration 026 — weekly/monthly goal columns + monthly_goals table"
```

**Acceptance criteria:**
- All new columns on `intentions` are nullable or have safe defaults — existing rows unaffected.
- `monthly_goals` table exists with sibling-shared `account_id` + soft-delete + version.
- Indexes cover `(account_id, week_of)` and `(account_id, month_of)` lookups.
- Rollback: a single `DROP TABLE monthly_goals; ALTER TABLE intentions DROP COLUMN ...` script in `migrations/rollback/026_*.sql` (Task 2.4).

- [ ] **Step 2.4: Write rollback script**

Create `migrations/rollback/026_weekly_monthly_goals_rollback.sql`:

```sql
-- Rollback for 026_weekly_monthly_goals.sql.
-- Drops the FK first (so monthly_goals can be dropped), then the columns,
-- then the table. Idempotent.

ALTER TABLE intentions DROP COLUMN IF EXISTS monthly_goal_id;
DROP TABLE IF EXISTS monthly_goals;
ALTER TABLE intentions
    DROP COLUMN IF EXISTS outcome,
    DROP COLUMN IF EXISTS status,
    DROP COLUMN IF EXISTS weekly_target_hours,
    DROP COLUMN IF EXISTS intent_text,
    DROP COLUMN IF EXISTS ai_scoring_enabled,
    DROP COLUMN IF EXISTS allow_websites,
    DROP COLUMN IF EXISTS allow_bundle_ids,
    DROP COLUMN IF EXISTS week_of;
DROP INDEX IF EXISTS intentions_week_idx;
DROP INDEX IF EXISTS intentions_monthly_goal_idx;
```

```bash
git add migrations/rollback/026_weekly_monthly_goals_rollback.sql
git commit -m "feat(goals): rollback script for migration 026"
```

---

## Phase 2: Pydantic models (independently mergable — wire format only)

### Task 3: Extend Intention models with new weekly-goal fields

**Files:**
- Modify: `models.py` at line 623–679 (`IntentionCreate`, `IntentionUpdate`, `Intention`)

- [ ] **Step 3.1: Add new fields to `IntentionCreate`**

In `models.py`, find class `IntentionCreate` (currently lines 623–636) and append these fields above the closing of the class (after `strictness_preset`):

```python
    # May 2026 weekly-goal extensions. All optional for backwards compat with
    # iOS clients that haven't shipped the new editor yet.
    outcome: Optional[str] = Field(None, max_length=2000)
    status: Optional[str] = Field("planned", pattern=r"^(planned|in_progress|done|slipped|dropped)$")
    weekly_target_hours: Optional[float] = Field(None, ge=0, le=168)
    intent_text: Optional[str] = Field(None, max_length=140)
    ai_scoring_enabled: Optional[bool] = True
    allow_websites: list[str] = Field(default_factory=list)
    allow_bundle_ids: list[str] = Field(default_factory=list)
    monthly_goal_id: Optional[str] = None  # UUID string
    week_of: Optional[str] = None  # ISO date YYYY-MM-DD (Monday)
```

- [ ] **Step 3.2: Mirror the same fields onto `IntentionUpdate`**

In the same file, find class `IntentionUpdate` (lines 639–652). Append the same nine fields. Use the same Field constraints — the only difference vs Create is that `version` is required (already present).

- [ ] **Step 3.3: Mirror onto `Intention` (response model)**

In the same file, find class `Intention` (lines 655–674). Append the new fields. Provide explicit `None` / default-empty-list defaults so older DB rows that pre-date migration 026 still serialize. Status default `"planned"`, `ai_scoring_enabled` default `True`.

```python
    # May 2026 weekly-goal extensions
    outcome: Optional[str] = None
    status: str = "planned"
    weekly_target_hours: Optional[float] = None
    intent_text: Optional[str] = None
    ai_scoring_enabled: bool = True
    allow_websites: list[str] = Field(default_factory=list)
    allow_bundle_ids: list[str] = Field(default_factory=list)
    monthly_goal_id: Optional[str] = None
    week_of: Optional[str] = None
```

- [ ] **Step 3.4: Commit**

```bash
git add models.py
git commit -m "feat(goals): extend Intention Pydantic models with weekly-goal fields"
```

**Acceptance criteria:**
- Existing `IntentionCreate`/`Update`/`Intention` JSON payloads continue to validate (all new fields optional).
- New fields round-trip from request → DB → response.

---

### Task 4: Add MonthlyGoal models

**Files:**
- Modify: `models.py` (append after `IntentionListResponse` at ~line 678)

- [ ] **Step 4.1: Add 4 model classes**

```python
# ==================== Monthly Goals (May 2026 prototype → production) ====================

class MonthlyGoalCreate(BaseModel):
    """Payload for POST /monthly_goals. id and version are server-assigned."""
    title: str = Field(..., min_length=1, max_length=200)
    outcome: Optional[str] = Field(None, max_length=2000)
    color_hex: Optional[str] = Field(None, pattern=r"^#[0-9A-Fa-f]{6}$")
    month_of: str = Field(..., description="ISO date YYYY-MM-01 for first-of-month")
    status: Optional[str] = Field("planned", pattern=r"^(planned|in_progress|done|slipped|dropped)$")


class MonthlyGoalUpdate(BaseModel):
    """Payload for PUT /monthly_goals/{id}. Must include current version."""
    title: str = Field(..., min_length=1, max_length=200)
    outcome: Optional[str] = Field(None, max_length=2000)
    color_hex: Optional[str] = Field(None, pattern=r"^#[0-9A-Fa-f]{6}$")
    month_of: str
    status: str = Field(..., pattern=r"^(planned|in_progress|done|slipped|dropped)$")
    version: int = Field(..., ge=1)


class MonthlyGoal(BaseModel):
    """Server-returned MonthlyGoal."""
    id: str
    title: str
    outcome: Optional[str]
    color_hex: Optional[str]
    month_of: str  # ISO YYYY-MM-DD
    status: str
    version: int
    created_at: str
    updated_at: str
    deleted_at: Optional[str] = None


class MonthlyGoalListResponse(BaseModel):
    monthly_goals: list[MonthlyGoal]
```

- [ ] **Step 4.2: Commit**

```bash
git add models.py
git commit -m "feat(goals): add MonthlyGoal Pydantic models"
```

---

## Phase 3: Endpoints (independently mergable)

### Task 5: Helper `_row_to_monthly_goal`

**Files:**
- Modify: `main.py` (add a helper near `_row_to_intention` at ~line 3427)

- [ ] **Step 5.1: Add the helper**

```python
def _row_to_monthly_goal(row: dict) -> "MonthlyGoal":
    """Convert a Supabase monthly_goals row to a MonthlyGoal response model."""
    return MonthlyGoal(
        id=row["id"],
        title=row["title"],
        outcome=row.get("outcome"),
        color_hex=row.get("color_hex"),
        month_of=row["month_of"],
        status=row.get("status") or "planned",
        version=row.get("version") or 1,
        created_at=row["created_at"],
        updated_at=row["updated_at"],
        deleted_at=row.get("deleted_at"),
    )
```

Add `MonthlyGoal`, `MonthlyGoalCreate`, `MonthlyGoalUpdate`, `MonthlyGoalListResponse` to the import block at the top of `main.py` (the line that imports from `models`).

- [ ] **Step 5.2: Commit**

```bash
git add main.py
git commit -m "feat(goals): add _row_to_monthly_goal helper + model imports"
```

---

### Task 6: GET /monthly_goals (list + optional month filter)

**Files:**
- Modify: `main.py` (insert after the existing intentions endpoints, before `/focus/` block)

- [ ] **Step 6.1: Write the failing test**

Create `tests/test_monthly_goals.py`:

```python
import pytest
from fastapi.testclient import TestClient
from main import app
from tests.conftest import _FakeDB, override_db  # adjust import if conftest path differs

client = TestClient(app)

def test_list_monthly_goals_empty(monkeypatch, fake_account):
    db = _FakeDB()
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    r = client.get("/monthly_goals", headers=headers)
    assert r.status_code == 200
    assert r.json() == {"monthly_goals": []}

def test_list_monthly_goals_filter_by_month(monkeypatch, fake_account):
    db = _FakeDB()
    db.seed("monthly_goals", [
        {"id":"a","account_id":fake_account.id,"title":"A","month_of":"2026-05-01","status":"planned","version":1,
         "created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:00:00Z","deleted_at":None,
         "outcome":None,"color_hex":None},
        {"id":"b","account_id":fake_account.id,"title":"B","month_of":"2026-04-01","status":"planned","version":1,
         "created_at":"2026-04-01T00:00:00Z","updated_at":"2026-04-01T00:00:00Z","deleted_at":None,
         "outcome":None,"color_hex":None},
    ])
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    r = client.get("/monthly_goals?month=2026-05", headers=headers)
    assert r.status_code == 200
    titles = [g["title"] for g in r.json()["monthly_goals"]]
    assert titles == ["A"]
```

Run: `pytest tests/test_monthly_goals.py::test_list_monthly_goals_empty -v` — expect FAIL (endpoint doesn't exist).

- [ ] **Step 6.2: Implement the endpoint**

Insert after `/intentions/{intention_id}` DELETE (around line 3615):

```python
@app.get("/monthly_goals", response_model=MonthlyGoalListResponse)
async def list_monthly_goals(
    request: Request,
    month: Optional[str] = None,
    include_deleted: bool = False,
):
    """List monthly goals for the authenticated account, optionally filtered by month.

    `month` is a `YYYY-MM` string. The DB stores `month_of` as the first-of-month
    `DATE`, so we filter `month_of = (month + "-01")`.
    """
    account_id = await _resolve_account_dual_auth(request)
    db = get_db()
    q = db.table("monthly_goals").select("*").eq("account_id", account_id)
    if not include_deleted:
        q = q.is_("deleted_at", "null")
    if month:
        try:
            month_anchor = month + "-01"
            # naive validation — let Postgres reject invalid dates
            q = q.eq("month_of", month_anchor)
        except Exception:
            raise HTTPException(400, "month must be YYYY-MM")
    rows = q.execute().data or []
    rows.sort(key=lambda r: (r["month_of"], r["created_at"]))
    return MonthlyGoalListResponse(monthly_goals=[_row_to_monthly_goal(r) for r in rows])
```

Run test: `pytest tests/test_monthly_goals.py::test_list_monthly_goals_empty -v` — expect PASS.
Run filter test: `pytest tests/test_monthly_goals.py::test_list_monthly_goals_filter_by_month -v` — expect PASS.

- [ ] **Step 6.3: Commit**

```bash
git add main.py tests/test_monthly_goals.py
git commit -m "feat(goals): GET /monthly_goals with month filter"
```

---

### Task 7: POST /monthly_goals (create)

**Files:** Modify `main.py`, extend `tests/test_monthly_goals.py`.

- [ ] **Step 7.1: Write failing test**

Append to `tests/test_monthly_goals.py`:

```python
def test_create_monthly_goal(monkeypatch, fake_account):
    db = _FakeDB()
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    body = {"title":"Ship Puck","month_of":"2026-05-01","status":"in_progress","color_hex":"#D85A30"}
    r = client.post("/monthly_goals", headers=headers, json=body)
    assert r.status_code == 200
    j = r.json()
    assert j["title"] == "Ship Puck"
    assert j["version"] == 1
    assert j["status"] == "in_progress"

def test_create_monthly_goal_rejects_bad_month(monkeypatch, fake_account):
    db = _FakeDB()
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    body = {"title":"X","month_of":"2026-05","status":"planned"}  # missing day
    r = client.post("/monthly_goals", headers=headers, json=body)
    assert r.status_code == 422 or r.status_code == 400
```

Run: expect FAIL.

- [ ] **Step 7.2: Implement endpoint**

```python
@app.post("/monthly_goals", response_model=MonthlyGoal)
async def create_monthly_goal(payload: MonthlyGoalCreate, request: Request):
    account_id = await _resolve_account_dual_auth(request)
    db = get_db()
    # Validate month_of is YYYY-MM-01
    if not re.match(r"^\d{4}-\d{2}-01$", payload.month_of):
        raise HTTPException(400, "month_of must be YYYY-MM-01")
    row = {
        "account_id": account_id,
        "title": payload.title,
        "outcome": payload.outcome,
        "color_hex": payload.color_hex,
        "month_of": payload.month_of,
        "status": payload.status or "planned",
    }
    result = db.table("monthly_goals").insert(row).execute()
    return _row_to_monthly_goal(result.data[0])
```

Run tests: expect PASS.

- [ ] **Step 7.3: Commit**

```bash
git add main.py tests/test_monthly_goals.py
git commit -m "feat(goals): POST /monthly_goals"
```

---

### Task 8: PUT /monthly_goals/{id} with version check

**Files:** Modify `main.py`, extend tests.

- [ ] **Step 8.1: Write failing test**

```python
def test_update_monthly_goal_increments_version(monkeypatch, fake_account):
    db = _FakeDB()
    db.seed("monthly_goals", [{
        "id":"g1","account_id":fake_account.id,"title":"Old","month_of":"2026-05-01",
        "status":"planned","version":1,"outcome":None,"color_hex":None,
        "created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:00:00Z","deleted_at":None
    }])
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    r = client.put("/monthly_goals/g1", headers=headers, json={
        "title":"New","month_of":"2026-05-01","status":"in_progress","version":1
    })
    assert r.status_code == 200
    assert r.json()["version"] == 2
    assert r.json()["title"] == "New"

def test_update_monthly_goal_version_conflict(monkeypatch, fake_account):
    db = _FakeDB()
    db.seed("monthly_goals", [{
        "id":"g1","account_id":fake_account.id,"title":"Old","month_of":"2026-05-01",
        "status":"planned","version":3,"outcome":None,"color_hex":None,
        "created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:00:00Z","deleted_at":None
    }])
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    r = client.put("/monthly_goals/g1", headers=headers, json={
        "title":"New","month_of":"2026-05-01","status":"in_progress","version":1
    })
    assert r.status_code == 409
```

Run: expect FAIL.

- [ ] **Step 8.2: Implement**

```python
@app.put("/monthly_goals/{goal_id}", response_model=MonthlyGoal)
async def update_monthly_goal(goal_id: str, payload: MonthlyGoalUpdate, request: Request):
    account_id = await _resolve_account_dual_auth(request)
    db = get_db()
    existing = db.table("monthly_goals").select("version,deleted_at").eq(
        "id", goal_id
    ).eq("account_id", account_id).limit(1).execute()
    if not existing.data:
        raise HTTPException(404)
    if existing.data[0].get("deleted_at"):
        raise HTTPException(410, "Goal deleted")
    if existing.data[0]["version"] != payload.version:
        raise HTTPException(409, f"version conflict; current={existing.data[0]['version']}")

    update = {
        "title": payload.title,
        "outcome": payload.outcome,
        "color_hex": payload.color_hex,
        "month_of": payload.month_of,
        "status": payload.status,
        "version": payload.version + 1,
    }
    db.table("monthly_goals").update(update).eq("id", goal_id).execute()
    result = db.table("monthly_goals").select("*").eq("id", goal_id).limit(1).execute()
    return _row_to_monthly_goal(result.data[0])
```

Run tests: expect PASS.

- [ ] **Step 8.3: Commit**

```bash
git add main.py tests/test_monthly_goals.py
git commit -m "feat(goals): PUT /monthly_goals/{id} with optimistic concurrency"
```

---

### Task 9: DELETE /monthly_goals/{id} (soft delete + FK cleanup verified)

**Files:** Modify `main.py`, extend tests.

- [ ] **Step 9.1: Write failing test**

```python
def test_delete_monthly_goal_soft_deletes(monkeypatch, fake_account):
    db = _FakeDB()
    db.seed("monthly_goals", [{
        "id":"g1","account_id":fake_account.id,"title":"X","month_of":"2026-05-01",
        "status":"planned","version":1,"outcome":None,"color_hex":None,
        "created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:00:00Z","deleted_at":None
    }])
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    r = client.delete("/monthly_goals/g1", headers=headers)
    assert r.status_code == 204
    # Subsequent list should exclude it
    r2 = client.get("/monthly_goals", headers=headers)
    assert r2.json()["monthly_goals"] == []

def test_delete_monthly_goal_nulls_intention_fk(monkeypatch, fake_account):
    """When a monthly goal is deleted, intentions with monthly_goal_id=that
    should have the FK set to NULL via ON DELETE SET NULL. The soft-delete
    path doesn't trigger that — only hard delete does. So for soft-delete,
    we must explicitly null the FK in app code OR document that orphan
    references are tolerated. This test pins the expected behavior."""
    db = _FakeDB()
    db.seed("monthly_goals", [{
        "id":"g1","account_id":fake_account.id,"title":"X","month_of":"2026-05-01",
        "status":"planned","version":1,"outcome":None,"color_hex":None,
        "created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:00:00Z","deleted_at":None
    }])
    db.seed("intentions", [{
        "id":"i1","account_id":fake_account.id,"name":"Y","monthly_goal_id":"g1",
        "version":1,"mac_websites":[],"mac_bundle_ids":[],
        "created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:00:00Z","deleted_at":None,
        "strictness_preset":"standard","status":"planned"
    }])
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    client.delete("/monthly_goals/g1", headers=headers)
    rows = db.table("intentions").select("*").eq("id","i1").execute().data
    assert rows[0]["monthly_goal_id"] is None
```

- [ ] **Step 9.2: Implement**

```python
@app.delete("/monthly_goals/{goal_id}", status_code=204)
async def delete_monthly_goal(goal_id: str, request: Request):
    account_id = await _resolve_account_dual_auth(request)
    db = get_db()
    existing = db.table("monthly_goals").select("id").eq("id", goal_id).eq(
        "account_id", account_id
    ).limit(1).execute()
    if not existing.data:
        raise HTTPException(404)
    now_iso = datetime.now(timezone.utc).isoformat()
    # Soft delete the row.
    db.table("monthly_goals").update({"deleted_at": now_iso}).eq("id", goal_id).execute()
    # Null the FK on linked intentions (soft delete doesn't fire DB cascade).
    db.table("intentions").update({"monthly_goal_id": None}).eq(
        "monthly_goal_id", goal_id
    ).eq("account_id", account_id).execute()
```

Run tests: expect PASS.

- [ ] **Step 9.3: Commit**

```bash
git add main.py tests/test_monthly_goals.py
git commit -m "feat(goals): DELETE /monthly_goals/{id} + FK null on linked intentions"
```

---

### Task 10: Extend intentions write/read paths to round-trip new fields

**Files:**
- Modify: `main.py` — find `_row_to_intention` (~line 3427) + `create_intention` + `update_intention`

- [ ] **Step 10.1: Write failing test**

Create `tests/test_intention_extensions.py`:

```python
import pytest
from fastapi.testclient import TestClient
from main import app
from tests.conftest import _FakeDB, override_db

client = TestClient(app)

def test_create_intention_with_new_fields(monkeypatch, fake_account):
    db = _FakeDB()
    db.seed("monthly_goals", [{
        "id":"m1","account_id":fake_account.id,"title":"Ship","month_of":"2026-05-01",
        "status":"in_progress","version":1,"outcome":None,"color_hex":None,
        "created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:00:00Z","deleted_at":None
    }])
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    body = {
        "name":"Record 3 demos",
        "outcome":"Posted to IG by Sun",
        "status":"in_progress",
        "weekly_target_hours":4.0,
        "intent_text":"Recording demo videos for Puck launch.",
        "ai_scoring_enabled":True,
        "allow_websites":["notion.so","capcut.com"],
        "allow_bundle_ids":["com.apple.FinalCutPro"],
        "monthly_goal_id":"m1",
        "week_of":"2026-05-11",
    }
    r = client.post("/intentions", headers=headers, json=body)
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["outcome"] == "Posted to IG by Sun"
    assert j["status"] == "in_progress"
    assert j["weekly_target_hours"] == 4.0
    assert j["allow_websites"] == ["notion.so","capcut.com"]
    assert j["monthly_goal_id"] == "m1"
    assert j["week_of"] == "2026-05-11"

def test_list_intentions_week_filter(monkeypatch, fake_account):
    db = _FakeDB()
    db.seed("intentions", [
        {"id":"i1","account_id":fake_account.id,"name":"A","week_of":"2026-05-11",
         "version":1,"mac_websites":[],"mac_bundle_ids":[],"allow_websites":[],"allow_bundle_ids":[],
         "created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:00:00Z","deleted_at":None,
         "status":"in_progress","strictness_preset":"standard"},
        {"id":"i2","account_id":fake_account.id,"name":"B","week_of":"2026-05-04",
         "version":1,"mac_websites":[],"mac_bundle_ids":[],"allow_websites":[],"allow_bundle_ids":[],
         "created_at":"2026-05-04T00:00:00Z","updated_at":"2026-05-04T00:00:00Z","deleted_at":None,
         "status":"done","strictness_preset":"standard"},
    ])
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    r = client.get("/intentions?week=2026-05-11", headers=headers)
    names = [x["name"] for x in r.json()["intentions"]]
    assert names == ["A"]
```

Run: expect FAIL.

- [ ] **Step 10.2: Extend `_row_to_intention`**

Find `_row_to_intention` near line 3427 in `main.py`. Add the new fields to the dict it builds:

```python
        outcome=row.get("outcome"),
        status=row.get("status") or "planned",
        weekly_target_hours=row.get("weekly_target_hours"),
        intent_text=row.get("intent_text"),
        ai_scoring_enabled=row.get("ai_scoring_enabled") if row.get("ai_scoring_enabled") is not None else True,
        allow_websites=row.get("allow_websites") or [],
        allow_bundle_ids=row.get("allow_bundle_ids") or [],
        monthly_goal_id=row.get("monthly_goal_id"),
        week_of=row.get("week_of"),
```

- [ ] **Step 10.3: Extend `create_intention` payload mapping**

Find `@app.post("/intentions"`/`/focus_modes"`. In the INSERT payload dict, add the new fields read off `payload`. Ensure `None` values pass through (don't default-fill the DB columns — let Postgres apply defaults).

- [ ] **Step 10.4: Extend `update_intention` payload mapping**

Same for the PUT path. The current handler already wraps SET in a dict — extend it with all 9 new fields.

- [ ] **Step 10.5: Add `?week=` filter to `list_intentions`**

Find `list_intentions`. After the `account_id` filter, before `.execute()`:

```python
    week = request.query_params.get("week")
    if week:
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", week):
            raise HTTPException(400, "week must be YYYY-MM-DD")
        q = q.eq("week_of", week)
```

- [ ] **Step 10.6: Run tests + commit**

```bash
pytest tests/test_intention_extensions.py -v
git add main.py tests/test_intention_extensions.py
git commit -m "feat(goals): round-trip new weekly-goal fields on /intentions endpoints + ?week filter"
```

**Acceptance criteria:**
- POSTing a body with new fields creates a row that round-trips through GET.
- PUTting new fields updates them + bumps version.
- `GET /intentions?week=YYYY-MM-DD` filters server-side.
- Old clients (no new fields in body) keep working — fields are nullable.

---

## Phase 4: Account deletion cascade verification (small)

### Task 11: Verify account-deletion cascade

**Files:**
- Modify: `auth.py` (find `delete_account` or equivalent and verify the cascade list)

- [ ] **Step 11.1: Read current cascade**

```bash
grep -n -E "delete.*account|cascade|monthly_goals" auth.py | head -20
```

Find the existing cascade (probably iterates over a list of tables). Confirm `monthly_goals` is included. If `intentions` is in the list, `monthly_goals` should be added BEFORE `intentions` only matters for FK direction — actually `intentions.monthly_goal_id` is set NULL on delete, so order doesn't matter. But list both.

- [ ] **Step 11.2: Add `monthly_goals` to cascade table list**

If the cascade is a literal list, append `"monthly_goals"`. If it relies on DB FK CASCADE alone, the `monthly_goals.account_id REFERENCES accounts(id) ON DELETE CASCADE` clause already handles it — verify and skip code change.

- [ ] **Step 11.3: Write a test (if cascade is in app code)**

```python
def test_delete_account_cascades_monthly_goals(monkeypatch, fake_account):
    db = _FakeDB()
    db.seed("monthly_goals", [{"id":"m1","account_id":fake_account.id, "title":"X",
        "month_of":"2026-05-01","status":"planned","version":1,
        "created_at":"2026-05-14T00:00:00Z","updated_at":"2026-05-14T00:00:00Z","deleted_at":None,
        "outcome":None,"color_hex":None}])
    override_db(monkeypatch, db)
    headers = {"Authorization": f"Bearer {fake_account.token}"}
    r = client.delete("/account", headers=headers)
    assert r.status_code in (200, 204)
    rows = db.table("monthly_goals").select("*").execute().data
    assert rows == []
```

- [ ] **Step 11.4: Commit**

```bash
git add auth.py tests/test_monthly_goals.py
git commit -m "feat(goals): cascade monthly_goals on account deletion"
```

---

## Phase 5: Cross-repo PR + docs

### Task 12: Open PR + append to cross-repo log

- [ ] **Step 12.1: Push branch + open PR**

```bash
git push -u origin feat/prototype-to-production
gh pr create --title "feat(goals): weekly + monthly goal model + endpoints" --body "$(cat <<'EOF'
## Summary
- Migration 026: nine new columns on `intentions` + new `monthly_goals` table.
- Models + endpoints for CRUD on monthly goals; week filter on intentions.
- Backwards-compat: all new fields optional, no client breakage.

## Test plan
- [ ] `pytest tests/test_monthly_goals.py -v`
- [ ] `pytest tests/test_intention_extensions.py -v`
- [ ] Deploy migration to staging Supabase + verify existing iOS + Mac clients still work (no field drops on response).

Per spec: docs/prototype-to-production-2026-05-14.md (intentional-macos-app).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 12.2: Append to cross-repo log**

In `intentional-macos-app/docs/cross-repo-prototype-to-production-2026-05-14.md` (Plan B creates this file in its Task 0), append a "Backend (Plan A)" section linking to the PR and listing the new endpoints + new fields. Format mirrors `docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md`.

---

## Migration / rollback summary

- **Forward:** run `026_weekly_monthly_goals.sql` in Supabase SQL editor. Safe to run during business hours — purely additive, no locks on existing reads/writes.
- **Rollback:** run `rollback/026_*.sql`. DROPs the new table + columns. Any Mac/dashboard code expecting these fields will fail gracefully (Pydantic models default them).
- **Pre-deploy check:** confirm no existing rows in `intentions` have a value in any of the new column names (impossible since the columns don't exist yet, but defensive).
- **Post-deploy check:** `SELECT count(*) FROM monthly_goals` should return 0. `SELECT count(*) FROM intentions WHERE status IS NOT NULL` should equal total intention count (default fills).

---

## Self-review checklist

- [x] **Spec coverage:** Brief sections A/B/C/D map to: A → none (sidebar is Mac), B → Today weekly cards (intentions + monthly FK), C → Plan tab (monthly_goals CRUD + week filter), D → Weekly Goal editor (all new fields).
- [x] **No placeholders.** Every test has full body code. Every endpoint impl is shown.
- [x] **Type consistency.** `monthly_goal_id` is a UUID string everywhere; `week_of` and `month_of` are ISO dates; `status` is the same 5-value enum across Intention + MonthlyGoal.
- [x] **Rollback present.** Yes — `migrations/rollback/026_*.sql`.
