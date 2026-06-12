# Focus Agent S1+S2 Implementation Plan (eval bench + shadow mode)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Focus Agent's brain in SHADOW MODE — the Mac streams abstracted telemetry to the backend, a DeepSeek-powered coach reasons over it and logs what it *would* say, nothing is ever shown to the user — plus the eval bench that gates any future visibility.

**Architecture:** Mac samples frontmost app/host + session/allowance state every 60s (privacy-gated: names only, no titles/content), batches to `POST /coach/telemetry` every 3 min. Backend stores events, throttles to ≤1 reasoning call per 5 min per account, assembles the cache-layered charter prompt, calls DeepSeek (temp 0, JSON), records the verdict in `coach_decisions` with `shadow=true`. `coach-bench` runs the same decide path against labeled scenarios and reports wrong-nudge rate.

**Tech Stack:** FastAPI + Supabase client (existing patterns in main.py), httpx (new dep) for DeepSeek, pytest with the `_FakeDB`/patch pattern, Swift (CoachTelemetry collector + BackendClient POST), Railway deploy.

**Spec:** `docs/superpowers/specs/2026-06-12-focus-agent-design.md`. Cross-repo log: append outcomes to `docs/cross-repo-focus-agent-2026-06-12.md` (create in Task 9).

**⚠️ USER ACTIONS REQUIRED (flag to Ameer, don't block on them):**
1. Create a DeepSeek API key (platform.deepseek.com) — bench + live shadow reasoning need it. Everything builds and tests with the mock until then.
2. Add `DEEPSEEK_API_KEY` (and optionally `DEEPSEEK_MODEL`) to the Railway project env vars before the deploy task goes live.

---

## File structure

**intentional-backend** (flat-file convention, like the rest of the repo):
| File | Responsibility |
|---|---|
| `migrations/029_coach_agent.sql` | `coach_events`, `coach_decisions`, `coach_memory` tables |
| `coach_prompts.py` | The charter (layer-1) text + prompt assembly helpers. Pure functions, no IO. |
| `coach_agent.py` | DeepSeek client (httpx), `decide(context) -> verdict`, guardrail caps, throttle check, telemetry→context compaction |
| `main.py` | `POST /coach/telemetry`, `GET /coach/decisions` (shadow-review), wiring |
| `models.py` | `CoachEventIn`, `CoachTelemetryBatch` pydantic models |
| `coach_bench/scenarios.jsonl` | 50 labeled scenarios |
| `coach_bench/run_bench.py` | Runner: accuracy + wrong-nudge rate per model |
| `tests/test_coach_agent.py` | Endpoint auth/store, decision write, caps, throttle — LLM mocked |

**intentional-macos-app:**
| File | Responsibility |
|---|---|
| `Intentional/CoachTelemetry.swift` (new) | Sampler (60s), boundary events, privacy gate, in-memory buffer, flush |
| `Intentional/BackendClient.swift` | `postCoachTelemetry(_:)` |
| `Intentional/AppDelegate.swift` | Instantiate + wire flush timer + onStateChanged boundary events |

---

### Task 1: Backend — migration 029 + pydantic models

**Files:**
- Create: `intentional-backend/migrations/029_coach_agent.sql`
- Modify: `intentional-backend/models.py` (append)

- [ ] **Step 1: Write the migration** (conventions per `migrations/028_rules_and_allowance.sql`):

```sql
-- 029_coach_agent.sql
-- Focus Agent S1+S2 (June 2026): shadow-mode coach.
-- (1) coach_events    — abstracted Mac telemetry (names+durations only, no content).
-- (2) coach_decisions — every reasoning verdict, shadow=true until S3 ships.
-- (3) coach_memory    — profile facts + daily diary (profile rows use day='1970-01-01').
-- Spec: intentional-macos-app/docs/superpowers/specs/2026-06-12-focus-agent-design.md

CREATE TABLE IF NOT EXISTS coach_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    device_id TEXT,
    ts TIMESTAMPTZ NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('sample', 'session_start', 'session_end', 'allowance_zero', 'idle')),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_coach_events_account_ts ON coach_events (account_id, ts DESC);

CREATE TABLE IF NOT EXISTS coach_decisions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    action TEXT NOT NULL CHECK (action IN ('silence', 'credit', 'nudge', 'rescue', 'celebrate')),
    message TEXT,
    buttons JSONB,
    why TEXT,
    model TEXT,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    shadow BOOLEAN NOT NULL DEFAULT TRUE,
    suppressed_by_caps BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_coach_decisions_account_ts ON coach_decisions (account_id, ts DESC);

CREATE TABLE IF NOT EXISTS coach_memory (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('profile', 'diary')),
    day DATE NOT NULL DEFAULT '1970-01-01',
    content TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (account_id, kind, day)
);
```

- [ ] **Step 2: Append models to `models.py`:**

```python
# --- Focus Agent (S1+S2, June 2026) ---

class CoachEventIn(BaseModel):
    ts: str                      # ISO8601 from the Mac
    kind: str                    # sample | session_start | session_end | allowance_zero | idle
    payload: dict = {}           # e.g. {"app": "com.figma.Desktop", "host": null, "in_session": false,
                                 #       "session_minutes": 0, "allowance_minutes_left": 9}

class CoachTelemetryBatch(BaseModel):
    events: list[CoachEventIn]
```

- [ ] **Step 3: Apply migration to Supabase** (same flow as 027/028: run the SQL in the Supabase SQL editor, or note for Ameer if access is interactive-only — check how 028 was applied per `docs/cross-repo-rules-2026-06-11.md` in the Mac repo; if prior migrations were applied via the Supabase dashboard by the agent session, repeat that; otherwise mark as USER ACTION).

- [ ] **Step 4: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add migrations/029_coach_agent.sql models.py
git commit -m "feat(coach): migration 029 — coach_events/decisions/memory + telemetry models"
```

---

### Task 2: Backend — charter prompt module (`coach_prompts.py`)

**Files:**
- Create: `intentional-backend/coach_prompts.py`
- Test: `intentional-backend/tests/test_coach_prompts.py`

- [ ] **Step 1: Write failing tests:**

```python
# tests/test_coach_prompts.py
from coach_prompts import CHARTER, assemble_prompt

def test_charter_contains_hard_rules():
    assert "silence" in CHARTER
    assert "JSON" in CHARTER
    assert "never" in CHARTER.lower()

def test_assemble_prompt_layers_in_cache_order():
    msgs = assemble_prompt(
        profile="- Tiny starters work.",
        week_summary="Interview pipelines 4h40m of 10h (behind).",
        diary_recent=["Wed: 2h40m focused, contract met."],
        today_log="9:02 session 25m pipelines",
        caps={"nudge_left": 2, "rescue_left": 2},
        fresh_observation="NOW 2:07pm: YouTube 14 min, no session.",
    )
    # system charter first (cacheable), fresh observation last (cache miss)
    assert msgs[0]["role"] == "system" and msgs[0]["content"].startswith(CHARTER[:40])
    assert "YouTube 14 min" in msgs[-1]["content"]
    assert "nudge_left" not in msgs[-1]["content"]  # caps rendered as prose, not raw dict

def test_assemble_prompt_renders_caps():
    msgs = assemble_prompt(profile="", week_summary="", diary_recent=[],
                           today_log="", caps={"nudge_left": 0, "rescue_left": 1},
                           fresh_observation="x")
    joined = " ".join(m["content"] for m in msgs)
    assert "nudge: 0 left" in joined
```

- [ ] **Step 2: Run:** `cd /Users/arayan/Documents/GitHub/intentional-backend && pytest tests/test_coach_prompts.py -v` → FAIL (module missing).

- [ ] **Step 3: Implement `coach_prompts.py`:**

```python
"""Focus Agent charter + prompt assembly. Pure functions — no IO, no DB.

Layer order is load-bearing for DeepSeek context caching:
stable charter first, fresh observation last. Spec:
intentional-macos-app/docs/superpowers/specs/2026-06-12-focus-agent-design.md
"""

CHARTER = """You are the focus coach inside Intentional, a Mac app for an adult with ADHD.
You are watching their day the way a trusted coach sitting next to them would:
mostly in silence, occasionally stepping in at exactly the right moment.

THE PERSON: They struggle to start tasks, lose hours without noticing, and
forget their own goals by afternoon. They are not lazy and must never be
treated as lazy. They have hired you to be their external executive function.

YOUR JOB on every observation: decide if this moment needs you. Almost always
it does not. You get many chances every hour - you do not need this one.

ACTIONS (choose exactly one):
- silence    : default. No output shown to the user.
- credit     : they are doing real work with no session running. Offer to count it.
- nudge      : they are idle/drifting AND a commitment exists. Remind them of
               THEIR OWN words, warmly. Never say "get back to work."
- rescue     : they are stuck (out of allowance and still scrolling, or thrashing
               between apps). Offer ONE tiny step, plus a guilt-free break option.
- celebrate  : they completed their commitment. Release them for the day.

HARD RULES:
- When unsure, choose silence. A wrong nudge costs 5x a missed one.
- Never nudge twice for the same idle stretch. If your last card was dismissed
  less than 90 minutes ago, the bar for speaking is doubled.
- Respect the caps given in TODAY's state. If a cap shows 0 left, that action
  is forbidden - choose silence instead.
- Messages: one or two sentences. Quote their own goal words. No exclamation
  marks. No "you should." Numbers must come from CONTEXT verbatim - never
  compute or invent numbers.
- Their work may legitimately happen outside sessions. Steady time in one
  work-typed app is work, not drift, even with no session running.

OUTPUT strict JSON only, no markdown fences:
{"action": "...", "message": "...", "buttons": [{"label": "...", "does": "start_session|credit_session|start_break|dismiss"}], "why": "one sentence for the log"}
For silence: {"action": "silence", "why": "..."}"""


def assemble_prompt(profile: str, week_summary: str, diary_recent: list[str],
                    today_log: str, caps: dict, fresh_observation: str) -> list[dict]:
    """Build chat messages in cache-friendly layer order."""
    caps_line = ", ".join(f"{k.replace('_left', '')}: {v} left" for k, v in sorted(caps.items()))
    context = (
        f"PROFILE:\n{profile or '(no profile yet)'}\n\n"
        f"WEEK: {week_summary or '(no weekly goals)'}\n\n"
        f"RECENT DIARY:\n" + ("\n".join(f"- {d}" for d in diary_recent) or "(none)") + "\n\n"
        f"TODAY LOG:\n{today_log or '(nothing yet today)'}\n\n"
        f"CAPS REMAINING: {caps_line}"
    )
    return [
        {"role": "system", "content": CHARTER},
        {"role": "user", "content": context},
        {"role": "user", "content": fresh_observation + "\n\nDecide. JSON only."},
    ]
```

- [ ] **Step 4: Run tests** → PASS.
- [ ] **Step 5: Commit:** `git add coach_prompts.py tests/test_coach_prompts.py && git commit -m "feat(coach): charter prompt + cache-layered assembly"`

---

### Task 3: Backend — DeepSeek client + decide() + guardrails (`coach_agent.py`)

**Files:**
- Create: `intentional-backend/coach_agent.py`
- Modify: `intentional-backend/requirements.txt` (add `httpx>=0.25.0`), `.env.example` (add `DEEPSEEK_API_KEY=sk-xxxx`, `DEEPSEEK_MODEL=deepseek-chat`)
- Test: `intentional-backend/tests/test_coach_agent.py`

- [ ] **Step 1: Failing tests** (LLM mocked — never call the network in tests):

```python
# tests/test_coach_agent.py
import json
import pytest
from unittest.mock import AsyncMock, patch
import coach_agent
from coach_agent import decide, compact_today_log, caps_from_decisions, parse_verdict

def test_parse_verdict_valid():
    v = parse_verdict('{"action":"silence","why":"steady work"}')
    assert v["action"] == "silence"

def test_parse_verdict_rejects_unknown_action():
    v = parse_verdict('{"action":"lecture","why":"x"}')
    assert v["action"] == "silence" and "invalid" in v["why"]

def test_parse_verdict_rejects_garbage():
    v = parse_verdict("not json at all")
    assert v["action"] == "silence"

def test_caps_from_decisions_counts_today():
    decisions = [{"action": "nudge", "suppressed_by_caps": False},
                 {"action": "nudge", "suppressed_by_caps": False},
                 {"action": "rescue", "suppressed_by_caps": False},
                 {"action": "silence", "suppressed_by_caps": False}]
    caps = caps_from_decisions(decisions)
    assert caps == {"nudge_left": 1, "rescue_left": 1, "celebrate_left": 1, "credit_left": 2}

def test_compact_today_log_renders_events():
    events = [
        {"ts": "2026-06-12T13:02:00Z", "kind": "session_start", "payload": {"goal": "pipelines"}},
        {"ts": "2026-06-12T13:30:00Z", "kind": "session_end", "payload": {"goal": "pipelines", "minutes": 28}},
        {"ts": "2026-06-12T14:07:00Z", "kind": "sample", "payload": {"app": "com.google.Chrome", "host": "youtube.com", "in_session": False}},
    ]
    log = compact_today_log(events)
    assert "session 28m" in log and "youtube.com" in log

@pytest.mark.asyncio
async def test_decide_marks_capped_action_suppressed():
    fake_llm = AsyncMock(return_value=('{"action":"nudge","message":"m","buttons":[],"why":"w"}', 100, 20))
    with patch.object(coach_agent, "call_deepseek", fake_llm):
        verdict = await decide(profile="", week_summary="", diary_recent=[],
                               today_log="", caps={"nudge_left": 0, "rescue_left": 2,
                                                   "celebrate_left": 1, "credit_left": 2},
                               fresh_observation="obs")
    assert verdict["action"] == "nudge"
    assert verdict["suppressed_by_caps"] is True   # code-level guardrail, independent of prompt

@pytest.mark.asyncio
async def test_decide_returns_silence_when_llm_unavailable():
    with patch.object(coach_agent, "call_deepseek", AsyncMock(side_effect=RuntimeError("down"))):
        verdict = await decide(profile="", week_summary="", diary_recent=[], today_log="",
                               caps={"nudge_left": 3, "rescue_left": 2, "celebrate_left": 1, "credit_left": 2},
                               fresh_observation="obs")
    assert verdict["action"] == "silence"
```

- [ ] **Step 2: Run** `pytest tests/test_coach_agent.py -v` → FAIL.

- [ ] **Step 3: Implement `coach_agent.py`:**

```python
"""Focus Agent reasoning core (S2, shadow mode). Guardrails live HERE in code;
the prompt is advisory, this module is law."""
import json
import os
import httpx
from datetime import datetime, timezone
from coach_prompts import assemble_prompt

DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
VALID_ACTIONS = {"silence", "credit", "nudge", "rescue", "celebrate"}
DAILY_CAPS = {"nudge": 3, "rescue": 2, "celebrate": 1, "credit": 2}
REASON_THROTTLE_SECONDS = 300  # >=5 min between reasoning calls per account


async def call_deepseek(messages: list[dict]) -> tuple[str, int, int]:
    """Returns (content, prompt_tokens, completion_tokens). Raises on failure."""
    api_key = os.getenv("DEEPSEEK_API_KEY")
    if not api_key:
        raise RuntimeError("DEEPSEEK_API_KEY not configured")
    model = os.getenv("DEEPSEEK_MODEL", "deepseek-chat")
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            DEEPSEEK_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            json={"model": model, "messages": messages, "temperature": 0,
                  "response_format": {"type": "json_object"}, "max_tokens": 300},
        )
        resp.raise_for_status()
        data = resp.json()
    usage = data.get("usage", {})
    return (data["choices"][0]["message"]["content"],
            usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0))


