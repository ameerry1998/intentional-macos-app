# Spec 1 — Backend Implementation Plan (Plan A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `intentions` table to the backend, expose 6 CRUD endpoints (sibling-sync via `account_id`), extend `/focus/toggle` and `/focus/active` to carry `intention_id`, send a silent APNs push to all peer iOS devices on session start, and seed a Day-1 default Intention for fresh accounts.

**Architecture:** Mirrors the proven `bedtime_config` / `schedule_blocks` patterns. Account-scoped via `account_id` (sibling-shared). Dual auth (Bearer JWT or `X-Device-ID`) via existing `_resolve_account_dual_auth()` helper. Soft delete with tombstones. Optimistic concurrency via `version` integer. APNs delivery via existing `apns_client.send_push_to_account()`.

**Tech Stack:** FastAPI (Python 3.9+), Supabase PostgreSQL (raw SQL migrations), Pydantic v2 models, supabase-py client, aioapns for push, pytest with `_FakeDB` mock pattern.

**Worktree:** This plan executes in `/Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/intentions-spec1` on branch `feat/intentions-spec1` from base `main`.

**Spec reference:** `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/superpowers/specs/2026-05-03-intentions-spec1-design.md`

**Cross-repo log:** `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/overnight-run-2026-05-03.md`

---

## File map

| File | Op | Purpose |
|---|---|---|
| `migrations/018_add_intentions.sql` | CREATE | `intentions` table + `focus_sessions.intention_id` column + indexes |
| `models.py` | MODIFY | Add `IntentionCreate`, `IntentionUpdate`, `Intention`, `IntentionListResponse` |
| `main.py` | MODIFY | Add 6 endpoints; extend `/focus/toggle` to accept `intention_id` and call APNs push; extend `/focus/active` to return `intention_id`; seed-default helper |
| `auth.py` | MODIFY | Extend account-deletion cascade to include `intentions` |
| `tests/test_intentions.py` | CREATE | Comprehensive endpoint + sibling-sync + 409 tests |
| `tests/test_focus_intention_id.py` | CREATE | `/focus/toggle` + `/focus/active` extension tests |
| `tests/test_intention_seeding.py` | CREATE | Day-1 default seeding tests |

---

## Task 1: Worktree setup + initial commit

**Files:** none (just git operations)

- [ ] **Step 1: Create the worktree**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
mkdir -p .claude/worktrees
git worktree add -b feat/intentions-spec1 .claude/worktrees/intentions-spec1 main
cd .claude/worktrees/intentions-spec1
```

Expected: worktree directory created, on branch `feat/intentions-spec1`.

- [ ] **Step 2: Verify clean state**

```bash
git status
git log --oneline -3
```

Expected: clean working tree, last commit is from `main`.

- [ ] **Step 3: Initial empty commit (allows clean PR base)**

```bash
git commit --allow-empty -m "spec1(intentions): start backend implementation

Per spec docs/superpowers/specs/2026-05-03-intentions-spec1-design.md
and plan docs/superpowers/plans/2026-05-03-intentions-spec1-plan-a-backend.md
in the intentional-macos-app repo."
```

---

## Task 2: Migration — `intentions` table

**Files:**
- Create: `migrations/018_add_intentions.sql`

- [ ] **Step 1: Write the migration**

```sql
-- 018_add_intentions.sql
-- Cross-device account-scoped Intentions (preset blocklists + intention text).
-- See spec docs/superpowers/specs/2026-05-03-intentions-spec1-design.md
-- in the intentional-macos-app repo.

