---
feature: FocusAgent
status: wip
owner: Shared
last_verified: 2026-06-12
files:
  - Intentional/CoachTelemetry.swift
  - Intentional/BackendClient.swift
  - Intentional/AppDelegate.swift
related:
  - onboarding
  - rules
---

## TL;DR

A cloud "coach" agent (DeepSeek, on intentional-backend) reasons over abstracted Mac activity every ~5 minutes and decides silence/credit/nudge/rescue/celebrate — currently in **shadow mode**: every verdict is logged, nothing is ever shown. Visibility (S3) is gated on the eval bench's zero wrong-speak requirement, which the tuned charter passes 50/50.

## User-visible behavior

- **None, by design (S2 = shadow).** The Mac samples frontmost app + browser host + session/allowance state every 60s and batch-posts every 180s; boundary events (session start/end) flush immediately.
- Privacy contract: **names and minutes only** — bundle ids, hosts, durations. No titles, no URL paths, no OCR text, no content. Gate: UserDefaults `coachTelemetryLevel` ("names" default | "off").
- Shadow verdicts are reviewable at `GET /coach/decisions` (dual-auth) — this becomes the "what your coach can see" transparency surface later.

## Architecture

```mermaid
flowchart LR
    A[CoachTelemetry.swift\n60s sample / 180s flush] -->|POST /coach/telemetry\nX-Device-ID| B[intentional-backend]
    B --> C[(coach_events)]
    B -->|>=5 min since last| D[coach_agent.decide\nDeepSeek temp=0 JSON]
    D --> E[(coach_decisions\nshadow=true)]
    B --> F[(coach_memory\nprofile + diary — writers land in S6)]
```

## Data flow

```mermaid
sequenceDiagram
    participant Mac
    participant API as /coach/telemetry
    participant LLM as DeepSeek
    Mac->>API: events batch (names+minutes)
    API->>API: store; throttle check (300s)
    API->>LLM: charter + profile + diary + today log + fresh obs
    LLM-->>API: {"action":"silence","why":"..."}
    API->>API: code-level caps; insert coach_decisions (shadow)
    Note over Mac,API: failure path: flush 404/network → events re-queue on Mac (400-event ring)
```

## Files

| File | Lines | Role |
|------|-------|------|
| `Intentional/CoachTelemetry.swift` | ~150 | Sampler, privacy gate, buffer, batched flush + re-queue |
| `Intentional/BackendClient.swift` | postCoachTelemetry | Authenticated batch POST |
| `Intentional/AppDelegate.swift` | ~692, fanout | Wiring + session boundary events |

Backend (intentional-backend): `coach_prompts.py` (charter), `coach_agent.py` (decide/caps/fail-closed), `main.py` /coach endpoints, `migrations/029_coach_agent.sql`, `coach_bench/` (50-scenario eval + results).

## Key functions

| Function | What it does | Called by |
|----------|-------------|-----------|
| `CoachTelemetry.sample()` | 60s snapshot: app/host/in_session/allowance | sample timer |
| `CoachTelemetry.flush()` | batch POST; re-queue on failure | flush timer + boundaries |
| `coach_agent.decide()` (py) | one reasoning pass; never raises; fail-closed to silence | /coach/telemetry |
| `caps_from_decisions` (py) | code-level daily caps (nudge 3, rescue 2, celebrate 1, credit 2) | decide path |
| `run_bench.py` | 50 scenarios; wrong-speak gate for S3 | manual / CI later |

## Configuration

| Key | Where | Default | Notes |
|-----|-------|---------|-------|
| `coachTelemetryLevel` | UserDefaults (Mac) | `"names"` | `"off"` disables collection entirely |
| `DEEPSEEK_API_KEY` / `DEEPSEEK_MODEL` | Railway env | — / `deepseek-chat` | reasoner scored worse (token-cap truncation) |
| Throttle / caps | code | 300s; 3/2/1/2 per day | guardrails in code, not prompt |

## Edge cases & limitations

- **Shadow only** — no UI exists; S3 (first visible nudge) is a separate plan, gated on bench wrong-speak = 0 (PASSED 2026-06-12, charter `fcdf967`).
- Bench gray zone: credit threshold is "20+ steady minutes"; 12–21 min behavior unverified (no scenarios there yet).
- `week_summary` is empty in S2 (weekly-pace context wires in with the morning ritual, S6); `coach_memory` tables exist but writers land in S6.
- Backend down → events ring-buffer caps at 400 (~6.5h); oldest drop first.

## Decision history

- **2026-06-12** — S1+S2 shipped + verified live: first real shadow verdict at 09:00 ("silence — user switching iTerm2/Chrome, no commitment exists, silence is safest", 953 tokens, ~0.02¢). Charter tuned 86%→100% / wrong-speak 7→0 in 3 bench iterations. Spec: `docs/superpowers/specs/2026-06-12-focus-agent-design.md`. Plan: `docs/superpowers/plans/2026-06-12-focus-agent-s1-s2.md`.
- **2026-06-12** — Design locked: local senses / cloud brain, silence-biased, constitution (can't touch rules/strict-mode/allowance), 13-tool roadmap, phone tools deferred.
