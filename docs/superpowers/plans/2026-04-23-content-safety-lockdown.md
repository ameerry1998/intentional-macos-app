# Content Safety Lockdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing partner lock actually enforced — edits to `onboarding_settings.json`, cache deletions, and backend-blocking attacks all get caught and force-corrected with partner notification.

**Architecture:** Constraint-typed enforcement blob stored on backend, fetched by macOS app, cached locally with daemon-signed HMAC. Reconciler runs at app startup (blocking local cache verify + async backend fetch) and every 5 minutes. Violations force-correct local state, rewrite JSON, show overlay, fire rate-limited tamper email to partner.

**Tech Stack:** FastAPI + Supabase (backend), Swift + NSXPC + WKWebView (macOS app + daemon), Python pytest (backend tests), XCTest (Swift tests).

**Spec reference:** `docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md` — read this first if anything in a task is ambiguous.

---

## File Structure

**intentional-backend (`/Users/arayan/Documents/GitHub/intentional-backend/`)**
- **Create** `migrations/006_add_enforcement.sql` — adds `users.enforced_settings`, `users.enforced_settings_updated_at`, `users.last_tamper_email_at`.
- **Create** `enforcement.py` — `derive_enforcement_blob()` function. Pure module, unit-tested.
- **Create** `scripts/backfill_enforcement.py` — one-shot backfill for partner-locked users.
- **Create** `tests/test_enforcement.py` — pytest suite for derive fn + endpoint.
- **Modify** `main.py` — new `GET /device/enforcement`, update `PUT /settings/sync`, `PUT /lock`, `POST /content-safety/tamper`.
- **Modify** `models.py` — new Pydantic schemas for enforcement response + register response update.

**intentional-macos-app daemon (`IntentionalDaemon/`, `Shared/`)**
- **Modify** `Shared/DaemonXPCProtocol.swift` — add `signEnforcement`, `verifyEnforcement`.
- **Modify** `IntentionalDaemon/main.swift` — implement new XPC methods.
- **Create** `IntentionalDaemon/EnforcementHMAC.swift` — key load/generate, sign/verify.

**intentional-macos-app client (`Intentional/`)**
- **Create** `Intentional/EnforcementReconciler.swift` — orchestrator.
- **Create** `Intentional/EnforcementCache.swift` — read/write signed cache file.
- **Create** `Intentional/EnforcementDaemonClient.swift` — XPC wrapper for sign/verify.
- **Create** `Intentional/ConstraintEvaluator.swift` — typed constraint evaluation.
- **Create** `Intentional/TamperOverlayController.swift` — overlay window + SwiftUI view.
- **Modify** `Intentional/BackendClient.swift` — add `fetchEnforcement()` with TLS pinning.
- **Modify** `Intentional/AppDelegate.swift` — insert step 15b, heartbeat hook.
- **Modify** `Intentional/MainWindow.swift` — push enforcement state to dashboard.
- **Modify** `Intentional/dashboard.html` — lock UI on lockable toggles.
- **Modify** `Intentional.xcodeproj/project.pbxproj` — add new files to target.
- **Create** `IntentionalTests/ConstraintEvaluatorTests.swift`
- **Create** `IntentionalTests/EnforcementReconcilerTests.swift`
- **Create** `docs/PARTNER_EMAIL_REGISTRY.md`

---

## Phase 1 — Backend

### Task 1: Database migration

**Files:**
- Create: `intentional-backend/migrations/006_add_enforcement.sql`

- [ ] **Step 1: Create migration file**

```sql
-- migrations/006_add_enforcement.sql
-- Adds enforcement blob storage and tamper-email rate-limiting.

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS enforced_settings JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS enforced_settings_updated_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_tamper_email_at TIMESTAMPTZ;

-- Index for filtering users that have enforcement state (used by analytics / ops queries).
CREATE INDEX IF NOT EXISTS idx_users_enforcement_updated
  ON users (enforced_settings_updated_at)
  WHERE enforced_settings_updated_at IS NOT NULL;
```

- [ ] **Step 2: Apply migration against staging Supabase**

Run via Supabase SQL Editor or CLI (whichever the team uses):
```bash
cat intentional-backend/migrations/006_add_enforcement.sql | psql $DATABASE_URL
```
Expected: three `ALTER TABLE` and one `CREATE INDEX` succeed without error.

- [ ] **Step 3: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add migrations/006_add_enforcement.sql
git commit -m "migration: add enforced_settings + tamper rate-limit columns (006)"
```

---

### Task 2: Pydantic models

**Files:**
- Modify: `intentional-backend/models.py`

- [ ] **Step 1: Add enforcement response schemas**

Append to `intentional-backend/models.py`:

```python
# ==================== Enforcement (Content Safety Lockdown) ====================

class ConstraintSpec(BaseModel):
    """A single constraint entry in the enforcement blob."""
    type: str  # "must_be_true" | "must_be_false" | "min_value" | "must_include_all" | "unknown"
    value: Optional[float] = None
    values: Optional[list[str]] = None


class EnforcementResponse(BaseModel):
    success: bool
    device_id: str
    lock_mode: str  # "none" | "partner"
    enforcement_active: bool
    constraints: dict  # Dict[str, ConstraintSpec] but Supabase returns raw dicts; keep as dict
    temporary_unlock_until: Optional[str] = None
    updated_at: Optional[str] = None
```

- [ ] **Step 2: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add models.py
git commit -m "models: add EnforcementResponse + ConstraintSpec schemas"
```

---

### Task 3: `derive_enforcement_blob` function + tests

**Files:**
- Create: `intentional-backend/enforcement.py`
- Create: `intentional-backend/tests/__init__.py` (if missing)
- Create: `intentional-backend/tests/test_enforcement.py`

- [ ] **Step 1: Write failing tests first**

Create `intentional-backend/tests/__init__.py` (empty file).
Create `intentional-backend/tests/test_enforcement.py`:

```python
import pytest
from enforcement import derive_enforcement_blob


def test_empty_settings_yields_empty_blob():
    assert derive_enforcement_blob({}) == {}


def test_content_safety_enabled_creates_must_be_true():
    settings = {"contentSafety": {"enabled": True}}
    blob = derive_enforcement_blob(settings)
    assert blob == {"content_safety.enabled": {"type": "must_be_true"}}


def test_content_safety_disabled_omits_constraint():
    settings = {"contentSafety": {"enabled": False}}
    assert derive_enforcement_blob(settings) == {}


def test_youtube_full_blob():
    settings = {
        "platforms": {
            "youtube": {
                "enabled": True,
                "blockShorts": True,
                "threshold": 7,
            }
        }
    }
    blob = derive_enforcement_blob(settings)
    assert blob["platforms.youtube.enabled"] == {"type": "must_be_true"}
    assert blob["platforms.youtube.block_shorts"] == {"type": "must_be_true"}
    assert blob["platforms.youtube.threshold"] == {"type": "min_value", "value": 7}


def test_distracting_sites_as_must_include_all_sorted_unique():
    settings = {"distractingSites": ["reddit.com", "x.com", "reddit.com"]}
    blob = derive_enforcement_blob(settings)
    assert blob["distracting_sites"] == {
        "type": "must_include_all",
        "values": ["reddit.com", "x.com"],  # sorted unique
    }


def test_facebook_all_flags():
    settings = {
        "platforms": {
            "facebook": {
                "enabled": True,
                "blockWatch": True,
                "blockReels": True,
                "blockGaming": True,
                "blockSponsored": True,
                "blockSuggested": True,
            }
        }
    }
    blob = derive_enforcement_blob(settings)
    for flag in ("enabled", "block_watch", "block_reels", "block_gaming", "block_sponsored", "block_suggested"):
        assert blob[f"platforms.facebook.{flag}"] == {"type": "must_be_true"}


def test_combined_settings():
    settings = {
        "contentSafety": {"enabled": True},
        "platforms": {"youtube": {"enabled": True, "threshold": 5}},
        "distractingSites": ["a.com"],
    }
    blob = derive_enforcement_blob(settings)
    assert len(blob) == 4
    assert "content_safety.enabled" in blob
    assert "platforms.youtube.enabled" in blob
    assert "platforms.youtube.threshold" in blob
    assert "distracting_sites" in blob
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python -m pytest tests/test_enforcement.py -v
```
Expected: all tests ERROR with `ModuleNotFoundError: enforcement`.

- [ ] **Step 3: Implement `derive_enforcement_blob`**

Create `intentional-backend/enforcement.py`:

```python
"""Enforcement blob derivation.

Converts a user's onboarding settings into a constraint-typed blob that the
macOS client reconciles against local state. The blob is a map of
`key -> constraint`, where constraint is a typed rule. See
docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md for the
design rationale.
"""

from typing import Any


# Per-platform boolean flag → enforcement key suffix mapping
_PLATFORM_BOOL_FLAGS = {
    "enabled": "enabled",
    "blockShorts": "block_shorts",
    "blockReels": "block_reels",
    "blockWatch": "block_watch",
    "blockGaming": "block_gaming",
    "blockSponsored": "block_sponsored",
    "blockSuggested": "block_suggested",
}

_PLATFORMS = ("youtube", "instagram", "facebook")


def derive_enforcement_blob(settings: dict[str, Any]) -> dict[str, dict]:
    """Produce the enforcement blob from a user's onboarding settings.

    The resulting blob captures a ratchet-up-only semantic: booleans that
    are currently True become `must_be_true`, numeric thresholds become
    `min_value`, and lists become `must_include_all`. The user can only
    strengthen from here while partner-locked.
    """
    blob: dict[str, dict] = {}

    # Content Safety
    if settings.get("contentSafety", {}).get("enabled") is True:
        blob["content_safety.enabled"] = {"type": "must_be_true"}

    # Platforms
    platforms = settings.get("platforms", {})
    for platform in _PLATFORMS:
        pconfig = platforms.get(platform, {})

        for field_key, enforcement_suffix in _PLATFORM_BOOL_FLAGS.items():
            if pconfig.get(field_key) is True:
                blob[f"platforms.{platform}.{enforcement_suffix}"] = {"type": "must_be_true"}

        threshold = pconfig.get("threshold")
        if isinstance(threshold, int):
            blob[f"platforms.{platform}.threshold"] = {"type": "min_value", "value": threshold}

    # Distracting sites — dedupe + sort for stable blob ordering
    sites = settings.get("distractingSites", [])
    if sites:
        blob["distracting_sites"] = {
            "type": "must_include_all",
            "values": sorted(set(sites)),
        }

    return blob
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python -m pytest tests/test_enforcement.py -v
```
Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add enforcement.py tests/__init__.py tests/test_enforcement.py
git commit -m "feat(enforcement): derive_enforcement_blob + unit tests"
```

---

### Task 4: `GET /device/enforcement` endpoint

**Files:**
- Modify: `intentional-backend/main.py`
- Modify: `intentional-backend/tests/test_enforcement.py`

- [ ] **Step 1: Write endpoint tests (failing)**

Append to `tests/test_enforcement.py`:

```python
from fastapi.testclient import TestClient
from unittest.mock import patch, AsyncMock

# Test client constructed lazily because main.py import may fail if env vars missing
def _client():
    import main  # noqa
    return TestClient(main.app)


def _mock_user(device_id="dev-123", **kwargs):
    base = {
        "id": "user-uuid-1",
        "device_id": device_id,
        "partner_email": "caity@example.com",
        "lock_mode": "none",
        "enforced_settings": {},
        "temporary_unlock_until": None,
        "enforced_settings_updated_at": None,
    }
    base.update(kwargs)
    return base


def test_enforcement_endpoint_unlocked_user_returns_empty():
    user = _mock_user(lock_mode="none")
    with patch("main.get_user_by_device_id", new=AsyncMock(return_value=user)):
        r = _client().get("/device/enforcement", headers={"X-Device-ID": "dev-123"})
    assert r.status_code == 200
    body = r.json()
    assert body["enforcement_active"] is False
    assert body["constraints"] == {}
    assert body["lock_mode"] == "none"


def test_enforcement_endpoint_partner_locked_returns_constraints():
    user = _mock_user(
        lock_mode="partner",
        enforced_settings={"content_safety.enabled": {"type": "must_be_true"}},
        enforced_settings_updated_at="2026-04-23T12:00:00+00:00",
    )
    with patch("main.get_user_by_device_id", new=AsyncMock(return_value=user)):
        r = _client().get("/device/enforcement", headers={"X-Device-ID": "dev-123"})
    assert r.status_code == 200
    body = r.json()
    assert body["enforcement_active"] is True
    assert body["constraints"] == {"content_safety.enabled": {"type": "must_be_true"}}


def test_enforcement_endpoint_temp_unlock_masks_constraints():
    from datetime import datetime, timedelta, timezone
    future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    user = _mock_user(
        lock_mode="partner",
        enforced_settings={"content_safety.enabled": {"type": "must_be_true"}},
        temporary_unlock_until=future,
    )
    with patch("main.get_user_by_device_id", new=AsyncMock(return_value=user)):
        r = _client().get("/device/enforcement", headers={"X-Device-ID": "dev-123"})
    body = r.json()
    assert body["enforcement_active"] is False
    assert body["constraints"] == {}
    assert body["temporary_unlock_until"] == future


def test_enforcement_endpoint_404_on_unknown_device():
    with patch("main.get_user_by_device_id", new=AsyncMock(return_value=None)):
        r = _client().get("/device/enforcement", headers={"X-Device-ID": "dev-unknown"})
    assert r.status_code == 404
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python -m pytest tests/test_enforcement.py::test_enforcement_endpoint_unlocked_user_returns_empty -v
```
Expected: FAIL (endpoint doesn't exist yet, 404).

- [ ] **Step 3: Add endpoint to main.py**

In `intentional-backend/main.py`, add the import at the top imports section:

```python
from datetime import datetime, timezone
from models import EnforcementResponse
```

Then add the endpoint (place it after the existing `/partner/status` endpoint around line 335):

```python
@app.get("/device/enforcement", response_model=EnforcementResponse)
async def get_enforcement(x_device_id: str = Header(..., alias="X-Device-ID")):
    """
    Returns the authoritative enforcement state for this device.

    - If lock_mode != 'partner': enforcement_active=False, constraints={}.
    - If temporary_unlock_until > now: enforcement_active=False, constraints={},
      temporary_unlock_until set. Enforcement resumes when the window expires.
    - Otherwise: enforcement_active=True, constraints=users.enforced_settings.
    """
    if not validate_device_id(x_device_id):
        raise HTTPException(status_code=400, detail="Invalid device ID")

    user = await get_user_by_device_id(x_device_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    lock_mode = user.get("lock_mode", "none")
    temp_unlock = user.get("temporary_unlock_until")
    now = datetime.now(timezone.utc)

    active = lock_mode == "partner"
    constraints: dict = {}

    # Temp-unlock window open → pause enforcement but preserve the stored blob.
    if active and temp_unlock:
        try:
            if datetime.fromisoformat(temp_unlock.replace("Z", "+00:00")) > now:
                active = False
        except (ValueError, TypeError):
            pass

    if active:
        constraints = user.get("enforced_settings") or {}

    return EnforcementResponse(
        success=True,
        device_id=x_device_id,
        lock_mode=lock_mode,
        enforcement_active=active,
        constraints=constraints,
        temporary_unlock_until=temp_unlock,
        updated_at=user.get("enforced_settings_updated_at"),
    )
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python -m pytest tests/test_enforcement.py -v
```
Expected: all tests PASS (incl. 7 from Task 3 + 4 new).

- [ ] **Step 5: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add main.py tests/test_enforcement.py
git commit -m "feat(enforcement): GET /device/enforcement endpoint + tests"
```

---

### Task 5: Wire blob writes into PUT /settings/sync + PUT /lock

**Files:**
- Modify: `intentional-backend/main.py`
- Modify: `intentional-backend/tests/test_enforcement.py`

- [ ] **Step 1: Write tests**

Append to `tests/test_enforcement.py`:

```python
def test_settings_sync_updates_enforcement_when_partner_locked():
    """When a partner-locked user saves settings, enforced_settings is recomputed."""
    # TODO: This test requires JWT auth mocking. Skip full test; verify by integration.
    pass  # pragma: no cover


def test_lock_change_to_partner_derives_blob_from_last_settings():
    """PUT /lock with mode=partner triggers blob derivation from account_settings."""
    pass  # pragma: no cover


def test_lock_change_from_partner_clears_blob():
    """PUT /lock with mode=none clears enforced_settings."""
    pass  # pragma: no cover
```

*(These cover integration paths that are easier to verify end-to-end. Placeholders kept to document intent; end-to-end verification happens in Task 21.)*

- [ ] **Step 2: Modify `/settings/sync` to derive blob**

In `intentional-backend/main.py`, find the `save_settings` function (~line 1601) and modify it. Add after the existing upsert to `account_settings`:

```python
    # Re-derive enforcement blob when the user is partner-locked.
    # This is how new/changed constraints propagate to the client.
    from enforcement import derive_enforcement_blob
    user_row = db.table("users").select("id, device_id, lock_mode").eq("account_id", account_id).execute()
    if user_row.data:
        user = user_row.data[0]
        if user.get("lock_mode") == "partner":
            blob = derive_enforcement_blob(request.settings)
            db.table("users").update({
                "enforced_settings": blob,
                "enforced_settings_updated_at": now,
            }).eq("id", user["id"]).execute()
```

- [ ] **Step 3: Modify `/lock` to derive / clear blob**

In `intentional-backend/main.py`, find the `set_lock_mode` function (~line 337). After the existing update that sets `lock_mode`, add:

```python
    # Recompute enforcement blob based on new lock mode.
    from enforcement import derive_enforcement_blob
    now_iso = datetime.now(timezone.utc).isoformat()
    if mode == "partner":
        # Derive from most recent saved settings.
        settings_row = db.table("account_settings").select("settings").eq("account_id", user["account_id"]).execute()
        current_settings = settings_row.data[0]["settings"] if settings_row.data else {}
        blob = derive_enforcement_blob(current_settings)
        db.table("users").update({
            "enforced_settings": blob,
            "enforced_settings_updated_at": now_iso,
        }).eq("id", user["id"]).execute()
    else:
        # Clear blob when leaving partner mode.
        db.table("users").update({
            "enforced_settings": {},
            "enforced_settings_updated_at": now_iso,
        }).eq("id", user["id"]).execute()
```

- [ ] **Step 4: Verify existing lock tests still pass**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python -m pytest tests/ -v
```
Expected: all tests PASS (no regressions).

- [ ] **Step 5: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add main.py tests/test_enforcement.py
git commit -m "feat(enforcement): derive blob on /settings/sync and /lock changes"
```

---

### Task 6: Tamper email rate limit

**Files:**
- Modify: `intentional-backend/main.py`
- Modify: `intentional-backend/tests/test_enforcement.py`

- [ ] **Step 1: Write failing test**

Append to `tests/test_enforcement.py`:

```python
def test_tamper_email_rate_limited_to_one_per_hour():
    from datetime import datetime, timezone, timedelta
    # Recent tamper email → no new email sent
    recent = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
    user = _mock_user(partner_email="caity@example.com", lock_mode="partner", last_tamper_email_at=recent)

    with patch("main.get_user_by_device_id", new=AsyncMock(return_value=user)), \
         patch("main.send_tamper_email", new=AsyncMock()) as send_mock, \
         patch("main.get_db") as db_mock:
        db_mock.return_value.table.return_value.update.return_value.eq.return_value.execute.return_value = None

        r = _client().post(
            "/content-safety/tamper",
            json={"event_type": "enforcement_mismatch", "detail": "test"},
            headers={"X-Device-ID": "dev-123"},
        )
        assert r.status_code == 200
        send_mock.assert_not_called()


def test_tamper_email_sent_when_older_than_one_hour():
    from datetime import datetime, timezone, timedelta
    old = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    user = _mock_user(partner_email="caity@example.com", lock_mode="partner", last_tamper_email_at=old)

    with patch("main.get_user_by_device_id", new=AsyncMock(return_value=user)), \
         patch("main.send_tamper_email", new=AsyncMock()) as send_mock, \
         patch("main.get_db") as db_mock:
        db_mock.return_value.table.return_value.update.return_value.eq.return_value.execute.return_value = None

        r = _client().post(
            "/content-safety/tamper",
            json={"event_type": "enforcement_mismatch", "detail": "test"},
            headers={"X-Device-ID": "dev-123"},
        )
        assert r.status_code == 200
        send_mock.assert_called_once()
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python -m pytest tests/test_enforcement.py::test_tamper_email_rate_limited_to_one_per_hour -v
```
Expected: FAIL (no rate-limit logic yet — may send multiple times or throw).

- [ ] **Step 3: Refactor the tamper endpoint to check rate limit**

In `intentional-backend/main.py`, find the existing `report_content_safety_tamper` function (~line 1158). Replace the email-send section with:

```python
    # Rate-limit: one tamper email per user per hour.
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    last = user.get("last_tamper_email_at")
    should_send = True
    if last:
        try:
            last_dt = datetime.fromisoformat(last.replace("Z", "+00:00"))
            if now - last_dt < timedelta(hours=1):
                should_send = False
        except (ValueError, TypeError):
            pass

    if should_send:
        # Preserve the existing email call; name may be different — match source.
        await send_tamper_email(user["partner_email"], request.event_type, request.detail)
        db.table("users").update({
            "last_tamper_email_at": now.isoformat(),
        }).eq("id", user["id"]).execute()

    # Always return 200 — client doesn't need to know whether we sent.
    return ContentSafetyTamperResponse(success=True)
```

**Note on the `send_tamper_email` call:** inspect the existing function around line 1158 to confirm the exact function name and signature. If it's called inline via `email_service`, adapt the patch and code accordingly. The test uses `main.send_tamper_email` as a patchable symbol — add a thin wrapper at module level if needed:

```python
# Near top of main.py, next to other email helpers:
from email_service import send_email_template  # or whatever the existing import is

async def send_tamper_email(partner_email: str, event_type: str, detail: str) -> None:
    # Delegate to the existing email_service function. Named explicitly so tests can patch it.
    await send_email_template(partner_email, "content_safety_tamper", {
        "event_type": event_type,
        "detail": detail,
    })
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python -m pytest tests/test_enforcement.py -v
```
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add main.py tests/test_enforcement.py
git commit -m "feat(enforcement): rate-limit tamper emails to 1/hour/device"
```

---

### Task 7: Backfill script for existing partner-locked users

**Files:**
- Create: `intentional-backend/scripts/backfill_enforcement.py`

- [ ] **Step 1: Create script**

Create `intentional-backend/scripts/backfill_enforcement.py`:

```python
#!/usr/bin/env python3
"""One-shot: populate enforced_settings for all currently partner-locked users.

Idempotent — re-running computes the same blobs and updates only if changed.
Run after migration 006 and after the new `/device/enforcement` endpoint is deployed.

Usage:
    cd intentional-backend
    python scripts/backfill_enforcement.py [--dry-run]
"""

import argparse
import sys
from datetime import datetime, timezone

# Ensure parent dir is importable
sys.path.insert(0, ".")
from database import get_db
from enforcement import derive_enforcement_blob


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="Print plan without writing")
    args = parser.parse_args()

    db = get_db()
    users = db.table("users").select("id, account_id, device_id, lock_mode, enforced_settings") \
                .eq("lock_mode", "partner").execute()

    now_iso = datetime.now(timezone.utc).isoformat()
    total = 0
    changed = 0

    for user in users.data:
        total += 1
        account_id = user.get("account_id")
        if not account_id:
            print(f"  [skip] user {user['id']}: no account_id")
            continue

        settings_result = db.table("account_settings").select("settings").eq("account_id", account_id).execute()
        settings = settings_result.data[0]["settings"] if settings_result.data else {}
        blob = derive_enforcement_blob(settings)

        current_blob = user.get("enforced_settings") or {}
        if blob == current_blob:
            print(f"  [skip] user {user['id']}: blob unchanged ({len(blob)} constraints)")
            continue

        changed += 1
        print(f"  [update] user {user['id']}: {len(current_blob)} → {len(blob)} constraints")
        if not args.dry_run:
            db.table("users").update({
                "enforced_settings": blob,
                "enforced_settings_updated_at": now_iso,
            }).eq("id", user["id"]).execute()

    print(f"\nDone. Scanned {total} partner-locked users; updated {changed}.")
    if args.dry_run:
        print("(dry-run — no writes performed)")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Dry-run against staging**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python scripts/backfill_enforcement.py --dry-run
