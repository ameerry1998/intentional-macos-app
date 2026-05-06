# Slice 13 — Cleanup Deletion Checklist

> Slice 13 of 2026-05-05 redesign per `docs/superpowers/plans/2026-05-05-app-redesign-plan.md`.
>
> **Run this AFTER slices 1–12 are stable for ≥2 weeks of real-world use.** Premature deletion can re-introduce regressions that the slice plans deliberately avoided by leaving fallback paths in place.

This is a checklist, not a code change. Each item is "safe to delete when no live code path references it." Verify with grep + manual audit before each deletion.

## Backend (`intentional-backend`)

- [ ] **Legacy `/intentions/*` route aliases** (added in slice 2 alongside `/focus_modes/*` twins). Once Mac + iOS clients stop calling `/intentions`, drop the `@app.X("/intentions/...")` decorators from `main.py`. Search for `"/intentions"` in client repos to verify zero callers.
- [ ] **`Intention*` Pydantic models** in `models.py`. After all clients are on `FocusMode*` types and the legacy aliases are removed, delete the `Intention*` classes themselves. Also drop the `FocusModeCreate = IntentionCreate` style aliases (since they'll no longer have a target).
- [ ] **`intentions` SQL view** (created in `migrations/022_focus_modes_rename.sql`). Once no client + no internal code reads from `intentions`, drop the view. Add a `migrations/0XX_drop_intentions_view.sql`.
- [ ] **Legacy `/schedule/blocks` redirects** (`main.py` lines ~4001 + ~4008). Per inventory zero callers; safe to drop now if confirmed.
- [ ] **`/partner/dashboard/*` endpoints** (4 routes). Per inventory zero callers; drop. Confirm via grep across client repos.
- [ ] **`/ws/focus` websocket** if Mac never migrates from polling to ws (inventory says it doesn't). Drop if true.
- [ ] **`migrations/020` columns** (`weekly_budget_hours`, `budget_enforcement`, `derived_from_budget`) — these are spec-prep with no current readers. Re-evaluate post slice 6 (Focus Lock) to see if they get used; otherwise drop in a future migration.

## Mac (`intentional-macos-app`)

- [ ] **`BlockingProfileManager.swift`** — marked `@available(*, deprecated)` in slice 2. Delete the file once all `BlockingProfileManager.shared` references are removed (grep should be zero).
- [ ] **`ProjectStore.swift`** + project-related code paths — per inventory, replaced by IntentionStore in Spec 1. Verify zero references; delete.
- [ ] **`IntentionalModeController` references** — controller was deleted in TimeState consolidation (per CLAUDE.md item 11) but stale references may remain. Grep `IntentionalModeController` and clean up.
- [ ] **Settings → Focus Mode toggle JS** in `dashboard.html` — per inventory, dead code (UserDefault wiped on launch). Find the JS handler + DOM elements and remove.
- [ ] **Force-a-plan code paths** flagged with TODO in `FocusMonitor.swift:~1634`. Slice 6's Focus Lock now provides the same enforcement; remove the dead old-style force-a-plan code if any remains.
- [ ] **Legacy `*_PROJECT_*` bridge handlers** in `MainWindow.swift`. Per inventory, deprecated aliases for one cycle; cycle is over.
- [ ] **14 legacy branches in `dashboard.html` Intentions tab** — per inventory §9. Audit and delete the dead branches.
- [ ] **Pages folded into Settings** (`page-distractions`, `page-sensitive`, `page-weekly`, `page-lock`) — slice 10 hid these from the sidebar but left the DOM nodes. Once Settings sub-sections render the same content in-place, delete the orphan page divs.
- [ ] **Mac typealiases for FocusMode** in `Intention.swift` and `IntentionStore.swift` — once internal Swift code is fully renamed, drop the typealiases.

## iOS (`puck-ios`)

- [ ] **`Intention.swift`** — once iOS code uses `FocusMode` everywhere (the SwiftData class) or the merge spec lands, delete the standalone Codable struct. Slice 2 deferred this because the SwiftData `FocusMode` and Codable `Intention` serve different purposes; merge needs separate spec.
- [ ] **Hidden tab views removed in slice 11**: `IntentionsTabView`, `WakeView`, `PartnerView` — once their sub-section equivalents render in `SettingsView`, delete the orphan tab views.
- [ ] **Dead views** (per inventory §9): `RoutineView`, `HabitGoalCreationView`, `WeeklyReportSheet`, `CalendarTimelineView`, `QuickBlockButton`, `ScheduleBlockEditSheet`, `ScheduleBlockDetailSheet`, `NetworkClient` (superseded), `ModePickerSheet` (never wired). Verify zero references; delete.
- [ ] **Legacy SwiftData models**: `PuckSchedule`, `ScheduleBlock`, `IntentionalBlock`. Verify no @Model registration consumers; delete.
- [ ] **`PUCK_ALARM_ONLY_MODE` flag** (slice 12) plus the daytime NFC code paths it gates — once daytime tap-to-toggle has been disabled for a release cycle without complaints, physically remove those code paths and the flag itself.

## Cross-cutting

- [ ] **Slice-N branches** that have been merged to main → delete with `git branch -d slice-NN-<name>`.
- [ ] **Stale TODOs** referencing deferred work that's now done — grep for `TODO(slice 6+)`, `TODO(slice 7)`, etc., and remove the ones that are no longer applicable.
- [ ] **Inventory + synthesis docs** at `docs/inventory-{mac,ios,backend}-2026-05-04.md` — these are point-in-time snapshots from before the redesign. Move to `docs/archive/` rather than delete (they're useful historical context).

## Verification commands

Before deleting anything, run:

```bash
# Confirm no client calls a legacy backend endpoint:
grep -rn '/intentions' /Users/arayan/Documents/GitHub/intentional-macos-app /Users/arayan/Documents/GitHub/puck-ios

# Confirm no Mac code uses BlockingProfileManager:
grep -rn 'BlockingProfileManager' /Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/

# Confirm no iOS code uses RoutineView:
grep -rn 'RoutineView' /Users/arayan/Documents/GitHub/puck-ios/Puck/

# (etc. — run for each item above)
```

If grep returns matches, fix the callers BEFORE deleting. Don't ship a deletion that breaks builds.

---

**TL;DR:** Slice 13 is a deletion checklist, not a code change. Run after slices 1–12 are stable. Each deletion needs a grep-verify pass first. Don't speed-run this.