def parse_verdict(raw: str) -> dict:
    """Strict parse; anything malformed degrades to silence (fail-closed)."""
    try:
        v = json.loads(raw)
        action = v.get("action")
        if action not in VALID_ACTIONS:
            return {"action": "silence", "why": f"invalid action from model: {action!r}"}
        return {"action": action, "message": v.get("message"),
                "buttons": v.get("buttons"), "why": v.get("why", "")}
    except (json.JSONDecodeError, AttributeError, TypeError):
        return {"action": "silence", "why": "unparseable model output"}


def caps_from_decisions(todays_decisions: list[dict]) -> dict:
    """Remaining caps given today's non-suppressed decisions."""
    used: dict[str, int] = {}
    for d in todays_decisions:
        if d.get("suppressed_by_caps"):
            continue
        a = d.get("action")
        if a in DAILY_CAPS:
            used[a] = used.get(a, 0) + 1
    return {f"{a}_left": max(0, cap - used.get(a, 0)) for a, cap in DAILY_CAPS.items()}


def compact_today_log(events: list[dict]) -> str:
    """Render today's coach_events as compact one-per-line history."""
    lines = []
    for e in events:
        t = e["ts"][11:16] if len(e.get("ts", "")) >= 16 else "?"
        kind, p = e.get("kind"), e.get("payload", {}) or {}
        if kind == "session_start":
            lines.append(f"{t} session started ({p.get('goal', '?')})")
        elif kind == "session_end":
            lines.append(f"{t} session {p.get('minutes', '?')}m ({p.get('goal', '?')})")
        elif kind == "allowance_zero":
            lines.append(f"{t} allowance hit zero")
        elif kind == "sample":
            where = p.get("host") or p.get("app", "?")
            flag = "in-session" if p.get("in_session") else "free"
            lines.append(f"{t} {where} [{flag}]")
        elif kind == "idle":
            lines.append(f"{t} idle")
    return "\n".join(lines[-60:])  # last 60 lines is plenty of context


