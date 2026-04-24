# Puck Focus Signal End-to-End Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Puck tap → iOS NFC handler → backend `/focus/toggle` → Mac via WebSocket, all using the user's Supabase JWT for auth across three repos, with email-based account linking on the backend so Puck and the Mac both talk to the same `accounts` row.

**Architecture:**
- Backend accepts EITHER the existing intentional-JWT OR a Supabase JWT on `/devices/register`, `/focus/toggle`, `/focus/active`, and `/ws/focus`. A new helper `verify_any_token` unifies both.
- When a Supabase JWT is presented, the backend uses its `email` claim to look up the matching `accounts` row, or auto-creates one. A new `supabase_user_id` column is added (migration 011) so we can optionally differentiate, but the primary lookup is email.
- iOS: on successful auth, registers the device with the backend via `POST /devices/register`. On each NFC tap it also fires `POST /focus/toggle` (fire-and-forget, additive on top of existing FamilyControls toggle).
- Mac: already has `FocusWebSocketClient` that connects to `/ws/focus`. Fixes: heartbeat timer, `triggered_by` propagation to `FocusSessionManager`/`FocusSession`, WS auth token refresh on expiry, device registration on startup.

**Tech Stack:** FastAPI + pyjwt (backend), Swift (iOS + macOS), URLSession, Supabase Auth SDK (iOS).

---

## File Structure

**Backend (`/Users/arayan/Documents/GitHub/intentional-backend`):**
- Create: `migrations/011_add_supabase_user_id.sql` — add `supabase_user_id` column to `accounts`.
- Modify: `security.py` — add `verify_supabase_token` and `verify_any_token` helpers.
- Modify: `main.py` — swap `verify_access_token(...)` for `verify_any_token(...)` on the four focus-signal endpoints; add email-lookup-or-create helper.
- Create: `tests/test_focus_signal.py` — pytest unit tests for verifier + endpoints.

**Puck iOS (`/Users/arayan/Documents/GitHub/puck-ios`):**
- Create: `Puck/Core/Network/IntentionalAPIClient.swift` — thin client targeting `api.intentional.social` (separate from `api.getpuck.app`). Uses Supabase `accessToken` for `Authorization: Bearer`.
- Create: `Puck/Core/Network/IntentionalDeviceRegistration.swift` — service that calls `POST /devices/register` once per login, stores returned `device_id` in UserDefaults.
- Create: `Puck/Core/Network/IntentionalFocusSignalClient.swift` — `toggleFocus(action:)` fire-and-forget.
- Modify: `Puck/Core/Coordinator/PuckCoordinator.swift` — on NFC activation/deactivation, call `IntentionalFocusSignalClient.toggleFocus(action:)`.
- Modify: `Puck/Utils/Theme.swift` — add `Constants.IntentionalAPI.baseURL`.
- Modify: `Puck/Core/Auth/AuthService.swift` — on successful auth, trigger one-shot device registration.

**macOS (`/Users/arayan/Documents/GitHub/intentional-macos-app`):**
- Modify: `Intentional/FocusWebSocketClient.swift` — add 2-minute heartbeat timer when a session is active, plumb `triggered_by` through `onFocusSignal`.
- Modify: `Intentional/FocusSessionManager.swift` — add `remoteSessionId` property so heartbeats can include it.
- Modify: `Intentional/AppDelegate.swift` — call `POST /devices/register` once after login, pass `triggered_by` through to `FocusSession`.
- Create: `Intentional/IntentionalDeviceRegistration.swift` — same-idea service as iOS but for Mac.

**Docs:**
- Create: `docs/overnight-run-2026-04-24.md` — progress log + hand-off (required by CLAUDE.md convention).

---

## Safety Order

1. Backend first (everything depends on backend contract being settled).
2. iOS and Mac in parallel afterward.

---

## Task 1: Backend — add `supabase_user_id` column migration

**Files:**
- Create: `intentional-backend/migrations/011_add_supabase_user_id.sql`

- [ ] **Step 1: Write the migration**

```sql
-- 011_add_supabase_user_id.sql
-- Supabase auth federation: allow accounts to track their Supabase auth.users.id
-- This is additive. Email remains the primary account-identity field;
-- Supabase sub is stored for debugging and future auth federation.

ALTER TABLE accounts ADD COLUMN IF NOT EXISTS supabase_user_id UUID;
CREATE INDEX IF NOT EXISTS idx_accounts_supabase_user_id ON accounts(supabase_user_id);
```

- [ ] **Step 2: Commit**

```bash
git add migrations/011_add_supabase_user_id.sql
git commit -m "feat(migration): add supabase_user_id to accounts for Supabase auth federation"
```

---

## Task 2: Backend — add Supabase JWT verifier in `security.py`

**Files:**
- Modify: `intentional-backend/security.py`

- [ ] **Step 1: Add `verify_supabase_token` and `verify_any_token` functions**

Append to `security.py` (keep the existing `verify_access_token` untouched):

```python
# --- Supabase JWT support ---

def _get_supabase_jwt_secret() -> Optional[str]:
    """Return the Supabase JWT secret (HS256). None if not configured."""
    return os.getenv("SUPABASE_JWT_SECRET")


def verify_supabase_token(token: str) -> Optional[dict]:
    """
    Verify a Supabase-issued HS256 JWT using SUPABASE_JWT_SECRET.

    Supabase JWT payload fields of interest:
      - sub: auth.users.id (Supabase user UUID)
      - email: user email (present when `email` is the auth provider or user has an email)
      - aud: typically "authenticated"
      - role: "authenticated" or "anon"

    Returns the decoded payload on success, None on failure.
    Callers must perform email-based account lookup separately.
    """
    if not token:
        return None
    secret = _get_supabase_jwt_secret()
    if not secret:
        return None
    try:
        # Supabase JWTs use HS256 and audience "authenticated".
        payload = jwt.decode(
            token,
            secret,
            algorithms=["HS256"],
            audience="authenticated",
        )
    except jwt.ExpiredSignatureError:
        return None
    except jwt.InvalidTokenError:
        return None
    # Reject anon tokens (service-role/anon must never hit authed endpoints)
    if payload.get("role") != "authenticated":
        return None
    return payload


def verify_any_token(token: str) -> Optional[dict]:
    """
    Verify a JWT that is either:
      1) An intentional-issued HS256 JWT (via verify_access_token), OR
      2) A Supabase-issued HS256 JWT (via verify_supabase_token).

    Returns a payload dict normalized with at least `email`; the `sub`
    value is whatever the original token had (intentional-sub = account_id;
    supabase-sub = supabase user UUID). Callers must NOT assume `sub` is
    an account_id — use `token_source` to disambiguate.

    Added keys:
      - token_source: "intentional" or "supabase"

    Returns None if both verifiers fail.
    """
    payload = verify_access_token(token)
    if payload is not None:
        payload = dict(payload)
        payload["token_source"] = "intentional"
        return payload

    payload = verify_supabase_token(token)
    if payload is not None:
        payload = dict(payload)
        payload["token_source"] = "supabase"
        return payload

    return None
```

