# Puck iOS — Product Inventory (2026-05-04)

Snapshot of every user-facing surface in the Puck iOS app at `/Users/arayan/Documents/GitHub/puck-ios`. Read-only inventory; no source modified.

Repo entry points: `Puck/App/PuckApp.swift`, `Puck/App/PuckAppDelegate.swift`, `Puck/Views/AppView.swift`, `Puck/Views/ContentView.swift`.

Targets: `Puck` (main app), `PuckBedtimeMonitor` (DeviceActivityMonitor extension), `PuckActivities` (Live Activity widget), `PuckShieldConfiguration` (custom shield UI), `PuckShieldAction` (shield button handler), `PuckTests`.

Backend base URL: `https://api.intentional.social` (`Puck/Utils/Theme.swift:13`). Auth has two domains: Bearer (Supabase JWT) and `X-Device-ID` (legacy 64-char hex). Supabase auth client lives at `Puck/Core/Auth/SupabaseService.swift`.

App Group: `group.com.getpuck.app`.

---

## 1. Tab structure

Order is the source-of-truth `enum PuckTab` in `Puck/Views/ContentView.swift:5`. NOTE: enum order and declared `TabView` render order differ — the `body` declares: Home → Schedule → Focus Modes → Alarms → Partner → Settings (lines 80–116). That is the visual order in the app.

| # | Tab | Symbol | Tab title | View | One-line role |
|---|-----|--------|-----------|------|---------------|
| 1 | Home | `house.fill` | Home | `HomeView` | Puck-tap focus dashboard: registered pucks chips, today's stats, focus-modes 2-col grid; renders BedtimeView during active bedtime. |
| 2 | Schedule | `chart.bar.fill` | Schedule | `ScheduleTabView` | Day calendar of recurring TimeBlocks with Wake/Bedtime banners; tap empty-hour to create, tap block to edit. |
| 3 | Focus Modes | `target` | Focus Modes | `IntentionsTabView` | 2-col grid of cross-device-synced Intentions; create/edit, strictness pill on each. |
| 4 | Alarms | `alarm.fill` | Alarms | `WakeView` | Morning alarms list, bedtime hub card, wake-streak; sheets for AlarmEditView/BedtimeDetailView. |
| 5 | Partner | `person.2.fill` | Partner | `PartnerView` | Three-state accountability partner (paired / pending / empty). |
| 6 | Settings | `gearshape.fill` | Settings | `SettingsView` | Account, Pucks list, Emergency unlocks, Notifications, Support; partner-lock indicator. |

`enum PuckTab` declares `routine` (title "Schedule") at index 1 and `intentions` (title "Focus Modes") at index 5; the body re-orders them so users see Schedule and Focus Modes consecutively. The `routine` enum case maps to `ScheduleTabView` despite being named after the legacy `RoutineView`.

Active tint: `DesignTokens.Color.accentPrimary` (coral) for all tabs.

App-wide modal layer (above tabs, `PuckApp` body):
- `BedtimeLockoutWindow` — explicitly NOT attached (`PuckApp.swift:166–174` comment); design pivoted to Live Activity + per-app shield only.
- `.sheet(item: pushRouter.pendingApproval)` → `PartnerApprovalView` for incoming `bedtime.unlock_requested` pushes.
- `.fullScreenCover(showPuckSetup)` → `PuckSetupView` (driven by NFC of unknown slug) — wired from ContentView, not PuckApp.
- `.alert("Wrong Puck", showTapError)` → ContentView shows when coordinator emits `onTapError`.
- `.sheet(showModePicker)` → `ModePickerSheet` (no current callers wire `onShowModePicker`; appears dead).

---

## 2. Per-tab inventory

### Home (`Puck/Views/Home/HomeView.swift`)

Body switches on `bedtimeService.isActive` → `BedtimeView` (in `Puck/Views/Evening/EveningModeView.swift`); else `blockingService.blockingState.isActive` → `activeBlockingContent`; else `idleContent`.

| Control | What it does | API method + path | SwiftData @Model mutated | Cross-device sync? |
|---|---|---|---|---|
| Puck chip (filled) | Tap any registered puck → `nfcService.startScan` then coordinator routing | none direct (focus session → POST `focus/toggle`) | none | yes (focus.toggle backend) |
| Puck chip (`.empty`) | Opens `PuckSetupView` fullScreenCover | none | RegisteredPuck (on save) | no (local) |
| Status footer dot/label | Shows blocking ✕ active | none | none | no |
| Alarm row card | `tabRouter.selection = .alarms` | none | none | no |
| Wake-up bento card | Same — pivots to Alarms tab | none | none | no |
| Blocked-today bento card | Read-only stat | none | none | no |
| Emergency bento card | Read-only ("X left this week") | none | none | no |
| `activeBanner` Unlock-with-Puck button | `nfcService.startScan(...)`; coordinator routes to deactivate same mode or end bedtime via different puck | none direct | FocusSession.endTime | yes |
| ModeTile (per Intention) | Tap card → opens `ModeEditView` for paired FocusMode | none | FocusMode (on save) | partial (Intention is synced; FocusMode not) |
| ModeTile play button | Sets `coordinator.pendingFocusMode`; `nfcService.startScan` to start session via NFC | POST `focus/toggle` (start) on NFC | FocusSession (insert), FocusMode.lastUsedAt | yes |
| ModeTile long-press | Opens "Start Remote Session?" alert | none | none | no |
| Remote-start alert "Start" | Calls `startSessionDirectly(mode:)` — no NFC, just activates | POST `focus/toggle` (start) | FocusSession (insert) | yes |
| `addModeTile` ("+ New mode") | Opens `ModeCreationView` sheet | POST `intentions` after save | FocusMode (insert), Intention (server) | yes |

Sheets owned by HomeView (`HomeSheetsModifier`): PuckSetupView, NFCScanSheet, PuckEditSheet, PuckInfoSheet, ModeEditView, ModeCreationView.

#### Sheet: `ModePickerSheet` (in ContentView.swift:214)

Reachable only when `coordinator.onShowModePicker` fires — not currently wired.

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Mode list row tap | `blockingService.activate(mode:)`, inserts FocusSession | none | FocusSession | yes (start signal) |

#### Sheet: `ModeCreationView` (`Puck/Views/Focus/ModeCreationView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Cancel pill | Dismiss | none | none | no |
| Save pill | Persists FocusMode (and creates Intention) | POST `intentions` (creates Intention) + writes NFC if puck connected | FocusMode (insert), Intention (server) | yes |
| Mode-color picker (8 colors) | Sets local `selectedModeHex` | none | none | no |
| Icon picker | Sets local `iconName` | none | none | no |
| App-blocklist picker (FamilyActivityPicker) | Sets `appTokens` / `categoryTokens` | none | FocusMode tokens | partial |
| Add custom website button | Appends URL string | none | FocusMode.websiteURLs | no |
| Remove website row tap | Deletes from list | none | FocusMode.websiteURLs | no |

#### Sheet: `ModeEditView` (`Puck/Views/Focus/ModeEditView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Cancel pill | Dismiss | none | none | no |
| Save pill | Saves FocusMode + Intention | PUT `intentions/{id}` | FocusMode, Intention | yes |
| Delete-mode danger | Confirm-then-delete | DELETE `intentions/{id}` | FocusMode (delete), Intention (soft-delete) | yes |
| Color tile button | Sets `mode.modeColorHex` | none | FocusMode | no |
| Puck picker row | Open puck picker sheet | none | RegisteredPuck.focusModeId | no |
| Open Intention editor row | `showIntentionEditor = true` | none | none | no |
| Apps row | Opens FamilyActivityPicker | none | FocusMode tokens | partial |
| Add website / Remove website | Mutate `websiteURLs` | none | FocusMode | no |

#### Sheet: `PuckSetupView` (`Puck/Views/PuckSetup/PuckSetupView.swift`)

3-step wizard: pick mode → configure → done.

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Mode selection button | Sets `selectedMode` | none | none | no |
| Create-new-mode button | Inline new mode | none | FocusMode | no |
| Color swatch button | Sets `selectedColorHex` | none | none | no |
| Cancel pill | Dismiss | none | none | no |
| "Configure puck" PrimaryButton | Calls `nfcService.writeMode(slug:)` to write NDEF URI | none | none | no |
| "Done" PrimaryButton | Inserts RegisteredPuck | none | RegisteredPuck (insert) | no |