async def decide(profile: str, week_summary: str, diary_recent: list[str],
                 today_log: str, caps: dict, fresh_observation: str) -> dict:
    """One reasoning pass. Always returns a verdict dict; never raises."""
    messages = assemble_prompt(profile, week_summary, diary_recent,
                               today_log, caps, fresh_observation)
    try:
        raw, ptok, ctok = await call_deepseek(messages)
    except Exception as exc:  # network/key/HTTP — coach goes quiet, never breaks telemetry
        return {"action": "silence", "why": f"llm unavailable: {exc}",
                "suppressed_by_caps": False, "prompt_tokens": 0, "completion_tokens": 0,
                "model": os.getenv("DEEPSEEK_MODEL", "deepseek-chat")}
    verdict = parse_verdict(raw)
    # Code-level cap enforcement (prompt is advisory; this is law).
    action = verdict["action"]
    capped = action in DAILY_CAPS and caps.get(f"{action}_left", 0) <= 0
    verdict["suppressed_by_caps"] = capped
    verdict["prompt_tokens"] = ptok
    verdict["completion_tokens"] = ctok
    verdict["model"] = os.getenv("DEEPSEEK_MODEL", "deepseek-chat")
    return verdict
```

- [ ] **Step 4: Add `httpx>=0.25.0` to requirements.txt; add env keys to `.env.example`. Run tests** → PASS. (If `pytest-asyncio` isn't installed/configured, add `pytest-asyncio` to dev requirements and `asyncio_mode = "auto"` to pytest config — check `pytest.ini`/`pyproject.toml` first.)
- [ ] **Step 5: Commit:** `git add coach_agent.py requirements.txt .env.example tests/test_coach_agent.py && git commit -m "feat(coach): DeepSeek client + decide() with code-level caps, fail-closed parsing"`

---

### Task 4: Backend — telemetry endpoint + shadow reasoning + review endpoint

**Files:**
- Modify: `intentional-backend/main.py` (new endpoints; import coach modules)
- Test: append to `intentional-backend/tests/test_coach_agent.py`

- [ ] **Step 1: Failing endpoint tests** (use the repo's `_FakeDB` + `patch("main.get_db")` + `_auth()` header patterns from `tests/test_rules_and_allowance.py` — read that file first and mirror its fixtures exactly):

```python
# append to tests/test_coach_agent.py — imports/fixtures mirroring test_rules_and_allowance.py
def test_telemetry_requires_auth():
    r = _client().post("/coach/telemetry", json={"events": []})
    assert r.status_code == 401