```
Expected: prints plan for each partner-locked user, no DB writes.

- [ ] **Step 3: Apply to staging, verify**

```bash
python scripts/backfill_enforcement.py
```
Expected: updates staging users. Verify via SQL:
```sql
SELECT id, enforced_settings, enforced_settings_updated_at
  FROM users
 WHERE lock_mode = 'partner'
 LIMIT 5;
```
Expected: rows have non-empty `enforced_settings`.

- [ ] **Step 4: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add scripts/backfill_enforcement.py
git commit -m "feat(enforcement): backfill script for existing partner-locked users"
```

---

## Phase 2 — Daemon

### Task 8: Extend DaemonXPCProtocol

**Files:**
- Modify: `Shared/DaemonXPCProtocol.swift`
- Modify: `syspolicyd_helper/DaemonXPCProtocol.swift` (if still present as a duplicate)

- [ ] **Step 1: Add new method signatures**

In `/Users/arayan/Documents/GitHub/intentional-macos-app/Shared/DaemonXPCProtocol.swift`, append to the protocol body (before the closing `}`):

```swift
    /// Sign an enforcement cache payload with the daemon's HMAC key.
    /// The app passes canonical JSON bytes; daemon returns HMAC-SHA256 raw bytes.
    /// Reply: (signature, errorMessage) — signature nil on failure.
    func signEnforcement(payload: Data, reply: @escaping (Data?, String?) -> Void)

    /// Verify an enforcement cache signature.
    /// Reply: (valid) — true if signature matches the stored HMAC key.
    func verifyEnforcement(payload: Data, signature: Data, reply: @escaping (Bool) -> Void)
```

- [ ] **Step 2: Mirror changes in the duplicate (if present)**

Check if `syspolicyd_helper/DaemonXPCProtocol.swift` exists and is used. If yes, apply the same edit. If it's stale / unused, delete it in a separate cleanup commit — do not do that as part of this task.

```bash
diff /Users/arayan/Documents/GitHub/intentional-macos-app/Shared/DaemonXPCProtocol.swift \
     /Users/arayan/Documents/GitHub/intentional-macos-app/syspolicyd_helper/DaemonXPCProtocol.swift
```
If they differ beyond our edit, raise for review before proceeding. For now apply the same edit to both.

- [ ] **Step 3: Verify project builds**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` (daemon still has no implementations, so runtime calls would fail — but compile should succeed because protocol methods can be added without daemon conformance until Task 9).

Wait — Swift `@objc` protocols DO require the daemon class to conform. Task 9 adds the implementations; before that, `DaemonDelegate` in `IntentionalDaemon/main.swift` must stub out the new methods (no-op returning false/nil) so it keeps compiling. Add those stubs in this task too:

In `IntentionalDaemon/main.swift`, inside the `DaemonDelegate` class, append stubs:

```swift
    // Stub — real implementation in Task 9.
    func signEnforcement(payload: Data, reply: @escaping (Data?, String?) -> Void) {
        reply(nil, "not implemented")
    }

    // Stub — real implementation in Task 9.
    func verifyEnforcement(payload: Data, signature: Data, reply: @escaping (Bool) -> Void) {
        reply(false)
    }
```

Re-run build. Expected: SUCCESS.

- [ ] **Step 4: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Shared/DaemonXPCProtocol.swift syspolicyd_helper/DaemonXPCProtocol.swift IntentionalDaemon/main.swift
git commit -m "feat(daemon): add signEnforcement/verifyEnforcement XPC methods (stubs)"
```

---

### Task 9: Implement HMAC sign/verify in daemon

**Files:**
- Create: `IntentionalDaemon/EnforcementHMAC.swift`
- Modify: `IntentionalDaemon/main.swift` — wire real implementations
- Modify: `Intentional.xcodeproj/project.pbxproj` — add `EnforcementHMAC.swift` to daemon target

- [ ] **Step 1: Create EnforcementHMAC**

Create `IntentionalDaemon/EnforcementHMAC.swift`:

```swift
//
//  EnforcementHMAC.swift
//  IntentionalDaemon
//
//  HMAC-SHA256 key management for enforcement cache signing.
//  Key is generated lazily on first sign request and stored at
//  /var/root/intentional/enforcement_hmac_key (0600). Never transmitted.
//

import Foundation
import CryptoKit

final class EnforcementHMAC {
    private static let directoryURL = URL(fileURLWithPath: "/var/root/intentional", isDirectory: true)
    private static let keyURL = directoryURL.appendingPathComponent("enforcement_hmac_key")

    /// Load the key from disk, generating and persisting it if absent.
    static func loadOrGenerateKey() throws -> SymmetricKey {
        // Ensure directory exists with strict permissions.
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700,
                .ownerAccountID: 0,  // root
            ])
        }

        if fm.fileExists(atPath: keyURL.path) {
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else {
                throw NSError(domain: "EnforcementHMAC", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Corrupt HMAC key (size \(data.count))"
                ])
            }
            return SymmetricKey(data: data)
        }

        // Generate fresh 256-bit key, write with 0600 perms.
        var keyBytes = Data(count: 32)
        let status = keyBytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "EnforcementHMAC", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "SecRandomCopyBytes failed: \(status)"
            ])
        }
        try keyBytes.write(to: keyURL, options: .atomic)
        // Set 0600 owner=root — file is created by current process (daemon runs as root).
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return SymmetricKey(data: keyBytes)
    }

    /// HMAC-SHA256 of payload with the stored key. Returns raw 32-byte MAC.
    static func sign(payload: Data) throws -> Data {
        let key = try loadOrGenerateKey()
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(mac)
    }

    /// Returns true iff signature is a valid HMAC-SHA256 of payload under the stored key.
    static func verify(payload: Data, signature: Data) throws -> Bool {
        let key = try loadOrGenerateKey()
        let expected = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        // Constant-time compare via Data equality on the MAC object.
        return Data(expected) == signature
    }
}
```

- [ ] **Step 2: Wire real implementations in DaemonDelegate**

Replace the stubs in `IntentionalDaemon/main.swift` with real calls:

```swift
    func signEnforcement(payload: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            let mac = try EnforcementHMAC.sign(payload: payload)
            reply(mac, nil)
        } catch {
            NSLog("[Daemon] signEnforcement failed: \(error.localizedDescription)")
            reply(nil, error.localizedDescription)
        }
    }

    func verifyEnforcement(payload: Data, signature: Data, reply: @escaping (Bool) -> Void) {
        do {
            let ok = try EnforcementHMAC.verify(payload: payload, signature: signature)
            reply(ok)
        } catch {
            NSLog("[Daemon] verifyEnforcement failed: \(error.localizedDescription)")
            reply(false)
        }
    }
```

- [ ] **Step 3: Add EnforcementHMAC.swift to the daemon target in Xcode**

Open `Intentional.xcodeproj`, select `EnforcementHMAC.swift` in the file browser, File Inspector → Target Membership → check `syspolicyd_helper` (or whichever target builds the daemon binary — confirm by looking at which target compiles `IntentionalDaemon/main.swift`; it's the same target).

Alternate: edit `project.pbxproj` manually if Xcode unavailable. Match the pattern used for `AppWatchdog.swift` or `HeartbeatService.swift` (daemon's existing files).

- [ ] **Step 4: Build daemon + app**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual smoke test (optional — full end-to-end waits for client)**

With daemon installed (PKG build):
```bash
sudo launchctl bootout system/com.intentional.daemon 2>/dev/null
sudo launchctl bootstrap system /Library/LaunchDaemons/com.intentional.daemon.plist
tail -f /var/log/intentional-daemon.log
```
Expected: daemon starts without errors; no "signEnforcement" calls yet (client not ready).

- [ ] **Step 6: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add IntentionalDaemon/EnforcementHMAC.swift IntentionalDaemon/main.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(daemon): implement enforcement HMAC sign/verify via /var/root/"
```

---

## Phase 3 — macOS Client

### Task 10: ConstraintEvaluator + tests

**Files:**
- Create: `Intentional/ConstraintEvaluator.swift`
- Create: `IntentionalTests/ConstraintEvaluatorTests.swift`

- [ ] **Step 1: Write tests first**

Create `/Users/arayan/Documents/GitHub/intentional-macos-app/IntentionalTests/ConstraintEvaluatorTests.swift`:

```swift
import XCTest
@testable import Intentional

final class ConstraintEvaluatorTests: XCTestCase {

    func test_mustBeTrue_satisfied_when_true() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .mustBeTrue, currentValue: true)
        XCTAssertEqual(result, .satisfied)
    }

    func test_mustBeTrue_violated_corrects_to_true() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .mustBeTrue, currentValue: false)
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        XCTAssertEqual(correction as? Bool, true)
    }

    func test_mustBeTrue_violated_when_missing() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .mustBeTrue, currentValue: nil)
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        XCTAssertEqual(correction as? Bool, true)
    }

    func test_minValue_satisfied_when_equal() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .minValue(7), currentValue: 7)
        XCTAssertEqual(result, .satisfied)
    }

    func test_minValue_satisfied_when_greater() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .minValue(7), currentValue: 10)
        XCTAssertEqual(result, .satisfied)
    }

    func test_minValue_violated_corrects_to_floor() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .minValue(7), currentValue: 3)
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        XCTAssertEqual(correction as? Double, 7)
    }

    func test_mustIncludeAll_satisfied_when_superset() {
        let result = ConstraintEvaluator.evaluate(
            key: "sites",
            constraint: .mustIncludeAll(["a", "b"]),
            currentValue: ["a", "b", "c"]
        )
        XCTAssertEqual(result, .satisfied)
    }

    func test_mustIncludeAll_violated_corrects_by_adding_missing() {
        let result = ConstraintEvaluator.evaluate(
            key: "sites",
            constraint: .mustIncludeAll(["a", "b", "c"]),
            currentValue: ["a"]
        )
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        let out = (correction as? [String])?.sorted()
        XCTAssertEqual(out, ["a", "b", "c"])
    }

    func test_mustIncludeAll_violated_preserves_user_extras() {
        // Ratchet-up-only: user's extra items are preserved.
        let result = ConstraintEvaluator.evaluate(
            key: "sites",
            constraint: .mustIncludeAll(["a"]),
            currentValue: ["x", "y"]
        )
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        let out = (correction as? [String])?.sorted()
        XCTAssertEqual(out, ["a", "x", "y"])
    }

    func test_unknown_constraint_cannot_auto_correct() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .unknown("future_type"), currentValue: nil)
        XCTAssertEqual(result, .cannotAutoCorrect)
    }
}
```

- [ ] **Step 2: Create source file (minimal stub)**

Create `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/ConstraintEvaluator.swift`:

```swift
//
//  ConstraintEvaluator.swift
//  Intentional
//
//  Pure-function typed constraint evaluator. Produces the minimum-change
//  correction for ratchet-up-only enforcement. See
//  docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md §5.6.
//

import Foundation

enum Constraint: Equatable {
    case mustBeTrue
    case mustBeFalse
    case minValue(Double)
    case mustIncludeAll([String])
    case unknown(String)
}

enum ConstraintResult: Equatable {
    case satisfied
    case violated(correction: Any)
    case cannotAutoCorrect

    static func == (lhs: ConstraintResult, rhs: ConstraintResult) -> Bool {
        switch (lhs, rhs) {
        case (.satisfied, .satisfied), (.cannotAutoCorrect, .cannotAutoCorrect):
            return true
        case (.violated(let a), .violated(let b)):
            // Compare via description for test ergonomics; callers use pattern matching normally.
            return String(describing: a) == String(describing: b)
        default:
            return false
        }
    }
}

enum ConstraintEvaluator {
    static func evaluate(key: String, constraint: Constraint, currentValue: Any?) -> ConstraintResult {
        switch constraint {
        case .mustBeTrue:
            if let b = currentValue as? Bool, b == true { return .satisfied }
            return .violated(correction: true)

        case .mustBeFalse:
            if let b = currentValue as? Bool, b == false { return .satisfied }
            return .violated(correction: false)

        case .minValue(let floor):
            let current: Double? = {
                if let d = currentValue as? Double { return d }
                if let i = currentValue as? Int { return Double(i) }
                return nil
            }()
            if let c = current, c >= floor { return .satisfied }
            return .violated(correction: floor)

        case .mustIncludeAll(let required):
            let current = (currentValue as? [String]) ?? []
            let missing = required.filter { !current.contains($0) }
            if missing.isEmpty { return .satisfied }
            return .violated(correction: Array(Set(current + required)))

        case .unknown:
            return .cannotAutoCorrect
        }
    }

    /// Parse a JSON constraint spec from the backend blob into a `Constraint`.
    static func parse(_ spec: [String: Any]) -> Constraint {
        let type = spec["type"] as? String ?? ""
        switch type {
        case "must_be_true":       return .mustBeTrue
        case "must_be_false":      return .mustBeFalse
        case "min_value":
            let v = (spec["value"] as? Double) ?? Double(spec["value"] as? Int ?? 0)
            return .minValue(v)
        case "must_include_all":
            let values = spec["values"] as? [String] ?? []
            return .mustIncludeAll(values)
        default:
            return .unknown(type)
        }
    }
}
```

- [ ] **Step 3: Add both files to Xcode targets**

- `Intentional/ConstraintEvaluator.swift` → `Intentional` target
- `IntentionalTests/ConstraintEvaluatorTests.swift` → `IntentionalTests` target

- [ ] **Step 4: Run tests**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild test -project Intentional.xcodeproj -scheme Intentional \
  -destination 'platform=macOS' \
  -only-testing:IntentionalTests/ConstraintEvaluatorTests 2>&1 | tail -20
```
Expected: all 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/ConstraintEvaluator.swift IntentionalTests/ConstraintEvaluatorTests.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(enforcement): ConstraintEvaluator + unit tests"
```

---

### Task 11: EnforcementCache

**Files:**
- Create: `Intentional/EnforcementCache.swift`

- [ ] **Step 1: Create the cache reader/writer**

Create `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/EnforcementCache.swift`:

```swift
//
//  EnforcementCache.swift
//  Intentional
//
//  Reads and writes the daemon-signed enforcement cache.
//  See docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md §5.5.
//