#### Sheet: `PuckEditSheet` (`Puck/Views/Components/PuckEditSheet.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Cancel | Dismiss | none | none | no |
| Save | Persists puck edits | none | RegisteredPuck | no |
| Assigned mode card / chevron | Opens mode-changer sheet | none | none | no |
| Color swatch | Sets `selectedColorHex` | none | RegisteredPuck.colorHex | no |
| Name field | Sets `name` | none | RegisteredPuck.name | no |
| Location field | Sets `location` | none | RegisteredPuck.location | no |
| Blocked apps row tap | Opens FamilyActivityPicker | none | FocusMode tokens | partial |
| Mode-changer row tap | `startModeRewrite(mode:)` → writes new NFC URI, updates puck.modeSlug | none | RegisteredPuck.modeSlug, .focusModeId | no |
| Delete-puck danger | Confirm-then-delete row | none | RegisteredPuck (delete) | no |

#### Sheet: `PuckInfoSheet` (`Puck/Views/Components/PuckInfoSheet.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Edit puck button | Closes self → opens PuckEditSheet | none | none | no |
| Delete puck danger | Confirm-then-delete | none | RegisteredPuck (delete) | no |
| Done | Dismiss | none | none | no |

#### Sheet: `NFCScanSheet` (`Puck/Views/Components/NFCScanSheet.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Cancel | Aborts NFC session | none | none | no |

#### `BedtimeView` (`Puck/Views/Evening/EveningModeView.swift` — file misnamed, struct is `BedtimeView`)

Replaces idleContent during `bedtimeService.isActive`. Renders moon hero, gratitude AppStorage text input, "complete shortcuts setup" button.

---

### Schedule (`Puck/Views/Schedule/ScheduleTabView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| `+` button (top-right) | Opens TimeBlockEditSheet at next-rounded hour | none until save | TimeBlock (insert via service) | yes |
| DatePicker | Selects display day | none | none | no |
| Wake banner (coral) | Read-only when sourced from alarm/bedtime cfg; placeholder taps to Alarms tab | none | none | no |
| Bedtime banner (lavender) | Read-only when bedtime enabled; placeholder taps to Alarms tab | none | none | no |
| `DayCalendarView` empty hour tap | Opens `TimeBlockEditSheet(create)` | none until save | TimeBlock | yes |
| `DayCalendarView` block tap | Opens `TimeBlockEditSheet(edit)` | none until save | TimeBlock | yes |
| `InteractiveTimeBlockTile` long-press + drag | Move; commits via service.updateBlock | PUT `time_blocks` | TimeBlock | yes |
| `InteractiveTimeBlockTile` resize handles | Top/bottom edge drag; commits via service.updateBlock | PUT `time_blocks` | TimeBlock | yes |

#### Sheet: `TimeBlockEditSheet` (`Puck/Views/Schedule/TimeBlockEditSheet.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Title field | Sets local `title` | none | TimeBlock.title | yes (on save) |
| Focus Mode menu — pick existing | Sets `intentionId` | none | TimeBlock.intentionId | yes |
| Focus Mode menu — "None (use default)" | `intentionId = nil` (server falls back to seeded Focus) | none | TimeBlock.intentionId | yes |
| Focus Mode menu — "+ One-off block" | Opens OneOffBlockSheet | none | TimeBlock | yes |
| Strictness caption (read-only deep-link) | Dismisses + pivots to Intentions tab + writes UserDefaults `deeplink_open_intention_id` | none | none | no |
| Intensity segmented (Deep Work / Focus Hours) | Sets `intensity` | none | TimeBlock.intensityRaw | yes |
| Day pill row M–Sun | Toggles ISO day | none | TimeBlock.activeDays | yes |
| Start/End steppers | 15-min granularity | none | TimeBlock.startHour/Minute, endHour/Minute | yes |
| Delete Block (existing only) | `service.deleteBlock` | PUT `time_blocks` | TimeBlock (delete) | yes |
| Cancel toolbar | Dismiss | none | none | no |
| Save toolbar | `service.createBlock` or `updateBlock` | PUT `time_blocks` | TimeBlock | yes |

#### Sheet: `OneOffBlockSheet` (`Puck/Views/Schedule/OneOffBlockSheet.swift`)

D12 — title-only block (no Intention, no color/icon). Server saves as `intention_id == nil`, falls back to seeded Focus.

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Title field | Sets `title` | none | TimeBlock | yes |
| "Create an Intention" link | Bubbles up; ScheduleTabView pivots to Intentions tab | none | none | no |
| Cancel | Dismiss | none | none | no |
| Save | Inserts TimeBlock (intentionId=nil) | PUT `time_blocks` | TimeBlock | yes |

---

### Focus Modes (`Puck/Views/Intentions/IntentionsTabView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Trash toggle (top-right) | Toggles soft-deleted visibility | none | none | no |
| `+` plus button | Opens `IntentionEditView(mode: .create)` | POST `intentions` on save | Intention | yes |
| `IntentTile` tap | Opens `IntentionEditView(mode: .edit)`; auto-presents FamilyActivityPicker if 0 apps | none until save | Intention | yes |
| Conflict banner dismiss | Clears `store.conflictBanner` | none | none | no |

Deep-link consumer: on appear, reads UserDefaults `deeplink_open_intention_id` and opens that Intention's editor (cleared after read).

#### Sheet: `IntentionEditView` (`Puck/Views/Intentions/IntentionEditView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Cancel toolbar | Dismiss | none | none | no |
| Save toolbar | Create or update | POST `intentions` / PUT `intentions/{id}` | Intention | yes |
| Name field | Sets `name` | none | Intention.name | yes |
| Description field | Sets `description` | none | Intention.description | yes |
| Color swatch picker (8 colors) | Sets `colorHex` | none | Intention.colorHex | yes |
| Icon picker (8 SF symbols) | Sets `icon` | none | Intention.icon | yes |
| Strictness segmented (Strict/Standard/Soft) | Triggers strictness rules engine | PUT `intentions/{id}/strictness` | Intention.strictnessPreset (or pending) | yes |
| Pending-change cancel button | Cancels queued softening | POST `intentions/{id}/strictness/cancel` | Intention.pending | yes |
| iOS apps card (FamilyActivityPicker trigger) | Opens picker | none | Intention.iosAppTokens / iosCategoryTokens | yes |
| Mac websites (read-only) | display only | none | none | yes (display) |
| Mac bundle IDs (read-only) | display only | none | none | yes (display) |
| Weekly target placeholder | greyed; D9 stub | none | none | no |

#### Sheet: `StrictnessUnlockSheet` (`Puck/Views/Intentions/StrictnessUnlockSheet.swift`)

Two-stage: send request, then enter code.

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Reason chip | Sets local `reason` | none | none | no |
| Note field | Sets local `note` | none | none | no |
| "Send request" button | Posts unlock request | POST `intentions/strictness-unlock-request` | none (server-side) | yes |
| 6-digit code input | Builds verification body | (verify endpoint pending; client-defined but backend deferred) | Intention.strictnessPreset | yes (when shipped) |
| "Confirm" button | Verifies code | (deferred) | Intention | yes |
| Cancel | Dismiss | none | none | no |

#### Banner: `IntentionConflictBanner`

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Dismiss | Sets `store.conflictBanner = nil` | none | none | no |

---

### Alarms (`Puck/Views/Wake/WakeView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Settings (gear) icon | Opens AlarmSettingsView | none | none | no |
| "+" plus icon | Opens AlarmEditView (new) | none | none | no |
| EmptyStateCard "Add alarm" | Opens AlarmEditView | none | none | no |
| AlarmRow toggle | Schedule or cancel via AlarmService | none (AlarmKit) | PuckAlarm.isEnabled | no |
| AlarmRow tap | Opens AlarmEditView for editing | none | PuckAlarm | no |
| Ringing banner "Dismiss with Puck" button | `nfcService.startScan` | none | WakeEvent (on dismiss) | no |
| Bedtime card (off/armed/locked states) | Tap → opens BedtimeDetailView | PUT `bedtime/config` (on save inside) | BedtimeScheduleConfig | yes |
| Bedtime card toggle | `bedtimeService.updateConfig { c in c.enabled = newValue }` | PUT `bedtime/config` | BedtimeScheduleConfig.enabled | yes |
| Wake-streak section | Read-only display (7-day dots) | none | none | no |

