# Focus Agent S3 — First Visible Action: the Plan Prompt

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. Patterns established in `2026-06-12-focus-agent-s1-s2.md` apply (repo conventions, test fixtures, commit style, no pushes — orchestrator pushes).

**Goal:** The coach's first visible word: when the user is active with no commitment set, the pill shows ONE question — "What's the one thing today?" — with a text field + Start button that creates a goal-linked session. Everything else stays shadow.

**Architecture:** New action `plan_prompt` in the charter + bench (re-tuned to wrong-speak 0 before enabling). Backend marks `plan_prompt` decisions `shadow=false` (all other actions stay shadow) and serves them via the existing decisions endpoint; the Mac polls `GET /coach/decisions/pending` every 60s (piggybacks the telemetry flush timer), renders the coach card in the pill (DeepWorkTimerController gains a `.coachCard` mode), and reports outcome via `POST /coach/decisions/{id}/outcome` (`shown | tapped_start | dismissed`). Outcomes feed the charter context (the "last card was dismissed" rule already in the prompt).

**Caps & triggers (code-enforced, backend):** `plan_prompt` max 2/day; only 5:00–21:00 local; only when no contract/commitment today AND ≥20 min of activity since first morning event AND not in session AND last plan_prompt ≥3h ago. The LLM still decides WHETHER this is a good moment within those gates (it already says "no commitment exists" unprompted).

**Mac UX (reuses existing pill machinery):** card = kicker "Your coach" · the LLM's message (1–2 sentences) · text input (placeholder "e.g. Send 10 recruiter emails") · `[Start 25 min]` · quiet "later". Start path = existing CREATE_INTENTION → START_INTENTION_SESSION chain from onboarding screen 10 (same payload: name ≤60, intent_text ≤140, status in_progress, week_of ISO Monday). The session start emits the existing `session_start` boundary event — the coach sees its own prompt worked.

---

### Task 1: Bench first — plan_prompt scenarios + charter (backend)
- [ ] Add `plan_prompt` to VALID_ACTIONS + DAILY_CAPS (2/day) in coach_agent.py; add to migration: `migrations/031_plan_prompt_action.sql` re-creating coach_decisions.action CHECK with 'plan_prompt' (Supabase USER ACTION, note it).
- [ ] Charter: add the action definition — "plan_prompt: morning or sustained activity with NO commitment today. Ask for the single most important thing, warmly, ≤2 sentences. Never when a commitment exists, never in-session, never after 21:00."
- [ ] Bench: +10 scenarios in scenarios.jsonl — allowed `["plan_prompt"]`: morning 20+ min activity no contract (3, varied apps incl. work apps — planless work still deserves the ask); afternoon no contract after idle (2). Forbidden (allowed `["silence"]` etc.): contract already set (2), in-session (1), 22:30 (1), plan_prompt cap exhausted (1). Keep all 50 existing scenarios green.
- [ ] Run real bench (`DEEPSEEK_API_KEY` in .env): iterate charter until wrong-speak 0/60, accuracy maximized. Commit results file.

### Task 2: Backend — unshadow plan_prompt + pending/outcome endpoints
- [ ] `coach_decisions` insert: `shadow = (action != "plan_prompt")`. Code-gates BEFORE the LLM call sets `plan_prompt` availability in caps (time window 5–21 local from account tz — store/assume ET for now, note follow-up; no contract today = no session_start event AND no prior tapped_start outcome today; ≥3h since last plan_prompt; cap 2/day).
- [ ] `GET /coach/decisions/pending` (dual-auth): newest non-shadow decision with no outcome, `{decision: {...}|null}`.
- [ ] `POST /coach/decisions/{id}/outcome` body `{outcome: "shown"|"tapped_start"|"dismissed"}` → new column via migration 031 (`outcome TEXT`, `outcome_ts TIMESTAMPTZ`).
- [ ] Context addition: recent outcomes line in prompt context ("last card: dismissed 11:20").
- [ ] Tests: pending returns only unshadowed+un-outcomed; outcome write; caps/window gates (clock injected via parameter like existing patterns); full suite green minus 2 known baseline failures.

### Task 3: Mac — coach card in the pill + decision poll + outcome reporting
- [ ] BackendClient: `fetchPendingCoachDecision()`, `postCoachDecisionOutcome(id:outcome:)` (X-Device-ID patterns).
- [ ] CoachTelemetry (or small new CoachDecisionPoller in same file): on each flush tick, fetch pending; hand to DeepWorkTimerController.
- [ ] DeepWorkTimerController: `.coachCard` pill mode (~460×220, pattern of `.startRitualEdit`): coach message, input, Start button → existing goal-create+session-start path (mirror onboarding screen-10 chain via MainWindow handlers or direct store calls — reuse, don't duplicate); "later" → outcome dismissed. Report `shown` on render. One card at a time; card never appears during sessions/overlays (check FocusModeController + existing overlay guards).
- [ ] Build + commit. NO launch (orchestrator verifies live per verifier-intentional-gui).

### Task 4: Live verification + docs (orchestrator)
- [ ] Relaunch dev; force conditions (no session, morning window —or temporarily relax window in a debug override); watch pill render the card; type a task; verify session starts + goal created + outcome recorded; screenshot evidence.
- [ ] Update docs/features/focus-agent.md (status: shipping for S3 scope), cross-repo log, PROJECT-STATE. Push both repos.

**Self-review:** plan_prompt joins caps/charter/bench/gates consistently; outcome loop closes the "dismissed = back off" rule; the Mac card reuses onboarding's session-start chain (no new session plumbing); migration 031 covers CHECK + outcome columns; timezone simplification flagged.
