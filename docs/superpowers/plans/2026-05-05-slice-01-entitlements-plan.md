# Slice 1 — Subscription / Entitlements Infrastructure

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Parent plan:** `docs/superpowers/plans/2026-05-05-app-redesign-plan.md` (master)
**Spec:** `docs/superpowers/specs/2026-05-05-app-redesign-design.md` (§7, §12)

**Goal:** Backend tracks subscription state per user; Mac and iOS verify on launch + foreground; trial / active / lapsed states are gracefully handled. Stripe webhooks update user state in real time.

**Architecture:** New `subscription_tier` column on `users`. New `/me/entitlements` endpoint reads it. New Stripe webhook handler updates it. Mac `EntitlementClient` polls every 60s + on launch + on foreground. iOS `EntitlementGate` reads on launch + foreground. Both clients cache locally for offline resilience but treat backend as source of truth.

**Tech Stack:**
- Backend: FastAPI, Postgres (Supabase), Stripe Python SDK
- Mac: Swift, BackendClient pattern (existing)
- iOS: Swift, IntentionalAPIClient pattern (existing)

---

## Pre-flight context (existing code worth knowing)

**Backend already has:**
- Magic-link auth in `auth.py`: `POST /auth/login`, `POST /auth/verify`, `POST /auth/refresh`, `GET /auth/me`, `POST /auth/logout`. ~595 lines.
- User table with rows keyed by email + `account_id`. `lock_mode` column already used for partner-locking.
- 20 migrations applied, latest is `020_strictness_and_budget_prep.sql`.

**Mac already has:**
- `BackendClient.swift` with auth-aware request methods.
- No EntitlementClient yet.
- No sign-in window yet (Mac assumes the user is signed in via the existing PKG flow).

**iOS already has:**
- `Puck/Core/Auth/AuthService.swift` — magic-link sign-in flow.
- `Puck/Views/Onboarding/LandingView.swift` — landing/sign-in UI.
- `Puck/Core/Auth/AppleSignInHelper.swift` — Apple Sign-In support.
- `Puck/Core/Network/IntentionalAPIClient.swift` — backend client (recently fixed for URL encoding).

**Stripe does NOT exist yet** in any repo — fresh integration in this slice.

---

## File structure

### `intentional-backend/`

**Create:**
- `migrations/021_subscription_tier.sql` — schema additions
- `stripe_webhooks.py` — webhook handlers (separate file to keep main.py tidy)
- `tests/test_entitlements.py` — endpoint tests
- `tests/test_stripe_webhooks.py` — webhook tests

**Modify:**
- `requirements.txt` — add `stripe>=10.0.0`
- `models.py` — add `EntitlementResponse` Pydantic model
- `main.py` — register `/me/entitlements` route + Stripe webhook route
- `database.py` (no change expected; Postgres connection reused)

**Environment variables (set in Railway):**
- `STRIPE_SECRET_KEY` — `sk_live_...` or `sk_test_...` for staging
- `STRIPE_WEBHOOK_SECRET` — `whsec_...` from Stripe dashboard webhook config
- `STRIPE_PRICE_ID_MONTHLY` — created in Stripe dashboard ($12.99/mo)
- `STRIPE_PRICE_ID_ANNUAL` — created in Stripe dashboard ($79/yr)

### `intentional-macos-app/`

**Create:**
- `Intentional/EntitlementClient.swift` — calls `/me/entitlements`, caches state
- `Intentional/Entitlement.swift` — Codable struct
- `Intentional/SignInWindowController.swift` — sign-in window for unauthenticated users
- `Intentional/LapsedSubscriberBanner.swift` — banner UI shown when subscription has lapsed

**Modify:**
- `Intentional/AppDelegate.swift` — wire `EntitlementClient` into init flow
- `Intentional/BackendClient.swift` — add `getEntitlements()` method
- `Intentional/dashboard.html` — add lapsed-banner div + JS hook (small change)

### `puck-ios/`

**Create:**
- `Puck/Core/Auth/EntitlementGate.swift` — reads entitlement, gates app

**Modify:**
- `Puck/Core/Network/IntentionalAPIClient.swift` — add `getEntitlements()` method
- `Puck/Views/Onboarding/LandingView.swift` — add "Subscribe at intentional.app →" link below sign-in form
- `Puck/Views/ContentView.swift` — wrap content in `EntitlementGate` so non-subscribed users see the gate
- `Puck/App/PuckApp.swift` (or wherever app entry lives) — wire entitlement check on launch

---

## Task list

### Task 1: Backend — Migration `021_subscription_tier.sql`

**Files:**
- Create: `intentional-backend/migrations/021_subscription_tier.sql`

- [ ] **Step 1: Write the migration**