#### Sheet: `AlarmEditView` (`Puck/Views/Wake/AlarmEditView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Cancel | Dismiss | none | none | no |
| Save | Schedules via AlarmKit, persists | none (AlarmKit) | PuckAlarm | no |
| Time picker (wheel hidden under hero) | Sets `alarmTime` | none | PuckAlarm.time | no |
| Day chip M–S | Toggles repeat days | none | PuckAlarm.repeatDays | no |
| Dismiss with row tap | Opens puckPickerSheet | none | PuckAlarm.dismissModeSlug | no |
| Sound row tap | Opens soundPickerSheet | none | PuckAlarm.sound | no |
| More options expand | Shows volume / vibration / fade-in / mute / post-alarm | none | none | no |
| Auto-dismiss chip (60/180/300/600s) | Sets seconds | none | PuckAlarm.autoDismissSeconds | no |
| Volume slider | Sets `volume` | none | PuckAlarm.volume | no |
| Vibration toggle | Sets `vibration` | none | PuckAlarm.vibration | no |
| Fade in toggle | Sets `fadeInDuration` (0 or 15) | none | PuckAlarm.fadeInDuration | no |
| Mute duration chip (5/10/15/30s) | Sets `muteLengthSeconds` | none | PuckAlarm.muteLengthSeconds | no |
| Post-alarm focus toggle | Enable/disable | none | PuckAlarm.postAlarmModeId | no |
| Mode picker | Selects FocusMode | none | PuckAlarm.postAlarmModeId | no |

#### Sheet: `AlarmSettingsView` (in `AlarmEditView.swift:606`)

Global defaults.

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Dismiss window picker (1/3/5/10 min) | Sets `alarmDismissWindowMinutes` | none | UserDefaults | no |
| Default sound row (read-only) | display | none | UserDefaults `defaultAlarmSound` | no |
| Fade in toggle (local-only) | Sets local `fadeIn` | none | none | no |
| Vibration toggle | Sets local `vibration` | none | none | no |

#### Sheet: `BedtimeDetailView` (`Puck/Views/Bedtime/BedtimeDetailView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Cancel nav | Dismiss | none | none | no |
| Save nav | `bedtimeService.updateConfig { ... }` then push | PUT `bedtime/config` | BedtimeScheduleConfig | yes |
| Time hero (bedtime start, hidden DatePicker) | Sets `bedtimeStart` | PUT `bedtime/config` (on save) | BedtimeScheduleConfig.bedtimeStartHour/Minute | yes |
| "Ends at … alarm" link chip (read-only) | display | none | none | no |
| Day chips M–Sun | Toggles ISO day | PUT `bedtime/config` (on save) | BedtimeScheduleConfig.activeDays | yes |
| Allowlist row tap | Opens BedtimeAllowlistView | none until save | BedtimeScheduleConfig.allowlistBundleIDs | yes |
| Turn off bedtime danger | `enabled = false`, dismiss | PUT `bedtime/config` | BedtimeScheduleConfig.enabled | yes |

#### Sheet: `BedtimeAllowlistView` (`Puck/Views/Wake/BedtimeAllowlistView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Edit button | Opens FamilyActivityPicker | none | tokens (App Group + cfg) | partial |
| Done | Saves and dismisses | PUT `bedtime/config` (allowlist field) | BedtimeScheduleConfig.allowlistBundleIDs | yes (bundle ids only; tokens local) |
| Cancel pill | Dismiss | none | none | no |

#### Sheet: `PuckDismissDisambigSheet` (`Puck/Views/Wake/PuckDismissDisambigSheet.swift`)

Triggered when alarm is ringing AND tapped puck's slug matches a focus mode.

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| "Just dismiss alarm" | Calls `onJustDismiss` (no postAlarmMode) | none | WakeEvent (insert) | no |
| "Dismiss + start {mode}" | Calls `onDismissPlusActivate` (activates mode) | POST `focus/toggle` (start) | WakeEvent + FocusSession (insert) | yes |
| Remember-choice toggle | Saves to UserDefaults `puck.dismiss.disambig.preference` | none | UserDefaults | no |

---

### Partner (`Puck/Views/Partner/PartnerView.swift`)

Three render branches by `consentStatus` AppStorage value.

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| **Empty:** Name field | Sets local `inviteName` | none | none | no |
| **Empty:** Email field | Sets local `inviteEmail` | none | none | no |
| **Empty:** Send invite | Sends consent email | PUT `partner` (X-Device-ID auth) | UserDefaults partnerName/Email/consentStatus | yes |
| **Pending:** Resend | Re-fires invite | PUT `partner` | UserDefaults | yes |
| **Pending:** Cancel invite | Removes partner | DELETE `partner` (X-Device-ID auth) | UserDefaults | yes |
| **Paired:** Request unlock code | Stub alert ("coming soon") | (planned) | none | (planned) |
| **Paired:** Message {name} | Opens system mail composer | mailto: | none | no |
| **Paired:** "What's shared" row | TODO comment, no-op | none | none | no |
| **Paired:** Remove partner danger | Confirms then DELETE | DELETE `partner` | UserDefaults | yes |
| Status refresh (on appear / .task) | Pulls authoritative state | GET `partner/status` (Bearer) | UserDefaults | yes (read) |

Backed by `PartnerSyncService` which polls every 60s while active and pulls on launch + foreground.

---

### Settings (`Puck/Views/Settings/SettingsView.swift`)

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Partner-lock banner (when `lockStateService.isPartnerLocked`) | Read-only — informs user to unlock from Mac | none | none | yes (read via /unlock/status) |
| Account row (email + provider) | Read-only display | none | none | no |
| Sign out (when not locked) | Confirms then signs out | Supabase auth | UserDefaults clear | no |
| Delete account (when not locked) | Confirms then deletes | Supabase + backend | UserDefaults clear | yes |
| "Get code from partner to unlock" row (when locked) | Shows alert pointing to Mac | none | none | no |
| Pucks list row tap | Opens PuckEditSheet | none | RegisteredPuck | no |
| "Add a puck" row | Opens PuckSetupView | none | RegisteredPuck (insert on done) | no |
| Emergency unlocks row | Opens EmergencyUnlockView (or shows lock indicator if partner-locked) | none | none | yes (lock state) |
| Session reminders toggle | `@AppStorage("settings.sessionRemindersOn")` | none | UserDefaults | no |
| Weekly report toggle | `@AppStorage("settings.weeklyReportOn")` | none | UserDefaults | no |
| Support: How it works | Opens HowItWorksView | none | none | no |
| Support: Privacy policy | Opens https://getpuck.app/privacy | none | none | no |
| Support: Terms of service | Opens https://getpuck.app/terms | none | none | no |
| Support: Contact support | mailto:support@getpuck.app | none | none | no |

#### Sheet: `EmergencyUnlockView`

| Control | What it does | API | Model | Sync |
|---|---|---|---|---|
| Weekly limit chip (3/5/7/10) | Sets `weeklyEmergencyLimit` | none | UserDefaults | no |
| Use Emergency Unlock danger (visible only mid-session) | `blockingService.emergencyUnbrick()` | none | local count + ManagedSettings clear | no |

#### Sheet: `HowItWorksView`

Static 4-step illustration. No interactive controls beyond modal close.

---

## 3. SwiftData @Model classes

Schema declared in `PuckApp.swift:28–39`. ModelContainer uses App Group `group.com.getpuck.app`.