- [ ] **Step 2: Commit**

```bash
git add security.py
git commit -m "feat(auth): add Supabase JWT verifier and unified verify_any_token"
```

---

## Task 3: Backend — unit tests for Supabase verifier

**Files:**
- Create: `intentional-backend/tests/test_auth_supabase.py`

- [ ] **Step 1: Write failing tests**

```python
"""Unit tests for Supabase JWT verification and the unified verifier."""
import os
from datetime import datetime, timedelta, timezone

import jwt
import pytest


# Ensure SUPABASE_JWT_SECRET is set BEFORE importing security
os.environ["JWT_SECRET"] = "test-intentional-secret"
os.environ["SUPABASE_JWT_SECRET"] = "test-supabase-secret"

from security import (  # noqa: E402
    create_access_token,
    verify_access_token,
    verify_supabase_token,
    verify_any_token,
)


def _make_supabase_jwt(
    sub="abcd-1234",
    email="test@example.com",
    role="authenticated",
    aud="authenticated",
    expired=False,
    secret=None,
) -> str:
    """Mint a fake Supabase-style JWT for testing."""
    secret = secret or os.environ["SUPABASE_JWT_SECRET"]
    now = datetime.now(timezone.utc)
    exp = now - timedelta(minutes=5) if expired else now + timedelta(hours=1)
    payload = {
        "sub": sub,
        "email": email,
        "role": role,
        "aud": aud,
        "exp": exp,
        "iat": now,
    }
    return jwt.encode(payload, secret, algorithm="HS256")


def test_verify_supabase_token_valid():
    token = _make_supabase_jwt(email="alice@example.com")
    payload = verify_supabase_token(token)
    assert payload is not None
    assert payload["email"] == "alice@example.com"
    assert payload["role"] == "authenticated"


def test_verify_supabase_token_expired_returns_none():
    token = _make_supabase_jwt(expired=True)
    assert verify_supabase_token(token) is None


def test_verify_supabase_token_wrong_secret_returns_none():
    token = _make_supabase_jwt(secret="attacker-secret")
    assert verify_supabase_token(token) is None


def test_verify_supabase_token_anon_role_rejected():
    token = _make_supabase_jwt(role="anon")
    assert verify_supabase_token(token) is None


def test_verify_supabase_token_wrong_audience_rejected():
    token = _make_supabase_jwt(aud="not-authenticated")
    assert verify_supabase_token(token) is None


def test_verify_supabase_token_empty_returns_none():
    assert verify_supabase_token("") is None
    assert verify_supabase_token(None) is None  # type: ignore[arg-type]


def test_verify_any_token_accepts_intentional_jwt():
    token, _ = create_access_token("acct-uuid-1", "user@example.com")
    payload = verify_any_token(token)
    assert payload is not None
    assert payload["token_source"] == "intentional"
    assert payload["sub"] == "acct-uuid-1"
    assert payload["email"] == "user@example.com"


def test_verify_any_token_accepts_supabase_jwt():
    token = _make_supabase_jwt(sub="sb-uuid-1", email="sb@example.com")
    payload = verify_any_token(token)
    assert payload is not None
    assert payload["token_source"] == "supabase"
    assert payload["sub"] == "sb-uuid-1"
    assert payload["email"] == "sb@example.com"


def test_verify_any_token_rejects_garbage():
    assert verify_any_token("not-a-jwt") is None
    assert verify_any_token("") is None


def test_verify_any_token_supabase_without_secret_falls_through_to_none():
    token = _make_supabase_jwt()
    original = os.environ.pop("SUPABASE_JWT_SECRET", None)
    try:
        assert verify_any_token(token) is None
    finally:
        if original is not None:
            os.environ["SUPABASE_JWT_SECRET"] = original
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python3 -m pytest tests/test_auth_supabase.py -v
```

Expected: all 10 tests PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/test_auth_supabase.py
git commit -m "test(auth): unit tests for Supabase JWT verifier and verify_any_token"
```

---

## Task 4: Backend — email-based account resolver

**Files:**
- Modify: `intentional-backend/main.py`

- [ ] **Step 1: Add `_resolve_account_from_token` helper near the top of the focus-signal section (around line 2725)**

Add this helper function just above `# ===== Focus Signal API =====`:

```python
from security import verify_any_token  # ensure this import is in the module; add near top with other security imports

async def _resolve_account_from_token(authorization: str) -> str:
    """
    Validate Bearer token (intentional or Supabase), resolve to account_id.

    If the token is a Supabase JWT, look up the matching account by email,
    auto-creating one if it does not exist. Stamps `supabase_user_id` on the
    account row the first time we see a given Supabase user.

    Raises HTTPException(401) on invalid auth.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Invalid authorization header")
    token = authorization[7:]
    payload = verify_any_token(token)
    if payload is None:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    # Intentional-issued token: sub IS the account_id
    if payload.get("token_source") == "intentional":
        return payload["sub"]

    # Supabase-issued token: map email -> accounts.id
    email = (payload.get("email") or "").lower().strip()
    if not email:
        raise HTTPException(status_code=401, detail="Supabase token missing email claim")
    supabase_sub = payload.get("sub")
    db = get_db()
    existing = db.table("accounts").select("id,supabase_user_id").eq("email", email).limit(1).execute()
    if existing.data:
        account = existing.data[0]
        # Backfill supabase_user_id if first sight
        if supabase_sub and not account.get("supabase_user_id"):
            try:
                db.table("accounts").update({
                    "supabase_user_id": supabase_sub
                }).eq("id", account["id"]).execute()
            except Exception:
                pass  # non-fatal
        return account["id"]

    # Auto-create account for this Supabase user
    try:
        new = db.table("accounts").insert({
            "email": email,
            "supabase_user_id": supabase_sub,
        }).execute()
        return new.data[0]["id"]
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to provision account: {e}")
```

Make sure the `from security import verify_any_token` import is added near the existing `from security import ...` block. Look for `from security import (` around line 13 and add `verify_any_token` to the list. Otherwise add a fresh `from security import verify_any_token` line.

- [ ] **Step 2: Rewrite four endpoints to use the helper**

Edit `/devices/register` (starts at line 2728). Replace the token-verification block:

```python
@app.post("/devices/register", response_model=DeviceRegisterResponse)
async def register_focus_device(
    request: DeviceRegisterRequest,
    authorization: str = Header(...)
):
    """Register a Mac or iOS device for focus signal relay."""
    account_id = await _resolve_account_from_token(authorization)
    if request.device_type not in ("mac", "ios"):
        raise HTTPException(status_code=400, detail="device_type must be 'mac' or 'ios'")
    # ... rest unchanged
```

Edit `/focus/toggle` (starts at line 2776):

```python
@app.post("/focus/toggle", response_model=FocusToggleResponse)
async def toggle_focus(
    request: FocusToggleRequest,
    authorization: str = Header(...)
):
    account_id = await _resolve_account_from_token(authorization)
    # ... rest unchanged
```

Edit `/focus/active` (starts at line 2853):

```python
@app.get("/focus/active", response_model=FocusActiveResponse)
async def get_active_focus(authorization: str = Header(...)):
    account_id = await _resolve_account_from_token(authorization)
    # ... rest unchanged
```

Edit `/ws/focus` WebSocket handler (starts at line 2874). The WebSocket auth is different — first message is the JWT string. Replace the verify block:

```python
    try:
        auth_message = await websocket.receive_text()
        payload = verify_any_token(auth_message)
        if payload is None:
            await websocket.send_json({"type": "error", "message": "Invalid token"})
            await websocket.close(code=4001)
            return
        if payload.get("token_source") == "intentional":
            account_id = payload["sub"]
        else:
            # Supabase path: resolve by email (replicates _resolve_account_from_token logic)
            email = (payload.get("email") or "").lower().strip()
            if not email:
                await websocket.send_json({"type": "error", "message": "Missing email"})
                await websocket.close(code=4001)
                return
            db = get_db()
            existing = db.table("accounts").select("id,supabase_user_id").eq("email", email).limit(1).execute()
            if existing.data:
                account_id = existing.data[0]["id"]
                supabase_sub = payload.get("sub")
                if supabase_sub and not existing.data[0].get("supabase_user_id"):
                    try:
                        db.table("accounts").update({
                            "supabase_user_id": supabase_sub
                        }).eq("id", account_id).execute()
                    except Exception:
                        pass
            else:
                try:
                    new = db.table("accounts").insert({
                        "email": email,
                        "supabase_user_id": payload.get("sub"),
                    }).execute()
                    account_id = new.data[0]["id"]
                except Exception:
                    await websocket.close(code=4001)
                    return
    except Exception:
        await websocket.close(code=4001)
        return
```

- [ ] **Step 3: Commit**

```bash
git add main.py
git commit -m "feat(focus): accept Supabase JWTs on focus-signal endpoints via email-linked accounts"
```

---

## Task 5: Backend — endpoint integration tests

**Files:**
- Create: `intentional-backend/tests/test_focus_endpoints.py`

- [ ] **Step 1: Write tests that exercise the focus endpoints with both token kinds**

