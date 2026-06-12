# Focus Agent — Design Spec (2026-06-12)

**Status:** design — approved direction from 2026-06-11/12 brainstorm (Ameer + Claude). Companion artifacts: `docs/product-teardown-2026-06-11.html` (the problems), `.superpowers/brainstorm/` mockups v1–v6 (the surfaces).

## One line

Replace preset timers and dashboard passivity with an **agent that watches what the user is actually doing and coaches them through the day** — a human coach sitting next to you, implemented as a cheap cloud LLM with memory, with the existing on-device AI as its eyes. Whoop for ADHD: passive continuous measurement, one daily narrative, in-the-moment guidance.

## Why (from the teardown)

The app's surfaces are dead between sessions. Goals are written Monday and forgotten by Tuesday (goal amnesia). The Today tab answers nothing at 8:40pm. Preset heuristics (hourly nags, historical "launch windows") are thermostat thinking — the user explicitly rejected them: *"the app should react to what you're actually doing… as if a really smart LLM is looking at what the user is doing every 5 minutes and figuring out how to guide them."*

## Architecture: local senses, cloud brain

```
Mac (existing)                    Backend (new)                      LLM API
─────────────                     ─────────────                      ───────
OCR + Qwen relevance  ──┐
TimeTracker           ──┼─→ telemetry events ─→ POST /coach/telemetry
FocusMonitor          ──┘   (abstracted: app/site,    │
                             durations, session state,  ▼
                             allowance, drift flags)  Agent loop ──────→ DeepSeek V4 Flash
                                                      │  (reason)  ←──── JSON verdict
Pill renders decision ←── poll/push ←─ coach_decisions│
(nudge/credit/converse/                               ▼
 celebrate cards)                              coach_memory
                                               (working/episodic/profile)
```

- **Tier 1 — senses (local, exists):** RelevanceScorer's OCR+Qwen pipeline and TimeTracker keep running as today. New job: emit **abstracted telemetry** — app/site names, durations, session/allowance state, drift flags. **Raw screen text never leaves the Mac** (default privacy level: names + durations only; richer detail opt-in).
- **Tier 2 — brain (backend, new):** one agent per **account** (Mac + iPhone share the coach — fits backend-as-source-of-truth). Receives telemetry, reasons, mostly returns `silence`.
- **Why server-side:** cross-device memory, API keys off-device, model swap without app release, shadow-mode evaluation.

## The agent

**Observation cadence:** telemetry batch every ~2–5 min during free time; immediate on boundary events (session start/end, allowance zero, morning first-activity, 8pm settle). Cost makes cadence a non-issue (see Costs); the local gate exists for signal quality, not budget.

**Action space (closed set, v1):**
| Action | Example | Surface |
|---|---|---|
| `silence` | (the default — most observations) | — |
| `credit` | "Deep in Figma for 25 min — count it toward Ship v1?" → retroactive session | pill card |
| `nudge` | contract reminder in the user's own words, beautifully rendered | pill card |
| `rescue` | zero-allowance ramp / stuck ramp: 10-min starter, sweep-first, guilt-free break | pill card |
| `converse` | user typed/spoke "I can't focus" → triage dialogue (tired/anxious/bored/task-too-big → matched move) | pill chat |
| `celebrate` | contract met: "You did the thing. The evening's yours." | pill card |

**Memory (plain Postgres, no vector DB in v1):**
- *Working:* today's narrative log (sessions, drifts, interventions + outcomes, conversation turns).
- *Episodic:* daily summaries. **The evening settle is the agent writing its diary; the morning ritual is it reading the diary back.** Same data feeds the future partner email (v1.1 commitment loop).
- *Profile:* learned durable facts ("dismisses nudges during meetings", "tiny starters work"), updated by a weekly job.