def test_telemetry_stores_events_and_decides(fake_db):
    with patch("main.get_db", return_value=fake_db), \
         patch("main.coach_agent.decide", AsyncMock(return_value={
             "action": "silence", "why": "test", "suppressed_by_caps": False,
             "prompt_tokens": 1, "completion_tokens": 1, "model": "mock"})):
        r = _client().post("/coach/telemetry", headers=_auth(), json={"events": [
            {"ts": "2026-06-12T14:07:00Z", "kind": "sample",
             "payload": {"app": "com.google.Chrome", "host": "youtube.com", "in_session": False}}]})
    assert r.status_code == 200
    assert r.json()["stored"] == 1
    assert len(fake_db.tables["coach_events"]) == 1
    assert len(fake_db.tables["coach_decisions"]) == 1
    assert fake_db.tables["coach_decisions"][0]["shadow"] is True

def test_telemetry_throttles_reasoning(fake_db):
    # a decision 60 seconds ago → second post stores events but does NOT reason again
    fake_db.tables["coach_decisions"] = [_decision_row(ts_seconds_ago=60)]
    with patch("main.get_db", return_value=fake_db), \
         patch("main.coach_agent.decide", AsyncMock()) as mock_decide:
        r = _client().post("/coach/telemetry", headers=_auth(), json={"events": [
            {"ts": "2026-06-12T14:07:00Z", "kind": "sample", "payload": {}}]})
    assert r.status_code == 200
    mock_decide.assert_not_called()