| @Model | Fields | Written by | Read by |
|---|---|---|---|
| `FocusMode` (`Puck/Models/FocusMode.swift`) | id:UUID, name:String, slug:String, iconName:String, modeTypeRaw:String, blockBehaviorRaw:String, appTokenData:Data?, categoryTokenData:Data?, websiteURLs:[String], defaultDuration:Int?, colorHex:String, modeColorHex:String, createdAt:Date, lastUsedAt:Date?, intentionId:UUID?, bedtimeBrightness:Double? | HomeView (seed), ModeCreationView, ModeEditView, IntentionMigrationRunner, OnboardingFlowView (Pairing) | HomeView (NFC pairing lookup), Coordinator (slug → mode), AlarmEditView (post-alarm picker), PuckEditSheet, PuckCoordinator |
| `FocusSession` (`Puck/Models/Sessions.swift`) | id, modeName, modeIconName, modeSlug?, modeTypeRaw?, startTime, endTime?, scheduledDuration?, puckUID? (legacy), endReasonRaw? | Coordinator.activateMode, HomeView.startSessionDirectly, ModePickerSheet | HomeView (recent / today stats), Coordinator (restoreActiveSession) |
| `WakeEvent` (`Puck/Models/Sessions.swift`) | id, alarmTime, dismissTime?, dismissMethodRaw?, streakCredited:Bool | Coordinator.handleAlarmDismissWithNFC, handleAlarmTimeout | WakeView (streak calc), HomeView |
| `PuckAlarm` (`Puck/Models/PuckAlarm.swift`) | id, time, repeatDays, sound, volume, vibration, fadeInDuration, muteLengthSeconds, isEnabled, postAlarmModeId?, postAlarmDuration?, dismissPuckId? (legacy), dismissModeSlug?, autoDismissSeconds | AlarmEditView, AlarmRow toggle | WakeView, HomeView (next alarm), AlarmService, ScheduleTabView (wake banner source) |
| `PuckSchedule` (`Puck/Models/PuckSchedule.swift`) | id, name, days, blocks (relationship), alarmId?, bedtimeData?, isActive | (no current writers in main UI) | (no readers in main UI) |
| `ScheduleBlock` (`Puck/Models/PuckSchedule.swift`) | id, startTime, endTime, modeName, modeId? | (no writers) | (no readers) |
| `RegisteredPuck` (`Puck/Models/RegisteredPuck.swift`) | id, uid (legacy), modeSlug, name, iconName, colorHex, location, focusModeId?, habitGoalFrequency?, createdAt, lastTappedAt?, sortOrder | PuckSetupView, PuckEditSheet, OnboardingFlowView (Pairing), Coordinator (lastTappedAt update) | HomeView, SettingsView (Pucks section), AlarmEditView (puck picker), Coordinator |
| `BedtimeScheduleConfig` (`Puck/Models/BedtimeScheduleConfig.swift`) | id (singleton), enabled, bedtimeStartHour/Minute, wakeHour/Minute, activeDays, allowlistBundleIDs, partnerLocked, lastSyncedAt?, lastEditedAt | BedtimeScheduleService.pull/push/updateConfig, BedtimeDetailView, BedtimeAllowlistView | WakeView (bedtime card), ScheduleTabView (banner sources), BedtimeScheduleService.tick |
| `IntentionalBlock` (`Puck/Core/Schedule/ScheduleBlock.swift`) — DEPRECATED, kept one release for migration | blockId:String, title, blockType, startHour/Minute, endHour/Minute, activeDays, enabled, createdAt, lastEditedAt, lastSyncedAt? | ScheduleBlocksService.pull/push/createBlock/updateBlock/deleteBlock | (legacy schedule UI; superseded by TimeBlock) |
| `TimeBlock` (`Puck/Models/TimeBlock.swift`) — Spec 2 active | blockId:UUID (unique), title, intentionId?, intensityRaw, startHour/Minute, endHour/Minute, activeDays:[Int], enabled, createdAt, updatedAt | TimeBlocksService (create/update/delete), TimeBlockEditSheet, OneOffBlockSheet | ScheduleTabView, DayCalendarView |
| `Intention` (`Puck/Models/Intention.swift`) — STRUCT not @Model | id, name, description?, colorHex?, icon?, macWebsites:[String], macBundleIds:[String], iosAppTokens:Data?, iosCategoryTokens:Data?, strictnessPreset, weeklyBudgetHours?, budgetEnforcement?, version, createdAt, updatedAt, deletedAt? | IntentionStore (in-memory + JSON cache, NOT SwiftData) | IntentionsTabView, IntentionEditView, HomeView focus-modes grid, IntentionPushHandler, BlockingService.activate (token resolve) |
| `StrictnessPreset` (`Puck/Models/StrictnessPreset.swift`) — enum | strict / standard / soft | embedded in Intention | UI rendering, IntentionStore.changeStrictness |

Intention is NOT a SwiftData model — it lives in `IntentionStore` (in-memory `@Published [Intention]`) plus `IntentionStorage` (JSON file in App Group at key `intentions_cache_v1`). Backend at `/intentions` is the source of truth.

Migration runner: `IntentionMigrationRunner` (`Puck/Core/Intentions/IntentionMigrationRunner.swift`). One-time at first launch post-Spec-1; receipt at UserDefaults key `intention_migration_v1_completed_at`. Skips bedtime FocusModes; resumable via `intention_migration_v1_last_processed_id`.

---

## 4. Backend API calls

Network entry: `IntentionalAPIClient` (`Puck/Core/Network/IntentionalAPIClient.swift`). Two auth modes: `.bearer` (Supabase JWT) and `.deviceId` (legacy `X-Device-ID` 64-char hex, lazily registered via `POST /register`).

Base URL: `Constants.IntentionalAPI.baseURL = "https://api.intentional.social"`.

There is also `NetworkClient` (`Puck/Core/Network/NetworkClient.swift`) which targets `Constants.API.baseURL = "https://api.getpuck.app"`. Currently appears unused (no clients call into it).