**Scheduled appearances (the bookends, agent-authored):**
- *Morning ritual* — trigger: first sustained activity (unlock + ~2 min input) after 5am, once/day. Pill expands to replay carousel (yesterday's number → week pace → streak → THE ASK: one suggestion, one button). Day-1/no-history: ask only.
- *Evening settle* — trigger: first idle after 8pm, once/day. Contract closes honestly; diary written; tomorrow's suggestion computed.

**Guardrails — enforced in code, not prompt:** the LLM chooses *within* deterministic limits: max nudges/hour and /day, priority ordering (wall > stuck > nudge), nothing proactive mid-session, nothing after settle/before 5am, one-tap dismiss everywhere, dismissal outcomes fed back into context. Decision rule is silence-biased: a wrong nudge costs ~5× a missed one (sweep lesson, encoded in the eval metric and the policy).

## Model strategy

- **Telemetry verdicts:** DeepSeek **V4 Flash** — $0.14/M input cache-miss, **$0.0028/M cache-hit**, $0.28/M out (api-docs.deepseek.com/quick_start/pricing). Prompt structured for caching: [charter | profile | day-log prefix] cached, only the telemetry tail fresh. Realistic cost ≈ **$0.10–0.50/user/month** even at 2–3 min cadence.
- **Conversations:** V4 Pro or Haiku-class if Flash chat quality disappoints on the bench. Low volume, high stakes.
- **Router is server-side and model-agnostic.** The bench picks the model, not vibes. Temperature 0, JSON-schema-enforced output.
- Local Qwen stays for: relevance scoring (high-frequency), telemetry abstraction, offline fallback policy (current static behavior).

## Eval harness FIRST (build-order keystone)

`coach-bench` in intentional-backend, SweepBenchmark pattern: ~50 ground-truth scenarios (observation bundle → allowed action set), e.g. "Figma 25 min, no session → {credit, silence}; nudge = WRONG". Metrics: action accuracy, **wrong-nudge rate** (the 5×-cost number), silence precision. Run per candidate model + per prompt revision. No coach ships before the bench exists and the wrong-nudge rate is known.

## Rollout slices

1. **S1 — bench + prompt + model pick.** Backend only.
2. **S2 — telemetry pipe + shadow mode.** Mac emits telemetry; agent decides but decisions are only LOGGED. Runs on Ameer's machine; shadow log becomes labeled training/eval data.
3. **S3 — first visible action:** the contract-reminder `nudge`, capped 1/day. GUI-verified, motion-designed (this is where polish/animation budget goes — native springs + Lottie; Seedance only for ritual card backgrounds / marketing).
4. **S4 — `credit`, `celebrate`, `rescue`** ramps.
5. **S5 — `converse`** (pill chat, text first).
6. **S6 — bookends become agent-authored** (ritual + settle replace static copy); diary loop closes.

Each slice: live GUI verification per verifier-intentional-gui, wrong-nudge rate re-measured in shadow before widening caps.

## Also shipping alongside (from the teardown, independent of the agent)

- **Protection truth:** fix disabled-rules state; rules enabled-by-default on create; loud "nothing is blocked" banner + pill state. (Found live on Ameer's machine: all 11 block rules off, only the test rule active.)
- **State + vocabulary sweep:** kill "Free time"+"Stop session" contradictions; one allowance phrasing everywhere ("focus 25, earn 5").
- **Onboarding seam:** suppress close-the-noise sweep for the onboarding-started session.
- **Today tab = the record:** auto-filled day timeline (TimeTracker data), contract meter, protection banner. The pill is the loop; Today is the mirror.

## Open questions (for Ameer)

1. **Launch sequencing:** agent is a 1–2+ week build. Launch current app now and ship the agent as the fast-follow, or hold launch for S3 ("first visible coach moment")?
2. Conversation input v1: text only, or voice from day one (Whisper-class local transcription exists in macOS)?
3. Telemetry privacy default: names+durations only (recommended) — confirm.
4. iPhone telemetry in v1 or Mac-first? (Recommended: Mac-first; iPhone reads the same diary for the morning ritual later.)

## Out of scope (v1)

Partner-facing coach output (v1.1 commitment loop), VLM screenshot categorization, vector memory, iOS coach surfaces, web dashboard.