```python
"""
Integration tests for /devices/register, /focus/toggle, /focus/active.

These tests use a mocked Supabase DB layer (via patching `main.get_db`) to
verify that the auth path and business logic work end-to-end.
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
        "sub": sub,
        "email": email,
        "role": "authenticated",
        "aud": "authenticated",
        "exp": now + timedelta(hours=1),
        "iat": now,
    }
    return jwt.encode(payload, os.environ["SUPABASE_JWT_SECRET"], algorithm="HS256")


def _intentional_jwt(account_id="acct-1", email="user@example.com") -> str:
    from security import create_access_token
    token, _ = create_access_token(account_id, email)
    return token


class _FakeQuery:
    """Minimal supabase-py .table().select()/update()/insert() chain mock."""
    def __init__(self, data=None):
        self._data = data if data is not None else []
        self.last_update = None
        self.last_insert = None

    def select(self, *args, **kwargs): return self
    def eq(self, *args, **kwargs): return self
    def in_(self, *args, **kwargs): return self
    def gte(self, *args, **kwargs): return self
    def order(self, *args, **kwargs): return self
    def limit(self, *args, **kwargs): return self
    def update(self, payload): self.last_update = payload; return self
    def insert(self, payload):
        self.last_insert = payload
        ins = payload if isinstance(payload, list) else [payload]
        for row in ins:
            row.setdefault("id", "new-id")
        self._data = ins
        return self
    def upsert(self, payload, **kwargs):
        return self.insert(payload)
    def delete(self): return self
    def execute(self):
        r = MagicMock()
        r.data = self._data
        r.count = len(self._data) if self._data else 0
        return r


class _FakeDB:
    """Stand-in for the Supabase client with table-level routing."""
    def __init__(self, accounts=None, focus_sessions=None, registered_devices=None, users=None):
        self._tables = {
            "accounts": _FakeQuery(accounts if accounts is not None else []),
            "focus_sessions": _FakeQuery(focus_sessions if focus_sessions is not None else []),
            "registered_devices": _FakeQuery(registered_devices if registered_devices is not None else [{"id": "dev-1"}]),
            "users": _FakeQuery(users if users is not None else []),
            "system_events": _FakeQuery([]),
        }

    def table(self, name):
        return self._tables.setdefault(name, _FakeQuery([]))


def test_devices_register_with_supabase_jwt_auto_creates_account():
    fake_db = _FakeDB(accounts=[])  # no existing account
    with patch("main.get_db", return_value=fake_db):
        r = _client().post(
            "/devices/register",
            json={"device_type": "mac", "device_name": "Test Mac"},
            headers={"Authorization": f"Bearer {_supabase_jwt(email='new@example.com')}"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["success"] is True
    assert body["device_id"]


def test_devices_register_with_intentional_jwt():
    fake_db = _FakeDB()
    with patch("main.get_db", return_value=fake_db):
        r = _client().post(
            "/devices/register",
            json={"device_type": "ios", "device_name": "Test iPhone"},
            headers={"Authorization": f"Bearer {_intentional_jwt()}"},
        )
    assert r.status_code == 200


def test_devices_register_rejects_unauthorized():
    r = _client().post(
        "/devices/register",
        json={"device_type": "mac"},
        headers={"Authorization": "Bearer garbage"},
    )
    assert r.status_code == 401


def test_focus_toggle_start_with_supabase_jwt():
    accounts = [{"id": "acct-abc", "supabase_user_id": None}]
    fake_db = _FakeDB(accounts=accounts)
    with patch("main.get_db", return_value=fake_db):
        r = _client().post(
            "/focus/toggle",
            json={"action": "start"},
            headers={"Authorization": f"Bearer {_supabase_jwt(email='user@example.com')}"},
        )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "started"


def test_focus_toggle_bad_action():
    accounts = [{"id": "acct-abc"}]
    fake_db = _FakeDB(accounts=accounts)
    with patch("main.get_db", return_value=fake_db):
        r = _client().post(
            "/focus/toggle",
            json={"action": "pause"},
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 400


def test_focus_active_no_session():
    accounts = [{"id": "acct-1"}]
    fake_db = _FakeDB(accounts=accounts, focus_sessions=[])
    with patch("main.get_db", return_value=fake_db):
        r = _client().get(
            "/focus/active",
            headers={"Authorization": f"Bearer {_supabase_jwt()}"},
        )
    assert r.status_code == 200
    assert r.json()["active"] is False


def test_focus_endpoints_reject_missing_header():
    r = _client().post("/focus/toggle", json={"action": "start"})
    assert r.status_code in (401, 422)  # fastapi returns 422 for missing required Header
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python3 -m pytest tests/test_focus_endpoints.py -v
```

Expected: all 7 tests PASS. If a test fails due to existing `main.py` using `db.table("accounts").select("*")` while our fake returns rows without all fields, broaden the fake to return full dict or tighten the select. Fix iteratively.

- [ ] **Step 3: Commit**

```bash
git add tests/test_focus_endpoints.py
git commit -m "test(focus): integration tests for /devices/register and /focus/toggle with both token kinds"
```

---

## Task 6: Backend — verify full test suite still passes

- [ ] **Step 1: Run full pytest**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python3 -m pytest tests/ -v
```

Expected: all tests pass (the existing `test_enforcement.py` should be unaffected).

- [ ] **Step 2: Commit nothing if no changes, note any flakes in the progress log.**

---

## Task 7: iOS — Constants update for Intentional API

**Files:**
- Modify: `puck-ios/Puck/Utils/Theme.swift`

- [ ] **Step 1: Add `IntentionalAPI` section to Constants**

Edit the `Constants.API` block. Add a sibling struct:

```swift
struct Constants {
    struct API {
        static let baseURL = "https://api.getpuck.app"
        // Supabase credentials loaded from Config.plist via SupabaseService
    }

    // Intentional (macOS app) backend — separate from Puck backend
    struct IntentionalAPI {
        static let baseURL = "https://api.intentional.social"
    }
    // ... rest unchanged
```

- [ ] **Step 2: Commit**

```bash
git add Puck/Utils/Theme.swift
git commit -m "feat(config): add Intentional backend base URL to Constants"
```

---

## Task 8: iOS — create `IntentionalAPIClient`

**Files:**
- Create: `puck-ios/Puck/Core/Network/IntentionalAPIClient.swift`

- [ ] **Step 1: Write the client**

```swift
import Foundation

/// HTTP client for the Intentional (macOS app) backend at api.intentional.social.
/// Separate from the Puck backend client because it uses a different base URL
/// and a different path-space. Uses the user's Supabase access token as Bearer.
final class IntentionalAPIClient: @unchecked Sendable {
    static let shared = IntentionalAPIClient()
    private init() {}

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    struct EmptyBody: Encodable {}

    enum APIClientError: Error {
        case notAuthenticated
        case badURL
        case badResponse
        case serverError(Int, String)
    }

    func post<T: Decodable, B: Encodable>(
        path: String,
        body: B
    ) async throws -> T {
        try await send(path: path, method: "POST", body: body)
    }

    func get<T: Decodable>(path: String) async throws -> T {
        try await send(path: path, method: "GET", body: Optional<EmptyBody>.none)
    }