| Method | Endpoint | Auth | Defined in | When fires |
|---|---|---|---|---|
| `IntentionalAPIClient.getUnlockStatus()` | GET `/unlock/status` | deviceId | IntentionalAPIClient.swift | `LockStateService.refresh` (auth state, tab open, foreground) |
| `IntentionalAPIClient.setPartner(email:name:)` | PUT `/partner` | deviceId | IntentionalAPIClient.swift | PartnerView Send-invite/Resend |
| `IntentionalAPIClient.removePartner()` | DELETE `/partner` | deviceId | IntentionalAPIClient.swift | PartnerView Remove / Cancel-invite |
| `IntentionalAPIClient.getPartnerStatus()` | GET `/partner/status` | bearer | IntentionalAPIClient.swift | PartnerView .task; PartnerSyncService poll (60s + foreground) |
| `IntentionalLegacyDeviceID.registerOnce` | POST `/register` (no auth) | none | IntentionalAPIClient.swift | First call needing deviceId auth |
| `IntentionalDeviceRegistration.registerIfNeeded` | POST `/devices/register` | bearer | IntentionalDeviceRegistration.swift | After Supabase auth completes |
| `IntentionalPushTokenClient.uploadIfChanged(token:)` | POST `/devices/push-token` | bearer | IntentionalPushTokenClient.swift | `PuckAppDelegate.didRegisterForRemoteNotificationsWithDeviceToken` |
| `IntentionalFocusSignalClient.toggleFocus(action:intentionId:triggeredBy:)` | POST `/focus/toggle` | bearer | IntentionalFocusSignalClient.swift | `BlockingService.activate`, `Coordinator.endActiveFocusSession` (stop) |
| `IntentionalIntentionsClient.list(includeDeleted:)` | GET `/intentions` (or `/intentions?include_deleted=true`) | bearer | IntentionalIntentionsClient.swift | `IntentionStore.pull` (60s + foreground + launch + post-mutation) |
| `IntentionalIntentionsClient.get(id:)` | GET `/intentions/{id}` | bearer | IntentionalIntentionsClient.swift | (callable; not in main path) |
| `IntentionalIntentionsClient.create(_:)` | POST `/intentions` | bearer | IntentionalIntentionsClient.swift | `IntentionStore.create` from IntentionEditView Save |
| `IntentionalIntentionsClient.update(id:payload:)` | PUT `/intentions/{id}` | bearer | IntentionalIntentionsClient.swift | `IntentionStore.update` from IntentionEditView Save |
| `IntentionalIntentionsClient.delete(id:)` | DELETE `/intentions/{id}` | bearer | IntentionalIntentionsClient.swift | `IntentionStore.delete` |
| `IntentionalIntentionsClient.changeStrictness(id:toPreset:unlockCode:)` | PUT `/intentions/{id}/strictness` | bearer | IntentionalIntentionsClient.swift | IntentionEditView strictness segmented; StrictnessUnlockSheet confirm |
| `IntentionalIntentionsClient.cancelStrictnessChange(id:)` | POST `/intentions/{id}/strictness/cancel` | bearer | IntentionalIntentionsClient.swift | IntentionEditView cancel-pending button |
| `IntentionalIntentionsClient.pendingStrictnessChange(id:)` | GET `/intentions/{id}/strictness/pending` | bearer | IntentionalIntentionsClient.swift | IntentionEditView .task |
| `IntentionalIntentionsClient.activeSession(intentionId:)` | GET `/intentions/{id}/active-session` | bearer | IntentionalIntentionsClient.swift | `IntentionStore.isSessionActive` (D6 strictness gate) |
| `IntentionalIntentionsClient.requestStrictnessUnlock(...)` | POST `/intentions/strictness-unlock-request` | bearer | IntentionalIntentionsClient.swift | StrictnessUnlockSheet send-request (BACKEND DEFERRED per Mac CLAUDE.md) |
| `IntentionalBedtimeClient.getConfig()` | GET `/bedtime/config` | bearer | IntentionalBedtimeClient.swift | `BedtimeScheduleService.pull` |
| `IntentionalBedtimeClient.putConfig(_:)` | PUT `/bedtime/config` | bearer | IntentionalBedtimeClient.swift | `BedtimeScheduleService.push` after updateConfig |
| `IntentionalBedtimeClient.requestUnlock(reason:note:)` | POST `/bedtime/unlock-request` | bearer | IntentionalBedtimeClient.swift | BedtimeUnlockRequestSheet |
| `IntentionalBedtimeClient.verifyUnlock(code:)` | POST `/bedtime/unlock-verify` | bearer | IntentionalBedtimeClient.swift | BedtimeUnlockCodeView |
| `IntentionalBedtimeClient.getUnlockStatus()` | GET `/bedtime/unlock-status` | bearer | IntentionalBedtimeClient.swift | BedtimeUnlockPoller (5s while locked) |
| `IntentionalBedtimeClient.approveUnlock(requestId:durationMinutes:)` | POST `/bedtime/unlock-approve` | bearer | IntentionalBedtimeClient.swift | PartnerApprovalView Approve; PuckPushRouter notification action |
| `IntentionalScheduleClient.getBlocks()` | GET `/schedule/blocks` | bearer | IntentionalScheduleClient.swift | `ScheduleBlocksService.pull` (LEGACY/Spec1; superseded) |
| `IntentionalScheduleClient.putBlocks(_:)` | PUT `/schedule/blocks` | bearer | IntentionalScheduleClient.swift | `ScheduleBlocksService.push` (LEGACY) |
| `IntentionalTimeBlocksClient.getBlocks()` | GET `/time_blocks` | bearer | IntentionalTimeBlocksClient.swift | `TimeBlocksService.pull` (60s + foreground + on app launch) |
| `IntentionalTimeBlocksClient.putBlocks(_:)` | PUT `/time_blocks` | bearer | IntentionalTimeBlocksClient.swift | `TimeBlocksService.pushAll` after every create/update/delete |

Supabase auth (separate client): `Puck/Core/Auth/AuthService.swift` — `sendOTP`, `verifyOTP`, `signInWithApple`, `signOut`, `deleteAccount`. Not part of Intentional backend API.

---

## 5. Cross-device state

State the user can change, and how it propagates.

| State | Source of truth | Sync class |
|---|---|---|
| Intentions (name, color, icon, iOS apps, mac websites/bundle IDs, strictness) | `/intentions` table (backend) | pulled-on-launch + 60s + foreground; pushed-on-change |
| Strictness preset | `/intentions/{id}/strictness` (rules engine) | pushed-on-change; pull pending state on edit; pulled-via-`/intentions` 60s |
| Pending strictness change (queued softening) | `/intentions/{id}/strictness/pending` | pulled-on-edit |
| Active focus session (start/stop) | `focus_sessions` (backend) | pushed-via-`/focus/toggle`; **pushed-via-APNs** silent push (`focus.session_started/stopped`) drives `IntentionPushHandler` to apply per-session ManagedSettingsStore on this device; **triggers-Mac-state-change** |
| Time Blocks (Spec 2 schedule) | `/time_blocks` | pulled-on-launch + 60s + foreground; pushed-on-change (atomic full-set replace) |
| Schedule Blocks (legacy Spec 1) | `/schedule/blocks` | same pull/push cadence; deprecated |
| Bedtime config (start/wake/active days/allowlist bundles/enabled) | `/bedtime/config` | pulled-on-launch + foreground; pushed-on-change (last-write-wins by `account_id`) |
| Bedtime allowlist iOS tokens | local-only (FamilyControls tokens are device-scoped); `allowlist_bundle_ids` are synced as fallback | partial: bundle IDs synced, FamilyControls tokens cannot be |
| Bedtime released-until (partner unlock window) | `bedtime_unlock_requests` server table; **APNs `bedtime.unlock_approved`** push delivers `released_until_iso` | pushed-via-APNs to originator; polled at 5s by BedtimeUnlockPoller as fallback |
| Bedtime partner-unlock request | `/bedtime/unlock-request` server side | pushed-on-change; APNs to partner with category `bedtime.unlock_request` (Approve/Deny actions) |
| Partner identity (email, name, consent_status) | `partner_consent` table (backend) | pulled-on-launch + foreground + 60s via PartnerSyncService; pushed via PUT/DELETE `/partner` |
| Lock state (settings partner-lock) | `/unlock/status` (X-Device-ID) | pulled-on-auth-change + tab-open + foreground via LockStateService |
| Push token | `/devices/push-token` | pushed-on-change (deduped via UserDefaults `intentional_apns_token_last_uploaded`) |
| Device registration | `/devices/register` | pushed-once after Supabase auth |
| FocusMode (local apps + design metadata + slug) | local SwiftData only | local-only |
| RegisteredPuck (NFC pairings) | local SwiftData only | local-only |
| PuckAlarm (alarms + AlarmKit schedule) | local SwiftData only | local-only |
| WakeEvent (alarm-dismiss history) | local SwiftData only | local-only |
| FocusSession (per-tap session log) | local SwiftData only | local-only (start/stop signals replicate via /focus/toggle) |
| Quiz onboarding answers | discarded (computation only) | local-only |
| Settings.sessionRemindersOn | UserDefaults | local-only |
| Settings.weeklyReportOn | UserDefaults | local-only |
| weeklyEmergencyLimit | UserDefaults | local-only |
| alarmDismissWindowMinutes | UserDefaults | local-only |
| `puck.dismiss.disambig.preference` | UserDefaults | local-only |
| `intention_picker_onboarding_shown` | UserDefaults | local-only |
| `hasCompletedOnboarding` / `hasPairedPuck` | UserDefaults (mirrored to Supabase user metadata via `saveOnboardingToServer`) | partial — saved server-side |
| `bedtimeGratitude` | UserDefaults | local-only |
| `hasCompletedBedtimeShortcutsSetup` | UserDefaults | local-only |
| `hasSeededFocusModes` | UserDefaults | local-only |
| `deeplink_open_intention_id` | UserDefaults (transient) | local-only |
| App Group: `bedtime_allowlist_tokens_v1` (FamilyControls tokens) | App Group UserDefaults | local-only (cross-process between main app and PuckBedtimeMonitor extension) |
| App Group: `bedtime_active_days_iso_v1`, `bedtime_released_until_epoch_v1`, `schedule_block_metadata_v1`, `schedule_block_tokens_<blockId>` | App Group UserDefaults | local-only (extension contract) |

---

## 6. DeviceActivity / ManagedSettings flows

Extension target: `PuckBedtimeMonitor` (`PuckBedtimeMonitor/DeviceActivityMonitorExtension.swift`). Single class `DeviceActivityMonitorExtension : DeviceActivityMonitor` with three callbacks — `intervalDidStart`, `intervalDidEnd`, `intervalWillStartWarning`.

Dispatch by `DeviceActivityName.rawValue`:
- `"bedtime"` → bedtime path
- prefix `"schedule_"` → per-block schedule path (e.g. `schedule_a1b2c3d4`)
- otherwise → log unknown and return

### Bedtime flow

