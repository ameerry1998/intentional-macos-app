# Extension Removal Redo — Progress Log (2026-05-21)

**Why redo?** The first attempt scoped the extension-removal to `slice-13-cleanup` on the main repo, but that branch is BEHIND `feat/prototype-to-production` by 30+ commits of feature work (close-the-noise sweep, Stage 1 intent prompt, Always-Allowed list, Weekly Goals UI, asymmetric AI gate, etc.). The dev build from slice-13-cleanup showed old UI. This redo applies the SAME deletions/refactors but starting from feat/prototype-to-production's current state.

**Working directory:** `/Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/prototype-to-production` (worktree, branch `feat/prototype-to-production`).

**Reference:** `docs/superpowers/inventory-2026-05-21.md` §7 (deletion target) — committed to this branch as `05ebec4`.

**End state:** ONE branch with both feature work + extension removal, ready to merge → main.

## Tasks

- [ ] **1. Foundation** — orphan verification + 3 pure-extension deletes + main.swift strip
- [ ] **2. BrowserMonitor refactor** — strip extension-status, decide BrowserDiscovery/BrowserDatabase
- [ ] **3. Bridge-strip** — MainWindow + AppDelegate + LegacyMonitorView delete
- [ ] **4. Shim cleanup** — FocusMonitor + WebsiteBlocker + delete shim
- [ ] **5. Dashboard + docs + entitlements** — strip extension UI, archive EXTENSION_PROTOCOL, update CLAUDE.md, audit entitlements
- [ ] **6. Final verification + summary doc**
- [ ] **7. Merge feat/prototype-to-production → main** (after smoke test passes)

## Safety guardrails (every subagent prompt enforces)

- NEVER `git push` or `git push --force`.
- NEVER touch sibling repos (`intentional-backend`, `puck-ios`, `puck-partner-dashboard`).
- NEVER strip entitlements from `Intentional.entitlements` — Bug Fix #8.
- NEVER include unrelated dirty/untracked files (`scripts/playwright-tests/package*`, `scripts/vlm-test/`) in commits. Use `git add <specific paths>` always.

## Key difference vs the slice-13-cleanup run

The feature branch has code that DID NOT exist on slice-13-cleanup. These files are NEW and must be KEPT (not stripped):

- `Intentional/AppDelegate.swift::runCloseTheNoiseSweep` — the close-the-noise orchestrator. Already AppleScript-only, no extension involvement. Touches `WebsiteBlocker.readAllTabsAcrossWindows` + `RelevanceScorer.scoreTabBatch`. KEEP.
- `Intentional/SweepReviewWindow.swift`, `Intentional/StageOneIntentWindow.swift`, `Intentional/StashInspectorWindow.swift` — KEEP (post-pivot UI).
- `Intentional/Sweeper.swift`, `Intentional/SessionStash.swift`, `Intentional/AlwaysAllowedList.swift`, `Intentional/SweepBenchmark.swift` — KEEP (close-the-noise data model + benchmark).
- `Intentional/dashboard.html`'s Settings → Always Allowed page + sweep toast — KEEP (these are new, not extension-related).
- The "Hard-Won Lessons" section in CLAUDE.md — KEEP.

If a subagent is unsure whether a piece of code is "extension surface" or "close-the-noise surface", default to KEEP. Better to over-keep than over-delete.

## Done log

(empty — updated as tasks complete)