```sql
-- 021_subscription_tier.sql
-- Adds subscription state to users table.
-- Slice 1 of app redesign (2026-05-05).

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS subscription_tier text
    CHECK (subscription_tier IN ('none', 'trialing', 'active', 'past_due', 'canceled'))
    DEFAULT 'none' NOT NULL,
  ADD COLUMN IF NOT EXISTS subscription_plan text
    CHECK (subscription_plan IN ('monthly', 'annual'))
    DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS trial_ends_at timestamptz DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS current_period_ends_at timestamptz DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS stripe_customer_id text DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS stripe_subscription_id text DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS ship_puck boolean DEFAULT false NOT NULL;

CREATE INDEX IF NOT EXISTS idx_users_stripe_customer_id ON users(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_users_stripe_subscription_id ON users(stripe_subscription_id);
```

- [ ] **Step 2: Apply migration locally**

Run: `cd /Users/arayan/Documents/GitHub/intentional-backend && railway run --service intentional-backend python3 -c "from database import get_db; db = get_db(); print(db.table('users').select('id, subscription_tier').limit(1).execute().data)"`

Expected: empty list or row with `subscription_tier: 'none'`. If column doesn't exist, apply via Supabase SQL editor: copy-paste the SQL from step 1.

- [ ] **Step 3: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add migrations/021_subscription_tier.sql
git commit -m "migration: add subscription_tier columns to users"
```

---

### Task 2: Backend — `EntitlementResponse` Pydantic model

**Files:**
- Modify: `intentional-backend/models.py`

- [ ] **Step 1: Add model to models.py**

Append to end of `models.py`:

```python
class EntitlementResponse(BaseModel):
    """Returned by GET /me/entitlements. Source of truth for client gating."""
    tier: str  # 'none' | 'trialing' | 'active' | 'past_due' | 'canceled'
    plan: str | None  # 'monthly' | 'annual' | None
    trial_ends_at: str | None  # ISO 8601
    current_period_ends_at: str | None  # ISO 8601
    ship_puck: bool
```

- [ ] **Step 2: Verify import works**

Run: `cd /Users/arayan/Documents/GitHub/intentional-backend && python3 -c "from models import EntitlementResponse; print(EntitlementResponse.model_json_schema()['properties'].keys())"`

Expected: `dict_keys(['tier', 'plan', 'trial_ends_at', 'current_period_ends_at', 'ship_puck'])`

---

### Task 3: Backend — `/me/entitlements` endpoint with tests

**Files:**
- Create: `intentional-backend/tests/test_entitlements.py`
- Modify: `intentional-backend/main.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_entitlements.py`:

```python
"""Tests for /me/entitlements endpoint."""
import pytest
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_entitlements_requires_auth():
    """No Authorization header → 401."""
    resp = client.get("/me/entitlements")
    assert resp.status_code == 401


def test_entitlements_invalid_token():
    """Bad token → 401."""
    resp = client.get("/me/entitlements", headers={"Authorization": "Bearer invalid"})
    assert resp.status_code == 401


