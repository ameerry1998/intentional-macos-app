# Cross-Repo Log — 2026-05-04 — Scheduled Intentions Redesign

**Started:** 2026-05-04 (overnight, autonomous)
**Branch convention:** `feat/scheduled-intentions-redesign` in all three repos
**Predecessors:** Spec 1 (Intentions) + Spec 2 (Time Blocks) — both code-complete on `feat/intentions-spec1` + `feat/time-blocks-spec2`. THIS work assumes those branches are merged or internally merged into our branches.
**Spec:** `docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md`
**Plans:**
- A — Backend: `docs/superpowers/plans/2026-05-04-scheduled-intentions-redesign-plan-a-backend.md`
- B — Mac: `docs/superpowers/plans/2026-05-04-scheduled-intentions-redesign-plan-b-mac.md`
- C — iOS: `docs/superpowers/plans/2026-05-04-scheduled-intentions-redesign-plan-c-ios.md`

---

## TL;DR (continuously updated; final summary at bottom)

(Pending — executors not yet dispatched.)

---

## Locked decisions from spec (D1-D14)

Reference for executors. Don't relitigate.

- **D1** Block editor's Profile chips REPLACED by Intention picker. Migration: existing profiles → Intentions one-shot.
- **D2** Per-platform iPhone-app blocklist via FamilyActivityPicker (privacy-locked surface — Mac shows read-only).
- **D3** iPhone first-launch onboarding includes FamilyActivityPicker step + 0-apps banner in Intentions list.
- **D4** Three strictness presets: Strict / Standard / Soft.
- **D5** Direction-locked. Tightening = instant. Standard → Soft = 24h cool-down. Strict → anything = partner-unlock-required.
- **D6** Strictness CANNOT change while a Session of that Intention is currently running.
- **D7** Mac + iPhone calendars must support same set of editable fields including active-days.
- **D8** Sidebar restructure on Mac: promote Sensitive Content from Settings; add Weekly Planning placeholder.
- **D9** Schema prep for budgets — nullable `weekly_budget_hours` + `budget_enforcement` on intentions, `derived_from_budget` on time_blocks. NO behavior code yet.
- **D10** Strictness lives ONLY on Intention, NOT per-block.
- **D11** Bedtime + Wake-up render as SOLID color bands (no gradients) on BOTH platforms. Anchored top (wake) + bottom (bedtime) of day calendar.
- **D12** Intention picker offers "+ One-off block" — single text field, no color/emoji/strictness, neutral grey, Soft default. Full Intention creation lives ONLY in the Intentions tab.
- **D13** Mac calendar gestures (drag/resize/move) DEFERRED to v1.5. Mac keeps existing click-to-create-30-min behavior.
- **D14** Profiles UI tab cleanup MUST be in the next spec written after this one. Don't remove now (data risk during migration window).

---

## Repos & branches

| Repo | Path | Base | Feature branch | Worktree |
|---|---|---|---|---|
| Backend | `intentional-backend` | `main` (with feat/intentions-spec1 + feat/time-blocks-spec2 internally merged) | `feat/scheduled-intentions-redesign` | `.claude/worktrees/scheduled-intentions-redesign` |
| Mac | `intentional-macos-app` | `puck` (with both Spec branches merged in) | `feat/scheduled-intentions-redesign` | `.claude/worktrees/scheduled-intentions-redesign` |
| iOS | `puck-ios` | `main` (with both Spec branches merged in) | `feat/scheduled-intentions-redesign` | `.claude/worktrees/scheduled-intentions-redesign` |

---

## Phase tracker

- [x] Phase 1 — Spec written (committed earlier)
- [x] Phase 2 — Plans written (A directly, B + C via subagents)
- [ ] Phase 2.1 — Worktrees created in all 3 repos
- [ ] Phase 3 — Backend execution
- [ ] Phase 4 — Mac execution
- [ ] Phase 5 — iOS execution
- [ ] Phase 6 — Final cross-repo handoff

---

## Live progress log

### Phases 3-6
(Pending — append reports as executors complete.)