def test_decisions_review_endpoint(fake_db):
    fake_db.tables["coach_decisions"] = [_decision_row(ts_seconds_ago=10)]
    with patch("main.get_db", return_value=fake_db):
        r = _client().get("/coach/decisions?limit=10", headers=_auth())
    assert r.status_code == 200
    assert len(r.json()["decisions"]) == 1
```

- [ ] **Step 2: Run** → FAIL (404s).

- [ ] **Step 3: Implement in `main.py`** (place near the rules endpoints ~line 5300; follow `_resolve_account_dual_auth` + Supabase patterns exactly):

```python
# --- Focus Agent (S1+S2 shadow mode, June 2026) ---
import coach_agent
import coach_prompts

@app.post("/coach/telemetry")
async def coach_telemetry(
    batch: CoachTelemetryBatch,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """Mac posts abstracted activity events. Stores them; runs ONE shadow
    reasoning pass if >=5 min since the last decision for this account."""
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    rows = [{"account_id": account_id, "device_id": x_device_id,
             "ts": e.ts, "kind": e.kind, "payload": e.payload} for e in batch.events]
    if rows:
        db.table("coach_events").insert(rows).execute()

    # Throttle: at most one reasoning pass per REASON_THROTTLE_SECONDS.
    last = db.table("coach_decisions").select("ts").eq("account_id", account_id) \
             .order("ts", desc=True).limit(1).execute().data
    now = datetime.now(timezone.utc)
    if last:
        last_ts = datetime.fromisoformat(last[0]["ts"].replace("Z", "+00:00"))
        if (now - last_ts).total_seconds() < coach_agent.REASON_THROTTLE_SECONDS:
            return {"stored": len(rows), "reasoned": False}

    # Assemble context from today's data.
    day_start = now.strftime("%Y-%m-%dT00:00:00+00:00")
    todays_events = db.table("coach_events").select("ts,kind,payload") \
        .eq("account_id", account_id).gte("ts", day_start).order("ts").execute().data or []
    todays_decisions = db.table("coach_decisions").select("action,suppressed_by_caps") \
        .eq("account_id", account_id).gte("ts", day_start).execute().data or []
    profile_rows = db.table("coach_memory").select("content").eq("account_id", account_id) \
        .eq("kind", "profile").execute().data or []
    diary_rows = db.table("coach_memory").select("content").eq("account_id", account_id) \
        .eq("kind", "diary").order("day", desc=True).limit(3).execute().data or []

    fresh = coach_agent.compact_today_log([e for e in todays_events][-3:]) or "(no recent activity)"
    verdict = await coach_agent.decide(
        profile=profile_rows[0]["content"] if profile_rows else "",
        week_summary="",  # S2: weekly-goal pace summary wired in S3 when ritual lands
        diary_recent=[d["content"] for d in diary_rows],
        today_log=coach_agent.compact_today_log(todays_events),
        caps=coach_agent.caps_from_decisions(todays_decisions),
        fresh_observation=f"NOW {now.strftime('%H:%M')} UTC:\n{fresh}",
    )
    db.table("coach_decisions").insert({
        "account_id": account_id, "action": verdict["action"],
        "message": verdict.get("message"), "buttons": verdict.get("buttons"),
        "why": verdict.get("why"), "model": verdict.get("model"),
        "prompt_tokens": verdict.get("prompt_tokens"),
        "completion_tokens": verdict.get("completion_tokens"),
        "shadow": True, "suppressed_by_caps": verdict.get("suppressed_by_caps", False),
    }).execute()
    return {"stored": len(rows), "reasoned": True, "action": verdict["action"]}


@app.get("/coach/decisions")
async def coach_decisions_review(
    limit: int = 50,
    authorization: Optional[str] = Header(None),
    x_device_id: Optional[str] = Header(None, alias="X-Device-ID"),
):
    """Shadow-review: what would the coach have said. Also the future
    'what your coach can see' transparency surface."""
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    rows = db.table("coach_decisions").select("*").eq("account_id", account_id) \
             .order("ts", desc=True).limit(min(limit, 200)).execute().data or []
    return {"decisions": rows}
```

- [ ] **Step 4: Run all coach tests + full suite** (`pytest tests/ -q`) → PASS, no regressions.
- [ ] **Step 5: Commit:** `git commit -am "feat(coach): /coach/telemetry shadow reasoning + /coach/decisions review"`

---

### Task 5: Backend — coach-bench (S1)

**Files:**
- Create: `intentional-backend/coach_bench/scenarios.jsonl`, `intentional-backend/coach_bench/run_bench.py`

- [ ] **Step 1: Write `scenarios.jsonl`** — one JSON object per line, schema:

```json
{"id": "credit-steady-figma", "category": "credit", "context": {"profile": "- Deep work happens in Figma and Cursor.", "week_summary": "Ship v1 6h of 8h (ahead).", "diary_recent": [], "today_log": "9:02 session 25m pipelines\n10:32 figma.com [free]\n10:37 figma.com [free]\n10:42 figma.com [free]\n10:47 figma.com [free]\n10:52 figma.com [free]", "caps": {"nudge_left": 3, "rescue_left": 2, "celebrate_left": 1, "credit_left": 2}, "fresh_observation": "NOW 10:57: Figma, steady 25 min, no session running."}, "allowed": ["credit", "silence"], "forbidden": ["nudge", "rescue"]}
```

Write 50 scenarios total with this category quota (each line follows the schema above; vary apps, times, cap states):
- **silence×15**: steady work in work apps (5); brief 2-3 min social checks not worth speaking on (3); mid-session anything (2 — coach must not speak in-session); just-dismissed-a-card-recently situations (3); late evening / caps exhausted (2).
- **credit×8**: 20-45 min steady in Figma/Cursor/Docs with no session, varying goals and weeks.
- **nudge×8**: 10-20+ min in YouTube/Instagram/Reddit with an unmet contract and caps available, varying times of day.
- **rescue×8**: allowance-zero + still on limited site (4); rapid app thrashing 15+ min no session (4).
- **celebrate×5**: contract met just now, varying contracts.
- **edge×6** (allowed `["silence"]`): nudge correct-looking but `nudge_left: 0` (2); work-like activity in an ambiguous app like Gmail (2); first 10 minutes of the morning with no contract yet (2).

- [ ] **Step 2: Write `run_bench.py`:**

```python
"""Coach bench: runs scenarios through the live decide() path, reports
action accuracy and wrong-nudge rate. Usage:
  DEEPSEEK_API_KEY=... python coach_bench/run_bench.py
  python coach_bench/run_bench.py --mock   # plumbing check without a key
"""
import argparse, asyncio, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import coach_agent

async def run(mock: bool) -> int:
    path = os.path.join(os.path.dirname(__file__), "scenarios.jsonl")
    scenarios = [json.loads(l) for l in open(path) if l.strip()]
    results, wrong_speaks = [], 0
    for sc in scenarios:
        if mock:
            verdict = {"action": "silence", "suppressed_by_caps": False}
        else:
            verdict = await coach_agent.decide(**sc["context"])
        action = verdict["action"]
        ok = action in sc["allowed"]
        spoke_wrongly = (action in sc.get("forbidden", [])) or \
                        (action != "silence" and not ok)
        wrong_speaks += int(spoke_wrongly)
        results.append((sc["id"], sc["category"], action, ok))
        print(f"{'PASS' if ok else 'FAIL':4} [{sc['category']:9}] {sc['id']:34} -> {action}")
    n = len(results)
    acc = sum(1 for *_, ok in results if ok) / n
    print(f"\nscenarios: {n}  accuracy: {acc:.0%}  WRONG-SPEAK rate: {wrong_speaks}/{n} ({wrong_speaks/n:.0%})")
    print("Gate for S3 visibility: wrong-speak rate must be 0 on this bench.")
    return 0 if wrong_speaks == 0 else 1

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--mock", action="store_true")
    sys.exit(asyncio.run(run(ap.parse_args().mock)))
```

- [ ] **Step 3: Run `python coach_bench/run_bench.py --mock`** → completes, silence-only baseline shows the silence scenarios passing, others failing (expected in mock; proves plumbing).
- [ ] **Step 4: If `DEEPSEEK_API_KEY` is available in the environment, run the real bench** and save output to `coach_bench/results-2026-06-12-deepseek-chat.txt`; commit it. If no key: note USER ACTION in the final report.
- [ ] **Step 5: Commit:** `git add coach_bench/ && git commit -m "feat(coach): eval bench — 50 scenarios + wrong-speak gate"`

---

### Task 6: Backend — deploy

- [ ] **Step 1:** `cd /Users/arayan/Documents/GitHub/intentional-backend && pytest tests/ -q` → all green.
- [ ] **Step 2:** Push to main → Railway auto-deploys: `git push origin main`.
- [ ] **Step 3:** Verify live: `curl -s https://api.intentional.social/coach/decisions -H "X-Device-ID: <ameer device id from Mac UserDefaults>" | head -c 400` → `{"decisions": []}` (not 404/500). Note: reasoning stays silent server-side until `DEEPSEEK_API_KEY` is set in Railway (USER ACTION) — telemetry storage works regardless (decide() fails closed to silence verdicts with `llm unavailable` in `why`).

---

### Task 7: Mac — `CoachTelemetry.swift` collector

**Files:**
- Create: `intentional-macos-app/Intentional/CoachTelemetry.swift` (add to Xcode project — check how recent .swift files were added; if pbxproj edits were done by hand for SessionFocusScore.swift, mirror that; otherwise use `ruby -e` xcodeproj or list the file for Ameer)
- Modify: `Intentional/BackendClient.swift` (one new method), `Intentional/AppDelegate.swift` (wiring)

- [ ] **Step 1: Implement `CoachTelemetry.swift`:**

```swift
import Foundation
import AppKit

/// Focus Agent S2 (shadow mode): samples abstracted activity — app/host names
/// and durations only, never titles or content — buffers it, and flushes to
/// the backend every few minutes. Privacy gate: `coachTelemetryLevel`
/// UserDefaults ("names" default | "off").
/// Spec: docs/superpowers/specs/2026-06-12-focus-agent-design.md
final class CoachTelemetry {

    struct Event {
        let ts: Date
        let kind: String          // sample | session_start | session_end | allowance_zero | idle
        let payload: [String: Any]
    }

    private var buffer: [Event] = []
    private let lock = NSLock()
    private var sampleTimer: Timer?
    private var flushTimer: Timer?
    private weak var backendClient: BackendClient?
    private weak var focusModeController: FocusModeController?
    private weak var focusMonitor: FocusMonitor?

    static let sampleInterval: TimeInterval = 60
    static let flushInterval: TimeInterval = 180

    var enabled: Bool {
        (UserDefaults.standard.string(forKey: "coachTelemetryLevel") ?? "names") != "off"
    }

    init(backendClient: BackendClient?, focusModeController: FocusModeController?,
         focusMonitor: FocusMonitor?) {
        self.backendClient = backendClient
        self.focusModeController = focusModeController
        self.focusMonitor = focusMonitor
    }

    func start() {
        guard sampleTimer == nil else { return }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(sampleTimer!, forMode: .common)
        RunLoop.main.add(flushTimer!, forMode: .common)
        NSLog("📡 CoachTelemetry started (sample \(Int(Self.sampleInterval))s, flush \(Int(Self.flushInterval))s)")
    }

    func stop() {
        sampleTimer?.invalidate(); sampleTimer = nil
        flushTimer?.invalidate(); flushTimer = nil
    }

    /// Boundary events pushed by AppDelegate's onStateChanged fanout.
    func recordBoundary(kind: String, payload: [String: Any] = [:]) {
        guard enabled else { return }
        append(Event(ts: Date(), kind: kind, payload: payload))
        flush()  // boundaries flush immediately — they're the agent's trigger moments
    }

    private func sample() {
        guard enabled else { return }
        var payload: [String: Any] = [:]
        let frontmost = NSWorkspace.shared.frontmostApplication
        payload["app"] = frontmost?.bundleIdentifier ?? "unknown"
        // Host only (never title/path) — privacy level "names".
        if let url = focusMonitor?.lastScoredURL, let host = URL(string: url)?.host {
            payload["host"] = host
        }
        payload["in_session"] = focusModeController?.isOn == true
        if let mins = AllowanceBalance.shared.availableMinutesAfterPending {
            payload["allowance_minutes_left"] = mins
        }
        append(Event(ts: Date(), kind: "sample", payload: payload))
    }

    private func append(_ e: Event) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(e)
        if buffer.count > 400 { buffer.removeFirst(buffer.count - 400) }  // bound memory
    }

    func flush() {
        guard enabled else { return }
        lock.lock()
        let toSend = buffer
        buffer.removeAll()
        lock.unlock()
        guard !toSend.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        let events: [[String: Any]] = toSend.map {
            ["ts": iso.string(from: $0.ts), "kind": $0.kind, "payload": $0.payload]
        }
        Task { [weak self] in
            let ok = await self?.backendClient?.postCoachTelemetry(events: events) ?? false
            if !ok {
                // Put the batch back (front) so nothing is lost on transient failures.
                self?.lock.lock()
                self?.buffer.insert(contentsOf: toSend, at: 0)
                if let c = self?.buffer.count, c > 400 { self?.buffer.removeLast(c - 400) }
                self?.lock.unlock()
            } else {
                NSLog("📡 CoachTelemetry flushed \(events.count) events")
            }
        }
    }
}
```

(Adapt `focusMonitor?.lastScoredURL` to the actual access level found in FocusMonitor.swift:691 — if private, add an internal computed accessor `var currentTabHost: String?` to FocusMonitor instead. Check `AllowanceBalance.shared` import needs.)

- [ ] **Step 2: Add `postCoachTelemetry` to BackendClient.swift** (mirror `sendEvent`'s style, lines 64–110):

```swift
/// Focus Agent S2: batch-post abstracted telemetry. Returns success.
func postCoachTelemetry(events: [[String: Any]]) async -> Bool {
    guard let url = URL(string: "\(baseURL)/coach/telemetry") else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
    do {
        request.httpBody = try JSONSerialization.data(withJSONObject: ["events": events])
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
        return false
    }
}
```

- [ ] **Step 3: Wire in AppDelegate** — after FocusModeController + FocusMonitor exist (init order step 15a area): create `var coachTelemetry: CoachTelemetry?`, instantiate, `start()`. In the existing `onStateChanged` fanout add boundary events:

```swift
// Focus Agent S2 — boundary telemetry (shadow mode; nothing renders).
if new == .focus && old == .off {
    coachTelemetry?.recordBoundary(kind: "session_start",
        payload: ["goal": period?.intention ?? ""])
} else if new == .off && old == .focus {
    coachTelemetry?.recordBoundary(kind: "session_end",
        payload: ["goal": period?.intention ?? ""])
}
```

- [ ] **Step 4: Build:** `xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | grep -E "error:|BUILD" | sort -u` → `** BUILD SUCCEEDED **`. (If the new file isn't in the target, add it to the Xcode project — see Files note above.)
- [ ] **Step 5: Commit:** `git add Intentional/CoachTelemetry.swift Intentional/BackendClient.swift Intentional/AppDelegate.swift Intentional.xcodeproj && git commit -m "feat(coach): shadow-mode telemetry collector + batched flush (names-only privacy)"`

---

### Task 8: Live shadow verification (host)

- [ ] **Step 1:** `./scripts/dev-launch.sh --no-build`, wait for init, then `grep "CoachTelemetry" /tmp/intentional-fresh.log` → "started" line present.
- [ ] **Step 2:** Wait ≥4 minutes of normal activity, then `grep "CoachTelemetry flushed" /tmp/intentional-fresh.log` → at least one flush.
- [ ] **Step 3:** Read shadow decisions: `DID=$(defaults read com.arayan.intentional deviceId); curl -s "https://api.intentional.social/coach/decisions?limit=5" -H "X-Device-ID: $DID" | python3 -m json.tool | head -40` → decision rows exist; if `DEEPSEEK_API_KEY` not yet set in Railway, `why` says "llm unavailable" (acceptable; flag USER ACTION).
- [ ] **Step 4:** Privacy check: query `coach_events` payloads via the review of what was sent (`curl` a few events through Supabase or log inspection) — confirm NO titles, NO URLs beyond host, NO OCR text.

---

### Task 9: Docs + cross-repo log + push

- [ ] **Step 1:** Create `intentional-macos-app/docs/features/focus-agent.md` from `_TEMPLATE.md`: `status: wip`, `files: [Intentional/CoachTelemetry.swift, Intentional/BackendClient.swift]`, architecture diagram (Mac senses → /coach/telemetry → shadow decide → coach_decisions), the privacy contract (names+durations only), link to spec. Run `scripts/check-docs.sh` → 0 errors.
- [ ] **Step 2:** Create `intentional-macos-app/docs/cross-repo-focus-agent-2026-06-12.md`: what landed in each repo (commit SHAs), bench results (or mock-only note), USER ACTIONS outstanding (DeepSeek key → Railway; run real bench), next slice (S3 first visible nudge, gated on wrong-speak = 0).
- [ ] **Step 3:** Update `docs/PROJECT-STATE-2026-06-11.md`: add Focus Agent S1+S2 to DONE-this-session with shadow-mode status.
- [ ] **Step 4:** Commit + push BOTH repos (backend push deploys — that's intended).

---

## Self-review notes

- Spec coverage: S1 bench ✓(T5) charter ✓(T2) model pick ✓(bench gate + env-swappable model) S2 telemetry ✓(T7) shadow loop ✓(T4) privacy names-only ✓(T7 sample + T8.4 check) throttle ✓(T4) caps-in-code ✓(T3) fail-closed ✓(T3 parse + llm-down tests) review surface ✓(/coach/decisions). Memory tables created (T1) but profile/diary WRITERS are S6 — intentionally read-empty in S2 (spec's slice order).
- Type consistency: `decide()` signature matches between coach_agent.py, main.py call site, and run_bench.py (`**sc["context"]` keys = parameter names). `caps_from_decisions` output keys (`nudge_left`...) match `assemble_prompt` caps rendering and DAILY_CAPS gate.
- Known adaptation points (explicitly delegated to implementer): exact `_FakeDB` fixture import path, FocusMonitor URL accessor visibility, Xcode project file addition mechanics, pytest-asyncio config.