def test_entitlements_default_user(authed_test_user):
    """Authed user with no subscription → tier='none'."""
    token = authed_test_user["access_token"]
    resp = client.get("/me/entitlements", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["tier"] == "none"
    assert body["plan"] is None
    assert body["ship_puck"] is False
```

(Note: `authed_test_user` fixture must exist; if not, create one in `tests/conftest.py` that calls `auth/login` + `auth/verify` and returns the resulting tokens. If fixture doesn't exist, add this as Task 3a.)

- [ ] **Step 2: Run test to confirm it fails**

Run: `cd /Users/arayan/Documents/GitHub/intentional-backend && pytest tests/test_entitlements.py -v`

Expected: FAIL — endpoint not yet defined.

- [ ] **Step 3: Implement endpoint in main.py**

Find the line near `/auth/me` (around line 306 of auth.py) and add this endpoint to `main.py` (NOT auth.py — keep auth.py focused on auth itself). Add after existing imports + auth router include:

```python
from models import EntitlementResponse
from auth import get_current_user_id


@app.get("/me/entitlements", response_model=EntitlementResponse)
async def get_entitlements(authorization: str = Header(...)):
    """Returns the current user's subscription state.
    
    Source of truth for clients to gate features on.
    """
    user_id = await get_current_user_id(authorization)
    db = get_db()
    res = db.table("users").select(
        "subscription_tier, subscription_plan, trial_ends_at, "
        "current_period_ends_at, ship_puck"
    ).eq("id", user_id).execute()
    
    if not res.data:
        raise HTTPException(status_code=404, detail="user_not_found")
    
    u = res.data[0]
    return EntitlementResponse(
        tier=u["subscription_tier"],
        plan=u["subscription_plan"],
        trial_ends_at=u["trial_ends_at"],
        current_period_ends_at=u["current_period_ends_at"],
        ship_puck=u["ship_puck"],
    )
```

(If `get_current_user_id` doesn't exist as a helper in auth.py, extract it from existing `auth_me` endpoint — it's the JWT-decode-and-lookup pattern.)

- [ ] **Step 4: Run tests, verify pass**

Run: `cd /Users/arayan/Documents/GitHub/intentional-backend && pytest tests/test_entitlements.py -v`

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add models.py main.py tests/test_entitlements.py
git commit -m "feat(api): add /me/entitlements endpoint"
```

---

### Task 4: Backend — Add Stripe to dependencies

**Files:**
- Modify: `intentional-backend/requirements.txt`

- [ ] **Step 1: Add Stripe to requirements.txt**

Append:
```
stripe>=10.0.0,<11.0.0
```

- [ ] **Step 2: Install locally**

Run: `cd /Users/arayan/Documents/GitHub/intentional-backend && pip install -r requirements.txt`

Expected: `stripe` installed.

- [ ] **Step 3: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add requirements.txt
git commit -m "deps: add stripe library"
```

---

### Task 5: Backend — Stripe webhook handler module

**Files:**
- Create: `intentional-backend/stripe_webhooks.py`
- Create: `intentional-backend/tests/test_stripe_webhooks.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_stripe_webhooks.py`:

```python
"""Tests for Stripe webhook handlers."""
import pytest
import json
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_webhook_rejects_unsigned_payload():
    """Webhook without Stripe-Signature header → 400."""
    resp = client.post("/stripe/webhook", json={"type": "subscription.created"})
    assert resp.status_code == 400


def test_webhook_rejects_bad_signature():
    """Webhook with bad Stripe-Signature → 400."""
    resp = client.post(
        "/stripe/webhook",
        json={"type": "subscription.created"},
        headers={"Stripe-Signature": "bogus"},
    )
    assert resp.status_code == 400
```

- [ ] **Step 2: Run, confirm fail**

Run: `pytest tests/test_stripe_webhooks.py -v`

Expected: FAIL — endpoint not defined.

- [ ] **Step 3: Implement stripe_webhooks.py**

Create:

```python
"""Stripe webhook handlers.

Handles subscription lifecycle events to keep users.subscription_tier in sync.

Configured webhook events (set in Stripe dashboard):
  - customer.subscription.created
  - customer.subscription.updated
  - customer.subscription.deleted
  - customer.subscription.trial_will_end
  - invoice.payment_succeeded
  - invoice.payment_failed
"""
import os
import logging
from datetime import datetime, timezone
from fastapi import Request, HTTPException, APIRouter
import stripe

from database import get_db

logger = logging.getLogger(__name__)
router = APIRouter()

stripe.api_key = os.environ.get("STRIPE_SECRET_KEY", "")
WEBHOOK_SECRET = os.environ.get("STRIPE_WEBHOOK_SECRET", "")


def _isoz(ts: int) -> str:
    """Convert Stripe Unix timestamp to ISO-Z string."""
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


@router.post("/stripe/webhook")
async def stripe_webhook(request: Request):
    """Receive Stripe webhook, verify signature, route to handler."""
    payload = await request.body()
    sig_header = request.headers.get("Stripe-Signature")
    
    if not sig_header:
        raise HTTPException(status_code=400, detail="missing_signature")
    
    try:
        event = stripe.Webhook.construct_event(payload, sig_header, WEBHOOK_SECRET)
    except (ValueError, stripe.error.SignatureVerificationError) as e:
        logger.warning(f"stripe webhook signature fail: {e}")
        raise HTTPException(status_code=400, detail="invalid_signature")
    
    event_type = event["type"]
    obj = event["data"]["object"]
    
    handlers = {
        "customer.subscription.created": _handle_subscription_change,
        "customer.subscription.updated": _handle_subscription_change,
        "customer.subscription.deleted": _handle_subscription_deleted,
        "invoice.payment_succeeded": _handle_payment_success,
        "invoice.payment_failed": _handle_payment_failed,
    }
    handler = handlers.get(event_type)
    if handler:
        try:
            handler(obj)
        except Exception as e:
            logger.error(f"webhook handler {event_type} failed: {e}", exc_info=True)
            # Return 200 anyway — let Stripe move on, we'll inspect logs.
            # If we 500, Stripe retries indefinitely.
    else:
        logger.info(f"stripe webhook ignored: {event_type}")
    
    return {"received": True}


def _handle_subscription_change(sub):
    """Handle subscription.created or .updated."""
    customer_id = sub["customer"]
    sub_id = sub["id"]
    status = sub["status"]  # 'trialing', 'active', 'past_due', 'canceled', etc.
    
    # Map Stripe status → our subscription_tier values
    tier_map = {
        "trialing": "trialing",
        "active": "active",
        "past_due": "past_due",
        "canceled": "canceled",
        "unpaid": "past_due",
        "incomplete": "trialing",
        "incomplete_expired": "canceled",
    }
    tier = tier_map.get(status, "none")
    
    # Determine plan from price
    plan = None
    items = sub.get("items", {}).get("data", [])
    if items:
        price_id = items[0].get("price", {}).get("id")
        if price_id == os.environ.get("STRIPE_PRICE_ID_MONTHLY"):
            plan = "monthly"
        elif price_id == os.environ.get("STRIPE_PRICE_ID_ANNUAL"):
            plan = "annual"
    
    trial_end = sub.get("trial_end")
    period_end = sub.get("current_period_end")
    ship_puck = (plan == "annual")
    
    update = {
        "subscription_tier": tier,
        "subscription_plan": plan,
        "stripe_subscription_id": sub_id,
        "trial_ends_at": _isoz(trial_end) if trial_end else None,
        "current_period_ends_at": _isoz(period_end) if period_end else None,
        "ship_puck": ship_puck,
    }
    
    db = get_db()
    db.table("users").update(update).eq("stripe_customer_id", customer_id).execute()
    logger.info(f"subscription updated: {customer_id} → {tier} ({plan})")


def _handle_subscription_deleted(sub):
    """Subscription fully ended."""
    customer_id = sub["customer"]
    db = get_db()
    db.table("users").update({
        "subscription_tier": "canceled",
        "stripe_subscription_id": None,
    }).eq("stripe_customer_id", customer_id).execute()


def _handle_payment_success(invoice):
    """Payment went through, no special action — subscription.updated will fire."""
    pass


def _handle_payment_failed(invoice):
    """Payment failed. Stripe retries; we move tier to past_due via subscription.updated."""
    pass
```

- [ ] **Step 4: Wire into main.py**

In `main.py`, after `app = FastAPI(...)` and after other route includes, add:

```python
from stripe_webhooks import router as stripe_router
app.include_router(stripe_router)
```

- [ ] **Step 5: Run tests, verify pass**

Run: `cd /Users/arayan/Documents/GitHub/intentional-backend && pytest tests/test_stripe_webhooks.py -v`

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add stripe_webhooks.py main.py tests/test_stripe_webhooks.py
git commit -m "feat(stripe): add webhook handler for subscription lifecycle"
```

---

### Task 6: Backend — Stripe customer creation on first checkout

**Files:**
- Modify: `puck-site/src/app/api/checkout/route.ts`

- [ ] **Step 1: Update checkout API to look up or create Stripe customer keyed by user email**

The `/api/checkout` route already creates Stripe Checkout Sessions. We need to ensure each session is tied to a Stripe Customer that we can later match in the webhook by email or customer ID.

Modify `puck-site/src/app/api/checkout/route.ts`:

In the `stripe.checkout.sessions.create()` call, add `customer_email` if available, and add metadata to track which user this is for. Since the public marketing site doesn't have an authenticated user when checkout starts, we use the customer email Stripe collects.

Find existing:
```typescript
const session = await stripe.checkout.sessions.create({
  mode: "subscription",
  // ...
});
```

Add `customer_creation: "always"` to the call:
```typescript
const session = await stripe.checkout.sessions.create({
  mode: "subscription",
  customer_creation: "always",  // ← add this
  // ... existing fields
});
```

This ensures every checkout creates a Stripe customer record we can match by email later.

- [ ] **Step 2: Backend — match webhook to user by email**

In `stripe_webhooks.py`, modify `_handle_subscription_change` to look up the user by the Stripe customer's email if `stripe_customer_id` doesn't already exist on a user row. Add this above the `db.table("users").update(...)` call:

```python
db = get_db()
existing = db.table("users").select("id").eq("stripe_customer_id", customer_id).limit(1).execute()
if not existing.data:
    # First time we see this customer — match by email
    customer = stripe.Customer.retrieve(customer_id)
    email = customer.get("email")
    if email:
        u = db.table("users").select("id").eq("email", email).limit(1).execute()
        if u.data:
            db.table("users").update({"stripe_customer_id": customer_id}).eq("id", u.data[0]["id"]).execute()
        else:
            logger.warning(f"stripe webhook: no user with email {email} for customer {customer_id}")
            return  # User signed up via Stripe but never created an Intentional account
```

- [ ] **Step 3: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add stripe_webhooks.py
git commit -m "feat(stripe): match webhook customer to user by email"

cd /Users/arayan/Documents/GitHub/puck-site
git add src/app/api/checkout/route.ts
git commit -m "feat(checkout): always create Stripe customer for webhook matching"
```

---

### Task 7: Backend — Deploy + test webhook end-to-end

**Files:**
- N/A (deployment + manual test)

- [ ] **Step 1: Set environment variables in Railway**

Run: `cd /Users/arayan/Documents/GitHub/intentional-backend && railway variables --set "STRIPE_SECRET_KEY=$YOUR_STRIPE_SECRET_KEY" --service intentional-backend`

Then: `railway variables --set "STRIPE_WEBHOOK_SECRET=$YOUR_STRIPE_WEBHOOK_SECRET" --service intentional-backend`

Then: `railway variables --set "STRIPE_PRICE_ID_MONTHLY=price_xxx" --service intentional-backend`

Then: `railway variables --set "STRIPE_PRICE_ID_ANNUAL=price_yyy" --service intentional-backend`

(These are values you set in your Stripe dashboard. For now use TEST keys.)

- [ ] **Step 2: Deploy to Railway**

Run: `cd /Users/arayan/Documents/GitHub/intentional-backend && git push origin main`

Railway auto-deploys.

- [ ] **Step 3: Configure Stripe webhook**

In Stripe dashboard → Developers → Webhooks → "Add endpoint":
- Endpoint URL: `https://api.intentional.social/stripe/webhook`
- Events: `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `customer.subscription.trial_will_end`, `invoice.payment_succeeded`, `invoice.payment_failed`
- Copy the signing secret → set as `STRIPE_WEBHOOK_SECRET` in Railway

- [ ] **Step 4: Test with Stripe CLI**

In a terminal:
```bash
brew install stripe/stripe-cli/stripe   # if not installed
stripe login
stripe listen --forward-to https://api.intentional.social/stripe/webhook
```

In another terminal, trigger a test event:
```bash
stripe trigger customer.subscription.created
```

Expected: Stripe CLI shows event sent + 200 response. Railway logs show `subscription updated: cus_xxx → trialing (None)`.

- [ ] **Step 5: Verify DB row updated**

Run: `cd /Users/arayan/Documents/GitHub/intentional-backend && railway run --service intentional-backend python3 -c "from database import get_db; db = get_db(); print(db.table('users').select('id, email, subscription_tier, subscription_plan').neq('subscription_tier', 'none').execute().data)"`

Expected: list of users with subscription state set.

---

### Task 8: Mac — `Entitlement` Codable struct

**Files:**
- Create: `intentional-macos-app/Intentional/Entitlement.swift`

- [ ] **Step 1: Create the struct**

```swift
//
//  Entitlement.swift
//  Intentional
//
//  Subscription state returned by GET /me/entitlements.
//  Cached locally for offline resilience but backend is canonical.
//

import Foundation

struct Entitlement: Codable, Equatable {
    enum Tier: String, Codable {
        case none
        case trialing
        case active
        case pastDue = "past_due"
        case canceled
    }
    
    enum Plan: String, Codable {
        case monthly
        case annual
    }
    
    let tier: Tier
    let plan: Plan?
    let trialEndsAt: Date?
    let currentPeriodEndsAt: Date?
    let shipPuck: Bool
    let cachedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case tier
        case plan
        case trialEndsAt = "trial_ends_at"
        case currentPeriodEndsAt = "current_period_ends_at"
        case shipPuck = "ship_puck"
        case cachedAt
    }
    
    var isActive: Bool {
        tier == .active || tier == .trialing
    }
    
    var isLapsed: Bool {
        tier == .canceled || tier == .pastDue
    }
    
    /// Returns hours since lapse, or nil if not lapsed.
    var hoursSinceLapse: Double? {
        guard isLapsed, let ends = currentPeriodEndsAt else { return nil }
        let now = Date()
        if ends > now { return 0 }
        return now.timeIntervalSince(ends) / 3600.0
    }
    
    /// True if subscription is lapsed AND >24h have elapsed since the period end.
    var isHardLapsed: Bool {
        guard let h = hoursSinceLapse else { return false }
        return h >= 24
    }
}
```

- [ ] **Step 2: Add to Xcode project**

Open `intentional-macos-app/Intentional.xcodeproj` in Xcode → File → Add Files to Intentional → select `Entitlement.swift` → Add.

- [ ] **Step 3: Build, verify compiles**

Run: `cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/Entitlement.swift Intentional.xcodeproj
git commit -m "feat(entitlement): add Entitlement model"
```

---

### Task 9: Mac — Add `getEntitlements()` to BackendClient

**Files:**
- Modify: `intentional-macos-app/Intentional/BackendClient.swift`

- [ ] **Step 1: Add method to BackendClient**

In `BackendClient.swift`, find the existing API methods (around `func registerDevice` or similar). Add:

```swift
/// Fetches current user's subscription entitlement state.
/// - Returns: Entitlement or nil on failure (offline / 401 / etc.)
func getEntitlements() async -> Entitlement? {
    guard let url = URL(string: "\(baseURL)/me/entitlements") else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    if let token = authToken {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var ent = try decoder.decode(Entitlement.self, from: data)
        // Stamp cachedAt manually since backend doesn't include it
        ent = Entitlement(
            tier: ent.tier,
            plan: ent.plan,
            trialEndsAt: ent.trialEndsAt,
            currentPeriodEndsAt: ent.currentPeriodEndsAt,
            shipPuck: ent.shipPuck,
            cachedAt: Date()
        )
        return ent
    } catch {
        print("getEntitlements error: \(error)")
        return nil
    }
}
```

- [ ] **Step 2: Build, verify compiles**

Run: `xcodebuild ...build 2>&1 | tail -5`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Intentional/BackendClient.swift
git commit -m "feat(api): add BackendClient.getEntitlements"
```