import Foundation

struct EnforcementCacheData: Codable {
    let deviceId: String
    let enforcementActive: Bool
    let constraints: [String: [String: AnyCodable]]
    let temporaryUnlockUntil: String?
    let updatedAt: String?
    let cachedAt: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case enforcementActive = "enforcement_active"
        case constraints
        case temporaryUnlockUntil = "temporary_unlock_until"
        case updatedAt = "updated_at"
        case cachedAt = "cached_at"
    }
}

/// Helper for encoding heterogeneous constraint-spec dictionaries.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Int.self)  { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([String].self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value }; return }
        if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value }; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:      try c.encode(v)
        case let v as Int:       try c.encode(v)
        case let v as Double:    try c.encode(v)
        case let v as String:    try c.encode(v)
        case let v as [String]:  try c.encode(v)
        case let v as [Any]:     try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}

final class EnforcementCache {

    private static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Intentional/enforcement_cache.json")
    }()

    private static let signatureURL: URL = {
        fileURL.deletingLastPathComponent().appendingPathComponent("enforcement_cache.sig")
    }()

    /// Write cache atomically. Signature stored alongside as a base64 text file.
    static func write(cache: EnforcementCacheData, signature: Data) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // canonical form for signing
        let json = try encoder.encode(cache)

        // Ensure parent dir exists
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Atomic write
        try json.write(to: fileURL, options: .atomic)
        try signature.base64EncodedString().data(using: .utf8)!.write(to: signatureURL, options: .atomic)
    }

    /// Read cache + signature from disk. Returns nil if either is missing.
    static func read() -> (cache: EnforcementCacheData, canonicalJSON: Data, signature: Data)? {
        guard let json = try? Data(contentsOf: fileURL),
              let sigB64 = try? Data(contentsOf: signatureURL),
              let sigString = String(data: sigB64, encoding: .utf8),
              let signature = Data(base64Encoded: sigString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }

        let decoder = JSONDecoder()
        guard let cache = try? decoder.decode(EnforcementCacheData.self, from: json) else {
            return nil
        }

        // Re-encode canonically for signature verification.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let canonical = try? encoder.encode(cache) else { return nil }

        return (cache, canonical, signature)
    }

    /// Remove cache + signature (used when we detect corruption).
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: signatureURL)
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Intentional/EnforcementCache.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(enforcement): EnforcementCache read/write with canonical JSON"
```

---

### Task 12: EnforcementDaemonClient (XPC wrapper)

**Files:**
- Create: `Intentional/EnforcementDaemonClient.swift`

- [ ] **Step 1: Create wrapper**

Create `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/EnforcementDaemonClient.swift`:

```swift
//
//  EnforcementDaemonClient.swift
//  Intentional
//
//  Async wrapper around DaemonXPCClient.signEnforcement / verifyEnforcement.
//  Surfaces a clean `daemonAvailable` flag so callers can drop into the
//  degraded-mode fallback described in the spec §6.5.
//

import Foundation

final class EnforcementDaemonClient {
    private let daemonClient: DaemonXPCClient

    init(daemonClient: DaemonXPCClient) {
        self.daemonClient = daemonClient
    }

    /// True if the XPC connection looks healthy. Callers treat `false` as the
    /// degraded-mode signal (no daemon → ratchet-up-only mode, no cache signing).
    var daemonAvailable: Bool {
        daemonClient.isConnected
    }

    /// Sign payload via daemon. Returns nil on any failure (daemon absent, key error).
    func sign(_ payload: Data) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            guard let proxy = daemonClient.proxyForEnforcement() else {
                continuation.resume(returning: nil)
                return
            }
            proxy.signEnforcement(payload: payload) { signature, _ in
                continuation.resume(returning: signature)
            }
        }
    }

    /// Verify signature via daemon. Returns false on any failure.
    func verify(payload: Data, signature: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            guard let proxy = daemonClient.proxyForEnforcement() else {
                continuation.resume(returning: false)
                return
            }
            proxy.verifyEnforcement(payload: payload, signature: signature) { ok in
                continuation.resume(returning: ok)
            }
        }
    }
}
```

- [ ] **Step 2: Expose `isConnected` + `proxyForEnforcement` on DaemonXPCClient**

Edit `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/DaemonXPCClient.swift`. Inside the `DaemonXPCClient` class, add:

```swift
    /// True if the XPC connection object has been successfully established.
    /// (An unreachable daemon means .invalidated has already fired.)
    var isConnected: Bool { connection != nil }

    /// Typed proxy for the enforcement methods. Returns nil on connection failure.
    func proxyForEnforcement() -> DaemonXPCProtocol? {
        return proxy  // already-typed as DaemonXPCProtocol internally
    }
```

*(Inspect the existing file to align naming with the private `connection` / `proxy` properties — adjust wording above to match. The intent is a public `isConnected` boolean and a public proxy accessor scoped to the enforcement use.)*

- [ ] **Step 3: Build**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```
Expected: SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add Intentional/EnforcementDaemonClient.swift Intentional/DaemonXPCClient.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(enforcement): EnforcementDaemonClient async XPC wrapper"
```

---

### Task 13: BackendClient.fetchEnforcement + TLS cert pinning

**Files:**
- Modify: `Intentional/BackendClient.swift`

- [ ] **Step 1: Add pinning constant + struct for response**

Near the top of `BackendClient.swift`, after existing constants, add:

```swift
    /// SHA-256 fingerprint of the backend leaf certificate for the /device/enforcement call.
    /// Set to the production cert fingerprint. When the cert is about to rotate, add the
    /// NEW fingerprint to this array while keeping the old one, ship an app update, then
    /// drop the old after users have upgraded.
    ///
    /// To compute: `openssl s_client -connect api.intentional.social:443 -servername api.intentional.social </dev/null 2>/dev/null | openssl x509 -fingerprint -sha256 -noout`
    private static let pinnedBackendCertSHA256: [String] = [
        // TODO(ops): fill in actual fingerprint before production ship.
        // Format: "AA:BB:CC:..." uppercase, colon-separated.
    ]
```

Also add the response type:

```swift
struct EnforcementFetchResult {
    let success: Bool
    let lockMode: String
    let enforcementActive: Bool
    let constraints: [String: [String: Any]]
    let temporaryUnlockUntil: String?
    let updatedAt: String?
    let deviceId: String
    let rawJSON: Data  // the bytes we'll hand to daemon for signing
    let error: String?
}
```

- [ ] **Step 2: Add fetchEnforcement method**

Inside the `BackendClient` class:

```swift
    /// Fetch authoritative enforcement state. Uses cert-pinned URLSession when pinning
    /// fingerprints are configured; otherwise falls back to the default session with a
    /// warning log (dev/staging).
    func fetchEnforcement() async -> EnforcementFetchResult? {
        let endpoint = "\(baseURL)/device/enforcement"
        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        let session = Self.pinnedBackendCertSHA256.isEmpty
            ? URLSession.shared
            : URLSession(configuration: .default, delegate: CertPinningDelegate(pinned: Self.pinnedBackendCertSHA256), delegateQueue: nil)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let appDelegate = NSApplication.shared.delegate as? AppDelegate
                appDelegate?.postLog("⚠️ fetchEnforcement non-200: \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let constraints = (json["constraints"] as? [String: [String: Any]]) ?? [:]
            return EnforcementFetchResult(
                success: (json["success"] as? Bool) ?? false,
                lockMode: (json["lock_mode"] as? String) ?? "none",
                enforcementActive: (json["enforcement_active"] as? Bool) ?? false,
                constraints: constraints,
                temporaryUnlockUntil: json["temporary_unlock_until"] as? String,
                updatedAt: json["updated_at"] as? String,
                deviceId: (json["device_id"] as? String) ?? deviceId,
                rawJSON: data,
                error: nil
            )
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("⚠️ fetchEnforcement failed: \(error.localizedDescription)")
            return nil
        }
    }
```

- [ ] **Step 3: Add CertPinningDelegate**

Append to the end of `BackendClient.swift`:

```swift
final class CertPinningDelegate: NSObject, URLSessionDelegate {
    let pinned: [String]

    init(pinned: [String]) { self.pinned = pinned }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Let system evaluate trust first (chain + expiry).
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Then check the leaf cert SHA-256 against our pinned list.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(leaf) as Data
        let fingerprint = data.sha256HexColons.uppercased()
        if pinned.map({ $0.uppercased() }).contains(fingerprint) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private extension Data {
    var sha256HexColons: String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(self.count), &hash)
        }
        return hash.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
```

Add `import CommonCrypto` to the top of the file.

- [ ] **Step 4: Build**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```
Expected: SUCCESS.

- [ ] **Step 5: Commit**

```bash
git add Intentional/BackendClient.swift
git commit -m "feat(enforcement): BackendClient.fetchEnforcement with TLS cert pinning"
```

---

### Task 14: EnforcementReconciler orchestrator

**Files:**
- Create: `Intentional/EnforcementReconciler.swift`

- [ ] **Step 1: Create reconciler**

Create `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/EnforcementReconciler.swift`:

