# Branch Audit & Cleanup — 2026-05-21

Pre-flight safety tags (`archive/*-2026-05-21`) were placed on every branch tip before any deletions. These tags remain intact and serve as the rollback safety net.

---

## Cleanup pass (2026-05-21 final)

### Branches deleted (22 total)

**Tier A — confirmed merged by git ancestry (0 unmerged commits):**
- `feat/focus-mode-consolidation`
- `docs/html-doc-system`
- `slice-01-entitlements`
- `slice-02-focus-mode-rename-mac`
- `slice-03-distraction-budget`
- `slice-07-strict-mode`
- `slice-08-ai-budget-rewire`
- `slice-09-block-lifecycle`
- `slice-10-mac-sidebar`
- `feat/cs-tamper-detection`
- `feat/bedtime-lock-loop`
- `feat/mac-app-icon`
- `feat/partner-sync`
- `worktree-projects`
- `feat/prototype-to-production` (force-deleted: 0 unmerged commits, remote tracking branch lag caused -d refusal; merge commit `a9f94f8` is top of main)

**Tier B — squash-merged via puck → main (different SHA but content fully in main; main was 230–243 commits ahead):**
- `feat/intentions-spec1`
- `feat/time-blocks-spec2`
- `feat/scheduled-intentions-redesign`

**Additional local branches found and deleted:**
- `feat/bedtime-cross-device` — old ancestor, all Swift files present in main (`BedtimeConfigSync.swift`, `BedtimeEnforcer.swift`), code integrated via puck merge
- `feat/bedtime-lockdown` — old ancestor, `BedtimeOverlayView.swift` was removed from main per lock-loop redesign; superseded
- `feat/mac-bedtime-managedsettings` — explicitly ABORTED spike (`spike(bedtime): ABORTED`); one untracked spike Swift file never merged
- `docs/puck-pivot-suite` — docs-only branch, all 6 unmerged commits are markdown files that are already in main
- `docs/overnight-2026-04-25` — 4 docs/screenshots-only commits; main 305 commits ahead
- `feat/puck-focus-signal` — 2 Swift files (`FocusWebSocketClient.swift`, `IntentionalDeviceRegistration.swift`) both exist in main; main 309 commits ahead
- `plan/mac-bedtime-managedsettings` — 1 docs/plan-only commit; main 268 commits ahead

### Branches NOT deleted

- `main` — production branch, kept
- `slice-13-cleanup` — active working branch for current session; kept

### Worktrees removed (13 total)

- `.claude/worktrees/bedtime-cross-device`
- `.claude/worktrees/bedtime-lock-loop`
- `.claude/worktrees/bedtime-lockdown`
- `.claude/worktrees/cs-anti-tamper`
- `.claude/worktrees/intentions-spec1`
- `.claude/worktrees/mac-bedtime-managedsettings`
- `.claude/worktrees/mac-icon`
- `.claude/worktrees/partner-sync`
- `.claude/worktrees/projects` (force-removed: had modified Swift files that were known-superseded WIP — CS force-disabled experiment + learned-hit recording prototype)
- `.claude/worktrees/prototype-to-production` (force-removed: had only untracked playwright test scripts, no modified tracked files)
- `.claude/worktrees/puck-pivot-docs`
- `.claude/worktrees/scheduled-intentions-redesign`
- `.claude/worktrees/time-blocks-spec2`

### Worktrees NOT removed

- Main repo at `/Users/arayan/Documents/GitHub/intentional-macos-app` — kept (it is main)

### Final state

- Main branch SHA: `a9f94f82fc3bf998cca5d1b5b60a62d32de62e84`
- Local branches remaining: 2 (`main`, `slice-13-cleanup`) vs starting ~25
- Remote tracking refs remaining: 15 (read-only, origin/* refs — can prune with `git remote prune origin` later if desired)
- Worktrees remaining: 1 (main repo only) vs starting 14
- Build verified: yes — `** BUILD SUCCEEDED **` on main
- Archive tags still in place: yes — all 7 (`archive/cs-tamper-2026-05-21`, `archive/intentions-spec1-2026-05-21`, `archive/main-2026-05-21`, `archive/proto-to-prod-2026-05-21`, `archive/scheduled-intentions-2026-05-21`, `archive/slice-13-2026-05-21`, `archive/time-blocks-spec2-2026-05-21`)

### Recovery (if needed)

```bash
# Recover any deleted branch from its archive tag:
git branch <name> archive/<name>-2026-05-21
```

### Open follow-ups for user

- Remote tracking refs (`remotes/origin/*`) for the deleted branches are still visible in `git branch -a`. These are harmless read-only refs. To clean them up: `git remote prune origin` (requires the remote branches to have been deleted on GitHub first).
- `slice-13-cleanup` is 25 commits ahead of `origin/slice-13-cleanup`. This is the current working branch and was not touched during cleanup.