---

### Task 10: Mac — `EntitlementClient` actor with cache

**Files:**
- Create: `intentional-macos-app/Intentional/EntitlementClient.swift`

- [ ] **Step 1: Create actor**

```swift
//
//  EntitlementClient.swift
//  Intentional
//
//  Manages subscription state. Backend is canonical; local cache for offline.
//  Polls on launch + foreground + 60s timer.
//

import Foundation
import AppKit

@MainActor
final class EntitlementClient: ObservableObject {
    @Published private(set) var current: Entitlement?
    
    private let backendClient: BackendClient
    private let cacheURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Intentional/entitlement_cache.json")
    }()
    
    private var timer: Timer?
    private var foregroundObserver: NSObjectProtocol?
    
    init(backendClient: BackendClient) {
        self.backendClient = backendClient
        loadCache()
    }
    
    deinit {
        timer?.invalidate()
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
    
    /// Call once at app launch.
    func start() {
        Task { await self.refresh() }
        
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }
    
    func refresh() async {
        guard let fresh = await backendClient.getEntitlements() else {
            // Network failed — keep cached value
            return
        }
        current = fresh
        saveCache(fresh)
    }
    
    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(Entitlement.self, from: data) else {
            return
        }
        current = decoded
    }
    
    private func saveCache(_ ent: Entitlement) {
        guard let data = try? JSONEncoder().encode(ent) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}
```