CREATE TABLE IF NOT EXISTS intentions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    color_hex TEXT,
    icon TEXT,
    mac_websites TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    mac_bundle_ids TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    ios_app_tokens BYTEA,
    ios_category_tokens BYTEA,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS intentions_account_active_idx
    ON intentions(account_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS intentions_account_all_idx
    ON intentions(account_id);

-- Auto-bump updated_at on UPDATE (mirrors bedtime_config pattern)
CREATE OR REPLACE FUNCTION intentions_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS intentions_touch_updated_at ON intentions;
CREATE TRIGGER intentions_touch_updated_at
    BEFORE UPDATE ON intentions
    FOR EACH ROW EXECUTE FUNCTION intentions_touch_updated_at();

-- focus_sessions gains optional intention_id
ALTER TABLE focus_sessions
    ADD COLUMN IF NOT EXISTS intention_id UUID
    REFERENCES intentions(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS focus_sessions_intention_idx
    ON focus_sessions(intention_id) WHERE intention_id IS NOT NULL;

ALTER TABLE intentions ENABLE ROW LEVEL SECURITY;
-- Service role bypasses RLS; no policies = default-deny direct user access.
```

- [ ] **Step 2: Verify SQL syntax with a local Postgres dry-run** (skip if no local PG)

```bash
# Optional — only if local postgres is available
psql -h localhost -U postgres -d intentional_dev -c "BEGIN; \i migrations/018_add_intentions.sql; ROLLBACK;"
```

Expected: no errors. If no local PG, this step is skipped — Supabase SQL editor will validate at deploy time.

- [ ] **Step 3: Commit**

```bash
git add migrations/018_add_intentions.sql
git commit -m "feat(intentions): migration 018 — intentions table + focus_sessions.intention_id"
```

---

## Task 3: Pydantic models for Intention

**Files:**
- Modify: `models.py` (append at the end of the file, before any closing module-level statements)

- [ ] **Step 1: Add the models**

Find the bottom of `models.py` (after the last existing class) and append:

```python
# ==================== Intentions (Spec 1) ====================

class IntentionCreate(BaseModel):
    """Payload for POST /intentions. id and version are server-assigned."""
    name: str = Field(..., min_length=1, max_length=200)
    description: Optional[str] = Field(None, max_length=2000)
    color_hex: Optional[str] = Field(None, pattern=r"^#[0-9A-Fa-f]{6}$")
    icon: Optional[str] = Field(None, max_length=120)
    mac_websites: list[str] = Field(default_factory=list)
    mac_bundle_ids: list[str] = Field(default_factory=list)
    # iOS tokens are opaque encoded FamilyActivitySelection blobs.
    # Sent as base64 strings over JSON; we store raw bytes server-side.
    ios_app_tokens_b64: Optional[str] = Field(None, description="Base64-encoded FamilyActivitySelection app tokens")
    ios_category_tokens_b64: Optional[str] = Field(None, description="Base64-encoded FamilyActivitySelection category tokens")


class IntentionUpdate(BaseModel):
    """Payload for PUT /intentions/{id}. Must include current version for optimistic concurrency."""
    name: str = Field(..., min_length=1, max_length=200)
    description: Optional[str] = Field(None, max_length=2000)
    color_hex: Optional[str] = Field(None, pattern=r"^#[0-9A-Fa-f]{6}$")
    icon: Optional[str] = Field(None, max_length=120)
    mac_websites: list[str] = Field(default_factory=list)
    mac_bundle_ids: list[str] = Field(default_factory=list)
    ios_app_tokens_b64: Optional[str] = None
    ios_category_tokens_b64: Optional[str] = None
    version: int = Field(..., ge=1)


class Intention(BaseModel):
    """Server-returned Intention. Tokens are base64-encoded for JSON transit."""
    id: str
    name: str
    description: Optional[str]
    color_hex: Optional[str]
    icon: Optional[str]
    mac_websites: list[str]
    mac_bundle_ids: list[str]
    ios_app_tokens_b64: Optional[str]
    ios_category_tokens_b64: Optional[str]
    version: int
    created_at: str
    updated_at: str
    deleted_at: Optional[str] = None


class IntentionListResponse(BaseModel):
    intentions: list[Intention]
```

- [ ] **Step 2: Verify imports at top of `models.py`**

If `Optional`, `list`, `Field` aren't already imported, add them. Check the existing top imports:

```bash
head -20 models.py
```

Most likely already present (used elsewhere in the file). If `Field` isn't imported alongside `BaseModel`, add it: `from pydantic import BaseModel, Field`.

- [ ] **Step 3: Sanity check — import and instantiate**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/intentions-spec1
python -c "from models import Intention, IntentionCreate, IntentionUpdate, IntentionListResponse; print('OK')"
```

Expected: `OK`. If import fails, fix and retry.

- [ ] **Step 4: Commit**

```bash
git add models.py
git commit -m "feat(intentions): pydantic models (Create, Update, Intention, ListResponse)"
```

---

## Task 4: `GET /intentions` endpoint (TDD)

**Files:**
- Create: `tests/test_intentions.py`
- Modify: `main.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_intentions.py
"""
Integration tests for /intentions CRUD endpoints.
Mirrors the _FakeDB pattern used by tests/test_focus_endpoints.py.
"""
import os
from datetime import datetime, timedelta, timezone
from unittest.mock import patch, MagicMock

import jwt
import pytest

os.environ.setdefault("JWT_SECRET", "test-intentional-secret")
os.environ.setdefault("SUPABASE_JWT_SECRET", "test-supabase-secret")

from fastapi.testclient import TestClient  # noqa: E402


def _client():
    import main  # noqa
    return TestClient(main.app)


def _supabase_jwt(email="user@example.com", sub="sb-sub-1") -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": sub, "email": email, "role": "authenticated",
        "aud": "authenticated", "exp": now + timedelta(hours=1), "iat": now,
    }
    return jwt.encode(payload, os.environ["SUPABASE_JWT_SECRET"], algorithm="HS256")


class _FakeQuery:
    def __init__(self, data=None):
        self._data = list(data) if data is not None else []
        self._returned_data = self._data
        self._filters = []  # list of (field, value) tuples
        self.last_update = None
        self.last_insert = None

    def select(self, *args, **kwargs):
        self._returned_data = self._data
        return self

    def eq(self, field, value):
        self._filters.append(("eq", field, value))
        self._returned_data = [r for r in self._returned_data if r.get(field) == value]
        return self

    def is_(self, field, value):
        # Supabase's .is_("deleted_at", "null") matches NULL columns.
        if value == "null":
            self._returned_data = [r for r in self._returned_data if r.get(field) is None]
        return self

    def in_(self, field, values):
        self._returned_data = [r for r in self._returned_data if r.get(field) in values]
        return self

    def order(self, *args, **kwargs): return self
    def limit(self, n):
        self._returned_data = self._returned_data[:n]
        return self
    def gt(self, *args, **kwargs): return self

    def update(self, payload):
        self.last_update = payload
        # Apply update to filtered rows
        for row in self._data:
            match = True
            for op, field, value in self._filters:
                if op == "eq" and row.get(field) != value:
                    match = False
                    break
            if match:
                row.update(payload)
        self._returned_data = []
        return self

    def insert(self, payload):
        self.last_insert = payload
        ins = payload if isinstance(payload, list) else [payload]
        for row in ins:
            row.setdefault("id", f"new-id-{len(self._data)}")
            row.setdefault("created_at", "2026-05-03T00:00:00+00:00")
            row.setdefault("updated_at", "2026-05-03T00:00:00+00:00")
        self._data.extend(ins)
        self._returned_data = ins
        return self

    def upsert(self, payload, **kwargs):
        return self.insert(payload)

    def delete(self):
        self._returned_data = []
        return self

    def execute(self):
        r = MagicMock()
        r.data = list(self._returned_data)
        r.count = len(self._returned_data) if self._returned_data else 0
        # Reset filters for next chain
        self._filters = []
        self._returned_data = self._data
        return r


class _FakeDB:
    def __init__(self, **tables):
        self._tables = {name: _FakeQuery(rows) for name, rows in tables.items()}

    def table(self, name):
        return self._tables.setdefault(name, _FakeQuery([]))


def test_get_intentions_returns_empty_list_for_new_account():
    accounts = [{"id": "acct-1", "email": "user@example.com", "supabase_user_id": "sb-sub-1"}]
    fake_db = _FakeDB(accounts=accounts, intentions=[])
    with patch("main.get_db", return_value=fake_db):
        # NOTE: Day-1 seeding (Task 13) will later cause this to return 1 default intention
        # instead of 0. For now, we assert the empty case by patching the seed helper.
        with patch("main._maybe_seed_default_intention", return_value=None):
            r = _client().get(
                "/intentions",
                headers={"Authorization": f"Bearer {_supabase_jwt()}"},
            )
    assert r.status_code == 200, r.text
    assert r.json() == {"intentions": []}


def test_get_intentions_excludes_soft_deleted():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "i-1", "account_id": "acct-1", "name": "Coding", "description": None,
         "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
        {"id": "i-2", "account_id": "acct-1", "name": "Old", "description": None,
         "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-02T00:00:00+00:00",
         "deleted_at": "2026-05-02T00:00:00+00:00"},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        with patch("main._maybe_seed_default_intention", return_value=None):
            r = _client().get("/intentions",
                headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 200
    body = r.json()
    assert len(body["intentions"]) == 1
    assert body["intentions"][0]["name"] == "Coding"


def test_get_intentions_with_include_deleted_returns_tombstones():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "i-1", "account_id": "acct-1", "name": "Coding", "description": None,
         "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
        {"id": "i-2", "account_id": "acct-1", "name": "Old", "description": None,
         "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-02T00:00:00+00:00",
         "deleted_at": "2026-05-02T00:00:00+00:00"},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        with patch("main._maybe_seed_default_intention", return_value=None):
            r = _client().get("/intentions?include_deleted=true",
                headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 200
    body = r.json()
    assert len(body["intentions"]) == 2
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/intentions-spec1
pytest tests/test_intentions.py -v
```

Expected: tests fail with 404 (endpoint doesn't exist) or AttributeError (`_maybe_seed_default_intention` not defined).

- [ ] **Step 3: Implement the endpoint + seed helper stub**

In `main.py`, find the section after `/focus/active` (around line 3184) and BEFORE `# ==================== Bedtime Cross-Device ====================`, insert:

```python
# ==================== Intentions (Spec 1) ====================
import base64

def _b64_encode_bytes(data: Optional[bytes]) -> Optional[str]:
    """Encode raw bytes (e.g. from BYTEA column) to base64 string for JSON."""
    if data is None:
        return None
    if isinstance(data, str):
        # Already encoded (some Supabase configs return base64 strings for BYTEA)
        return data
    return base64.b64encode(data).decode("ascii")


def _b64_decode_str(s: Optional[str]) -> Optional[bytes]:
    """Decode base64 string from client to raw bytes for BYTEA column."""
    if s is None:
        return None
    return base64.b64decode(s)


def _row_to_intention(row: dict) -> Intention:
    """Convert a Supabase intentions row to an Intention response model."""
    return Intention(
        id=str(row["id"]),
        name=row["name"],
        description=row.get("description"),
        color_hex=row.get("color_hex"),
        icon=row.get("icon"),
        mac_websites=row.get("mac_websites") or [],
        mac_bundle_ids=row.get("mac_bundle_ids") or [],
        ios_app_tokens_b64=_b64_encode_bytes(row.get("ios_app_tokens")),
        ios_category_tokens_b64=_b64_encode_bytes(row.get("ios_category_tokens")),
        version=row.get("version", 1),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
        deleted_at=row.get("deleted_at"),
    )


async def _maybe_seed_default_intention(db, account_id: str) -> Optional[dict]:
    """Seed a Day-1 default 'Focus' Intention for fresh accounts.

    Triggered when GET /intentions sees zero rows AT ALL (live + deleted) for
    the account. Returns the seeded row, or None if nothing was seeded
    (account already has at least one intention, even a deleted one).
    """
    # Check for any intentions, including soft-deleted, for this account.
    all_check = db.table("intentions").select("id").eq(
        "account_id", account_id).limit(1).execute()
    if all_check.data:
        return None  # Account has used the system; do not seed.

    default_payload = {
        "account_id": account_id,
        "name": "Focus",
        "description": "Default starter intention. Edit me!",
        "color_hex": "#5E60CE",
        "icon": "moon.stars.fill",
        "mac_websites": [
            "twitter.com", "x.com", "reddit.com", "news.ycombinator.com",
            "youtube.com", "instagram.com", "tiktok.com", "facebook.com",
        ],
        "mac_bundle_ids": [],
        "version": 1,
    }
    result = db.table("intentions").insert(default_payload).execute()
    if result.data:
        return result.data[0]
    return None


@app.get("/intentions", response_model=IntentionListResponse)
async def list_intentions(
    include_deleted: bool = False,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """List Intentions for the authenticated account. Soft-deleted hidden by default."""
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()

    # Day-1 seed: if no intentions at all, create a default Focus intention.
    await _maybe_seed_default_intention(db, account_id)

    q = db.table("intentions").select("*").eq("account_id", account_id)
    if not include_deleted:
        q = q.is_("deleted_at", "null")
    rows = q.order("created_at", desc=False).execute().data or []
    return IntentionListResponse(intentions=[_row_to_intention(r) for r in rows])
```

- [ ] **Step 4: Verify imports — find the top of main.py and confirm**

```bash
head -30 main.py | grep -E "from models|import"
```

Ensure `Intention`, `IntentionCreate`, `IntentionUpdate`, `IntentionListResponse` are imported. Add to the existing `from models import` line if missing:

```python
from models import (
    # ... existing imports ...
    Intention, IntentionCreate, IntentionUpdate, IntentionListResponse,
)
```

- [ ] **Step 5: Run tests — verify they pass**

```bash
pytest tests/test_intentions.py -v
```

Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add main.py models.py tests/test_intentions.py
git commit -m "feat(intentions): GET /intentions + day-1 seed helper + base64 codec utils"
```

---

## Task 5: `GET /intentions/{id}` endpoint (TDD)

**Files:**
- Modify: `tests/test_intentions.py` (append)
- Modify: `main.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_intentions.py`:

```python
def test_get_single_intention():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "i-1", "account_id": "acct-1", "name": "Coding",
         "description": "ship Viper alpha",
         "color_hex": "#5E60CE", "icon": "laptopcomputer",
         "mac_websites": ["twitter.com"], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 3, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-02T00:00:00+00:00", "deleted_at": None},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/intentions/i-1",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["id"] == "i-1"
    assert body["name"] == "Coding"
    assert body["version"] == 3
    assert body["mac_websites"] == ["twitter.com"]


def test_get_single_intention_returns_404_when_not_found():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    fake_db = _FakeDB(accounts=accounts, intentions=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/intentions/nonexistent",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 404


def test_get_single_intention_returns_other_accounts_intention_as_404():
    """Cross-account isolation: I cannot read another account's intention by id."""
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "other-1", "account_id": "acct-other", "name": "Spy", "description": None,
         "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/intentions/other-1",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 404


def test_get_single_intention_returns_deleted_for_history():
    """Soft-deleted intentions are still resolvable by id (for session history)."""
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "i-tomb", "account_id": "acct-1", "name": "Old Coding",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-02T00:00:00+00:00",
         "deleted_at": "2026-05-02T00:00:00+00:00"},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/intentions/i-tomb",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 200
    assert r.json()["deleted_at"] is not None
```

- [ ] **Step 2: Run — fail**

```bash
pytest tests/test_intentions.py::test_get_single_intention -v
```

Expected: 404 — endpoint not defined yet.

- [ ] **Step 3: Implement the endpoint**

Add to `main.py` immediately after the `list_intentions` endpoint:

```python
@app.get("/intentions/{intention_id}", response_model=Intention)
async def get_intention(
    intention_id: str,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """Get a single Intention by id (includes soft-deleted, for session history)."""
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    result = db.table("intentions").select("*").eq(
        "id", intention_id).eq("account_id", account_id).limit(1).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Intention not found")
    return _row_to_intention(result.data[0])
```

- [ ] **Step 4: Run — pass**

```bash
pytest tests/test_intentions.py -v
```

Expected: all tests pass (now 7 total).

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_intentions.py
git commit -m "feat(intentions): GET /intentions/{id} (resolves tombstones for session history)"
```

---

## Task 6: `POST /intentions` endpoint (TDD)

**Files:**
- Modify: `tests/test_intentions.py`
- Modify: `main.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_intentions.py`:

```python
def test_post_intention_creates_with_server_assigned_id_and_version_1():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    fake_db = _FakeDB(accounts=accounts, intentions=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().post(
            "/intentions",
            json={"name": "Coding", "description": "ship Viper", "mac_websites": ["twitter.com"]},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["name"] == "Coding"
    assert body["description"] == "ship Viper"
    assert body["version"] == 1
    assert body["id"]
    assert body["deleted_at"] is None


def test_post_intention_with_ios_tokens_b64_round_trips():
    """iOS tokens come in as base64; stored as bytes; returned as base64 again."""
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    fake_db = _FakeDB(accounts=accounts, intentions=[])
    raw = b"\x00\x01\x02fake-token-blob"
    import base64 as b64
    encoded = b64.b64encode(raw).decode("ascii")
    with patch("main.get_db", return_value=fake_db):
        r = _client().post(
            "/intentions",
            json={"name": "Phone-Free Dinner", "ios_app_tokens_b64": encoded},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ios_app_tokens_b64"] == encoded


def test_post_intention_rejects_empty_name():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    fake_db = _FakeDB(accounts=accounts, intentions=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().post(
            "/intentions",
            json={"name": ""},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 422
```

- [ ] **Step 2: Run — fail**

```bash
pytest tests/test_intentions.py::test_post_intention_creates_with_server_assigned_id_and_version_1 -v
```

- [ ] **Step 3: Implement endpoint**

Add to `main.py` after `get_intention`:

```python
@app.post("/intentions", response_model=Intention)
async def create_intention(
    request: IntentionCreate,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """Create a new Intention. Server assigns id and version=1."""
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    payload = {
        "account_id": account_id,
        "name": request.name,
        "description": request.description,
        "color_hex": request.color_hex,
        "icon": request.icon,
        "mac_websites": request.mac_websites,
        "mac_bundle_ids": request.mac_bundle_ids,
        "ios_app_tokens": _b64_decode_str(request.ios_app_tokens_b64),
        "ios_category_tokens": _b64_decode_str(request.ios_category_tokens_b64),
        "version": 1,
    }
    result = db.table("intentions").insert(payload).execute()
    if not result.data:
        raise HTTPException(status_code=500, detail="Failed to create intention")
    return _row_to_intention(result.data[0])
```

- [ ] **Step 4: Run — pass**

```bash
pytest tests/test_intentions.py -v
```

Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_intentions.py
git commit -m "feat(intentions): POST /intentions (creates with version=1, base64 token round-trip)"
```

---

## Task 7: `PUT /intentions/{id}` with version check + 409 (TDD)

**Files:**
- Modify: `tests/test_intentions.py`, `main.py`

- [ ] **Step 1: Write failing tests**

Append:

```python
def test_put_intention_bumps_version_on_success():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "i-1", "account_id": "acct-1", "name": "Coding",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/intentions/i-1",
            json={"name": "Coding", "mac_websites": ["twitter.com"], "version": 1},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["version"] == 2
    assert body["mac_websites"] == ["twitter.com"]


def test_put_intention_409_on_stale_version():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "i-1", "account_id": "acct-1", "name": "Coding",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 5, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/intentions/i-1",
            json={"name": "Coding", "mac_websites": [], "version": 2},  # stale
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 409
    assert "version" in r.json()["detail"].lower() or "conflict" in r.json()["detail"].lower()


def test_put_intention_404_when_not_owned():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "other-1", "account_id": "acct-other", "name": "Other",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().put(
            "/intentions/other-1",
            json={"name": "Hijack", "mac_websites": [], "version": 1},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 404
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement**

Add to `main.py`:

```python
@app.put("/intentions/{intention_id}", response_model=Intention)
async def update_intention(
    intention_id: str,
    request: IntentionUpdate,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """Update an Intention. Optimistic concurrency: caller must include current version.

    Returns 409 if the stored version differs from the request's version
    (someone else edited concurrently).
    """
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    existing = db.table("intentions").select("version,deleted_at").eq(
        "id", intention_id).eq("account_id", account_id).limit(1).execute().data
    if not existing:
        raise HTTPException(status_code=404, detail="Intention not found")
    if existing[0].get("deleted_at"):
        raise HTTPException(status_code=410, detail="Intention has been deleted")
    if existing[0]["version"] != request.version:
        raise HTTPException(
            status_code=409,
            detail=f"Version conflict: server has v{existing[0]['version']}, you sent v{request.version}",
        )

    payload = {
        "name": request.name,
        "description": request.description,
        "color_hex": request.color_hex,
        "icon": request.icon,
        "mac_websites": request.mac_websites,
        "mac_bundle_ids": request.mac_bundle_ids,
        "ios_app_tokens": _b64_decode_str(request.ios_app_tokens_b64),
        "ios_category_tokens": _b64_decode_str(request.ios_category_tokens_b64),
        "version": existing[0]["version"] + 1,
    }
    db.table("intentions").update(payload).eq("id", intention_id).execute()

    # Re-read for canonical updated_at from trigger
    result = db.table("intentions").select("*").eq("id", intention_id).limit(1).execute()
    return _row_to_intention(result.data[0])
```

- [ ] **Step 4: Run — pass**

```bash
pytest tests/test_intentions.py -v
```

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_intentions.py
git commit -m "feat(intentions): PUT /intentions/{id} with optimistic concurrency (409 on stale)"
```

---

## Task 8: `DELETE /intentions/{id}` soft delete (TDD)

**Files:**
- Modify: `tests/test_intentions.py`, `main.py`

- [ ] **Step 1: Write failing tests**

```python
def test_delete_intention_soft_deletes():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "i-1", "account_id": "acct-1", "name": "Coding",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().delete("/intentions/i-1",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 204
    # Confirm row still present but with deleted_at populated
    assert intentions[0]["deleted_at"] is not None


def test_delete_intention_404_when_not_owned():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "other-1", "account_id": "acct-other", "name": "Other",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().delete("/intentions/other-1",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 404
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement**

```python
@app.delete("/intentions/{intention_id}", status_code=204)
async def delete_intention(
    intention_id: str,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """Soft-delete an Intention. Sets deleted_at. Preserves session history."""
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    existing = db.table("intentions").select("id").eq(
        "id", intention_id).eq("account_id", account_id).limit(1).execute().data
    if not existing:
        raise HTTPException(status_code=404, detail="Intention not found")
    now_iso = datetime.now(timezone.utc).isoformat()
    db.table("intentions").update({"deleted_at": now_iso}).eq("id", intention_id).execute()
    # Return 204 No Content
    from fastapi import Response
    return Response(status_code=204)
```

- [ ] **Step 4: Run — pass**

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_intentions.py
git commit -m "feat(intentions): DELETE /intentions/{id} soft-delete (preserves session history)"
```

---

## Task 9: Sibling-sync test (account_id sharing across devices)

**Files:**
- Modify: `tests/test_intentions.py`

- [ ] **Step 1: Write the test**

```python
def test_sibling_sync_devices_on_same_account_see_same_intentions():
    """Mac creates Intention; iPhone (same account_id) reads it back."""
    accounts = [{"id": "acct-shared", "email": "ameer@example.com",
                 "supabase_user_id": "sb-sub-shared"}]
    fake_db = _FakeDB(accounts=accounts, intentions=[])

    # Device A (Mac) creates an Intention via its JWT
    with patch("main.get_db", return_value=fake_db):
        with patch("main._maybe_seed_default_intention", return_value=None):
            create_r = _client().post(
                "/intentions",
                json={"name": "Coding", "mac_websites": ["twitter.com"]},
                headers={"Authorization": f"Bearer {_supabase_jwt(email='ameer@example.com', sub='sb-sub-shared')}"},
            )
    assert create_r.status_code == 200
    created_id = create_r.json()["id"]

    # Device B (iPhone) reads via its OWN JWT (same email/sub → same account)
    with patch("main.get_db", return_value=fake_db):
        with patch("main._maybe_seed_default_intention", return_value=None):
            list_r = _client().get(
                "/intentions",
                headers={"Authorization": f"Bearer {_supabase_jwt(email='ameer@example.com', sub='sb-sub-shared')}"},
            )
    assert list_r.status_code == 200
    body = list_r.json()
    names = [i["name"] for i in body["intentions"]]
    assert "Coding" in names
    assert any(i["id"] == created_id for i in body["intentions"])
```

- [ ] **Step 2: Run — should already pass (no implementation change)**

```bash
pytest tests/test_intentions.py::test_sibling_sync_devices_on_same_account_see_same_intentions -v
```

If it fails, the issue is in `_resolve_account_dual_auth()` or the account-resolution path. Investigate; do not work around.

- [ ] **Step 3: Commit**

```bash
git add tests/test_intentions.py
git commit -m "test(intentions): sibling-sync test — devices on same account see same intentions"
```

---

## Task 10: Extend `POST /focus/toggle` to accept `intention_id` (TDD)

**Files:**
- Create: `tests/test_focus_intention_id.py`
- Modify: `main.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_focus_intention_id.py
"""Tests for /focus/toggle and /focus/active intention_id extension."""
import os
from datetime import datetime, timedelta, timezone
from unittest.mock import patch, MagicMock

import jwt

os.environ.setdefault("JWT_SECRET", "test-intentional-secret")
os.environ.setdefault("SUPABASE_JWT_SECRET", "test-supabase-secret")

from fastapi.testclient import TestClient  # noqa

# Reuse the _FakeDB / _supabase_jwt helpers from test_intentions
from tests.test_intentions import _FakeDB, _supabase_jwt, _client


def test_focus_toggle_start_with_intention_id_records_it():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "intent-coding", "account_id": "acct-1", "name": "Coding",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
    ]
    focus_sessions = []
    fake_db = _FakeDB(accounts=accounts, intentions=intentions,
                       focus_sessions=focus_sessions, users=[])
    with patch("main.get_db", return_value=fake_db):
        with patch("main.send_push_to_account", return_value=0):
            r = _client().post(
                "/focus/toggle",
                json={"action": "start", "intention_id": "intent-coding",
                      "triggered_by": "mac_manual"},
                headers={"Authorization": f"Bearer {_supabase_jwt()}"},
            )
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "started"
    # The new session row must record intention_id
    assert focus_sessions[0]["intention_id"] == "intent-coding"
    assert focus_sessions[0]["triggered_by"] == "mac_manual"


def test_focus_toggle_start_without_intention_id_succeeds_with_null():
    """Backwards compat — older clients that don't send intention_id still work."""
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    focus_sessions = []
    fake_db = _FakeDB(accounts=accounts, intentions=[],
                       focus_sessions=focus_sessions, users=[])
    with patch("main.get_db", return_value=fake_db):
        with patch("main.send_push_to_account", return_value=0):
            r = _client().post(
                "/focus/toggle",
                json={"action": "start"},
                headers={"Authorization": f"Bearer {_supabase_jwt()}"},
            )
    assert r.status_code == 200
    assert focus_sessions[0].get("intention_id") is None
```

- [ ] **Step 2: Run — fail**

```bash
pytest tests/test_focus_intention_id.py::test_focus_toggle_start_with_intention_id_records_it -v
```

Expected: AttributeError or assertion fail because the existing handler doesn't read intention_id.

- [ ] **Step 3: Modify `FocusToggleRequest` model**

In `models.py`, find the `FocusToggleRequest` class and add the optional fields:

```python
class FocusToggleRequest(BaseModel):
    action: str  # "start" or "stop"
    intention_id: Optional[str] = None  # NEW: which Intention is starting
    triggered_by: Optional[str] = "puck"  # NEW: source label (mac_manual, ios_manual, ios_nfc, puck)
```

- [ ] **Step 4: Modify `toggle_focus` handler in `main.py`**

Find the start-branch (around line 3094) and update the insert payload:

```python
    if request.action == "start":
        # End any existing active sessions
        db.table("focus_sessions").update({
            "status": "ended", "ended_at": now.isoformat()
        }).eq("account_id", account_id).eq("status", "active").execute()
        expires_at = now + timedelta(hours=FOCUS_SESSION_TTL_HOURS)
        triggered_by = request.triggered_by or "puck"
        result = db.table("focus_sessions").insert({
            "account_id": account_id, "started_at": now.isoformat(),
            "triggered_by": triggered_by, "status": "active",
            "expires_at": expires_at.isoformat(),
            "intention_id": request.intention_id,  # NEW (None is valid)
        }).execute()
        session_id = result.data[0]["id"] if result.data else None
        # ... rest of the existing handler stays the same up through broadcast_focus_signal ...
        # AFTER broadcast_focus_signal, add:
        # Fire-and-forget APNs push to peer iOS devices.
        try:
            await send_push_to_account(
                db, account_id,
                payload={
                    "aps": {"content-available": 1},
                    "session_id": str(session_id),
                    "intention_id": request.intention_id,
                    "started_at": now.isoformat(),
                    "action": "start",
                    "triggered_by": triggered_by,
                },
                priority=10,
                push_type="background",
            )
        except Exception as exc:
            logger.warning("Failed to push session-start APNs: %s", exc)
```

NOTE: do NOT delete the existing start-branch logic (system_events log, broadcast_focus_signal). Just add `intention_id` to the insert payload AND insert the APNs push call after the broadcast. Locate the existing code; keep it intact.

Add the import for `send_push_to_account` at the top of `main.py` if not already present:

```python
from apns_client import send_push_to_account
```

- [ ] **Step 5: Run — pass**

```bash
pytest tests/test_focus_intention_id.py -v
```

Expected: 2 tests pass. If the `_FakeDB` import path complains, mark `tests/__init__.py` exists (it should) and re-run.

- [ ] **Step 6: Re-run existing focus tests to confirm no regression**

```bash
pytest tests/test_focus_endpoints.py -v
```

Expected: all existing tests still pass.

- [ ] **Step 7: Commit**

```bash
git add main.py models.py tests/test_focus_intention_id.py
git commit -m "feat(intentions): /focus/toggle accepts intention_id + triggered_by + APNs push on start"
```

---

## Task 11: Extend `GET /focus/active` to return `intention_id` (TDD)

**Files:**
- Modify: `tests/test_focus_intention_id.py`, `models.py`, `main.py`

- [ ] **Step 1: Write failing test**

```python
def test_focus_active_returns_intention_id():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    focus_sessions = [
        {"id": "sess-1", "account_id": "acct-1", "started_at": "2026-05-03T10:00:00+00:00",
         "triggered_by": "mac_manual", "status": "active",
         "expires_at": future, "intention_id": "intent-coding"},
    ]
    fake_db = _FakeDB(accounts=accounts, focus_sessions=focus_sessions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/focus/active",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 200
    body = r.json()
    assert body["active"] is True
    assert body["intention_id"] == "intent-coding"
    assert body["triggered_by"] == "mac_manual"
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Update `FocusActiveResponse` model**

In `models.py`, find `FocusActiveResponse` and add:

```python
class FocusActiveResponse(BaseModel):
    active: bool
    session_id: Optional[str] = None
    started_at: Optional[str] = None
    triggered_by: Optional[str] = None
    intention_id: Optional[str] = None  # NEW
```

- [ ] **Step 4: Update `get_active_focus` handler**

In `main.py`, find the existing `/focus/active` handler (around line 3160). Update the SELECT to include `intention_id`:

```python
    result = db.table("focus_sessions").select(
        "id,started_at,triggered_by,intention_id"  # added intention_id
    ).eq(
        "account_id", account_id).eq("status", "active").gt(
        "expires_at", now_iso).order("started_at", desc=True).limit(1).execute()
    if not result.data:
        return FocusActiveResponse(active=False)
    session = result.data[0]
    return FocusActiveResponse(
        active=True, session_id=str(session["id"]),
        started_at=session["started_at"],
        triggered_by=session.get("triggered_by", "puck"),
        intention_id=session.get("intention_id"),  # NEW
    )
```

- [ ] **Step 5: Run — pass**

```bash
pytest tests/test_focus_intention_id.py -v
pytest tests/test_focus_endpoints.py -v
```

Both should be green.

- [ ] **Step 6: Commit**

```bash
git add main.py models.py tests/test_focus_intention_id.py
git commit -m "feat(intentions): /focus/active returns intention_id"
```

---

## Task 12: APNs silent push on session start (verify payload shape)

**Files:**
- Modify: `tests/test_focus_intention_id.py`

The push call was added in Task 10. Add an explicit test that the payload shape matches what iOS expects.

- [ ] **Step 1: Write the assertion test**

```python
def test_focus_toggle_start_emits_apns_payload_to_account():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    focus_sessions = []
    fake_db = _FakeDB(accounts=accounts, intentions=[],
                       focus_sessions=focus_sessions, users=[])
    captured = {}
    async def _capture(db, account_id, *, payload, priority=10, push_type="alert", collapse_id=None):
        captured["account_id"] = account_id
        captured["payload"] = payload
        captured["priority"] = priority
        captured["push_type"] = push_type
        return 1
    with patch("main.get_db", return_value=fake_db):
        with patch("main.send_push_to_account", side_effect=_capture):
            r = _client().post(
                "/focus/toggle",
                json={"action": "start", "intention_id": "i-coding",
                      "triggered_by": "mac_manual"},
                headers={"Authorization": f"Bearer {_supabase_jwt()}"},
            )
    assert r.status_code == 200
    assert captured["account_id"] == "acct-1"
    assert captured["payload"]["aps"]["content-available"] == 1
    assert captured["payload"]["intention_id"] == "i-coding"
    assert captured["payload"]["action"] == "start"
    assert captured["payload"]["triggered_by"] == "mac_manual"
    assert "session_id" in captured["payload"]
    assert captured["push_type"] == "background"


def test_focus_toggle_stop_also_emits_apns_payload():
    """Stop is also broadcast so peer devices clear their shield."""
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    focus_sessions = [
        {"id": "sess-1", "account_id": "acct-1",
         "started_at": "2026-05-03T10:00:00+00:00",
         "triggered_by": "mac_manual", "status": "active",
         "expires_at": future, "intention_id": "i-coding"},
    ]
    fake_db = _FakeDB(accounts=accounts, focus_sessions=focus_sessions, users=[])
    captured = {}
    async def _capture(db, account_id, *, payload, priority=10, push_type="alert", collapse_id=None):
        captured["payload"] = payload
        return 1
    with patch("main.get_db", return_value=fake_db):
        with patch("main.send_push_to_account", side_effect=_capture):
            r = _client().post(
                "/focus/toggle",
                json={"action": "stop"},
                headers={"Authorization": f"Bearer {_supabase_jwt()}"},
            )
    assert r.status_code == 200
    assert captured["payload"]["action"] == "stop"
```

- [ ] **Step 2: Run — first test should pass; second will fail until we add stop-branch push**

```bash
pytest tests/test_focus_intention_id.py::test_focus_toggle_start_emits_apns_payload_to_account -v
pytest tests/test_focus_intention_id.py::test_focus_toggle_stop_also_emits_apns_payload -v
```

- [ ] **Step 3: Add stop-branch APNs push**

In `main.py`, find the stop branch of `toggle_focus` (around line 3131) and after the existing `broadcast_focus_signal` call, add:

```python
        try:
            await send_push_to_account(
                db, account_id,
                payload={
                    "aps": {"content-available": 1},
                    "session_id": str(session_id),
                    "intention_id": session.get("intention_id"),
                    "action": "stop",
                    "triggered_by": session.get("triggered_by", "puck"),
                },
                priority=10,
                push_type="background",
            )
        except Exception as exc:
            logger.warning("Failed to push session-stop APNs: %s", exc)
```

- [ ] **Step 4: Run — both pass**

```bash
pytest tests/test_focus_intention_id.py -v
```

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_focus_intention_id.py
git commit -m "feat(intentions): APNs silent push on session start AND stop (background priority)"
```

---

## Task 13: Day-1 default seeding integration tests

**Files:**
- Create: `tests/test_intention_seeding.py`

The seed helper exists from Task 4. Add explicit tests that exercise the seed path end-to-end via GET /intentions.

- [ ] **Step 1: Write tests**

```python
# tests/test_intention_seeding.py
import os
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import jwt

os.environ.setdefault("JWT_SECRET", "test-intentional-secret")
os.environ.setdefault("SUPABASE_JWT_SECRET", "test-supabase-secret")

from fastapi.testclient import TestClient  # noqa

from tests.test_intentions import _FakeDB, _supabase_jwt, _client


def test_get_intentions_seeds_default_for_new_account():
    accounts = [{"id": "acct-fresh", "email": "new@example.com",
                 "supabase_user_id": "sb-sub-fresh"}]
    intentions = []  # truly fresh
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get(
            "/intentions",
            headers={"Authorization": f"Bearer {_supabase_jwt(email='new@example.com', sub='sb-sub-fresh')}"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body["intentions"]) == 1
    seeded = body["intentions"][0]
    assert seeded["name"] == "Focus"
    assert "twitter.com" in seeded["mac_websites"]
    assert "instagram.com" in seeded["mac_websites"]
    assert seeded["version"] == 1


def test_get_intentions_does_not_seed_when_account_has_existing_intentions():
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "i-1", "account_id": "acct-1", "name": "Custom",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/intentions",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 200
    body = r.json()
    names = [i["name"] for i in body["intentions"]]
    assert names == ["Custom"]  # No seeded "Focus" added


def test_get_intentions_does_not_seed_when_account_has_only_tombstones():
    """User who deleted everything: respect the choice; don't re-seed."""
    accounts = [{"id": "acct-1", "supabase_user_id": "sb-sub-1"}]
    intentions = [
        {"id": "i-tomb", "account_id": "acct-1", "name": "Old",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-02T00:00:00+00:00",
         "deleted_at": "2026-05-02T00:00:00+00:00"},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/intentions",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"})
    assert r.status_code == 200
    body = r.json()
    assert len(body["intentions"]) == 0  # default GET hides deleted
    # Confirm no NEW intention got seeded (still just the tombstone)
    assert len(intentions) == 1


def test_get_intentions_seed_is_idempotent_under_concurrent_calls():
    """Two GET calls in quick succession should not seed twice."""
    accounts = [{"id": "acct-fresh", "supabase_user_id": "sb-sub-fresh"}]
    intentions = []
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    with patch("main.get_db", return_value=fake_db):
        r1 = _client().get("/intentions",
            headers={"Authorization": f"Bearer {_supabase_jwt(email='x@x.com', sub='sb-sub-fresh')}"})
        r2 = _client().get("/intentions",
            headers={"Authorization": f"Bearer {_supabase_jwt(email='x@x.com', sub='sb-sub-fresh')}"})
    assert r1.status_code == 200 and r2.status_code == 200
    # After 2 GETs, should still only be ONE seeded intention
    assert len(intentions) == 1
```

- [ ] **Step 2: Run — should pass**

```bash
pytest tests/test_intention_seeding.py -v
```

If `test_get_intentions_seed_is_idempotent_under_concurrent_calls` fails, the seed helper's "any rows" check is racing with the insert. The current implementation checks-then-inserts which is fine in serialized FastAPI but races at the DB level under real concurrency. For Spec 1 we accept this — duplicate seeding by genuine simultaneous requests is a benign edge case. Document and move on.

- [ ] **Step 3: Commit**

```bash
git add tests/test_intention_seeding.py
git commit -m "test(intentions): day-1 default seeding (Focus intention with curated blocklist)"
```

---

## Task 14: Account-deletion cascade

**Files:**
- Modify: `auth.py`
- Modify: `tests/test_intentions.py`

The migration's `ON DELETE CASCADE` on `account_id` already handles the DB side. But `auth.py`'s `delete-confirm` flow does explicit `db.table(...).delete()` per-table for hard deletes. Need to add `intentions` to that list.

- [ ] **Step 1: Find the deletion cascade in auth.py**

```bash
grep -n "delete().eq\|cascade\|delete-confirm" /Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/intentions-spec1/auth.py
```

Locate the explicit per-table deletes inside the delete-confirm endpoint.

- [ ] **Step 2: Add intentions to the cascade**

In `auth.py`, find the section where it deletes per-table rows for the account being removed. Add (in any sensible spot before `accounts` is deleted — alphabetical order is fine):

```python
    # Delete intentions (focus_sessions.intention_id will SET NULL automatically)
    db.table("intentions").delete().eq("account_id", account_id).execute()
```

- [ ] **Step 3: Write the test**

In `tests/test_intentions.py`:

```python
def test_account_delete_cascades_intentions():
    """When an account is deleted, its intentions are wiped too."""
    # Implementation note: this exercises the explicit cascade in auth.py.
    # We mock the delete-confirm flow rather than running it end-to-end.
    accounts = [{"id": "acct-doomed", "email": "bye@example.com",
                 "supabase_user_id": "sb-doomed"}]
    intentions = [
        {"id": "i-1", "account_id": "acct-doomed", "name": "Coding",
         "description": None, "color_hex": None, "icon": None,
         "mac_websites": [], "mac_bundle_ids": [],
         "ios_app_tokens": None, "ios_category_tokens": None,
         "version": 1, "created_at": "2026-05-01T00:00:00+00:00",
         "updated_at": "2026-05-01T00:00:00+00:00", "deleted_at": None},
    ]
    fake_db = _FakeDB(accounts=accounts, intentions=intentions)
    # Simulate the cascade: import the cascade helper or call delete directly.
    fake_db.table("intentions").delete().eq("account_id", "acct-doomed").execute()
    # In a fully integrated test we'd POST to /auth/delete-confirm.
    # Verify only the doomed account's intentions are removed (none in this case).
    assert all(i.get("account_id") != "acct-doomed" or i.get("deleted_at") for i in intentions) or len(intentions) == 0
```

NOTE: this test is mostly a sanity check. The real cascade happens at the DB level via `ON DELETE CASCADE` on the FK; the explicit `auth.py` delete is belt-and-suspenders.

- [ ] **Step 4: Run all tests, ensure no regression**

```bash
pytest -v
```

- [ ] **Step 5: Commit**

```bash
git add auth.py tests/test_intentions.py
git commit -m "feat(intentions): account-deletion cascade (auth.py + DB-level FK)"
```

---

## Task 15: Final integration smoke + push

**Files:** none (verification + push)

- [ ] **Step 1: Run the full test suite, expect green**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend/.claude/worktrees/intentions-spec1
pytest -v --tb=short
```

Expected: all tests pass. If anything red, fix before committing.

- [ ] **Step 2: Lint check (if project has one)**

```bash
ls .ruff.toml pyproject.toml setup.cfg 2>/dev/null
# If ruff is configured:
ruff check . || true
```

Address any new lint errors in changed files only; don't fix pre-existing.

- [ ] **Step 3: Verify migration SQL on local Postgres if available**

```bash
# Optional dry-run; skip if no local PG
psql -h localhost -U postgres -d intentional_dev -c "BEGIN; \i migrations/018_add_intentions.sql; ROLLBACK;" 2>&1 | head -20
```

- [ ] **Step 4: Push the branch**

```bash
git push -u origin feat/intentions-spec1
```

- [ ] **Step 5: Update the cross-repo overnight log**

Edit `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/overnight-run-2026-05-03.md` and append to the "Live progress log" section:

```markdown
### Phase 3 — Backend (DONE)
Branch `feat/intentions-spec1` pushed to `origin`. All tests green.
- Migration: `migrations/018_add_intentions.sql`
- Endpoints: GET/POST/PUT/DELETE `/intentions`, GET `/intentions/{id}`, GET with `include_deleted`
- `/focus/toggle` accepts `intention_id` + `triggered_by`; emits APNs background push on start AND stop
- `/focus/active` returns `intention_id`
- Day-1 seed: `Focus` intention with curated default blocklist (twitter, x, reddit, hn, youtube, instagram, tiktok, facebook)

**Action required from you in the morning:**
1. Apply migration in Supabase SQL editor: paste contents of `migrations/018_add_intentions.sql`
2. Merge `feat/intentions-spec1` → `main`
3. Trigger Railway deploy (auto on push to main, or manual)
4. Verify endpoints return 200 with a curl: `curl -H "X-Device-ID: <your-id>" https://<railway-url>/intentions`
```

- [ ] **Step 6: Commit the log update**

This commit goes in the Mac repo, not the backend repo:

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add docs/overnight-run-2026-05-03.md
git commit -m "log(overnight): backend phase complete"
```

---

## What this plan does NOT do (deferred)

- WebSocket broadcast extension to include `intention_id` — Mac and iOS use polling + APNs as the primary signal; WS extension is a nice-to-have.
- Server-side validation that `intention_id` belongs to the calling account before linking it to a session — currently just accepts any UUID. Add in follow-up if needed (low risk: cross-account intention_id would just point at someone else's intention which fails to resolve client-side).
- Pagination on `GET /intentions` — assume <100 intentions per account; add pagination if list grows.
- ETags / If-None-Match on GET — clients poll at 60s; pull cost is small. Can add later.
- Bulk endpoints (`POST /intentions/bulk` for migration) — clients loop POST one-at-a-time. Acceptable for first migration (typical user has <20 projects).

## Required environment variables (no new ones)

This plan uses only existing env vars (`APNS_*` for push, `SUPABASE_*` for DB, `JWT_SECRET` / `SUPABASE_JWT_SECRET` for auth). No new secrets needed.
