# Onboarding Rebuild Implementation Plan (Value-Before-Commitment Flow)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the extension-era 5-screen onboarding wizard with the approved 11-screen value-before-commitment flow (Opal-cloned copy): stat opener → quiz (mirror + insight + hours) → name-the-enemy (seeds real Rules) → computed shock math → the deal → can't-cheat flagship → just-in-time screen permission → first session started inside onboarding → partner ask post-win.

**Architecture:** `Intentional/onboarding.html` is rewritten in place (same filename — MainWindow routing untouched). The new flow reuses four existing bridge messages (`CREATE_RULE`, `CREATE_INTENTION`, `START_INTENTION_SESSION`, `SAVE_ONBOARDING`) and adds two new ones (`GET_SCREEN_PERMISSION`, `REQUEST_SCREEN_PERMISSION`). Auth flow (login.html) is untouched. Visuals reuse login.html's coral/warm design tokens. No theme system, no platforms config, no lock screen.

**Tech Stack:** Vanilla HTML/CSS/JS in WKWebView, Swift (MainWindow.swift bridge handlers), existing RuleStore/IntentionStore/FocusModeController plumbing.

---

## Verified integration facts (from code research 2026-06-11)

- Bridge: `window.webkit.messageHandlers.intentional.postMessage(payload)`; screens use `data-screen="N"`, nav via `goToScreen()`; MainWindow registers handler name `intentional` (MainWindow.swift:111).
- `CREATE_RULE` (MainWindow.swift:858, handler :3997): payload `{type:"CREATE_RULE", target_kind:"site", target:"tiktok.com", treatment:"blocked", enabled:true}`. Backend 409s duplicates → handler emits `_ruleCreated({success:false, reason:"duplicate"})` — harmless, fire-and-forget for seeding.
- `CREATE_INTENTION` (MainWindow.swift:741, handler :3333): accepts `name`, `intent_text`, `status`, `week_of` (ISO Monday), `ai_scoring_enabled`. Replies via `window._intentionMutationResult({status:"created", id:"<uuid>"})` (MainWindow.swift:3787-3791).
- `START_INTENTION_SESSION` (MainWindow.swift:758, handler :3496): payload `{type, id:"<intention uuid>"}`. Replies via `window.onProjectSessionResult({status:"started"|"refused"|"error", ...})`. Activates FocusModeController + POSTs /focus/toggle.
- `SAVE_ONBOARDING` (handler MainWindow.swift:907-968): writes `onboarding_settings.json`, sets UserDefaults `onboardingComplete=true`, POSTs partner via `setPartner` if `partnerEmail` present, then calls `window._onboardingSaveResult({success:true})`; JS then sends `NAVIGATE_TO_DASHBOARD`. **Caution:** `onboarding_settings.json` also stores `contentSafety.permissionsConfirmedAt` (ContentSafetyMonitor.swift:561-580) — the save must MERGE, not blind-overwrite.
- No permission bridge messages exist today. Screen Recording is checked via `CGPreflightScreenCaptureAccess()` (ContentSafetyMonitor.swift:121 etc.). Drift detection (RelevanceScorer OCR) degrades gracefully to metadata-only without it — so "Skip for now" on the permission screen is honest.
- Launch routing (MainWindow.swift:276-291): login → (onboardingComplete ? dashboard : onboarding). Unchanged by this plan.
- Design tokens: copy the `:root` block from `Intentional/login.html:10-25` verbatim (`--bg:#0a0c0a`, `--warm-1:#FF4D5E`, `--warm-2:#FF7A2E`, `--warm-3:#FFB347`, `--grad-warm`, `--text-1..4`, `--b-1/2`, Nunito font stack).
- WKWebView drops `alert()/confirm()/prompt()` — all errors must be inline DOM text (feedback_wkwebkit_no_prompt).

## Deliberate copy/product decisions locked here