- [ ] **Step 2: Add to Xcode project + build**

Add file in Xcode. Run build. Expected: SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Intentional/EntitlementClient.swift Intentional.xcodeproj
git commit -m "feat(entitlement): add EntitlementClient with cache + 60s polling"
```

---

### Task 11: Mac — Wire EntitlementClient into AppDelegate

**Files:**
- Modify: `intentional-macos-app/Intentional/AppDelegate.swift`

- [ ] **Step 1: Add property + init**

In AppDelegate.swift, add a property near other properties:

```swift
private(set) var entitlementClient: EntitlementClient!
```

In `applicationDidFinishLaunching`, after `BackendClient` is created (around init step 1), add:

```swift
// Init step 1.5: EntitlementClient (drives subscription gating across the app)
entitlementClient = EntitlementClient(backendClient: backendClient)
entitlementClient.start()
postLog("✅ EntitlementClient started")
```

- [ ] **Step 2: Build + run, verify entitlement is fetched**

Build, run app, watch logs. Expected: `✅ EntitlementClient started` appears, and a follow-up log line indicating refresh ran (you may need to add a log inside `refresh()`).

- [ ] **Step 3: Commit**

```bash
git add Intentional/AppDelegate.swift
git commit -m "feat(entitlement): wire EntitlementClient into AppDelegate"
```

---

### Task 12: Mac — `LapsedSubscriberBanner` UI

**Files:**
- Create: `intentional-macos-app/Intentional/LapsedSubscriberBanner.swift`
- Modify: `intentional-macos-app/Intentional/dashboard.html`
- Modify: `intentional-macos-app/Intentional/MainWindow.swift`

- [ ] **Step 1: Add Swift bridge**

Create `LapsedSubscriberBanner.swift`:

```swift
//
//  LapsedSubscriberBanner.swift
//  Intentional
//
//  Posts entitlement state changes to the dashboard so it can show the lapsed banner.
//