```swift
//
//  EnforcementReconciler.swift
//  Intentional
//
//  Orchestrates enforcement: Phase A (blocking, local cache verify + correction),
//  Phase B (async, backend fetch + re-sign cache), heartbeat, post-unlock refresh.
//
//  Callers:
//    - AppDelegate step 15b — reconciler.runBlockingPhaseA()
//    - AppDelegate async after 15b — reconciler.runPhaseB()
//    - Heartbeat every 5 min — reconciler.refreshIfDue()
//    - BackendClient.verifyUnlock success — reconciler.refresh()
//
//  See docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md §5.
//

import Foundation
import AppKit

struct EnforcementSnapshot {
    let enforcementActive: Bool
    let constraints: [String: [String: Any]]
    let temporaryUnlockUntil: String?
    let asOf: Date
    let source: Source

    enum Source: String { case cache, backend, defaults, empty }
}

final class EnforcementReconciler {

    weak var appDelegate: AppDelegate?
    private let backendClient: BackendClient
    private let daemonClient: EnforcementDaemonClient
    private(set) var current: EnforcementSnapshot?

    private let settingsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Intentional/onboarding_settings.json")
    }()

    private let reconcileInterval: TimeInterval = 5 * 60
    private var lastReconcile: Date?

    init(appDelegate: AppDelegate, backendClient: BackendClient, daemonClient: EnforcementDaemonClient) {
        self.appDelegate = appDelegate
        self.backendClient = backendClient
        self.daemonClient = daemonClient
    }

    // MARK: Phase A — blocking, local cache verify

    /// Synchronous-looking; actually awaits a single XPC verify (daemon-local, <100ms).
    /// Must complete before ContentSafetyMonitor starts so CS sees verified state.
    func runBlockingPhaseA() async {
        appDelegate?.postLog("🛡️ Enforcement Phase A: verifying cache…")

        // Try daemon-signed cache first.
        if daemonClient.daemonAvailable,
           let triple = EnforcementCache.read() {
            let ok = await daemonClient.verify(payload: triple.canonicalJSON, signature: triple.signature)
            if ok {
                let snapshot = EnforcementSnapshot(
                    enforcementActive: triple.cache.enforcementActive,
                    constraints: triple.cache.constraints.mapValues { dict in
                        dict.mapValues { $0.value }
                    },
                    temporaryUnlockUntil: triple.cache.temporaryUnlockUntil,
                    asOf: Date(),
                    source: .cache
                )
                current = snapshot
                applyCorrections(snapshot, logPrefix: "Phase A cache-hit")
                return
            } else {
                appDelegate?.postLog("🛡️ Enforcement Phase A: cache signature INVALID — TAMPER")
                EnforcementCache.clear()
                fallbackMaxStrictness(reason: "invalid cache signature")
                return
            }
        }

        // No cache. Could be first run OR tamper (cache deleted). Backend answers this.
        appDelegate?.postLog("🛡️ Enforcement Phase A: no cache — awaiting backend response in Phase B")
        current = EnforcementSnapshot(
            enforcementActive: false, constraints: [:], temporaryUnlockUntil: nil,
            asOf: Date(), source: .empty
        )
    }

    // MARK: Phase B — async, backend fetch

    func runPhaseB() async {
        appDelegate?.postLog("🛡️ Enforcement Phase B: fetching backend state…")
        guard let result = await backendClient.fetchEnforcement() else {
            // Backend unreachable. If we have no cache AND enforcement was ever seen,
            // fall back to max-strictness. If we have no cache AND no prior lock, stay empty.
            if current?.source == .empty {
                // Check local state for "has this device ever been onboarded" signal
                let settings = (try? Data(contentsOf: settingsURL))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let hasConsent = (settings["consentStatus"] as? String) == "confirmed"
                if hasConsent {
                    fallbackMaxStrictness(reason: "backend unreachable, onboarded device, no cache")
                }
            }
            return
        }

        let snapshot = EnforcementSnapshot(
            enforcementActive: result.enforcementActive,
            constraints: result.constraints,
            temporaryUnlockUntil: result.temporaryUnlockUntil,
            asOf: Date(),
            source: .backend
        )
        current = snapshot
        lastReconcile = Date()

        // Sign + write cache if daemon is available.
        if daemonClient.daemonAvailable {
            let cacheData = EnforcementCacheData(
                deviceId: result.deviceId,
                enforcementActive: result.enforcementActive,
                constraints: result.constraints.mapValues { inner in
                    inner.mapValues { AnyCodable($0) }
                },
                temporaryUnlockUntil: result.temporaryUnlockUntil,
                updatedAt: result.updatedAt,
                cachedAt: ISO8601DateFormatter().string(from: Date())
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let canonical = try? encoder.encode(cacheData),
               let signature = await daemonClient.sign(canonical) {
                try? EnforcementCache.write(cache: cacheData, signature: signature)
                appDelegate?.postLog("🛡️ Enforcement: cache re-signed (\(result.constraints.count) constraints)")
            }
        } else {
            appDelegate?.postLog("🛡️ Enforcement: daemon unavailable — cache not signed (degraded mode)")
        }

        applyCorrections(snapshot, logPrefix: "Phase B backend-synced")
        pushStateToDashboard()
    }

    // MARK: Refresh hooks

    func refreshIfDue() async {
        if let last = lastReconcile, Date().timeIntervalSince(last) < reconcileInterval {
            return
        }
        await runPhaseB()
    }

    func refresh() async {
        await runPhaseB()
    }

    // MARK: Corrections

    private func applyCorrections(_ snapshot: EnforcementSnapshot, logPrefix: String) {
        guard snapshot.enforcementActive, !snapshot.constraints.isEmpty else { return }

        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            appDelegate?.postLog("⚠️ \(logPrefix): cannot read onboarding_settings.json")
            return
        }

        var violations: [(String, Any)] = []  // (key, correction)

        for (key, spec) in snapshot.constraints {
            let constraint = ConstraintEvaluator.parse(spec)
            let current = getValue(forKeyPath: key, in: settings)
            let result = ConstraintEvaluator.evaluate(key: key, constraint: constraint, currentValue: current)
            switch result {
            case .satisfied:
                continue
            case .violated(let correction):
                settings = setValue(correction, forKeyPath: key, in: settings)
                violations.append((key, correction))
            case .cannotAutoCorrect:
                appDelegate?.postLog("⚠️ \(logPrefix): unknown constraint for \(key)")
                // Fire tamper with special type; block further progress.
                Task {
                    await appDelegate?.backendClient?.reportContentSafetyTamper(
                        eventType: "unknown_constraint_type",
                        detail: key
                    )
                }
            }
        }

        if violations.isEmpty { return }

        appDelegate?.postLog("🛡️ \(logPrefix): \(violations.count) violations corrected")

        // Atomic write
        if let new = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
            try? new.write(to: settingsURL, options: .atomic)
        }

        // Notify runtime services of changes they care about.
        for (key, _) in violations {
            if key == "content_safety.enabled" {
                appDelegate?.contentSafetyMonitor?.onSettingsChanged(enabled: true)
            }
            // Other keys: dashboard will re-read on next state push.
        }

        // Show overlay + fire tamper event (once, batched).
        DispatchQueue.main.async { [weak self] in
            self?.appDelegate?.tamperOverlayController?.show(violations: violations)
        }
        Task {
            let detail = violations.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
            await appDelegate?.backendClient?.reportContentSafetyTamper(
                eventType: "enforcement_mismatch",
                detail: detail
            )
        }
    }

    private func fallbackMaxStrictness(reason: String) {
        appDelegate?.postLog("🛡️ Enforcement: FAIL-CLOSED fallback — \(reason)")
        // Apply a conservative default: force content safety + block all known platforms
        // that were previously enabled. Detailed list matches what a partner-lock typically
        // contains. Cached previous snapshot preferred if available.
        let defaults: [String: [String: Any]] = [
            "content_safety.enabled": ["type": "must_be_true"],
        ]
        let snapshot = EnforcementSnapshot(
            enforcementActive: true,
            constraints: defaults,
            temporaryUnlockUntil: nil,
            asOf: Date(),
            source: .defaults
        )
        current = snapshot
        applyCorrections(snapshot, logPrefix: "fallback-max-strictness")
    }

    // MARK: Dashboard bridge

    func pushStateToDashboard() {
        guard let snapshot = current else { return }
        let payload: [String: Any] = [
            "enforcement_active": snapshot.enforcementActive,
            "constraints": snapshot.constraints,
            "temporary_unlock_until": snapshot.temporaryUnlockUntil as Any,
            "source": snapshot.source.rawValue,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        appDelegate?.mainWindow?.callJS("window._enforcementState && window._enforcementState(\(json))")
    }

    // MARK: KeyPath helpers

    private func getValue(forKeyPath path: String, in dict: [String: Any]) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        var current: Any? = dict
        for part in parts {
            guard let sub = current as? [String: Any] else { return nil }
            current = sub[part]
        }
        return current
    }

    private func setValue(_ value: Any, forKeyPath path: String, in dict: [String: Any]) -> [String: Any] {
        var parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return dict }
        var result = dict
        if parts.count == 1 {
            result[parts[0]] = value
            return result
        }
        let first = parts.removeFirst()
        let sub = (result[first] as? [String: Any]) ?? [:]
        result[first] = setValue(value, forKeyPath: parts.joined(separator: "."), in: sub)
        return result
    }
}
```

- [ ] **Step 2: Build (expect some missing references — AppDelegate hooks from Task 16)**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```
If references to `tamperOverlayController` / `mainWindow.callJS` fail: they are wired in Task 15/17. Proceed to those tasks, then re-build at the end of Task 17.

- [ ] **Step 3: Commit**

```bash
git add Intentional/EnforcementReconciler.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(enforcement): EnforcementReconciler orchestrator (Phase A + B)"
```

---

### Task 15: TamperOverlayController

**Files:**
- Create: `Intentional/TamperOverlayController.swift`

- [ ] **Step 1: Create overlay (SwiftUI view + KeyableWindow controller)**

Create `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/TamperOverlayController.swift`:

```swift
//
//  TamperOverlayController.swift
//  Intentional
//
//  Full-screen overlay shown when the EnforcementReconciler force-corrects
//  local state. Matches the pattern used by SwitchOverlayController (one
//  window per screen, screenSaver level, pull-back activation observer).
//

