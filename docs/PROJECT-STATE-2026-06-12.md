# Project State — 2026-06-12 (READ FIRST after /clear)

Supersedes `PROJECT-STATE-2026-06-11.md` (still valid for pre-coach context). A fresh session should read this + auto-loaded memory (MEMORY.md) before doing anything. Pin model to **Fable 5** in /config first — the model auto-switches to Opus on security-adjacent vocab (TCC, "lock/bypass", code-signing) and that churned cost today.

## Product in one line
macOS focus app, "Intentional", launching this week. AI scores whether you're on-task; you EARN screen-time allowance by focusing; an accountability partner holds you to commitments. **Today's work = the Focus Agent**, the coaching brain.

---

## THE BIG THING BUILT TODAY: the Focus Agent (a coach that watches your day)

**Vision (spec: `docs/superpowers/specs/2026-06-12-focus-agent-design.md`):** local senses → cloud brain. The Mac watches the screen privately; a cheap cloud LLM reasons about it and coaches mostly by staying silent. "Whoop for ADHD." Constitution: the coach can NEVER change rules, unlock strict mode, mint allowance, or message the partner — it persuades; enforcement enforces.

### Architecture (all LIVE + deployed unless noted)
```
Mac (local senses)                         Backend (cloud brain, Railway)        LLM
CoachTelemetry.swift  ──telemetry every 60s + app-switch──> POST /coach/telemetry
  • app/host/title/session/allowance                          • dedupe, throttle ≤1/5min
  • VLMDescriber (Qwen3-VL-4B, on-device) ── one sentence ──> • assemble prompt ──────────> DeepSeek
    "what's on screen" + [category]                           • day_stats (computed)        v4 (deepseek-chat)
  • OCR+Qwen text = fallback when VLM not loaded              • week-goal pace
                                                              • charter (silence-biased)
pill card  <── poll /coach/decisions/pending ──  coach_decisions (shadow=true, except plan_prompt=LIVE)
  DeepWorkTimerController .coachCard            POST /coach/decisions/{id}/outcome (shown/tapped_start/dismissed)
```