import Foundation
import AppKit

@MainActor
final class LapsedSubscriberBanner {
    weak var mainWindow: MainWindow?
    
    init(mainWindow: MainWindow, entitlementClient: EntitlementClient) {
        self.mainWindow = mainWindow
        // Observe entitlement changes
        // (Simplest pattern: have AppDelegate call updateBanner when entitlement changes)
    }
    
    func update(entitlement: Entitlement?) {
        guard let main = mainWindow else { return }
        let payload: [String: Any] = [
            "tier": entitlement?.tier.rawValue ?? "none",
            "is_hard_lapsed": entitlement?.isHardLapsed ?? false,
            "current_period_ends_at": entitlement?.currentPeriodEndsAt?.iso8601() ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            main.callJS("window._entitlementState && window._entitlementState(\(json))")
        }
    }
}

private extension Date {
    func iso8601() -> String {
        ISO8601DateFormatter().string(from: self)
    }
}
```

- [ ] **Step 2: Add receiver in dashboard.html**

In `dashboard.html`, add a top banner div near the top of `<body>`:

```html
<div id="lapsed-banner" style="display:none;background:#dc2626;color:white;padding:12px 16px;text-align:center;font-weight:500;">
  Your subscription has lapsed. <a href="https://intentional.social/account" target="_blank" style="color:white;text-decoration:underline;">Renew now →</a>
</div>
```

In the dashboard's main JS (in `dashboard.html`'s `<script>` section), add:

```javascript
window._entitlementState = function(state) {
  const banner = document.getElementById('lapsed-banner');
  if (state.is_hard_lapsed) {
    banner.style.display = 'block';
  } else {
    banner.style.display = 'none';
  }
};
```

- [ ] **Step 3: Wire from AppDelegate**

In `AppDelegate.swift`, after `entitlementClient.start()`:

```swift
// Wire entitlement changes to dashboard banner
let banner = LapsedSubscriberBanner(mainWindow: mainWindow, entitlementClient: entitlementClient)
self.lapsedBanner = banner
// Subscribe to entitlement changes
entitlementClient.$current.sink { [weak banner] ent in
    banner?.update(entitlement: ent)
}.store(in: &cancellables)
```

(Add `private var lapsedBanner: LapsedSubscriberBanner?` and `private var cancellables = Set<AnyCancellable>()` properties to AppDelegate.)

- [ ] **Step 4: Build, verify**

Run app. Modify your user's `subscription_tier` in DB to 'canceled' and `current_period_ends_at` to 25h ago. Watch banner appear in dashboard.

- [ ] **Step 5: Commit**

```bash
git add Intentional/LapsedSubscriberBanner.swift Intentional/AppDelegate.swift Intentional/dashboard.html
git commit -m "feat(entitlement): lapsed subscriber banner in dashboard"
```

---

### Task 13: iOS — Add `getEntitlements()` to API client

**Files:**
- Modify: `puck-ios/Puck/Core/Network/IntentionalAPIClient.swift`

- [ ] **Step 1: Add method**

Find existing API methods. Add:

```swift
struct IOSEntitlement: Codable {
    let tier: String
    let plan: String?
    let trialEndsAt: Date?
    let currentPeriodEndsAt: Date?
    let shipPuck: Bool
    