Trigger: `BedtimeScheduleService.registerOrClearSchedule(for:)` calls `DeviceActivityCenter.startMonitoring(.bedtime, schedule:)` with start/end times from `BedtimeScheduleConfig`.

`intervalDidStart(.bedtime)`:
1. Skip if today is not in `BedtimeSharedStorage.loadActiveDays()` (ISO 1=Mon..7=Sun)
2. Skip if `BedtimeSharedStorage.releasedUntil() > now` (partner-unlock window)
3. Load allowlist tokens (`bedtime_allowlist_tokens_v1` App Group key)
4. Apply shield via `ManagedSettingsStore(named: .init("bedtime"))`:
   - `shield.applicationCategories = .all(except: allowlist)`
   - `shield.webDomainCategories = .all()`
5. Mark `setShieldAppliedByExtension(true)`

`intervalDidEnd(.bedtime)`: `bedtimeStore.clearAllSettings()` + flag false.

`intervalWillStartWarning(.bedtime)`: Marks `lastWindDownWarning` (T-15 fires) for the main-app banner controller to surface.

### Schedule block flow (per block)

Each TimeBlock generates a `DeviceActivityName` of `schedule_<first 8 hex of UUID>` (`IntentionalBlock.deviceActivityName`). `ScheduleBlocksService.reregisterAllSchedules()` registers up to 20 (iOS soft cap; soft-logged if exceeded).

`intervalDidStart(schedule_<short>)`:
1. Skip if today not in block's `activeDays` (`isTodayInActiveDaysFor(shortName:)`)
2. Look up full UUID via `BedtimeSharedStorage.blockId(forShortName:)`
3. Load per-block blocklist: `BedtimeSharedStorage.loadBlockBlocklist(blockId:)` — App Group key `schedule_block_tokens_<blockId>`
4. If empty → no-op log
5. Apply shield via `ManagedSettingsStore(named: shortName)`:
   - `shield.applications = blocklist`

`intervalDidEnd(schedule_<short>)`: `store.clearAllSettings()` for that named store.

### Cross-device push-driven shielding (no DeviceActivity)

`IntentionPushHandler` (`Puck/Core/Push/IntentionPushHandler.swift`) — handles `focus.session_started` / `focus.session_stopped` APNs payloads (e.g. session started on Mac):
- Looks up Intention from `IntentionStore.cachedIntention(intentionId)` (or pulls then retries once)
- Decodes `iosAppTokens` + `iosCategoryTokens`
- Applies via `ManagedSettingsStore(named: "session-<sessionId>")` so `stop` can clear precisely
- On `stopped`: removes that named store and `clearAllSettings()`

### App Group storage keys

Suite: `group.com.getpuck.app`.

**Bedtime extension keys** (`BedtimeSharedStorage`):
- `bedtime_allowlist_tokens_v1`: encoded `Set<ApplicationToken>`
- `bedtime_active_days_iso_v1`: `[Int]` ISO 1=Mon..7=Sun
- `bedtime_released_until_epoch_v1`: Double (Unix epoch)
- `bedtime_shield_applied_by_extension_v1`: Bool
- `bedtime_last_winddown_warning_epoch_v1`: Double
- `bedtime_extension_log_v1`: `[String]` ring buffer (cap 100)

**Schedule block keys**:
- `schedule_block_metadata_v1`: encoded `[ScheduleBlockMetadata]` (blockId, shortName, activeDays)
- `schedule_block_tokens_<blockId>`: encoded `Set<ApplicationToken>` per block

**Shield extension keys** (used by PuckShieldConfiguration / PuckShieldAction):
- `puck_blocking_mode_name`, `puck_blocking_mode_color`, `puck_blocking_mode_icon` (written by `BlockingService.activate`, cleared by `deactivate`)

**Other**:
- `intentions_cache_v1`: Intentions JSON cache
- SwiftData store lives at App Group container's `Library/Application Support/default.store`

### Live Activity

`PuckActivities` widget extension target. `BedtimeLiveActivityController.start/.update/.end` fired from `BedtimeScheduleService.tick` on shield activation/refresh/deactivation. 8-hour ActivityKit cap. Pushes update to lock screen + Dynamic Island. Updates via `PuckPushRouter` on `bedtime.unlock_approved` push so partner-approved release reflects immediately.

---

## 7. NFC / Puck pairing

Source: `Puck/Core/NFC/NFCService.swift`, `Puck/Views/PuckSetup/PuckSetupView.swift`, `Puck/Core/Coordinator/PuckCoordinator.swift`.

**Patent-safe URI design** (per `Puck/CLAUDE.md` + `docs/patent-analysis.md`): the app NEVER reads, stores, or compares hardware NFC UIDs. Each tag stores a single NDEF URI: `puck://mode/{slug}` (e.g. `puck://mode/deep-work`). Reads use `NFCNDEFReaderSession`.

### Pairing flow (write tag)

1. User opens PuckSetupView → picks a FocusMode → "Configure puck"
2. `nfcService.writeMode(slug:)` opens NDEF write session
3. On tag detect, app writes single URI record: `puck://mode/{slug}`
4. On success, app inserts `RegisteredPuck(modeSlug:, focusModeId:, name: "My Puck")`
5. Color / name / location editable in `PuckEditSheet`

### Reconfigure flow

1. PuckEditSheet → mode-changer sheet → tap new mode
2. `startModeRewrite(mode:)` calls `nfcService.writeMode(slug: newMode.slug)`
3. Updates `puck.modeSlug` and `puck.focusModeId`

### Tap-to-activate flow (read)

1. `nfcService.startScan(message:)` triggered from any of: HomeView puck chip tap, ModeTile play button, active-banner "Unlock with Puck", alarm-ringing "Dismiss with Puck"
2. NFCNDEFReaderSession reads → `parsePuckURI(...)` extracts slug → fires `onPuckTapped(slug)` → `PuckCoordinator.handleNFCSlug(slug)`
3. Coordinator (`PuckCoordinator.swift:127`):
   - Empty slug → `onUnknownSlugScanned` → opens PuckSetupView
   - Alarm ringing → `decideAlarmDismissRouting` → one of `wrongPuck` / `dismissOnly` / `dismissAndActivate` / `disambiguate`
   - Same-mode tap with active session → ends session (unless bedtime: requires different puck)
   - Different puck during bedtime → ends bedtime, activates new mode
   - Different puck during blocking session → tap error
   - Otherwise → `activateMode(mode:slug:)`

### Software puck "buttons"

Physical puck has only one capability — being tapped (NFC read). Functions:
- **Tap during idle** → starts focus session for that puck's mode
- **Tap during same active mode** → ends session
- **Tap during different mode** (when current is bedtime) → ends bedtime + starts new mode
- **Tap during bedtime + same puck** → tap error ("Tap a different puck to end Bedtime")
- **Tap during alarm ringing** → dismisses (with disambiguation if mode would normally activate)
- **Tap on unknown URI / unknown slug** → opens PuckSetupView (suggesting pairing)

### Backend endpoints hit by NFC

- `POST /focus/toggle` (action=start, intention_id=mode.intentionId, triggered_by="ios_nfc") — fired by `BlockingService.activate` after NFC routing
- `POST /focus/toggle` (action=stop) — fired by `Coordinator.endActiveFocusSession` for blocking sessions

### URL scheme support

`puck://mode/{slug}` is also handled when invoked from outside the app (`PuckApp.handleIncomingURL`) — Shortcuts automation can deeplink → `coordinator.handleNFCSlug(slug)`. Same routing, no NFC required.

---

## 8. Notifications / silent push

Bridge: `PuckAppDelegate` (`Puck/App/PuckAppDelegate.swift`) routes UIApplicationDelegate methods into Swift code. Wired via `@UIApplicationDelegateAdaptor`.

Permissions on launch: requestAuthorization for `[.alert, .sound, .badge]`, then `registerForRemoteNotifications()`.

### Categories registered (`PuckPushRouter.registerCategories`)

| Category ID | Actions |
|---|---|
| `bedtime.unlock_request` | `bedtime.approve_30` (Approve · 30 min — foreground + authenticationRequired), `bedtime.deny` (destructive) |

Other notifications (alarm-related, focus-complete) are scheduled via `UNUserNotificationCenter` directly without category.

### Push payload routing

Entry: `PuckAppDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` → `PuckPushRouter.shared.route(payload:)`.

