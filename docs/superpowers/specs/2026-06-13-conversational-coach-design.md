# Conversational Coach (talk-to-it) — Design Spec

**Date:** 2026-06-13
**Status:** APPROVED for usable-today MVP (forks locked with Ameer 2026-06-13)
**Builds on:** the Focus Agent (`2026-06-12-focus-agent-design.md`), Daily Focus (`2026-06-12-daily-focus-and-coach-powers-design.md`), coach voice Slice 2.

## Why
Ameer wants to TALK to the coach like a person — declare intent conversationally ("I've got an interview Monday, want to practice most of today"), have it help break the work down, and set a daily TIME TARGET it holds him to. This is the *Enter* stage made conversational + the living coaching profile that is the product's moat (a coach that knows you beats any chatbot).

## Locked decisions (Ameer)
- **Target, not cap:** the daily time number is an aim-for (coach helps you HIT it, going over is fine), never a hard stop.
- **Both surfaces eventually:** dashboard chat (MVP, ships first) + pill quick-chat (follow-up).
- **Adaptive breakdown:** the coach's help is informed by a living profile, not a fixed script.
- **Onboarding profile questions (4, strengths-first, ask only what the screen can't reveal):**
  1. "Last time you were so locked in you lost track of time — what were you doing?" (flow conditions / strengths)
  2. "When you actually get hard things done, what's around you — someone there, a deadline, music, a place?" (environment → body-double / urgency strategy)
  3. "What's been stuck on your list for weeks, and what happens when you try to start it?" (the real task-initiation barrier: overwhelm vs boredom vs fear)
  4. "When you blow off your own plan, what's the worst thing I could say to you?" (RSD / tone)
  Grounded in real ADHD-coach intake practice (Practice.do questionnaire, Tandem/ADDCA, Calm Seas). Principle: a human coach asks ~14 because they can't see you; ours watches, so ask only the subjective/environmental/relational and LEARN the rest.

## Three-tier memory
- **Tier 1 — onboarding (4 Qs above)** → seeds `coach_memory.profile`.
- **Tier 2 — learned silently** from telemetry (real focus hours, time-sink apps, slump windows, session lengths, which goals get progress vs avoidance). No asking.
- **Tier 3 — asked one at a time at the right moment**, saved as memory ("that worked — what was different?" after a great session; "what happened?" after a bad day). The profile is LIVING + user-visible/editable (the "what your coach knows about you" page).

---

## MVP scope (usable TODAY) — what we build now

### 1. Backend `/coach/chat` (new endpoint)
- POST `/coach/chat` {messages: [{role, content}...], }, X-Device-ID auth. Assembles the SAME context the decision path uses (profile + week_summary + day_stats + recent today_log) + the conversation, calls DeepSeek with a CHAT charter (warm, plain, ADHD-coach tone, C3 rules: never fake-human, never "get back to work", strengths-first), returns:
  ```json
  { "reply": "<conversational text>",
    "proposed_focus": { "title": "Interview prep — coding", "intent_text": "...", "target_minutes": 240 } | null }
  ```
- `proposed_focus` is emitted ONLY when the conversation has converged on a concrete focus + the user signalled they want to start (the model decides; structured-output gated). The UI renders it as an accept button. NOTHING is created server-side by the chat — creation happens when the user taps accept (agency principle).
- Chat charter is a NEW prompt (not the decision charter): it's allowed to converse, ask ONE breaking-down question at a time, propose a focus + target. It still cannot change rules/unlock/mint allowance/message the partner.
- Bench: a small `coach_bench/chat_scenarios` (≥8) — must (a) never fabricate "you said X" unless in profile, (b) converge to a sensible proposed_focus for the interview case, (c) NOT propose a focus prematurely (mid-exploration), (d) hold tone. Wrong-speak style gate before ship.

### 2. Daily Focus gains a target (migration 033 — DONE, awaiting apply)
- `daily_focus.target_minutes` (aim-for). `created_via='chat'`. Backend `/daily_focus` create accepts target_minutes + created_via='chat'. New: `GET /daily_focus/today` already returns the row; add `progress_minutes` (sum of today's focus_sessions durations linked to this daily_focus_id, OR matching intent for unlinked) so the UI/coach can show "2.1 of 4h".

### 3. Dashboard chat surface (Today tab)
- A chat panel on the Today tab (dashboard.html / its JSX): message list + input; POSTs to `/coach/chat` via the existing bridge → MainWindow → BackendClient. When `proposed_focus` returns, render an inline "▶ Start: Interview prep · target 4h" button → CREATE the daily_focus (created_via=chat, target_minutes) + start a floored session against it (reuse startDailyFocusSession path). Progress chip "2.1 / 4h" on the Today focus slot.
- WKWebView constraints: no window.prompt/alert; use existing modal/toast patterns; chat is in-page HTML.

### 4. Coach awareness of the target
- The decision-path context (day_stats / week_summary assembly) gains today's daily_focus title + target + progress, so nudges/credit can reference pace ("you're at 2 of 4 hours on interview prep"). Small addition to the context builder.

## OUT of MVP (fast-follow)
- Pill quick-chat surface (dashboard first).
- The 4-question onboarding UI + profile editor page (the chat works without a seeded profile — just more generic; seed it next).
- Structured sub-task storage (the breakdown is conversational for now — the coach talks you through it, doesn't persist a checklist).
- Tier-3 timed questions automation.

## Build order
1. Backend `/coach/chat` + chat charter + bench (verifiable headless).
2. Backend daily_focus target_minutes wiring + progress in /daily_focus/today + decision-context target awareness.
3. Mac/dashboard: chat panel on Today tab + accept→create+start + progress chip.
4. Live GUI verify the interview-prep flow end to end.

## Risks / honesty
- Migration must be applied by Ameer (no DB access) — flagged, SQL provided.
- The chat is text-only MVP; voice later.
- Without the onboarding profile seeded, day-1 chat is more generic — acceptable; it still has telemetry context + week goals.
