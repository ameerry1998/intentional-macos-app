# Bedtime Config Cross-Device Sync — 2026-04-30 hand-off

**Goal:** when bedtime is enabled (or hours change) on one device, the other device picks it up automatically without re-entry.

**Status:** shipped on `intentional-macos-app:feat/bedtime-lock-loop`. iPhone side already had `BedtimeScheduleService` / `IntentionalBedtimeClient` (shipped earlier). Backend already had `GET/PUT /bedtime/config` upsert keyed by `account_id`.

## Problem observed (April 30, 00:22)

User reported the iPhone showed bedtime off, but the Mac kept locking the screen every 10s (lock-loop firing). Local `bedtime_settings.json` on Mac said `enabled:true`. Direct curl of `GET /bedtime/config` confirmed backend agreed with Mac (last write was the Mac's, on 2026-04-29T00:59:58Z) — iPhone's local "off" was never PUT to the backend.

Root cause: the lock-loop branch was forked off a base that **predated** the original `BedtimeConfigSync` (which had shipped on the unmerged `feat/bedtime-lockdown` branch). The production PKG that did include `BedtimeConfigSync` was a different lineage. The lock-loop branch's PKG would have lacked it entirely.

## What shipped

Single commit `b5884e7` on `feat/bedtime-lock-loop`:

| File | Change |
|---|---|
| `Intentional/BedtimeConfigSync.swift` | NEW. Pulls `/bedtime/config` on launch + `didBecomeActive` + 60s timer. Encodes DTO format on disk. One-time migration of legacy local format → backend. |
| `Intentional/BackendClient.swift` | Added `BedtimeConfigDTO` + `BedtimeTimeOfDayDTO` + `getBedtimeConfig()` + `putBedtimeConfig(_:)`. X-Device-ID auth. |
| `Intentional/BedtimeEnforcer.swift` | Added `applyRemoteSettings(_:)` — distinct entry point from `saveSettings(_:)` so the cache write happens via `BedtimeConfigSync` (DTO format) not the legacy path. |
| `Intentional/AppDelegate.swift` | `var bedtimeConfigSync: BedtimeConfigSync?` + init/start after BedtimeEnforcer.start(). |
| `Intentional/MainWindow.swift` | `handleSaveBedtimeSettings` now also fires `BackendClient.putBedtimeConfig(_:)` after the local save so sibling iPhone picks up the change on its next pull. |
| `Intentional.xcodeproj/project.pbxproj` | New file added to target (B + F + S + group entries). |

## End-to-end flow

1. User toggles bedtime in Mac dashboard. `handleSaveBedtimeSettings` writes local `bedtime_settings.json` AND PUTs `/bedtime/config` to backend.
2. iPhone's `BedtimeScheduleService` pulls `/bedtime/config` on next foreground (or every periodic check). Sees the updated config, applies locally.
3. User toggles bedtime on iPhone. `BedtimeScheduleService` PUTs to backend.
4. Mac's `BedtimeConfigSync` pulls within 60s, calls `applyRemoteSettings(...)`, `BedtimeEnforcer` recalculates, lock-loop self-cancels if bedtime now disabled.

Backend upsert on `account_id` means **last write wins**. No clock-skew-based conflict resolution; if both devices write at the exact same moment, the one whose request arrives second wins.

## Tonight's tactical fix (before the new PKG is installed)

1. Curl-PUT to backend with `enabled:false`. Backend now has off.
2. Delete local `bedtime_settings.json`. (Avoids the running PKG's launch-time rewrite via cached state.)
3. `pkill` the Mac app. Watchdog respawns it.
4. On respawn, the running PKG's `BedtimeConfigSync` (yes — it's actually present in the production PKG built April 28; it was the lock-loop branch alone that lacked it) pulls backend → sees off → writes new local file → `BedtimeEnforcer.recalculate` sees `enabled:false` → state stays `.inactive`.
5. Mac no longer locks tonight.

The backup of the original local file is at `bedtime_settings.json.bak-2026-04-30` if the user needs to revert.

## What's left

- Manually verify when user wakes: iPhone-side toggle should propagate to Mac within ~60s on the new PKG.
- Eventually merge `feat/bedtime-lock-loop` (this branch) → main. Preserves SACLockScreenImmediate fix + cross-device bedtime config sync + duration-aware unlock + everything else from the lock-loop work.

## Companion notes

- See `docs/cross-repo-partner-sync-2026-04-30.md` (on `feat/partner-sync` branch) for the sibling-sync architecture pattern this borrows from.
- See `docs/overnight-run-2026-04-30.md` (on `feat/partner-sync` branch) for the broader overnight summary.