| `payload.type` | Handler | Effect |
|---|---|---|
| `bedtime.unlock_requested` | `PuckPushRouter.handleUnlockRequested` | Sets `pendingApproval` → drives `.sheet(item:)` in PuckApp body → presents `PartnerApprovalView` (partner side) |
| `bedtime.unlock_approved` | `PuckPushRouter.handleUnlockApproved` | Parses `released_until_iso`, calls `BedtimeScheduleService.setReleasedUntil(...)`, updates Live Activity (originator side) |
| `focus.session_started` | `IntentionPushHandler.handle` | Look up Intention → apply per-session ManagedSettingsStore (cross-device shield from Mac) |
| `focus.session_stopped` | `IntentionPushHandler.handle` | Find the per-session store, `clearAllSettings()` |
| (any other type) | log + ignore | — |

### Notification-tap routing

Set on `UNUserNotificationCenter.current().delegate = NotificationDelegate()` in `PuckApp.init`.

`NotificationDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` forwards to `PuckPushRouter.handleNotificationTap(response:)`:

| Action ID | Behaviour |
|---|---|
| `bedtime.approve_30` (foreground action) | Calls `IntentionalBedtimeClient.approveUnlock(requestId:durationMinutes: 30)` |
| `bedtime.deny` (destructive) | No-op (server endpoint pending per code comment) |
| (default tap) | Sets `pendingApproval` → opens PartnerApprovalView |
| `bedtime.unlock_approved` tap | Same as foreground: applies released-until |

### Background modes (Info.plist `UIBackgroundModes`)

- `remote-notification` — silent push delivery
- `processing` — heartbeat / tamper-detection (per CLAUDE.md, not yet implemented)

### Local notifications

- `Coordinator.sendCompletionNotification` — fires "Focus Session Complete" `UNNotificationRequest` when blocking timer completes
- AlarmKit drives ringing alerts (separate framework, separate Live Activity)

### Push token lifecycle

`PuckAppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` → `IntentionalPushTokenClient.uploadIfChanged(token:)` → POST `/devices/push-token` with hex token + `bundle_id` + `environment` (sandbox in DEBUG, production in RELEASE). Deduped against UserDefaults `intentional_apns_token_last_uploaded`.

---

## 9. Suspected dead code

Concrete dead code (no live references):

| File | Reason | Replaced by |
|---|---|---|
| `Puck/Views/Routine/RoutineView.swift` | "Coming soon" placeholder; `PuckTab.routine` enum case maps to ScheduleTabView via the body's TabView declaration, not RoutineView | `Puck/Views/Schedule/ScheduleTabView.swift` |
| `Puck/Views/Routine/HabitGoalCreationView.swift` | No external references; `RegisteredPuck.habitGoalFrequency` field exists but no UI writes it | n/a (concept dropped) |
| `Puck/Views/Routine/WeeklyReportSheet.swift` | No external references | n/a |
| `Puck/Views/Schedule/CalendarTimelineView.swift` | Uses deprecated `IntentionalBlock`; ScheduleTabView uses `DayCalendarView` instead | `DayCalendarView.swift` |
| `Puck/Views/Schedule/QuickBlockButton.swift` | References `ScheduleBlockEditSheet.QuickPrefill`; no callers in current ScheduleTabView | n/a |
| `Puck/Views/Schedule/ScheduleBlockEditSheet.swift` | Old IntentionalBlock-based editor; no external callers | `TimeBlockEditSheet.swift` |
| `Puck/Views/Schedule/ScheduleBlockDetailSheet.swift` | Same | `TimeBlockEditSheet` (handles both modes) |
| `Puck/Views/Evening/EveningModeView.swift` (struct `BedtimeView`) | File misnamed — Evening Mode design pivoted; struct still used by HomeView for active-bedtime takeover but the surrounding "Evening Mode" concept is largely gone | survives via `BedtimeView` struct only |
| `Puck/Views/Evening/EveningShortcutsSetupView.swift` | Wired only from `EveningModeView`/BedtimeView's "Set up Shortcuts" button; Evening Mode shortcut automation never shipped end-to-end | n/a (Phase 4 evening mode unfinished) |
| `Puck/Core/Evening/EveningModeService.swift` (`BedtimeService`) | Still used by HomeView/Coordinator gating but does brightness/grayscale that may not be functional with current bedtime lock-loop design | partially live — `bedtimeService.isActive` is read |
| `Puck/Core/Evening/EveningShortcutsProvider.swift` | AppIntents for Shortcuts; only useful if user wired the evening-mode automation | possibly orphaned |
| `Puck/Views/Wake/WakeActivityView.swift` | No external references | n/a |
| `Puck/Models/PuckSchedule.swift` (both `PuckSchedule` and `ScheduleBlock`) | Models registered in container schema but no UI reads/writes — kept for SwiftData migration | n/a (legacy schedule concept) |
| `Puck/Models/RegisteredPuck.uid: String` field | Comment: "Legacy: NFC hardware UID. Kept for migration, no longer used" (patent compliance) | n/a |
| `Puck/Models/PuckAlarm.dismissPuckId: UUID?` field | Comment: "Legacy: kept for migration"; replaced by `dismissModeSlug` | `dismissModeSlug` |
| `Puck/Models/Sessions.FocusSession.puckUID: String?` field | Comment: "Legacy: kept for migration, no longer written" | n/a |
| `Puck/Core/Schedule/ScheduleBlock.swift` (`IntentionalBlock` model) | `@available(*, deprecated, message: "Use TimeBlock instead — Spec 2 supersedes IntentionalBlock")`; still in container schema | `TimeBlock.swift` |
| `Puck/Core/Schedule/ScheduleBlocksService.swift` | Spec 1 service; UI side is gone but schema kept for migration | `TimeBlocksService.swift` |
| `Puck/Core/Network/IntentionalScheduleClient.swift` | Backed by deprecated /schedule/blocks (backend keeps as 301 redirect for one cycle) | `IntentionalTimeBlocksClient.swift` |
| `Puck/Core/Network/NetworkClient.swift` | Generic client targeting `https://api.getpuck.app`; no callers found | replaced by IntentionalAPIClient |
| `Puck/Views/ContentView.swift` `ModePickerSheet` | Coordinator's `onShowModePicker` is never wired (only declared) — sheet never shows | n/a |
| `Puck/Views/Partner/PartnerView.swift` "Request unlock code" button | Stub alert "Coming soon" — TODO comment in `requestUnlock()` | (planned) |
| `Puck/Views/Partner/PartnerView.swift` "What's shared" row | TODO comment, no-op | (planned) |
| `Puck/Models/FocusMode.swift` `BlockBehavior` enum (`blockSelected` / `allowOnly`) | `blockBehaviorRaw` field on FocusMode; no UI reads/writes it after the redesign | n/a |
| `Puck/Models/FocusMode.swift` `bedtimeBrightness: Double?` | Bedtime lock-loop replaced full-screen overlay; brightness no longer driven from FocusMode | n/a (kept for SwiftData) |
| `Puck/Views/Onboarding/OnboardingFlowView.swift` quiz steps | Skip-able; result page exists but the "calculation" is placeholder | (kept) |

Naming inconsistencies that imply dead-or-renamed concepts:
- File `EveningModeView.swift` contains struct `BedtimeView` — Evening Mode was renamed to Bedtime mid-development, file never renamed.
- Service class `BedtimeService` lives in `Puck/Core/Evening/EveningModeService.swift` — same renaming.
- Tab enum `PuckTab.routine` (title "Schedule") points at `ScheduleTabView`, but the legacy `RoutineView` file still exists.
- Tab enum `PuckTab.intentions` has title "Focus Modes" — the renaming history per task brief: Focus Modes → Intents → Focus Modes.
- The Intentions backend endpoint set is named `/intentions` (singular concept "Intention"), but iOS UI labels the tab "Focus Modes". Mac dashboard CLAUDE.md says user-facing copy is now "Intent(s)".
- `IntentionRowView.swift` exists in `Puck/Views/Intentions/` but `IntentionsTabView` uses an inline `IntentTile` struct (private) instead. The `IntentionRowView` file is the previous list-row layout, replaced by the 2-col grid.

