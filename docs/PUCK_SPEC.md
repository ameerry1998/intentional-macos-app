# Product Vision — Puck Integration

Puck is the physical product. Intentional is the software. Together they form one system.

## Two-Device Philosophy

**Phone (Puck iOS):** Simple on/off blocker. Tap Puck → distracting apps blocked. Tap again → unblocked. No AI, no scheduling. The phone is a distraction machine — Puck just limits how much of it you get.

**Laptop (Intentional macOS):** Smart focus enforcement. Tap Puck (or toggle in app) → blocking mode starts. Optionally set an intention ("What are you working on?") for AI-powered relevance scoring. The laptop is a work tool — Intentional keeps you on task.

## Core Interaction

The Puck is a two-feature device:
1. **Alarm clock** — tap phone on Puck to dismiss the alarm
2. **Blocker toggle** — tap to start blocking, tap again to stop

The macOS app mirrors this simplicity: one toggle between blocking ON and blocking OFF.

## Blocking Modes

| Mode | With Intention Set | Without Intention |
|------|-------------------|-------------------|
| Blocking ON | Smart blocking — AI scores relevance. Educational YouTube? Allowed. YouTube Shorts? Blocked + nudge. | Dumb blocking — all distracting sites blocked, no exceptions. |
| Blocking OFF | Everything open, no monitoring. | Everything open. |

Setting an intention is optional but upgrades blocking from dumb to smart.

## What to Keep (Puck Branch)

- **RelevanceScorer** — AI focus scoring (opt-in "AI Coach" feature, toggle on/off)
- **FocusMonitor** — enforcement during blocking (nudges, red screen, overlays)
- **ContentSafetyMonitor** — NSFW screen detection, blocks screen on explicit content, notifies accountability partner. Like Covenant Eyes but more accurate and blocks in real-time. Polls every 2 seconds.
- **GrayscaleOverlayController** — progressive desaturation during distraction
- **NEFilterDataProvider** — system-level site blocking across all browsers (no extension needed)
- **WebsiteBlocker** — AppleScript fallback for browsers without NE support
- **Distracting sites/apps list** — user-configured, its own tab
- **Accountability partner** — for Content Safety notifications and settings locking
- **Browser extension** — optional sensing layer (page content for AI scoring), NOT required for blocking

## What Changed (Puck Branch — April 2026)

- **ScheduleManager** — STRIPPED. Schedules are removed; Puck on/off is the primary model. No daily schedule planning.
- **EarnedBrowseManager** — KEPT. Earned browse is the pressure valve for always-active blocks.
- **TimeTracker** — strip (no usage tracking/budgets)
- **Block rituals (start/end)** — strip (no ceremonies)
- **PlanningCoach** — already removed
- **BlockingProfile: always-active toggle** — Per-profile `isAlwaysActive` flag. When ON, profile is enforced 24/7 (free time doesn't override; only earned browse or partner code can bypass). When OFF, profile only blocks during active focus sessions.

## New Systems (April 2026)

- **BlockingProfileManager** — Reusable named profiles of blocked domains + app bundle IDs. One default preset ships out of the box. Stored in `blocking_profiles.json`.
- **FocusModeController** — Single source of truth for is-app-enforcing (3 states: off/focus/bedtime). Replaces the deleted FocusSessionManager + IntentionalModeController. On-demand focus (Puck tap) calls `focusModeController.activate(source: .puck)`. Survives block changes; state fans out to FocusMonitor, SwitchInterventionCoordinator, SocketRelayServer.
- **FocusStartOverlay** — Full-screen SwiftUI overlay shown on focus trigger. Profile picker + AI intention field. Puck mode skips straight to "Just Block Distractions."
- **BedtimeEnforcer** — Fixed nightly bedtime with 15-min wind-down, one snooze, 3-min auto-sleep countdown. Independent of schedule system.
- **TrustedClock** — Monotonic drift detection + NTP re-anchoring to prevent clock-change bypass.
- **QuitPolicy** — Extracted quit decision logic. Allows quit when daemon is running (daemon relaunches app for permission changes like Screen Recording).

## Puck Tap Behavior

When Puck tapped: default "Distracting Apps & Sites" profile activates immediately (non-negotiable floor). User can optionally plan additional profiles + AI intention. No free time exists during Puck focus. Only Puck re-tap ends the session.

Always-active profiles are enforced regardless of Puck state — they block 24/7. Puck tap adds session-only profiles on top. Non-always-active profiles only block during active sessions. Schedules are stripped; Puck on/off is the primary model.

Mock trigger: `Cmd+Shift+P` global hotkey (menu bar: "Toggle Focus"). Real Puck signal via backend WebSocket (see `intentional-backend/docs/prd-focus-signal-api.md`).

## Extension Role Change (Puck Branch)

The extension's role changes significantly:
- **Keeps:** Reading page titles/content and sending to the macOS app for AI relevance scoring
- **Loses:** All in-browser blocking logic. NEFilterDataProvider handles blocking at the network level now.
- NEFilterDataProvider = hard blocks for always-bad sites (porn, TikTok). Binary block/allow per domain.
- Extension = sensing layer for gray-area sites (YouTube, Reddit, Twitter) where AI needs page content to judge relevance.
- ContentSafetyMonitor = catches explicit images that slip through on allowed sites.

## Puck Tap → Both Devices

When the user taps the Puck, both devices respond simultaneously:

| | Phone | Laptop |
|---|---|---|
| **Tap ON** | Distracting apps locked | Distracting sites blocked + optional AI focus |
| **Tap OFF** | Everything open | Everything open |

## Puck Branch: Website Blocking Changes

- **No hardcoded blocked domains** — `WebsiteBlocker.coreDomains` removed. Entirely user-configured via dashboard Distracting Websites list.
- **No PINNED_SITES in dashboard** — all sites shown in one flat user-editable list
- **BrowserMonitor reports ALL browsers** to WebsiteBlocker — extension-installed browsers are NOT exempt from blocking (extension is sensing-only in puck branch)
- **blocked.html** shows "This site is blocked during focus time" instead of "Install Extension" nag
- **Extension puck branch** — ~3,890 lines of blocking code commented out. Keeps ML classification, DOM extraction, native messaging. Strips all UI overlays, session timers, intent prompts, zen screens.