1. **Chips must map to real blockable domains** (no promises we can't keep). Approved chips "News" and "Shopping" are replaced with **Netflix** and **Amazon**. Final chips: TikTok, Instagram, YouTube, Reddit, X, Twitch, Netflix, Amazon, + add your own. X seeds two rules (`x.com` + `twitter.com`).
2. **Insight card is its own screen** (screen 3) — total 11 screens, thin progress bar (no dots).
3. **Shock math is computed from the user's own answer** (screen 4 → screen 6): Under 2 → "2 hours a day. 30 days a year." / 2-4 → "3 hours a day. 45 days a year." / 4-6 → "5 hours a day. 76 days a year." / No idea → "4 hours a day. 61 days a year." (avg). All = hours×365/24, rounded.
4. **Rules are seeded when the user advances past the enemy screen** (so blocking is live before the first session). Fire-and-forget; duplicates are fine.
5. **First session creates a Weekly Goal** from the typed task (`name` = task text trimmed to 60 chars, `intent_text` = task text trimmed to 140, `status:"in_progress"`, `week_of` = current ISO Monday computed in JS), then starts a session on it. The session is open-ended (no fake 25-min countdown promise; "25 minutes" in copy is the suggested first rep and matches the real 5:1 allowance earn rate).
6. **Partner screen ends onboarding**: both "Add my person" and "Maybe later" send `SAVE_ONBOARDING` (with/without partner) → `NAVIGATE_TO_DASHBOARD`. `lockMode` is always `"none"` (strictness now lives on the dial; lock screen deleted).
7. The permission screen polls `GET_SCREEN_PERMISSION` every 2s while visible (grant state can change while the user is in System Settings).

---

### Task 1: Swift — screen-permission bridge messages

**Files:**
- Modify: `Intentional/MainWindow.swift` (message switch ~line 858 region; new private funcs near handleCreateRule ~line 3997)

- [ ] **Step 1: Add the two cases to the bridge message switch** (same `switch` that contains `case "CREATE_RULE":` at MainWindow.swift:858 — add adjacent):

```swift
case "GET_SCREEN_PERMISSION":
    emitScreenPermissionStatus()
case "REQUEST_SCREEN_PERMISSION":
    handleRequestScreenPermission()
```

- [ ] **Step 2: Add the handlers** (place next to `handleCreateRule`):

```swift
// MARK: - Screen-permission bridge (onboarding just-in-time ask)

private func emitScreenPermissionStatus() {
    let granted = CGPreflightScreenCaptureAccess()
    callJS("window._screenPermissionStatus && window._screenPermissionStatus({\"granted\": \(granted)})")
}

private func handleRequestScreenPermission() {
    if CGPreflightScreenCaptureAccess() {
        emitScreenPermissionStatus()
        return
    }
    // Triggers the one-time system prompt AND registers the app in the
    // Screen Recording list. Returns current grant state immediately.
    let granted = CGRequestScreenCaptureAccess()
    if !granted {
        // The system prompt only fires once per install; afterwards the user
        // must flip the toggle manually — take them straight to the pane.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    emitScreenPermissionStatus()
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | grep -E "error:|BUILD" | sort -u`
Expected: `** BUILD SUCCEEDED **`, no errors.

- [ ] **Step 4: Commit**

```bash
git add Intentional/MainWindow.swift
git commit -m "feat(onboarding): GET/REQUEST_SCREEN_PERMISSION bridge messages"
```

---

### Task 2: Swift — SAVE_ONBOARDING accepts the new payload (merge-write)

**Files:**
- Modify: `Intentional/MainWindow.swift:907-968` (`handleSaveOnboarding`) and `:1017-1046` (`saveOnboardingSettings`)

- [ ] **Step 1: Read both functions in full first** (`handleSaveOnboarding`, `saveOnboardingSettings`) so the edit preserves the partner POST + `getPartnerStatus` + `setLockMode` behavior exactly as-is.

- [ ] **Step 2: Make the persistence pass through the whole settings dict, merged over the existing file.** Replace the body of `saveOnboardingSettings` (keep its signature if it fits, otherwise add a new `mergeOnboardingSettings(_ new: [String: Any])` and call it from `handleSaveOnboarding`):

```swift
/// Merge-writes onboarding settings. MUST NOT drop keys other components
/// store in this file (e.g. contentSafety.permissionsConfirmedAt).
private func mergeOnboardingSettings(_ new: [String: Any]) {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Intentional", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("onboarding_settings.json")
    var merged: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        merged = existing
    }
    for (k, v) in new { merged[k] = v }
    merged["completedAt"] = ISO8601DateFormatter().string(from: Date())
    if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url)
    }
}
```

In `handleSaveOnboarding`, keep the existing extraction of `partnerEmail` / `partnerName` / `lockMode` (default `"none"` when absent), keep `UserDefaults` writes (`onboardingComplete=true`, `lockMode`), keep the async partner POST + consent fetch + `setLockMode` block, and replace the old field-by-field JSON construction with `mergeOnboardingSettings(settings)` where `settings = body["settings"] as? [String: Any]`. The new payload's extra fields (`quiz`, `enemyPicks`) ride through untouched. Absent `platforms`/`theme` must not crash (current code already uses optional `as?` extraction — verify after edit).

- [ ] **Step 3: Build**

Run: `xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | grep -E "error:|BUILD" | sort -u`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Intentional/MainWindow.swift
git commit -m "feat(onboarding): SAVE_ONBOARDING merge-writes new quiz/enemyPicks payload"
```

---

### Task 3: Rewrite onboarding.html — the 11-screen flow

**Files:**
- Rewrite: `Intentional/onboarding.html` (full replacement; old file is ~1869 lines, new is ~600)

- [ ] **Step 1: Replace the file in full.** Structure spec (all copy is FINAL — approved 2026-06-11, do not edit wording):

  **Head/CSS:** copy `:root` token block verbatim from `Intentional/login.html:10-25`. Dark `--bg` background. One `.screen` class with fade/slide transitions (reuse old `goToScreen` active/exit-left pattern). Thin 3px progress bar fixed at top: width = `(currentScreen/11)*100%`, background `var(--grad-warm)`. Headline ~34px/800, sub ~16px `var(--text-2)` one line, primary button = pill, `var(--grad-warm)` bg, `--cta-text` color. Option rows and chips: `--b-2` border, 12px radius, selected state = warm border + subtle warm tint. NO theme system, NO violet.

  **Screens (`data-screen` 1–11):**

  1. **Stat opener.** H1 `5 to 6 hours.` Sub `That's the average time you'll spend on a screen today.` Button `See where it goes` → next.
  2. **Mirror question.** H1 `Ever deleted an app to focus?` Sub `And reinstalled it within the week?` Three option rows: `More times than I can count` / `Once or twice` / `Never`. Tap records `state.quiz.reinstall`, auto-advances after 250ms.
  3. **Insight card.** H1 `You're not alone.` Body `Most people reinstall within 3 days. It's not a willpower problem. Those apps are built by teams whose job is to beat you.` Button `Continue` → next.
  4. **Hours question.** H1 `How many hours did you scroll yesterday?` Four option rows: `Under 2` / `2 to 4` / `4 to 6` / `Honestly, no idea`. Records `state.quiz.hoursPerDay`, auto-advance.
  5. **Name the enemy.** H1 `Where does it go?` Sub `Tap everything that pulls you in.` Chip grid: TikTok, Instagram, YouTube, Reddit, X, Twitch, Netflix, Amazon, plus a `+ add your own` chip that reveals a text input (domain cleanup: lowercase, strip protocol/`www.`, require a dot; invalid input shows inline red text `Enter a site like example.com`). Button `Next` (disabled until ≥1 pick) → **on advance, fire one `CREATE_RULE` per pick** (X fires `x.com` AND `twitter.com`), then next.
  6. **Shock math** (computed from screen 4 per the table in the decisions section). H1 e.g. `3 hours a day. 45 days a year.` Sub e.g. `A month and a half, gone to the feed.` ("No idea" variant sub: `That's the average. Two months, gone to the feed.`) Button `Get it back` → next.
  7. **The deal.** H1 `Here, scroll time is earned.` Sub `Focus 25 minutes. Earn 5 minutes back.` Three static rows (first row interpolates up to 3 of the user's picks by label): `🚫 TikTok, Instagram, YouTube: blocked while you work` / `✅ 15 free minutes a day, guilt-free` / `⏱ Every focused 25 earns 5 more`. Button `Sounds fair` → next.
  8. **Can't cheat.** H1 `This one you can't cheat.` Sub `No off switch to find at 1am. Strict mode gives the key to someone you trust.` Button `Good. I need that.` → next.
  9. **Permission.** H1 `One thing first.` Sub `Intentional reads your screen to spot drift. Nothing ever leaves your Mac.` Button `Allow screen access` → sends `REQUEST_SCREEN_PERMISSION`. Below: muted link `Skip for now` → next. On screen-enter: send `GET_SCREEN_PERMISSION` and start a 2s poll (cleared on screen-exit). `window._screenPermissionStatus({granted})`: when granted, swap button for `✓ You're set` (green, disabled) and auto-advance after 900ms.
  10. **First session.** H1 `Pick one thing to finish today.` Sub `25 minutes. We'll guard the door.` Text input placeholder `e.g. Finish the deck for Thursday's pitch`. Button `Start my first session` (disabled while empty): sends `CREATE_INTENTION` `{type, name: task.slice(0,60), intent_text: task.slice(0,140), status: "in_progress", ai_scoring_enabled: true, week_of: <ISO Monday computed in JS>}`; on `window._intentionMutationResult({status:"created", id})` sends `START_INTENTION_SESSION {type, id}`; on `window.onProjectSessionResult({status:"started"})` → next. Any error status → inline red text `Couldn't start the session. Check your connection and try again.` + button re-enabled. While in flight, button text `Starting…` disabled. (NEVER `alert()`.)
  11. **Partner, post-win.** Small green badge line `● Session running` at top. H1 `Want backup?` Sub `Strict mode works best with someone you'd hate to disappoint.` Inputs: name placeholder `e.g., Mom, Alex, Coach`, email placeholder `partner@email.com`. Primary `Add my person` (validates email regex; inline error `That email doesn't look right`) → `finish(withPartner=true)`. Muted link `Maybe later` → `finish(withPartner=false)`.

  **finish(withPartner):** sends
  ```js
  sendMessage({ type: 'SAVE_ONBOARDING', settings: {
    quiz: state.quiz,                          // {reinstall, hoursPerDay}
    enemyPicks: Array.from(state.picks),       // domain list actually seeded
    firstTask: state.firstTask || null,
    partnerEmail: withPartner ? email : null,
    partnerName:  withPartner ? (name || null) : null,
    lockMode: 'none'
  }});
  ```
  `window._onboardingSaveResult(r)`: if `r.success` → `sendMessage({type:'NAVIGATE_TO_DASHBOARD'})`; else inline error on the partner screen.

  **ISO Monday helper:**
  ```js
  function isoMonday() {
    const d = new Date();
    const day = (d.getDay() + 6) % 7;   // Mon=0
    d.setDate(d.getDate() - day);
    return d.toISOString().slice(0, 10);
  }
  ```

  **Keep:** `sendMessage()` bridge guard exactly as in the old file (lines 1453-1459 pattern). Keyboard: Enter on screens with a single primary button triggers it.

- [ ] **Step 2: Syntax sanity check** (no Node DOM test — WKWebView is the real surface; this just catches JS parse errors):

Run: `python3 -c "import re,sys; html=open('Intentional/onboarding.html').read(); m=re.findall(r'<script>(.*?)</script>', html, re.S); open('/tmp/ob.js','w').write('\n'.join(m))" && node --check /tmp/ob.js && echo JS_OK`
Expected: `JS_OK`

- [ ] **Step 3: Verify zero leftovers**

Run: `grep -ci "theme\|platform\|shorts\|reels\|lock your settings\|set up my limits" Intentional/onboarding.html`
Expected: `0`

- [ ] **Step 4: Commit**

```bash
git add Intentional/onboarding.html
git commit -m "feat(onboarding): 11-screen value-before-commitment flow, approved copy"
```

---

### Task 4: Build + live host smoke test

- [ ] **Step 1: Full build**

Run: `xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | grep -E "error:|BUILD" | sort -u`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Launch dev instance** (`./scripts/dev-launch.sh --no-build`), then drive the onboarding page via the DEBUG ui-test hook (same `/tmp/intentional-uitest-cmd.json` mechanism used in the 2026-06-11 cold-walk) — force the window to onboarding.html if needed and step through all 11 screens, asserting per screen that the H1 text matches the approved copy. The Rules-seeding step (screen 5 → Next) must produce `_ruleCreated` logs; check `~/Library/Application Support/Intentional/rules.json` afterwards for the picked domains.
  **CAUTION (host machine):** screen 10 starts a REAL session on the user's account. Use a throwaway task name, then immediately stop the session from the menubar/dashboard after the test, and delete the created test goal + test rules. Better: do only screens 1–9 on the host; screens 10–11 get fully exercised in the VM (Task 5).

- [ ] **Step 3: Commit any fixes** (`fix(onboarding): ...`).

---

### Task 5: VM cold-walk verification + docs

- [ ] **Step 1: Stage the build into the Tart VM** (procedure proven 2026-06-11: sign with adjusted entitlements — strip `application-identifier`/`team-identifier` — scp tarball, relaunch; SSH `admin@$(tart ip intentional-test)`, password auth with `-o IdentitiesOnly=yes -o PreferredAuthentications=password`).
- [ ] **Step 2: Fresh-account walk:** sign up with a new `ameer.rayan+ob2@gmail.com` alias (OTP via Gmail tool), then drive all 11 screens via the ui-test hook. Screenshot EVERY screen (`/tmp/ob-N.png`). Verify: (a) copy matches approved text verbatim, (b) rules.json in VM contains the picks, (c) session actually starts (pill/menubar state + `onProjectSessionResult` status started), (d) partner skip path lands on dashboard mid-session — dashboard must NOT be the empty cliff (goal exists, session running), (e) relaunching the app shows dashboard (onboardingComplete persisted).
- [ ] **Step 3: Permission screen check in VM:** click `Allow screen access`, confirm the macOS prompt (or Settings pane) appears and the poll flips the button to `✓ You're set` after granting.
- [ ] **Step 4: Docs (same commit discipline):** create `docs/features/onboarding.md` from `docs/features/_TEMPLATE.md` (`status: shipping`, `files: [Intentional/onboarding.html, Intentional/MainWindow.swift]`, flow description, bridge contract incl. the two new permission messages); run `scripts/check-docs.sh` → must pass; update `docs/PROJECT-STATE-2026-06-11.md` item 3 to DONE; add a dated HTML walk report only if screenshots reveal fixes worth recording.
- [ ] **Step 5: Commit + push**

```bash
git add docs/ Intentional/
git commit -m "feat(onboarding): verified 11-screen flow end-to-end in VM + feature doc"
git push origin main
```

---

## Self-review notes

- Spec coverage: stat ✓(S1) quiz ✓(S2-4) insight ✓(S3) enemy→Rules ✓(S5+CREATE_RULE) shock math ✓(S6, computed) deal ✓(S7) flagship ✓(S8) permission ✓(S9+new bridge) first session ✓(S10+CREATE_INTENTION/START_INTENTION_SESSION) partner post-win ✓(S11) theme/platforms/lock deleted ✓ auth untouched ✓ empty-dashboard cliff killed ✓ (lands mid-session with a goal).
- Type consistency: `_screenPermissionStatus` / `_intentionMutationResult` / `onProjectSessionResult` / `_onboardingSaveResult` / `_ruleCreated` names verified against MainWindow.swift.
- Known accepted edges: quitting between screen 10 and 11 leaves onboardingComplete=false with a session running (re-shows onboarding; CREATE_RULE duplicates no-op, a second goal could be created — acceptable). Screen-recording grant on macOS may require app relaunch to take effect for actual capture; status reporting is still correct and RelevanceScorer degrades gracefully meanwhile.