Migration leftovers (legitimately kept short-term):
- `IntentionalBlock` model in container schema (Spec 2 transition period)
- `PuckSchedule` + `ScheduleBlock` models (never had UI — appear to be deeper legacy)
- `puckUID` field on FocusSession; `dismissPuckId` on PuckAlarm (NFC patent rewrite)

---

## 10. Open observations

Naming chaos:
- "Intention" / "Focus Mode" / "Intent": three names for the same concept. Backend table is `intentions`. Local SwiftData model is `FocusMode`. iOS UI labels them "Focus Modes". Strict struct used at the network/store layer is `Intention`. Mac dashboard now calls them "Intents". The user reading IntentionsTabView sees "Focus Modes". The same code calls into IntentionStore.
- "Bedtime" / "Evening Mode": collapsed but with the rename incomplete in file/folder names. `Puck/Core/Evening/` and `Puck/Views/Evening/` should not exist as folders if Evening Mode is gone.
- "Schedule" used for two things: the `ScheduleTabView` (TimeBlocks) AND the legacy `IntentionalScheduleClient` / `ScheduleBlocksService` / `ScheduleBlock` SwiftData model.
- `PuckTab.routine` enum case (title "Schedule") in ContentView points at ScheduleTabView, not RoutineView. Confusing.
- `RegisteredPuck.uid` is named like an NFC UID but per patent compliance is unused. Field name should probably be removed once SwiftData migration is safe.
- `BedtimeService` (the class) is actually for Evening-Mode-style phone degradation. `BedtimeScheduleService` is for the bedtime-lockdown DeviceActivity flow. Two services with overlapping names doing different things — Bedtime card on WakeView reads `bedtimeService.isActive` but the new bedtime lockdown is `bedtimeScheduleService.isActive`.

Mac/iOS asymmetry:
- iOS has Pucks and NFC-tap focus session start; Mac has none of this. Pucks are listed in iOS Settings only.
- iOS has `WakeEvent` streak tracking; Mac doesn't.
- iOS has Bedtime config + lock-loop; Mac also has bedtime but with different primitive (`SACLockScreenImmediate`). Both share `/bedtime/config`.
- Mac has Earned Browse, Time Tracker, Intentional Mode pill, AI scoring, Content Safety NSFW detection — none on iOS.
- iOS has Strictness presets in UI; Mac CLAUDE.md says "Strict-step-down softening will throw a runtime error in the UI dialog until the backend endpoints land — request stage fails with 'Couldn't reach partner'". iOS code calls these endpoints too — same backend deferral applies to both.
- Mac calls focus toggle endpoint with `triggered_by` like `mac_manual`; iOS uses `ios_nfc`. Unified vocabulary needed.
- Mac has "Bedtime" + "Wake" as part of schedule UI; iOS has them as solid coral/lavender banners on the schedule card AND as a card on the Alarms tab. Two surfaces for the same data.
- `BedtimeScheduleConfig.allowlistBundleIDs` is synced; `bedtime_allowlist_tokens_v1` (FamilyControls tokens) is local. So if user picks apps on iPhone A, the same iPhone B sees only the bundle IDs and has to re-pick to get tokens. Documented but worth noting in product brainstorm.

Inconsistent UI patterns:
- `BedtimeDetailView` saves on Save button; `IntentionEditView` also saves on Save button; `AlarmEditView` saves on Save button; `TimeBlockEditSheet` saves on Save toolbar button. Consistent. ✓
- `WakeView` Bedtime card has its own toggle; the toggle changes config without opening the detail view (saves immediately). Different commit semantics from the rest of the app.
- Active session display lives in `HomeView.activeBlockingContent` but bedtime active state takes the entire view (`BedtimeView` replaces idleContent). Two completely different "active session" UI patterns.
- "Focus Modes" tab uses 2-col grid; HomeView "Focus modes" section uses 2-col grid; these are different code paths (different IntentTile and ModeTile structs). Risk of drift.
- `ModeCreationView` and `ModeEditView` are separate views with overlapping responsibilities (color, icon, app picker, websites). Could be one view with a `mode: .create | .edit` enum like `IntentionEditView` already does.
- `ModePickerSheet` (in ContentView.swift) and `IntentionsTabView` both show grids of focus modes with similar tap behavior; the ModePickerSheet can never show today.
- Two onboarding flows: `OnboardingFlowView` (4-question quiz + ResultView + PairingView) and `IntentionPickerOnboardingStep` (D3 post-auth picker). Both gate ContentView. Sequential — quiz runs in `.onboarding` auth state, picker runs after `.authenticated` + before `pickerShown`.
- `BedtimeUnlockRequestSheet` (originator) and `PartnerApprovalView` (partner) and `BedtimeUnlockCodeView` (originator code-entry fallback) — three separate views for one flow with branches by role and channel (push vs email-code).
- `IntentionConflictBanner` only ever surfaces inside Focus Modes tab; conflicts on TimeBlocks would have no surface (conflicts on `/time_blocks` are silently dropped).

Concepts on iOS but not Mac:
- Strictness preset (D4) UI is mirrored across both per the Mac CLAUDE.md. Backend partial. ✓
- Intention 0-app meta state ("Tap to add apps" tile) — iOS-only because Mac doesn't have FamilyControls.
- One-off block (D12) — iOS-only feature on TimeBlockEditSheet.

Concepts on Mac but not iOS:
- Earned Browse pool, social-media tax, AI scoring relevance, Content Safety NSFW detection, Intentional Mode pill, Schedule's Calendar (with rituals), Block Rituals, Switch Intervention coordinator, Day-1 default seeded "Focus" intention with Mac blocklist (server seeds it but iOS UI never seeds the iOS app blocklist — that's the IntentionPickerOnboardingStep).

Things worth flagging for product thinking:
- The "Focus Modes" tab is essentially a 2-col grid of Intentions. Why is there also a "Focus modes" section on Home? Two surfaces, same data, different layouts. Same with how the Schedule card shows Wake/Bedtime banners on the Alarms tab (BedtimeCard) AND on Schedule tab (banners in scheduleCard).
- Pucks are physically tied to a single Intention via `modeSlug`. If user reconfigures an Intention they don't reconfigure the puck — but the puck slug stays in sync because slug is generated from the FocusMode (local SwiftData) not the Intention. Need to think through: what happens when user creates an Intention on Mac? It pulls down to iOS but no FocusMode exists for it (per HomeView grid code: `mode = focusModes.first(where: { $0.intentionId == intention.id })`). The grid handles missing-mode gracefully but the play button is no-op.
- `pendingFocusMode` on PuckCoordinator is a transient state from "user tapped play on a tile" → "wait for NFC". This is iOS-only and could be confusing UX if user picks Intention A then taps a puck paired to Intention B.
- Onboarding quiz collects answers but only uses `dailyTimeLost`, `snoozeCount`, `morningPhoneTime` for a hours-lost/days-reclaimed calculation. `biggestChallenge` is never read.
- `Settings.weeklyEmergencyLimit` is per-device UserDefaults, not synced. Mac and iOS could each have different limits.
- `BedtimeAllowlistView` saves `allowlist_bundle_ids` to backend AND local FamilyControls tokens to App Group — but the backend never sees the tokens, so on a fresh device the bedtime allowlist is empty until user re-picks apps. No UI hint about this.
- The patent-compliance rules in `Puck/CLAUDE.md` mean "pair", "register", "verify", "authenticate" must not be used in NFC UI copy. Worth a copy audit before launch.
- Test target `PuckTests` exists per CLAUDE.md but the project doesn't build it by default; running `xcodebuild test` per the docs.
- `LockStateService` polls `/unlock/status` to gate Sign Out / Delete Account / Emergency Unlock buttons. The lock is per-account, not per-device — so locking on Mac propagates to iPhone. But the UI message says "Open the Intentional app on your Mac" — assumes Mac is the primary device. If user locked from iPhone, iPhone would still send them to Mac.
- The Intention create/update flow always goes through `IntentionEditView` regardless of source. But `ModeCreationView` and `ModeEditView` are separate older flows that ALSO can create/save FocusMode + (theoretically) Intention. Risk of two paths writing to the same backend resource with different code.
- Build artifacts and `Puck 2.xcodeproj` exist alongside `Puck.xcodeproj` — possibly leftover from project rename. XcodeGen generates `Puck.xcodeproj`.