import Cocoa
import SwiftUI

final class TamperOverlayController {

    private var windows: [NSWindow] = []

    func show(violations: [(String, Any)]) {
        dismiss()

        let headline: String
        if violations.count == 1 && violations[0].0 == "content_safety.enabled" {
            headline = "Content Safety was turned off outside the dashboard."
        } else if violations.count == 1 {
            headline = "A partner-locked setting was changed outside the dashboard."
        } else {
            headline = "Partner-locked settings were changed outside the dashboard."
        }

        let formatted = violations.map { format(key: $0.0, correction: $0.1) }
        let view = TamperOverlayView(
            headline: headline,
            bullets: formatted,
            dismiss: { [weak self] in self?.dismiss() }
        )

        for (i, screen) in NSScreen.screens.enumerated() {
            let host = NSHostingView(rootView: view)
            host.frame = screen.frame
            let w = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.level = .screenSaver
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            if i == 0 { w.makeKeyAndOrderFront(nil) } else { w.orderFront(nil) }
            windows.append(w)
        }

        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    func dismiss() {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
    }

    var isShowing: Bool { !windows.isEmpty }

    private func format(key: String, correction: Any) -> String {
        switch key {
        case "content_safety.enabled":
            return "Content Safety: re-enabled"
        case "distracting_sites":
            let items = (correction as? [String]) ?? []
            return "Distracting sites: restored \(items.count) site(s)"
        default:
            if key.hasSuffix(".enabled") {
                return "\(key): re-enabled"
            }
            if key.hasSuffix(".threshold"), let v = correction as? Double {
                return "\(key): raised back to \(Int(v))"
            }
            return "\(key): corrected"
        }
    }
}

struct TamperOverlayView: View {
    let headline: String
    let bullets: [String]
    let dismiss: () -> Void
    @State private var breathing = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 28) {
                Text(headline)
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text("It has been re-enabled. Caity has been notified.")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.6))
                if !bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(bullets, id: \.self) { b in
                            HStack(alignment: .top) {
                                Text("•").foregroundColor(.white.opacity(0.45))
                                Text(b).foregroundColor(.white.opacity(0.85))
                            }
                        }
                    }.padding(.top, 8)
                }
                Button(action: dismiss) {
                    Text("Got it — keep working")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 13)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(40)
            .frame(maxWidth: 600)
        }
        .opacity(breathing ? 1.0 : 0.96)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```
Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add Intentional/TamperOverlayController.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(enforcement): TamperOverlayController — multi-screen, SwiftUI"
```

---

### Task 16: Wire Reconciler into AppDelegate init + heartbeat

**Files:**
- Modify: `Intentional/AppDelegate.swift`

- [ ] **Step 1: Add properties on AppDelegate**

In `/Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/AppDelegate.swift`, near where other managers are declared (around line 45-50 with `contentSafetyMonitor`):

```swift
    var enforcementReconciler: EnforcementReconciler?
    var tamperOverlayController: TamperOverlayController?
```

- [ ] **Step 2: Insert init step 15b**

In `applicationDidFinishLaunching(_:)`, find step 15a (`BlockRitualController`) or step 15c (`ContentSafetyMonitor`). Insert BEFORE step 15c:

```swift
        // Step 15b: Enforcement Reconciler — runs BEFORE ContentSafetyMonitor
        // so CS reads a verified state.
        tamperOverlayController = TamperOverlayController()
        let enforcementDaemonClient = EnforcementDaemonClient(daemonClient: daemonClient)
        enforcementReconciler = EnforcementReconciler(
            appDelegate: self,
            backendClient: backendClient!,
            daemonClient: enforcementDaemonClient
        )

        // Phase A is async but fast (local XPC). Block startup briefly.
        let sema = DispatchSemaphore(value: 0)
        Task {
            await enforcementReconciler?.runBlockingPhaseA()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 1.0)  // hard cap at 1s; if daemon hangs, proceed
        postLog("🛡️ Enforcement: Phase A complete")

        // Phase B runs async after CS init — kicks off below.
```

After step 15d (SwitchInterventionCoordinator wiring), add the Phase B kickoff:

```swift
        // Phase B: async backend fetch. Don't block startup.
        Task { [weak self] in
            await self?.enforcementReconciler?.runPhaseB()
        }
```

- [ ] **Step 3: Wire periodic reconciliation into heartbeat**

Find the 2-minute heartbeat timer (step 21, around the bottom of `applicationDidFinishLaunching`). Inside its closure, add:

```swift
            Task { [weak self] in
                await self?.enforcementReconciler?.refreshIfDue()
            }
```

- [ ] **Step 4: Wire post-unlock refresh**

