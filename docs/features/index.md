# Intentional — Feature Documentation

Engineering reference for the Intentional macOS focus enforcement platform.
One doc per feature. Each doc is the authoritative source for how the feature works,
its data flow, failure modes, and decision history.

---

## Mac Features

| Feature | Status | Doc |
|---------|--------|-----|
| Focus Sessions | shipping | [focus-sessions.md](focus-sessions.md) |
| Schedule Manager | shipping | coming soon |
| Focus Monitor | shipping | coming soon |
| Earned Browse | shipping | coming soon |
| Blocking Profiles | shipping | coming soon |
| Block Start / End Rituals | shipping | coming soon |
| Context Switching Overlay | shipping | coming soon |
| Content Safety Monitor | shipping | coming soon |
| Strict Mode Watchdog | shipping | coming soon |
| Intentions (cross-device presets) | shipping | coming soon |
| Close the Noise Sweep | shipping | coming soon |
| Bedtime Enforcer | shipping | coming soon |
| AI Relevance Scoring | shipping | coming soon |
| Partner Sync | shipping | coming soon |
| Switch Intervention Coordinator | shipping | coming soon |

## Backend Features

| Feature | Status | Doc |
|---------|--------|-----|
| Focus Toggle API (`/focus/toggle`, `/focus/active`) | shipping | coming soon |
| Intentions API | shipping | coming soon |
| Partner Endpoints | shipping | coming soon |

---

## How to use this site

- Each doc has a **TL;DR** at the top, a Mermaid architecture diagram, a data-flow sequence diagram, a files table, and a failure-modes table.
- The `last_verified` frontmatter field tells you when someone last checked the doc against the code. If it is stale (> 60 days), run `./scripts/check-docs.sh` to surface it.
- `./scripts/check-docs.sh` also validates that every file listed in frontmatter `files:` still exists. Missing files are errors, not warnings.

## Running locally

```bash
/Users/arayan/Library/Python/3.9/bin/mkdocs serve
```

Then open `http://localhost:8000`.