### What's real and verified live (2026-06-12)
- **End-to-end loop WORKS**: coach decided plan_prompt → card rendered in pill → user typed → goal created → session started → outcome recorded. All confirmed in backend (timestamps).
- **Telemetry**: app/site/window+tab titles + on-device VLM screen descriptions flowing to `coach_events`. Privacy tiers in `coachTelemetryLevel` UserDefaults: descriptions(default)/titles/names/off. Only generated sentences + names leave the Mac; never pixels/raw OCR.
- **VLM**: Qwen3-VL-4B-Instruct-4bit via MLXVLM (Swift MLX doesn't support Qwen3.5 vision yet — Qwen3-VL was the bench winner anyway). ~8s median / ~10s typical-worst per look (one fat-tail outlier ~30s on dense X feeds). Triggers: 60s floor + app-switch (2s settle, 15s min-gap). NOT yet tab-change triggered. Bench: `vlm_bench/RESULTS.md` (Qwen3-VL 90% / OCR+text 23% on visual content — OCR is fallback only).
- **Coach judgment**: bench at `intentional-backend/coach_bench/` — 72 scenarios, wrong-speak 0/72 twice. Charter includes: silence-biased, intermittent-drift detection, computed day_stats it must trust, plan-prompt bar (ask if planless 2h+ unless 25min+ single-app work stretch), and the **message-faithfulness rule** (NEVER fabricate "you said/mentioned" — caught live when it invented a commitment).
- **Observability**: live feed at `http://localhost:8799` (server: `scripts/dev-tools/coach-feed-server.py`; snapshot: `scripts/dev-tools/coach-feed.sh`). Shows samples, descriptions (engine-tagged), verdicts (shadow/LIVE), and the local describe-pipeline timings. This is the prototype of the in-app "what your coach can see" transparency page that MUST ship.

### Slices done: S1 (bench+charter) · S2 (telemetry+shadow) · S3 (plan_prompt = first visible action, LIVE). Screen-descriptions + judgment-v2 + faithfulness landed on top.

---

## OPEN: the design debt this exposed (do this NEXT — needs a spec, not hot-patches)
The coach works but it's bolted onto a **broken session/goal model**. One root flaw with stacked symptoms (full diagnosis: `docs/superpowers/debugging/2026-06-11-pill-blockless-manual-session.md`):
1. **Daily commitment ≠ weekly goal, but the code makes them the same.** The plan_prompt card does `CREATE_INTENTION` + start session, so ANYTHING typed becomes a permanent Weekly Goal. "idk what to do" became a weekly goal. WRONG.
2. **"I don't know" must route to a help/triage conversation** (the S5 stuck-flow), not create a goal.
3. **No real session duration**: manual/coach sessions inject a fake block ending 23:59 → pill counts down to midnight ("709:35"), hits 0 at 11:59pm, wedges on "Block complete". Broken since 2026-05-17, not the coach's fault.
4. **Sessions invisible in the schedule** ("No blocks scheduled" while Focusing) + **no kill/delete affordance** for a coach/manual session (user's exact May-18 complaint, still true).
5. **Restart mid-manual-session** = pill vanishes (injected block is in-memory only).

**FIXED already today:** in-session focus % (was hardcoded 0 after R6 deleted EarnedBrowseManager's counter — rebuilt from live relevance assessments, `e449783`); fake "+0m" earned chip now hidden not faked.

**Recommendation for Fable:** write a short spec for "a bounded, nameable, killable Daily Focus that is NOT a permanent weekly goal" + "idk → triage" + per-session duration + restart survival, get Ameer's approval, THEN rebuild the slice. Do NOT whack-a-mole the 5 symptoms.

---

## IN FLIGHT (background when this was written)
- **Model bake-off** (`intentional-backend`, uncommitted edits in coach_agent.py/run_bench.py — env-configurable max_tokens, production default 300 unchanged; + token tally): deepseek-chat vs deepseek-reasoner (4000 tok) vs deepseek-v4-pro on the 72-scenario bench, with cost/user/month math + sample-message tone comparison. Results → `coach_bench/results-2026-06-12-bakeoff-*.txt` + a `-model-bakeoff.md`. **Commit those when done; pick the brain by: wrong-speak 0 required, tie-break on message quality.** Ameer's hypothesis: the smarter (thinking/pro) model may write better, less-robotic coach messages — worth weighing vs cost.

## QUEUED Mac fixes (small, from live screenshots)
- Timer-to-midnight (709:35) — folded into the session-model spec above.
- The pill `.blockComplete` wedge on manual sessions — same spec.

---

## DEV ENVIRONMENT — IMPORTANT CAVEATS
- **The Tart test VM was DELETED today** (disk hit 917MB free; VM was 63GB). Re-clone (~30GB base re-download) when the installer cold-test is needed. Until then, GUI testing is on the dev build on Ameer's own Mac (verifier-intentional-gui rules: foreground bursts, restore focus, query live coords).
- **The dev build keeps dying → watchdog respawns PRODUCTION `/Applications/Intentional.app`** (which lacks all coach code). ALWAYS verify which instance is running before trusting a screenshot: `pgrep -lf "Intentional.app/Contents/MacOS"` — DerivedData path = dev (good), /Applications = old prod. Relaunch dev: `./scripts/dev-launch.sh --no-build`. Durable fix (replace /Applications build) needs sudo = Caity.
- **Content Safety is OFF on the dev build** (`enabled=false` since May 17 in onboarding_settings.json). Offered to re-enable; Ameer hasn't said yes. Relevant because the VLM feed showed CSAM-adjacent content today that CS would normally catch. **Flag this to Ameer again.**
- DeepSeek key is in `intentional-backend/.env` (gitignored) + Railway vars. Railway: paid plan active (trial expired earlier today, Ameer paid). Supabase migrations 029/030/031 applied by Ameer.

## Coach feed live URL: http://localhost:8799 (relaunch server if rebooted)

---

## LAUNCH CHECKLIST status (from yesterday's doc)
1-3 (polish/rebrand/onboarding) DONE. Onboarding rebuilt + VM-verified yesterday (`docs/features/onboarding.md`). 4-5 (notarized PKG + cold-install test) BLOCKED on re-cloning the VM. 6 (landing page) done on a branch in puck-site. 7 (iOS) untouched.

## How we worked (process note for Fable)
Coach was built via brainstorming→writing-plans→subagent-driven-development (proper). Later bug-fixing dispatched debug agents directly — each wrote a root-cause doc in `docs/superpowers/debugging/`. Bench-first discipline held throughout (no AI behavior shipped without a wrong-speak=0 gate). Keep it.