    private func send<T: Decodable, B: Encodable>(
        path: String,
        method: String,
        body: B?
    ) async throws -> T {
        let base = URL(string: Constants.IntentionalAPI.baseURL)!
        let url = base.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body = body as? B {
            req.httpBody = try Self.jsonEncoder.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let token = await currentAccessToken() else {
            throw APIClientError.notAuthenticated
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw APIClientError.serverError(http.statusCode, msg)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try Self.jsonDecoder.decode(T.self, from: data)
    }

    @MainActor
    private func currentAccessToken() async -> String? {
        AuthService.shared.accessToken
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Puck/Core/Network/IntentionalAPIClient.swift
git commit -m "feat(network): add IntentionalAPIClient for api.intentional.social"
```

---

## Task 9: iOS — create `IntentionalDeviceRegistration`

**Files:**
- Create: `puck-ios/Puck/Core/Network/IntentionalDeviceRegistration.swift`

- [ ] **Step 1: Write the service**

```swift
import Foundation
import UIKit

/// One-shot registration of this Puck iOS device with the Intentional backend.
/// Idempotent: the backend upserts on (account_id, device_type, device_name).
@MainActor
final class IntentionalDeviceRegistration {
    static let shared = IntentionalDeviceRegistration()
    private init() {}

    private struct RegisterRequest: Encodable {
        let device_type: String
        let device_name: String?
        let push_token: String?
    }

    private struct RegisterResponse: Decodable {
        let success: Bool
        let device_id: String
        let message: String?
    }

    private let storedDeviceIdKey = "intentional_backend_device_id"

    /// The registered device_id from the Intentional backend, if we have one.
    var storedDeviceId: String? {
        UserDefaults.standard.string(forKey: storedDeviceIdKey)
    }

    /// Register this device. Fire-and-forget; swallows errors and logs.
    /// Call after successful Supabase auth.
    func registerIfNeeded(pushToken: String? = nil) {
        Task { [weak self] in
            guard let self = self else { return }
            // No token → not authed yet; skip. AuthService will trigger us when authed.
            guard AuthService.shared.accessToken != nil else { return }
            let name = UIDevice.current.name
            let body = RegisterRequest(
                device_type: "ios",
                device_name: name,
                push_token: pushToken
            )
            do {
                let resp: RegisterResponse = try await IntentionalAPIClient.shared.post(
                    path: "devices/register",
                    body: body
                )
                UserDefaults.standard.set(resp.device_id, forKey: self.storedDeviceIdKey)
                AppLogger.authInfo("Registered with Intentional backend: device_id=\(resp.device_id)")
            } catch {
                AppLogger.authError("Intentional device registration failed", errorObj: error)
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Puck/Core/Network/IntentionalDeviceRegistration.swift
git commit -m "feat(network): add IntentionalDeviceRegistration service"
```

---

## Task 10: iOS — create `IntentionalFocusSignalClient`

**Files:**
- Create: `puck-ios/Puck/Core/Network/IntentionalFocusSignalClient.swift`

- [ ] **Step 1: Write the client**

```swift
import Foundation

/// Sends focus start/stop signals to the Intentional backend so the Mac mirrors
/// Puck's NFC tap in real-time. Fire-and-forget by design: if the backend is
/// unreachable, the phone still blocks locally; the Mac catches up on reconnect.
@MainActor
final class IntentionalFocusSignalClient {
    static let shared = IntentionalFocusSignalClient()
    private init() {}

    enum Action: String, Encodable {
        case start
        case stop
    }

    private struct ToggleRequest: Encodable {
        let action: String
    }

    private struct ToggleResponse: Decodable {
        let session_id: String?
        let status: String
        let started_at: String?
        let message: String?
    }

    /// Fire-and-forget: never throws, never blocks the caller.
    func toggleFocus(action: Action) {
        Task.detached {
            do {
                let body = ToggleRequest(action: action.rawValue)
                let resp: ToggleResponse = try await IntentionalAPIClient.shared.post(
                    path: "focus/toggle",
                    body: body
                )
                AppLogger.nfcInfo("Intentional focus toggle: action=\(action.rawValue) status=\(resp.status) session=\(resp.session_id ?? "-")")
            } catch {
                // Fire-and-forget: don't surface to UI. Log only.
                AppLogger.nfcError("Intentional focus toggle failed", errorObj: error)
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Puck/Core/Network/IntentionalFocusSignalClient.swift
git commit -m "feat(network): add IntentionalFocusSignalClient for fire-and-forget focus signal"
```

---

## Task 11: iOS — wire PuckCoordinator to focus-signal client

**Files:**
- Modify: `puck-ios/Puck/Core/Coordinator/PuckCoordinator.swift`

- [ ] **Step 1: Add focus signal calls on mode activation/deactivation**

In `PuckCoordinator.swift`:

1. In `activateMode` (around line 206), after `blockingService.activate(...)` (or after bedtime), add:

```swift
// Also mirror to Mac via Intentional backend (fire-and-forget).
IntentionalFocusSignalClient.shared.toggleFocus(action: .start)
```

Only send for `.blocking` mode (not for bedtime, which is phone-only). Skip the signal for bedtime.

2. In `endActiveFocusSession` (around line 343), add BEFORE `activeFocusSession = nil`:

```swift
// Fire-and-forget stop signal to Mac.
IntentionalFocusSignalClient.shared.toggleFocus(action: .stop)
```

Exact diffs:

In `activateMode`:

```swift
    private func activateMode(_ mode: FocusMode, slug: String) {
        guard let modelContext else { return }

        switch mode.modeType {
        case .blocking:
            blockingService.activate(mode: mode, duration: mode.defaultDuration)
            // Mirror to Mac via Intentional backend (fire-and-forget)
            IntentionalFocusSignalClient.shared.toggleFocus(action: .start)

        case .bedtime:
            bedtimeService.activate(brightness: mode.bedtimeBrightness)
            if !mode.appTokens.isEmpty || !mode.categoryTokens.isEmpty {
                blockingService.activate(mode: mode, duration: nil)
            }
        }
        // ... rest unchanged
```

In `endActiveFocusSession`:

```swift
    func endActiveFocusSession(reason: EndReason) {
        guard let session = activeFocusSession else { return }

        // Fire-and-forget stop signal to Mac (only if this was a blocking session)
        if session.modeType == .blocking {
            IntentionalFocusSignalClient.shared.toggleFocus(action: .stop)
        }

        session.endTime = Date()
        session.endReason = reason
        activeFocusSession = nil
        activeModeSlug = nil
        AppLogger.coordinatorInfo("FocusSession ended: \(reason.rawValue)")
    }
```

Note: `FocusSession` has a `modeType` field. Verify by reading the `FocusSession` model file. If `modeType` is optional, default to `.blocking` when missing (the predominant case).

- [ ] **Step 2: Commit**

```bash
git add Puck/Core/Coordinator/PuckCoordinator.swift
git commit -m "feat(coordinator): mirror Puck NFC taps to Mac via Intentional backend"
```

---

## Task 12: iOS — wire AuthService to trigger device registration

**Files:**
- Modify: `puck-ios/Puck/Core/Auth/AuthService.swift`

- [ ] **Step 1: Add a call to `IntentionalDeviceRegistration.shared.registerIfNeeded()` wherever `accessToken` becomes non-nil**

Add a helper method at the bottom of `AuthService`:

```swift
    /// Trigger backend registrations that depend on an access token.
    /// Safe to call multiple times — the downstream services are idempotent.
    private func triggerPostAuthBackendCalls() {
        IntentionalDeviceRegistration.shared.registerIfNeeded()
    }
```

Then call it in three places where the token becomes set:
1. `listenForAuthChanges()` — after `accessToken = state.session?.accessToken` inside the `if let session` branch (line ~50):

```swift
if let session = state.session {
    userEmail = session.user.email
    restoreOnboardingState(from: session.user)
    updateAuthState()
    triggerPostAuthBackendCalls()
} else {
```

2. `verifyOTP(...)` after `updateAuthState()`:

```swift
            updateAuthState()
            triggerPostAuthBackendCalls()
```

3. `signInWithApple(...)` after `updateAuthState()`:

```swift
            updateAuthState()
            triggerPostAuthBackendCalls()
```

- [ ] **Step 2: Commit**

```bash
git add Puck/Core/Auth/AuthService.swift
git commit -m "feat(auth): register device with Intentional backend after successful auth"
```

---

## Task 13: iOS — add files to Xcode project

**Files:**
- Modify: `puck-ios/Puck.xcodeproj/project.pbxproj`

- [ ] **Step 1: Use the xcodeproj ruby gem to add the three new swift files**

```bash
cd /Users/arayan/Documents/GitHub/puck-ios
ruby -e '
require "xcodeproj"
project_path = "Puck.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == "Puck" }
raise "target not found" unless target

network_group_path = "Puck/Core/Network"
group = project.main_group
network_group_path.split("/").each do |segment|
  sub = group.children.find { |c| c.respond_to?(:name) && (c.name == segment || c.display_name == segment) }
  raise "group #{segment} missing" unless sub
  group = sub
end

new_files = [
  "Puck/Core/Network/IntentionalAPIClient.swift",
  "Puck/Core/Network/IntentionalDeviceRegistration.swift",
  "Puck/Core/Network/IntentionalFocusSignalClient.swift",
]
new_files.each do |path|
  basename = File.basename(path)
  already_in_group = group.children.any? { |c| c.respond_to?(:path) && c.path && File.basename(c.path) == basename }
  already_in_target = target.source_build_phase.files_references.any? { |r| r && r.path && File.basename(r.path) == basename }
  next if already_in_group && already_in_target
  ref = already_in_group ? group.children.find { |c| c.respond_to?(:path) && c.path && File.basename(c.path) == basename } : group.new_reference(basename)
  target.add_file_references([ref]) unless already_in_target
  puts "added #{basename}"
end

project.save
'
```

- [ ] **Step 2: Verify pbxproj changes are sane**

```bash
cd /Users/arayan/Documents/GitHub/puck-ios
git diff Puck.xcodeproj/project.pbxproj | head -80
```

Expect: three `PBXFileReference` entries with `IntentionalAPIClient.swift`, `IntentionalDeviceRegistration.swift`, `IntentionalFocusSignalClient.swift`, plus three `PBXBuildFile` entries, plus the main target `PBXSourcesBuildPhase` referencing them.

- [ ] **Step 3: Commit**

```bash
git add Puck.xcodeproj/project.pbxproj
git commit -m "feat(xcode): register new Intentional backend network files"
```

---

## Task 14: iOS — build verification

- [ ] **Step 1: Build for simulator**

```bash
cd /Users/arayan/Documents/GitHub/puck-ios
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -60
```

Expected: `** BUILD SUCCEEDED **`.

If build fails due to a missing symbol or misplaced reference, read the error carefully, fix, re-run. DO NOT attempt to sign or run on device — generic simulator build only.

- [ ] **Step 2: Document any warnings in the progress log.**

---

## Task 15: Mac — DeviceRegistration service

**Files:**
- Create: `intentional-macos-app/Intentional/IntentionalDeviceRegistration.swift`

- [ ] **Step 1: Write the Swift class**

```swift
import Foundation
import IOKit

/// One-shot registration of this Mac with the Intentional backend.
/// Called after we have a valid access token. Idempotent.
final class IntentionalDeviceRegistration {
    static let shared = IntentionalDeviceRegistration()
    private init() {}

    private let storedDeviceIdKey = "intentional_backend_mac_device_id"

    var storedDeviceId: String? {
        UserDefaults.standard.string(forKey: storedDeviceIdKey)
    }

    /// Register this Mac. Pass the current access token (intentional JWT or Supabase JWT).
    func registerIfNeeded(token: String, log: @escaping (String) -> Void) {
        guard !token.isEmpty else { return }

        #if DEBUG
        let base = "http://localhost:8000"
        #else
        let base = "https://api.intentional.social"
        #endif
        guard let url = URL(string: "\(base)/devices/register") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let name = Host.current().localizedName ?? "Mac"
        let body: [String: Any] = [
            "device_type": "mac",
            "device_name": name,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            if let error = error {
                log("🔌 DeviceRegister failed: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("🔌 DeviceRegister non-2xx or bad body")
                return
            }
            if let deviceId = json["device_id"] as? String {
                UserDefaults.standard.set(deviceId, forKey: self?.storedDeviceIdKey ?? "")
                log("🔌 DeviceRegister OK: device_id=\(deviceId)")
            }
        }.resume()
    }
}
```

- [ ] **Step 2: Add file to Xcode project**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
ruby -e '
require "xcodeproj"
project_path = "Intentional.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == "Intentional" }
raise "target not found" unless target

group = project.main_group.children.find { |g| g.respond_to?(:name) && (g.name == "Intentional" || g.display_name == "Intentional") }
raise "Intentional group not found" unless group

new_files = ["IntentionalDeviceRegistration.swift"]
new_files.each do |basename|
  already_in_group = group.children.any? { |c| c.respond_to?(:path) && c.path && File.basename(c.path) == basename }
  already_in_target = target.source_build_phase.files_references.any? { |r| r && r.path && File.basename(r.path) == basename }
  next if already_in_group && already_in_target
  ref = already_in_group ? group.children.find { |c| c.respond_to?(:path) && c.path && File.basename(c.path) == basename } : group.new_reference(basename)
  target.add_file_references([ref]) unless already_in_target
  puts "added #{basename}"
end

project.save
'
```

- [ ] **Step 3: Commit**

```bash
git add Intentional/IntentionalDeviceRegistration.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(focus): add IntentionalDeviceRegistration service for Mac"
```

---

## Task 16: Mac — propagate `triggered_by` through WebSocket signals

**Files:**
- Modify: `intentional-macos-app/Intentional/FocusWebSocketClient.swift`

- [ ] **Step 1: Extend the `onFocusSignal` signature**

Change the closure signature to include `triggeredBy`:

```swift
    /// Called when a focus signal is received from the backend
    /// Parameters: action ("start" or "stop"), sessionId, triggeredBy ("puck" | "app" | other)
    var onFocusSignal: ((_ action: String, _ sessionId: String, _ triggeredBy: String) -> Void)?
```

Update `handleMessage` to parse `triggered_by` (backend currently sends `session_id` and `action` — extend the server-side message so it also includes `triggered_by`; see Task 18).

For now (before backend update), default to `"puck"` when the field is missing since the current backend uses `triggered_by: 'puck'` on all its session inserts:

```swift
        case "focus_signal":
            let action = json["action"] as? String ?? ""
            let sessionId = json["session_id"] as? String ?? ""
            let triggeredBy = json["triggered_by"] as? String ?? "puck"
            print("[WS] Focus signal: \(action) session=\(sessionId) triggeredBy=\(triggeredBy)")
            DispatchQueue.main.async {
                self.onFocusSignal?(action, sessionId, triggeredBy)
            }
```

- [ ] **Step 2: Add heartbeat timer fields**

Add these to the class:

```swift
    private var heartbeatTimer: Timer?
    private var heartbeatSessionId: String?
```

Add public methods:

```swift
    /// Start sending heartbeats every 2 minutes for the given session.
    func startHeartbeat(sessionId: String) {
        heartbeatSessionId = sessionId
        stopHeartbeat()
        let timer = Timer(timeInterval: 120.0, repeats: true) { [weak self] _ in
            guard let self = self, let sid = self.heartbeatSessionId else { return }
            self.sendHeartbeat(sessionId: sid)
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heartbeatSessionId = nil
    }
```

Also call `stopHeartbeat()` from `disconnect()`.

- [ ] **Step 3: Update callers in AppDelegate.swift**

In AppDelegate.swift around line 573:

```swift
        focusWebSocketClient?.onFocusSignal = { [weak self] action, sessionId, triggeredBy in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if action == "start" {
                    self.postLog("🔌 Puck focus signal: START (session: \(sessionId), triggeredBy: \(triggeredBy))")
                    self.focusWebSocketClient?.startHeartbeat(sessionId: sessionId)
                    self.showFocusStartOverlay(isPuckTriggered: triggeredBy == "puck")
                } else if action == "stop" {
                    self.postLog("🔌 Puck focus signal: STOP (session: \(sessionId))")
                    self.focusWebSocketClient?.stopHeartbeat()
                    self.endFocusSession()
                }
            }
        }
```

- [ ] **Step 4: Commit**

```bash
git add Intentional/FocusWebSocketClient.swift Intentional/AppDelegate.swift
git commit -m "feat(focus): heartbeat timer + triggered_by propagation in WS client"
```

---

## Task 17: Mac — call DeviceRegistration after login

**Files:**
- Modify: `intentional-macos-app/Intentional/AppDelegate.swift`

- [ ] **Step 1: Call `IntentionalDeviceRegistration.shared.registerIfNeeded(token:)` after the WebSocket connect block**

Right after the existing block that connects the WebSocket (line 593-596), add:

```swift
        // Register this Mac with the Intentional backend (idempotent, one-shot)
        if let token = backendClient?.getAccessToken() {
            IntentionalDeviceRegistration.shared.registerIfNeeded(token: token) { [weak self] msg in
                self?.postLog(msg)
            }
        }
```

- [ ] **Step 2: Commit**

```bash
git add Intentional/AppDelegate.swift
git commit -m "feat(focus): register Mac with Intentional backend on startup"
```

---

## Task 18: Backend — include `triggered_by` in `focus_signal` WebSocket payload

**Files:**
- Modify: `intentional-backend/main.py`

- [ ] **Step 1: Update the two `broadcast_focus_signal(...)` call sites in `/focus/toggle` to include `triggered_by`**

Around line 2819:

```python
        await broadcast_focus_signal(account_id, {
            "type": "focus_signal", "action": "start",
            "session_id": str(session_id), "timestamp": now.isoformat(),
            "triggered_by": "puck",
        })
```

Around line 2846:

```python
        await broadcast_focus_signal(account_id, {
            "type": "focus_signal", "action": "stop",
            "session_id": str(session_id), "timestamp": now.isoformat(),
            "triggered_by": session.get("triggered_by", "puck"),
        })
```

- [ ] **Step 2: Commit**

```bash
git add main.py
git commit -m "feat(focus): include triggered_by in focus_signal WebSocket payload"
```

---

## Task 19: Mac — build verification

- [ ] **Step 1: Build**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -60
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Document any warnings.**

---

## Task 20: Cross-repo — progress log

**Files:**
- Create: `intentional-macos-app/docs/overnight-run-2026-04-24.md`

- [ ] **Step 1: Write the progress log with sections for Summary, Per-repo, Verification commands, Blockers/TODOs, Decisions.**

(Full template inline; see the actual file — skipped in plan to keep plan compact.)

- [ ] **Step 2: Commit**

```bash
git add docs/overnight-run-2026-04-24.md
git commit -m "docs(overnight): progress log for 2026-04-24 Puck focus signal run"
```

---

## Task 21: Push branches and open PRs

- [ ] **Step 1: Backend**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git push -u origin feat/puck-focus-signal
gh pr create --base main --title "feat(focus): accept Supabase JWTs on focus-signal endpoints" --body "$(cat <<'EOF'
## Summary
- Adds Supabase JWT verifier alongside existing intentional-JWT verifier.
- `/devices/register`, `/focus/toggle`, `/focus/active`, `/ws/focus` now accept either token.
- Supabase users are linked to the `accounts` table by email (auto-created on first sight).
- New migration `011_add_supabase_user_id.sql` adds a nullable `supabase_user_id` column for diagnostics.
- WebSocket `focus_signal` payload now includes `triggered_by` so Mac can enforce the Puck-only-end rule.

## How to review
1. `security.py` — new `verify_supabase_token` + `verify_any_token`.
2. `main.py` — new `_resolve_account_from_token` helper; four endpoints rewritten.
3. Migration — additive; can apply before deploy or on next deploy.

## How to test
```bash
cd intentional-backend
python3 -m pytest tests/ -v
```

## Required env on Railway before merging to main
- `SUPABASE_JWT_SECRET` — the project's JWT secret from the Supabase dashboard (Settings → API → JWT secret).

## Blockers / user TODOs
- Add `SUPABASE_JWT_SECRET` to Railway env vars.
- Apply migration 011 (Railway auto-apply or manual).
- Merge to `main` only after adding the env var (otherwise Supabase-auth'd clients get 401).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: iOS**

```bash
cd /Users/arayan/Documents/GitHub/puck-ios
git push -u origin feat/intentional-backend-integration
gh pr create --base main --title "feat(focus): mirror Puck taps to Mac via Intentional backend" --body "$(cat <<'EOF'
## Summary
- New network layer: `IntentionalAPIClient`, `IntentionalDeviceRegistration`, `IntentionalFocusSignalClient`.
- On successful Supabase auth, registers this iPhone with `api.intentional.social`.
- On Puck NFC activation, fires `POST /focus/toggle {action: "start"}` (additive, fire-and-forget).
- On deactivation, fires `POST /focus/toggle {action: "stop"}`.
- Bedtime sessions do NOT fire the Mac signal (phone-only).

## How to review
1. `Puck/Utils/Theme.swift` — added `Constants.IntentionalAPI.baseURL`.
2. `Puck/Core/Network/Intentional*.swift` — three new files.
3. `Puck/Core/Coordinator/PuckCoordinator.swift` — two call sites.
4. `Puck/Core/Auth/AuthService.swift` — one hook after login.

## How to test
- Build: `xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'generic/platform=iOS Simulator' -configuration Debug build`
- Manual (simulator, once backend is deployed with `SUPABASE_JWT_SECRET`): sign in, tap Puck NFC. Expect `POST /focus/toggle` log.

## Blockers / user TODOs
- Backend PR must be merged AND `SUPABASE_JWT_SECRET` set before Mac receives signals.
- Device-side test requires a physical NFC tag — documented in the cross-repo progress log.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: macOS**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git push -u origin feat/puck-focus-signal
gh pr create --base puck --title "feat(focus): Mac side of Puck focus signal (heartbeat + triggered_by + device registration)" --body "$(cat <<'EOF'
## Summary
- `FocusWebSocketClient` now sends a 2-minute heartbeat while a session is active, and propagates `triggered_by` to its callback.
- New `IntentionalDeviceRegistration` service registers this Mac on startup.
- `AppDelegate` wires heartbeat start/stop on focus signals and calls the new registration.
- Adds cross-repo hand-off log `docs/overnight-run-2026-04-24.md` (master source of truth for this multi-repo change).

See the progress log for verification commands the user can run tomorrow.

## How to test
- Build: `xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build`
- End-to-end: backend deployed with `SUPABASE_JWT_SECRET` + iOS PR merged. Tap Puck; Mac should show focus-start overlay.

## Blockers / user TODOs
See `docs/overnight-run-2026-04-24.md` — the single source of truth for this overnight run.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Capture all three PR URLs into the progress log file on the Mac branch, and push an update if needed.**

---

## Self-review — Spec coverage checklist

- [x] Backend accepts Supabase JWT on `/devices/register` — Task 4
- [x] Backend accepts Supabase JWT on `/focus/toggle` — Task 4
- [x] Backend accepts Supabase JWT on `/focus/active` — Task 4
- [x] Backend accepts Supabase JWT on `/ws/focus` — Task 4
- [x] Email-based account linking, auto-create — Task 4
- [x] New migration `011` adds `supabase_user_id` — Task 1
- [x] Backend unit tests pass — Tasks 3, 5, 6
- [x] iOS calls `/devices/register` on login — Task 12
- [x] iOS calls `/focus/toggle` on NFC activate/deactivate — Task 11
- [x] iOS auth header = Supabase accessToken — Tasks 8, 9, 10
- [x] Mac calls `/devices/register` on login — Task 17
- [x] Mac WebSocket reconnect exists (already) — reviewed, no change needed
- [x] Mac heartbeat — Task 16
- [x] Mac propagates `triggered_by` for Puck escape-hatch rule — Task 16/18
- [x] Build verification on both Swift projects — Tasks 14, 19
- [x] Progress log — Task 20
- [x] PRs opened to non-main (puck) on Mac — Task 21
- [x] User is warned SUPABASE_JWT_SECRET must be set before backend merge — Task 21 PR body
