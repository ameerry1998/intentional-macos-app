# Settings Consolidation (post-calm-down) — Design

**Date:** 2026-06-10 · **Status:** approved (user, in-session) · **Scope:** Mac app. Blocks/Allowed/Distractions consolidation explicitly EXCLUDED (separate deep-planning track, see docs/blocks-consolidation-research-2026-06-10.md when it lands).

## S1. Debug test hook (build FIRST — unblocks fast verification)
DEBUG-builds-only (`#if DEBUG`, must not exist in release): the app watches
`/tmp/intentional-uitest-cmd.json` ({"id": N, "js": "..."}); on change, evaluates the JS in
the dashboard WKWebView and writes {"id": N, "result"/"error"} to
`/tmp/intentional-uitest-result.json`. Enables instant selector-clicks + DOM-state reads
during verification instead of synthesized mouse events.

## S2. Kill the AI Scoring settings page
- Remove the page + its Settings row. Hardcode Qwen3-4B (delete the Apple FM model option
  and the model picker; keep `SET_AI_MODEL` handler as no-op one cycle).
- "Focus Profile" editing moves to the Account page (its current "Edit profile" button is
  broken anyway — it just navigates to Today). Place beside the existing About-Me editor.

## S3. Sensitive Content into Settings
- Rename the Settings row "Content Safety" → "Sensitive Content"; its detail page becomes
  the (already-simplified) Sensitive Content page content.
- Remove the standalone "Sensitive Content" sidebar tab. Sidebar = Today / Plan /
  Accountability / Settings (4 items). Partner lock + state guard untouched.

## S4. Focus Mode settings page → merge into Strictness
- Inspect what's uniquely on the "Focus Mode · Interventions & screen lock" page first;
  move any non-duplicate control (e.g. screen lock) into Strictness → Advanced; delete the
  page + row. No feature loss.

## S5. Account row subtitle
- Fix the menu row stuck on "Loading…" (page works; subtitle never updates).

## Verification
Build green; then GUI pass (use S1 hook where possible): 4-item sidebar renders; Sensitive
Content reachable under Settings with lock intact; AI Scoring row gone; Focus Profile
editable+saving under Account; Strictness Advanced contains migrated controls; Account
subtitle correct. Every touched control clicked/exercised.
