# Cross-repo log — Focus Agent S1+S2 (2026-06-12)

Authoritative hand-off for the Focus Agent's first two slices (eval bench + shadow mode). Spec: `docs/superpowers/specs/2026-06-12-focus-agent-design.md` · Plan: `docs/superpowers/plans/2026-06-12-focus-agent-s1-s2.md` · Feature doc: `docs/features/focus-agent.md`.

## What shipped

**intentional-backend (main, pushed + deployed via `railway up`):**
- `3c1588e` migration 029 (coach_events / coach_decisions / coach_memory, RLS) — **applied to Supabase by Ameer 2026-06-12**
- `0282857` coach_prompts.py (charter + cache-layered assembly)
- `69bd49d` coach_agent.py (DeepSeek client, decide(), code-level caps, fail-closed parsing)
- `1f86771` POST /coach/telemetry (store + 5-min-throttled shadow reasoning) + GET /coach/decisions
- `1e05dc4` coach_bench: 50 labeled scenarios + runner with wrong-speak gate
- `fcdf967` charter tuned on bench: **accuracy 86%→100%, wrong-speak 7→0/50** (3 iterations; fixes were definitional: credit needs 20+ continuous out-of-session minutes; one-site drift = nudge never rescue; multi-app thrash = rescue never nudge)

**intentional-macos-app (main):**
- `7783f4c` CoachTelemetry.swift (60s sample / 180s flush, names-only privacy, 400-event re-queue ring) + BackendClient.postCoachTelemetry + AppDelegate wiring (incl. correct session_end goal via endedPeriod snapshot)
- Feature doc + this log

## Verified live (2026-06-12 ~09:00 ET)

- Coach endpoints live on production (post Railway plan payment — trial had expired and blocked deploys).
- First real flush: 12 events. First real shadow verdict: **silence** — "user switching between iTerm2 and Chrome… no commitment exists, silence is safest" (deepseek-chat, 953 prompt / 48 completion tokens, shadow=true).
- DeepSeek key in Railway vars + local gitignored .env.

## Model notes

- deepseek-chat (V4 Flash class): 100% on tuned bench. ~$0.10–0.20/user/mo at current cadence.
- deepseek-reasoner: 74% — reasoning consumes the max_tokens=300 cap → truncated JSON → fail-closed silences. Don't use without raising the cap; not needed.

## Outstanding / next

1. **Let shadow data accumulate** on Ameer's machine for a few days; review `GET /coach/decisions` for judgment quality on real life (the bench's 12–21-min credit gray zone especially).
2. **S3 (separate plan):** first visible action — generic coach card in the pill, nudge only, cap 1/day initially. Gate passed on bench; real-shadow review is the second gate.
3. S4–S6 per spec: credit/celebrate/rescue → conversation → ritual bookends + memory writers (diary/profile).
4. Bench follow-ups: add 12–21-min credit scenarios; measure run-to-run variance (single-run temp-0 today).
5. Teardown items still queued (separate from agent): protection-truth fix (#2 in teardown), state-vocab sweep, onboarding sweep suppression, PKG cold-install test (launch checklist 4/5).