    enum CodingKeys: String, CodingKey {
        case tier
        case plan
        case trialEndsAt = "trial_ends_at"
        case currentPeriodEndsAt = "current_period_ends_at"
        case shipPuck = "ship_puck"
    }
    
    var isActive: Bool { tier == "active" || tier == "trialing" }
    var isHardLapsed: Bool {
        guard let ends = currentPeriodEndsAt else { return false }
        return Date().timeIntervalSince(ends) >= 86400 && (tier == "canceled" || tier == "past_due")
    }
}

extension IntentionalAPIClient {
    func getEntitlements() async -> IOSEntitlement? {
        do {
            return try await send(.get, path: "/me/entitlements", as: IOSEntitlement.self)
        } catch {
            print("getEntitlements failed: \(error)")
            return nil
        }
    }
}
```

(Adjust to match your IntentionalAPIClient method signatures. The existing `send(.get, path: "/path", as: T.self)` is the established pattern from URL-encoding fix work.)

- [ ] **Step 2: Build, verify compiles**

Run: `cd /Users/arayan/Documents/GitHub/puck-ios && xcodebuild -project Puck.xcodeproj -scheme Puck -configuration Debug build 2>&1 | tail -10`

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
cd /Users/arayan/Documents/GitHub/puck-ios
git add Puck/Core/Network/IntentionalAPIClient.swift
git commit -m "feat(api): iOS getEntitlements"
```

---

### Task 14: iOS — `EntitlementGate` view modifier

**Files:**
- Create: `puck-ios/Puck/Core/Auth/EntitlementGate.swift`

- [ ] **Step 1: Create gate**

```swift
//
//  EntitlementGate.swift
//  Puck
//
//  Reads subscription state on launch + foreground.
//  Non-subscribers see the LandingView with a "Subscribe at intentional.app" link.
//

import SwiftUI

@MainActor
final class EntitlementStore: ObservableObject {
    @Published var current: IOSEntitlement?
    @Published var isLoaded = false
    
    private let api: IntentionalAPIClient
    
    init(api: IntentionalAPIClient) {
        self.api = api
    }
    
    func refresh() async {
        if let ent = await api.getEntitlements() {
            current = ent
        }
        isLoaded = true
    }
    
    var isPaid: Bool {
        current?.isActive ?? false
    }
}

struct EntitlementGate<Content: View>: View {
    @StateObject var store: EntitlementStore
    let content: () -> Content
    
    var body: some View {
        Group {
            if !store.isLoaded {
                ProgressView()
            } else if store.isPaid {
                content()
            } else {
                LandingView()
            }
        }
        .task {
            await store.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
    }
}
```

- [ ] **Step 2: Add to project**

Add file in Xcode.

- [ ] **Step 3: Wire into PuckApp**

Find the App entry point (probably `PuckApp.swift`). Wrap `ContentView` in `EntitlementGate`:

```swift
@main
struct PuckApp: App {
    @StateObject var entitlementStore = EntitlementStore(api: IntentionalAPIClient.shared)
    
    var body: some Scene {
        WindowGroup {
            EntitlementGate(store: entitlementStore) {
                ContentView()
            }
        }
    }
}
```

- [ ] **Step 4: Build + run on simulator, verify gate works**

Run app. Without subscription → LandingView shown. With `tier=active` (set DB row manually) → ContentView shown.

- [ ] **Step 5: Commit**

```bash
git add Puck/Core/Auth/EntitlementGate.swift Puck/App/PuckApp.swift Puck.xcodeproj
git commit -m "feat(entitlement): EntitlementGate around ContentView"
```

---

### Task 15: iOS — "Subscribe at intentional.app" link on LandingView

**Files:**
- Modify: `puck-ios/Puck/Views/Onboarding/LandingView.swift`

- [ ] **Step 1: Add link below sign-in form**

In LandingView, find the existing sign-in button. Below it, add:

```swift
Divider()
    .padding(.vertical, 16)

VStack(spacing: 8) {
    Text("No account?")
        .font(.subheadline)
        .foregroundColor(.secondary)
    
    Link(destination: URL(string: "https://intentional.social")!) {
        HStack(spacing: 4) {
            Text("Subscribe at intentional.app")
                .fontWeight(.semibold)
            Image(systemName: "arrow.up.right")
        }
        .foregroundColor(.accentColor)
    }
}
.padding(.bottom, 24)
```