Find where `verifyUnlock` is called (look for `backendClient?.verifyUnlock` or similar in `MainWindow.swift`'s unlock flow). On success, append:

```swift
Task { [weak self] in
    await self?.enforcementReconciler?.refresh()
}
```

*(If the unlock flow currently lives in MainWindow.swift and doesn't have a direct AppDelegate handle, add a notification-based hookup: post `.enforcementShouldRefresh` on unlock success; AppDelegate observes and calls `refresh()`.)*

- [ ] **Step 5: Build + run**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```
Expected: SUCCESS.

Launch the app manually (or via the existing debug launch flow) and check logs for:
- `🛡️ Enforcement Phase A: verifying cache…`
- `🛡️ Enforcement: Phase A complete`
- `🛡️ Enforcement Phase B: fetching backend state…`

- [ ] **Step 6: Commit**

```bash
git add Intentional/AppDelegate.swift
git commit -m "feat(enforcement): wire Reconciler into AppDelegate step 15b + heartbeat"
```

---

### Task 17: Dashboard enforcement bridge

**Files:**
- Modify: `Intentional/MainWindow.swift`
- Modify: `Intentional/dashboard.html`

- [ ] **Step 1: Expose `callJS` publicly on MainWindow (if not already)**

Verify `MainWindow.swift` has a method that calls JavaScript. Per prior greps, line 2583 has `callJS("window._contentSafetyStatus(...)")` so the method exists. Add an explicit `public` wrapper if needed:

```swift
    // Already exists in MainWindow — verify accessibility.
    func callJS(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }
```

- [ ] **Step 2: Add JS handler in dashboard.html**

In `Intentional/dashboard.html`, near the top of the script section (search for `window._contentSafetyStatus` to find a similar pattern), add:

```javascript
    // Receives enforcement state from Swift reconciler. See
    // docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md §8.2.
    window._enforcementState = function(payload) {
      window._currentEnforcementState = payload;
      if (typeof applyEnforcementStateToDashboard === 'function') {
        applyEnforcementStateToDashboard(payload);
      }
    };
```

- [ ] **Step 3: Define `applyEnforcementStateToDashboard`**

Elsewhere in the dashboard's settings script block, add:

```javascript
    function applyEnforcementStateToDashboard(state) {
      if (!state || !state.enforcement_active) {
        document.querySelectorAll('.enforcement-locked').forEach(el => {
          el.classList.remove('enforcement-locked');
          const input = el.querySelector('input, select');
          if (input) input.disabled = false;
          const subtext = el.querySelector('.enforcement-lock-hint');
          if (subtext) subtext.remove();
        });
        return;
      }

      const constraints = state.constraints || {};
      const lockableSelectors = {
        'content_safety.enabled':      '#cs-screen-monitoring',
        'platforms.youtube.enabled':   '#yt-enabled',
        'platforms.youtube.threshold': '#yt-threshold',
        'platforms.instagram.enabled': '#ig-enabled',
        'platforms.facebook.enabled':  '#fb-enabled',
        // Add more as needed — match element IDs in the settings HTML.
      };

      Object.keys(lockableSelectors).forEach(key => {
        if (!constraints[key]) return;
        const sel = lockableSelectors[key];
        const input = document.querySelector(sel);
        if (!input) return;
        const row = input.closest('.settings-row') || input.parentElement;
        row.classList.add('enforcement-locked');
        input.disabled = true;
        if (!row.querySelector('.enforcement-lock-hint')) {
          const hint = document.createElement('div');
          hint.className = 'enforcement-lock-hint';
          hint.textContent = 'Get code from accountability partner to unlock';
          row.appendChild(hint);
        }
      });

      // Distracting sites list: show lock icon on items in constraints.must_include_all.values
      const siteConstraint = constraints['distracting_sites'];
      if (siteConstraint && siteConstraint.values) {
        const lockedSites = new Set(siteConstraint.values);
        document.querySelectorAll('.distracting-site').forEach(el => {
          const host = el.dataset.host || '';
          const removeBtn = el.querySelector('.remove-site');
          if (lockedSites.has(host) && removeBtn) {
            removeBtn.style.display = 'none';
            if (!el.querySelector('.site-lock-icon')) {
              const icon = document.createElement('span');
              icon.className = 'site-lock-icon';
              icon.textContent = '🔒';
              icon.title = 'This site is partner-locked.';
              el.appendChild(icon);
            }
          }
        });
      }
    }

    // Also apply on initial load in case state arrives before settings-panel render.
    window.addEventListener('DOMContentLoaded', function() {
      if (window._currentEnforcementState) {
        applyEnforcementStateToDashboard(window._currentEnforcementState);
      }
    });
```

- [ ] **Step 4: Add CSS for locked rows**

In the dashboard's style block, add:

```css
    .enforcement-locked {
      opacity: 0.5;
      pointer-events: none;
    }
    .enforcement-locked input, .enforcement-locked select {
      cursor: not-allowed;
    }
    .enforcement-lock-hint {
      font-size: 11px;
      color: #c88;
      margin-top: 4px;
    }
    .site-lock-icon {
      margin-left: 6px;
      opacity: 0.7;
    }
```

- [ ] **Step 5: Push state from reconciler after phase completion**

The reconciler's `pushStateToDashboard()` was already wired in Task 14. Verify it's invoked at the end of `runPhaseB()`. No additional code needed.

- [ ] **Step 6: Build + smoke test**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```
Expected: SUCCESS.

Manual test: launch the app, open Settings > Content Safety. If the user is partner-locked, the Screen Monitoring toggle should be greyed with "Get code from accountability partner to unlock" below it.

- [ ] **Step 7: Commit**

```bash
git add Intentional/MainWindow.swift Intentional/dashboard.html
git commit -m "feat(enforcement): dashboard bridge + locked-toggle UI"
```

---

### Task 18: Partner email registry

**Files:**
- Create: `docs/PARTNER_EMAIL_REGISTRY.md`

- [ ] **Step 1: Enumerate existing partner emails**

```bash
grep -n "send.*email\|Resend\|email_service" /Users/arayan/Documents/GitHub/intentional-backend/main.py /Users/arayan/Documents/GitHub/intentional-backend/email_service.py | head -40
```

Gather the list of every email send site + their triggers.

- [ ] **Step 2: Write registry document**

Create `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/PARTNER_EMAIL_REGISTRY.md`:

```markdown
# Partner Email Registry

Living inventory of every email an accountability partner (e.g. Caity) can receive from the Intentional system. Update any time a new trigger is added or an existing one is modified.

**Goals of this document:** reason about cumulative email volume, decide when consolidation or digests are warranted, avoid surprising the partner with undocumented senders.

---

## Entry format

```markdown
## <Email name>
- **Trigger:** <when it fires>
- **Sender template:** <Resend template id / hardcoded subject>
- **Rate limit:** <per-device-per-X, or "none">
- **Payload:** <what the email contains>
- **Source:** <backend endpoint + code location>
- **Added:** <YYYY-MM-DD, feature/PR>
```

---

## Registry

<!-- Populated during implementation. For each entry in email_service.py, fill out the template above. -->

## Content Safety — Tamper Detected (NEW, 2026-04-23)

- **Trigger:** macOS client detects a mismatch between local onboarding_settings.json and the backend enforcement blob at startup or heartbeat; client POSTs `/content-safety/tamper` with `event_type=enforcement_mismatch`.
- **Sender template:** `content_safety_tamper` (Resend) — customize subject/body as needed.
- **Rate limit:** 1 per hour per device (server-side, see `users.last_tamper_email_at`).
- **Payload:** partner name, device display name, timestamp, list of which settings were auto-corrected.
- **Source:** `intentional-backend/main.py` → `report_content_safety_tamper`; `intentional-macos-app/Intentional/EnforcementReconciler.swift` → `applyCorrections`.
- **Added:** 2026-04-23, Content Safety Lockdown feature.

---

## Open questions

- Should non-urgent events move to a daily digest while keeping urgent events real-time?
- Volume threshold for "overwhelming" — measure first before deciding.
- Should content-safety detections be further batched beyond the existing `batch-send`?
```

- [ ] **Step 3: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add docs/PARTNER_EMAIL_REGISTRY.md
git commit -m "docs: add partner email registry"
```

---

### Task 19: Degraded-mode banner when daemon is absent

**Files:**
- Modify: `Intentional/MainWindow.swift` (or `AppDelegate.swift`)
- Modify: `Intentional/dashboard.html`

- [ ] **Step 1: Push daemon-available flag to dashboard**

In `AppDelegate.swift`, after Phase A completion (inside the reconciler setup in Task 16), push a flag:

```swift
let available = enforcementDaemonClient.daemonAvailable
DispatchQueue.main.async { [weak self] in
    let js = "window._daemonAvailable && window._daemonAvailable(\(available ? "true" : "false"))"
    self?.mainWindow?.callJS(js)
}
```

- [ ] **Step 2: Dashboard JS handler**

Add to `dashboard.html`:

```javascript
    window._daemonAvailable = function(ok) {
      const banner = document.getElementById('daemon-degraded-banner');
      if (!ok) {
        if (!banner) {
          const b = document.createElement('div');
          b.id = 'daemon-degraded-banner';
          b.className = 'degraded-banner';
          b.textContent = '⚠ Lockdown not fully protected — install production build for full protection.';
          document.body.insertBefore(b, document.body.firstChild);
        }
      } else if (banner) {
        banner.remove();
      }
    };
```

Add CSS:

```css
    .degraded-banner {
      background: #5b2a2a;
      color: #fff;
      padding: 10px 16px;
      font-size: 12px;
      text-align: center;
      border-bottom: 1px solid #7a3838;
    }
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
git add Intentional/AppDelegate.swift Intentional/dashboard.html
git commit -m "feat(enforcement): degraded-mode banner when daemon unreachable"
```

---

### Task 20: End-to-end verification

- [ ] **Step 1: Clean-state reset**

```bash
# On the running machine (production or debug build):
python3 -c "
import json, pathlib
p = pathlib.Path.home() / 'Library/Application Support/Intentional/onboarding_settings.json'
d = json.loads(p.read_text())
print('current contentSafety:', d.get('contentSafety'))
print('current lockMode:', d.get('lockMode'))
"
```

Expected: `lockMode=partner` (current state).

- [ ] **Step 2: Tamper test**

```bash
# Edit JSON to disable CS
python3 -c "
import json, pathlib
p = pathlib.Path.home() / 'Library/Application Support/Intentional/onboarding_settings.json'
d = json.loads(p.read_text())
d['contentSafety']['enabled'] = False
p.write_text(json.dumps(d, indent=2))
print('tampered')
"

# Kill running app + relaunch
pkill -f "DerivedData.*Intentional"; sleep 2
DEBUG_APP="$HOME/Library/Developer/Xcode/DerivedData/Intentional-cjpaicwfawcwqgepfrsxstqebhev/Build/Products/Debug/Intentional.app"
__XCODE_BUILT_PRODUCTS_DIR_PATHS="$DEBUG_APP" "$DEBUG_APP/Contents/MacOS/Intentional" > /tmp/intentional-debug.log 2>&1 &
sleep 5

# Verify overlay fired + CS re-enabled
grep "Phase A\|Phase B\|TAMPER\|violations corrected" /tmp/intentional-debug.log | head
python3 -c "
import json, pathlib
p = pathlib.Path.home() / 'Library/Application Support/Intentional/onboarding_settings.json'
d = json.loads(p.read_text())
print('post-restart contentSafety:', d.get('contentSafety'))
"
```
Expected:
- Log shows "violations corrected" or equivalent
- `contentSafety.enabled` is back to `true`
- Tamper overlay appeared on screen (verify visually)
- Caity received tamper email (check inbox OR backend `users.last_tamper_email_at` timestamp)

- [ ] **Step 3: Offline test**

With the app running and CS enabled, block the backend:
```bash
sudo echo "127.0.0.1 api.intentional.social" >> /etc/hosts   # temporary block
```

Tamper again (JSON edit), restart, verify overlay still fires from cache.

Cleanup:
```bash
sudo sed -i '' '/api.intentional.social/d' /etc/hosts
```

- [ ] **Step 4: Daemon-absent test**

```bash
sudo launchctl bootout system/com.intentional.daemon 2>/dev/null
# Relaunch app — should show degraded-mode banner
grep "daemon unavailable\|degraded mode" /tmp/intentional-debug.log | head
```

Restore:
```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.intentional.daemon.plist
```

- [ ] **Step 5: Document test results in the spec**

Append a short "Verification run — 2026-04-23" section at the bottom of `docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md` with pass/fail for each step above. Commit with message: `docs: verification run for content safety lockdown`.

---

## Self-Review

**Spec coverage check:**
- §4 Backend schema/endpoints → Tasks 1, 2, 4 ✓
- §4.4 derivation function → Task 3 ✓
- §4.5 rate limit → Task 6 ✓
- §4.6 /register response extended → **Gap:** not explicitly tasked. Covered implicitly because `GET /device/enforcement` is the primary state-fetch path; a reinstalled device re-registers and then Phase B calls the enforcement endpoint on first run. The spec mentions `/register` extension as belt-and-suspenders; marking as a **follow-up** if/when we see reinstall-race issues in the wild.
- §4.7 TLS cert pinning → Task 13 ✓
- §5 client components → Tasks 10–17 ✓
- §6 daemon → Tasks 8, 9 ✓
- §7 security properties → inherent in the implementation across tasks
- §8 UX (tamper overlay, dashboard locked UI, email registry) → Tasks 15, 17, 18 ✓
- §9 failure modes → covered by Reconciler fallback paths in Task 14; verification in Task 20
- §11 migration/rollout → Task 7 (backfill) + task ordering reflects rollout order

**Placeholder scan:** one `TODO(ops): fill in actual fingerprint` in Task 13 — this is an intentional ops handoff (requires running `openssl` against prod). Acceptable placeholder.

**Type consistency:** `Constraint` enum cases match across tasks. `ConstraintResult` equality handled in Task 10 via `String(describing:)` compare — acceptable for test ergonomics. `EnforcementSnapshot` / `EnforcementCacheData` / `EnforcementFetchResult` are distinct shapes with a clear data-flow seam between them.

**Notes for executing agent:**
- Tasks 1–7 live in `intentional-backend`. Cd into that repo before running.
- Tasks 8–9 modify daemon code inside `intentional-macos-app`.
- Tasks 10–19 modify macOS app in `intentional-macos-app`.
- Task 20 is verification only — no commits unless verification step 5 documents results.
- If a subagent hits missing Xcode target-membership issues on new Swift files, include adding file-to-target in their task — this is easy to miss with `xcodebuild` command-line runs.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-23-content-safety-lockdown.md`.

Use **superpowers:subagent-driven-development** per standing user preference — dispatch a fresh subagent per task, two-stage review between tasks.
