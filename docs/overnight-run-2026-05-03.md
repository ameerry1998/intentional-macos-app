# Overnight Run — 2026-05-03 — Spec 1: Unified Intentions

**Started:** 2026-05-03 (autonomous overnight)
**Branch convention:** `feat/intentions-spec1` in all three repos
**Spec:** `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md`

---

## TL;DR for the morning

(Updated continuously as work progresses. Final summary at bottom.)

---

## Repos & branches

| Repo | Path | Base | Feature branch | Worktree |
|---|---|---|---|---|
| Mac | `intentional-macos-app` | `puck` | `feat/intentions-spec1` | `.claude/worktrees/intentions-spec1` |
| Backend | `intentional-backend` | `main` | `feat/intentions-spec1` | `.claude/worktrees/intentions-spec1` |
| iOS | `puck-ios` | `main` | `feat/intentions-spec1` | `.claude/worktrees/intentions-spec1` |

---

## What I can do tonight (autonomous)

- Write & commit code on feature branches in all 3 repos
- Run all unit + integration tests locally; gate on green
- Run Mac build (`xcodebuild`) and Python tests (`pytest`)
- Cross-link spec ↔ plan ↔ code in commit messages
- Document everything in this log

## What requires you in the morning

- **Backend:** Push `feat/intentions-spec1` to remote, deploy to Railway. Run migration `018_add_intentions.sql` via Supabase SQL editor.
- **Mac PKG:** sign + notarize a fresh build via `./scripts/build-pkg.sh` if you want a distributable binary
- **iOS:** open Xcode, run on a real device or simulator. The DeviceActivity / FamilyControls path needs a real iPhone for full E2E.
- **Cross-device smoke test:** install both clients, create an Intention on Mac, tap Start, verify iPhone shields within 5s.

---

## Phase tracker

- [x] Phase 1 — Spec written (committed `fa868ff`)
- [ ] Phase 2 — Plans written (A/B/C)
- [ ] Phase 3 — Backend implementation
- [ ] Phase 4 — Mac implementation
- [ ] Phase 5 — iOS implementation
- [ ] Phase 6 — Final verification + handoff

---

## Plans

| Plan | File | Status |
|---|---|---|
| A — Backend | `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-a-backend.md` | (writing) |
| B — Mac | `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-b-mac.md` | (writing) |
| C — iOS | `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-c-ios.md` | (writing) |

---

## Live progress log

### Phase 1 — Spec (DONE)
Spec doc committed `fa868ff` on `puck`. Vocabulary locked: Intention/Time Block/Session/Goal. Decisions locked: 1A/2A/3A/4A/6A/7A/8A/9A. Bedtime stays separate. Puck behavior unchanged in Spec 1.

### Phase 2 — Plans (in progress)
(Updates will append here as plans land.)