- [ ] **Step 2: Build + run, verify link appears + opens Safari**

Build, run on simulator. Tap link. Expected: opens Safari to intentional.app.

- [ ] **Step 3: Commit**

```bash
git add Puck/Views/Onboarding/LandingView.swift
git commit -m "feat(landing): add 'Subscribe at intentional.app' link"
```

---

### Task 16: End-to-end manual test plan

**Files:**
- N/A (manual)

- [ ] **Step 1: Test trial flow**

1. Visit https://intentional.social, click "Try free for 7 days" on Annual
2. Use Stripe test card 4242 4242 4242 4242
3. Complete Stripe Checkout
4. Verify webhook received in Railway logs: `subscription updated: cus_xxx → trialing (annual)`
5. Sign in to iOS app with the same email
6. Verify EntitlementGate shows ContentView (subscriber state)
7. Sign in to Mac dashboard
8. Verify no lapsed banner shown

- [ ] **Step 2: Test cancellation flow**

1. In Stripe Dashboard, find the test subscription, cancel it immediately
2. Verify Railway logs: `subscription updated: cus_xxx → canceled`
3. Verify `users.subscription_tier = 'canceled'` and `current_period_ends_at` is set in past
4. Wait or manually set `current_period_ends_at` to 25h ago
5. Open Mac dashboard, verify lapsed banner appears
6. Open iOS app, verify EntitlementGate shows LandingView

- [ ] **Step 3: Test reactivation**

1. In Stripe Dashboard, reactivate the subscription
2. Within 60s, Mac entitlement refreshes
3. Lapsed banner disappears
4. iOS app moves from LandingView to ContentView

- [ ] **Step 4: Document test pass/fail**

Add a `docs/slice-01-test-results-2026-05-XX.md` with screenshots of each step. Commit.

---

## Acceptance criteria summary

The slice is complete when **all** of these are true:

1. ✓ Migration applied; `users.subscription_tier`, `subscription_plan`, `trial_ends_at`, `current_period_ends_at`, `stripe_customer_id`, `stripe_subscription_id`, `ship_puck` columns exist
2. ✓ `GET /me/entitlements` endpoint returns 200 with valid JSON for authed user, 401 unauthenticated
3. ✓ Stripe webhooks received, signature verified, `subscription_tier` updated correctly for create/update/delete events
4. ✓ Mac `EntitlementClient` polls every 60s + on launch + on foreground, caches to disk
5. ✓ Mac dashboard shows lapsed banner when `is_hard_lapsed = true`, hidden otherwise
6. ✓ iOS `EntitlementGate` shows `LandingView` for non-subscribers, `ContentView` for active subscribers
7. ✓ iOS LandingView has "Subscribe at intentional.app →" link below sign-in
8. ✓ End-to-end flow: trial start → app unlocks; cancellation → 24h grace → app locks
9. ✓ All tests pass (`pytest tests/test_entitlements.py tests/test_stripe_webhooks.py`, Mac/iOS XCTest if added)
10. ✓ All commits pushed; CI green if configured

---

## Risks + mitigations

- **Stripe webhook signature verification edge cases.** Mitigation: test with Stripe CLI locally before depending on it in production. Don't 500 on handler errors — log and 200, otherwise Stripe retries indefinitely.
- **Email mismatch between Stripe customer and Intentional user.** Mitigation: webhook handler logs but no-ops if no user exists with the customer's email. Future: add a "claim subscription by email" flow.
- **Race conditions on simultaneous webhook + Mac entitlement check.** Mitigation: backend is single-source-of-truth; Mac just reads. Postgres row-level read is atomic.
- **iOS entitlement gate flicker on launch.** Mitigation: `isLoaded` flag shows ProgressView for the first sub-second.
- **24h grace timing.** Mitigation: client computes locally from `currentPeriodEndsAt`, no clock-sync needed.

---

## Post-slice cleanup

After acceptance criteria met, these can be removed (none right now — this slice is purely additive). Future slices may consolidate the entitlement state into a single `SubscriptionService` that combines Mac + iOS logic.

---

## What this slice does NOT include

- Subscribing flow inside the iOS app (that's the legal-link pattern; we link out, never collect payment in-app)
- Payment retry or dunning email flows (Stripe handles that automatically)
- Klaviyo email triggers on lifecycle events (separate work, not gating)
- Account management UI (cancel/upgrade in iOS) — links to website
- Family Sharing / multi-user accounts
- Plan switching mid-cycle (rare, defer)
- Promo codes / discounts (Stripe Checkout handles via existing coupon code field on website)
- Hard re-auth flow if token expired beyond refresh (existing magic-link flow handles)

---

## Next slice

Once Slice 1 ships and is verified stable for 2–3 days: write `slice-02-focus-mode-rename-plan.md` and execute. See master plan for sequencing.

---

**Status:** Plan written 2026-05-05. Awaiting user approval before executing via `superpowers:subagent-driven-development`.
