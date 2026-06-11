# UI Jargon Audit — 2026-06-11

**Audience test:** a 15-year-old and their non-technical parent must understand every word.
**Locked vocab:** Goals · Rules · Allowance · Sessions · Blocks (time) · Strictness.
**House style:** warm, short, self-help-first (works for a solo adult AND a parent-teen pair). Subtitles 3–7 words. No lectures.

Read-only audit. Line numbers are as of this morning's `main` working tree — another agent is editing `dashboard.html`, so treat them as anchors, not gospel.

---

## Summary counts per surface

| Surface | P0 | P1 | P2 | Total |
|---|---|---|---|---|
| Sidebar + status footer (dashboard.html) | 4 | 2 | 0 | 6 |
| Today page (dashboard.html) | 3 | 3 | 1 | 7 |
| Goals/Plan page + goal editor + modals (dashboard.html) | 4 | 4 | 2 | 10 |
| Rules page + allowance + rule modal (dashboard.html) | 2 | 3 | 1 | 6 |
| Accountability page (dashboard.html) | 0 | 2 | 1 | 3 |
| Settings (Strictness, Screen Lock, Sensitive Content, Bedtime) (dashboard.html) | 2 | 4 | 1 | 7 |
| Legacy "Focus Mode" / page-intentions surfaces (dashboard.html) | 2 | 1 | 0 | 3 |
| Pill (DeepWorkTimerController.swift) | 1 | 2 | 2 | 5 |
| Overlays (FocusOverlayWindow, FocusStartOverlay, NudgeWindow, StageOneIntent, Intervention, blocked.html) | 3 | 4 | 1 | 8 |
| Notifications + menu bar (FocusMonitor, AppDelegate, BedtimeWindDown) | 0 | 3 | 1 | 4 |
| onboarding.html | 0 | 2 | 0 | 2 |
| login.html | 1 | 0 | 0 | 1 |
| **Total** | **22** | **30** | **10** | **62** |

---

## P0 — Confusing, wrong, or actively misleading

| # | Location | Current text | Why it fails | Suggested replacement |
|---|---|---|---|---|
| P0-1 | Rules page, allowance card · `Intentional/dashboard.html:9552-9556` | "⏳ Allowance · 38 min left today" + "Base 15 · Earned 4 · Spent 2 · Bank 0/60 · 5 focused min = 1 allowance min" | The breakdown is a formula dump. "Bank 0/60" is a cryptic fraction of two unexplained numbers; "Base" is dev vocabulary; a teen reads "Bank" as money. | Keep headline. Breakdown as a sentence: "15 daily + 4 earned − 2 used · 0 min saved for tomorrow (max 60) · every 5 focused min earns 1" |
| P0-2 | Allowance editor field · `Intentional/dashboard.html:5172`, error at `:9607` | "Bank cap — rollover limit (0–240)" / "Bank cap must be 0–240 minutes." | "Bank cap" + "rollover limit" are two pieces of jargon explaining each other. | "Save for tomorrow — up to (minutes)" / "You can save 0–240 minutes for tomorrow." |
| P0-3 | Log-time modal · `Intentional/dashboard.html:14404` | "Adds a backend focus session — counts toward your hours_done." | Worst string in the app: "backend" + raw DB column `hours_done` shown to users. | "This time counts toward your goal's progress." |
| P0-4 | Sidebar session card · `Intentional/dashboard.html:4968-4971` | Label "Session" (renders "SESSION" via CSS uppercase) over "Free Time" / "No active session" | Three messages stacked, two of them near-duplicates. "Free Time" is also a block type elsewhere — same words, different concept. Parent reads "SESSION / Free Time" as gibberish. | One line under a "Now" label: "Not in a session" (and when active: "Writing essay · 32 min left"). |
| P0-5 | Sidebar status footer · `Intentional/dashboard.html:4983-4991`, `:15379-15409` | "Partner — checking…", "Content — checking…", "Puck — checking…", "Content protection · ON", "Puck · not paired", "⟨Name⟩ · partner active" | "Puck" is unexplained hardware (most users don't own one); "Content protection" is ambiguous (protecting content?); "partner active" reads like surveillance status. ON/OFF caps feel like a server console. | "Partner: Caity ✓" / "No partner yet" · "Sensitive-content filter: on/off" · hide the Puck row entirely when no Puck has ever paired; otherwise "Puck connected / not connected". |
| P0-6 | Today schedule header button · `Intentional/dashboard.html:5034` | "+ Focus" | "+ Focus" isn't a thing you add. Sibling button "+ Free Time" names a duration; this names a mood. | "+ Focus time" (or "+ Session" to match locked vocab). |
| P0-7 | Block editor goal picker → slide-in editor · picker label `Intentional/dashboard.html:11995`, "+ Create new weekly goal…" `:10500`, sheet title "New Focus Mode" `:14193` | Picker is labeled "Weekly Goal", its create-option says "weekly goal", the sheet that opens says **"New Focus Mode"** | Three names for one concept on one click-path (Weekly Goal → Focus Mode; "Intention" survives in code comments and the old page). The #1 vocabulary inconsistency in the app. | Rename sheet title to "New Weekly Goal". Purge "Focus Mode"/"Intention" from all user-visible strings. |
| P0-8 | Same picker, first option · `Intentional/dashboard.html:10517` | "(none)" | Programmer null. A parent doesn't know what picking "(none)" does. | "No goal — just this session" |
| P0-9 | Session-start overlay · `Intentional/FocusStartOverlay.swift:134,150,155,96` | "BLOCKING PROFILES" · "AI FOCUS (OPTIONAL)" · "Describe your task for AI scoring..." · "Just Block Distractions" | This is a live surface (manual toggle + Puck start). "Blocking Profiles" is a dead concept (removed from dashboard May 2026); "AI FOCUS" and "AI scoring" are engine-room words. | Drop the profiles section header or rename to "What gets blocked". "AI FOCUS (OPTIONAL)" → "What are you working on? (optional)". Placeholder → "e.g. writing my history essay in Google Docs". |
| P0-10 | Legacy projects page · `Intentional/dashboard.html:~13049` ("Define a focus mode, pick a blocklist, get to work."), `:~13699` ("No blocklists yet. Create one in Distractions.") | — | "Focus mode", "blocklist", and a pointer to the **Distractions tab, which no longer exists** (killed Slice 10, 2026-05-05). User is told to go somewhere that's gone. | If this page is still reachable, repoint to "Rules" and rename concepts to Goals/Rules; if not reachable, delete the strings. |
| P0-11 | blocked.html install CTA · `Intentional/blocked.html:463-470` | "Chrome Web Store" / "Firefox Add-ons" / "Install Extension" | The browser extension was removed 2026-05-21. This sends users to install something that doesn't exist (URLs are placeholders too). | Delete the install path; replace with "Intentional protects this browser automatically." |
| P0-12 | Goals (Plan) page header · `Intentional/dashboard.html:15156` and month eyebrow `:15212` | Hardcoded "Wednesday · Week 2 of May" and eyebrow "May" | It is June. The page literally displays the wrong date/month — prototype strings shipped as-is. | Compute from `Date()`: weekday + "Week N of ⟨month⟩". |
| P0-13 | Settings → Strictness → Advanced → Screen Lock · `Intentional/dashboard.html:5588,5599,5604` | "Block your screen until you set a focus mode for your time" · "When should Intentional Mode be active?" · option "Puck Only" | "Intentional Mode" and "focus mode" are both dead concepts (consolidated April 2026); "Puck Only" is meaningless without a Puck. | "Lock your screen until you start a session" · "When should Screen Lock be on?" · hide "Puck Only" unless a Puck is paired. |
| P0-14 | Strictness Advanced grid · `Intentional/dashboard.html:5494,5548,5560,5572` | "Per-mechanism overrides" · rows "Auto-redirect", "Intervention exercises", "Context-switch countdown" | "Per-mechanism overrides" is engineering taxonomy. Row names describe internals, not what the user experiences. | Card title: "Fine-tune what happens". Rows: "Send me back to my work", "Make me pause and refocus", "Countdown before switching apps". |
| P0-15 | AI Assessments card (Today) · title `Intentional/dashboard.html:5053`; badges `:12636-12642`; reasons from `Intentional/FocusMonitor.swift:3202,2251,3016,1924,3503` | "AI Assessments" · badges "META", "META ?", "OCR ✓/✗" with tooltips like "Off-task verdict below confidence threshold — not enforced" · log reasons "Block rule (standalone)", "Whitelisted site", "Deep Work auto-redirect red shift", "Browser activated — maintaining red shift pending AI score", "Level 2 nudge (persistent)" | An entire debug console rendered on the main Today page. "OCR", "metadata", "verdict", "whitelisted", "standalone" all fail the 15-year-old test. | Card title "Activity check". Badges → plain words ("quick check" / "read the screen"). Reasons → human sentences ("Blocked by your rule", "On your always-allowed list", "Sent you back to work"). Or move the raw detail behind a "details" disclosure. |
| P0-16 | Blocking overlay "Why?" panel · `Intentional/FocusOverlayWindow.swift:589-591,633,637,653` | "Metadata only" / "Metadata only (low confidence — not enforced)" / "OCR-verified" / "Verdict path" / "OCR excerpt" / "Trace" | Debug internals on the full-screen overlay a frustrated user sees mid-block. "Verdict path" sounds like a courtroom. | "How we checked: page title only / read what's on screen". Drop "Trace" + "OCR excerpt" behind a dev flag. |
| P0-17 | Pill + nudge toast button · `Intentional/DeepWorkTimerController.swift:685-687`, `Intentional/NudgeWindowController.swift:224-226` | "Override AI" / "Override AI (none left)" | "Override" + "AI" = robot fighting language. "(none left)" reads like ammo. Parent-teen hostile: sounds like the machine is in charge. | "I need this" / "No passes left today". |
| P0-18 | New-session modal + scheduler dropdown · `Intentional/dashboard.html:5779,15339`, goal editor `:9871` | "No goal — standalone session" · "No link · standalone" | "Standalone" is software vocabulary. | "Not linked to a goal" / "No goal linked". |
| P0-19 | login.html, whole page · `Intentional/login.html:359-471` | "Sign in to Puck", "puck" wordmark, "Subscriptions managed on getpuck.com" | The Mac app is **Intentional**; the login screen says you're signing into a different product. First-run brand whiplash for a parent setting this up. | "Sign in to Intentional" + Intentional wordmark (keep getpuck.com only if billing truly lives there, phrased "Billing is handled at getpuck.com"). |
| P0-20 | Strict Mode toasts (3 variants) · `Intentional/dashboard.html:6254,9123,9620` | "Strict Mode — unlocking a protection needs a partner code" / "…loosening a rule needs a partner code" / "…loosening the allowance needs a partner code" | "Loosening" is internal gate vocabulary; the message names the policy, not the next step. | "Locked by Strict Mode — ask your partner for the code to change this." (one consistent string). |
| P0-21 | Strictness cool-down dialog · `Intentional/dashboard.html:14079` | "Tomorrow you, not right-now you, gets the change.\n\nYou picked Standard because it's where the work happens. The cool-down is the part that protects that decision…" | A three-paragraph lecture in a native confirm box. Violates "no lectures"; patronizing to both teen and adult. | "This change takes effect in 24 hours, so future-you gets a say. You can cancel anytime before then. Continue?" |
| P0-22 | Bedtime settings detail · `Intentional/dashboard.html:5694,5697` | "Wind-down and sleep enforcement" · "Bedtime Enforcer" · "15-min wind-down, then lockout with 3-min auto-sleep" | "Enforcement/Enforcer/lockout/auto-sleep" — prison vocabulary, four jargon terms in two lines. "Wind-down" alone is fine; the stack isn't. | Sub: "Reminders, then the screen locks". Label: "Bedtime". Desc: "Reminders starting 15 min before, then your Mac locks at bedtime." |

---

## P1 — Jargon or inconsistency, understandable with effort

| # | Location | Current text | Why it fails | Suggested replacement |
|---|---|---|---|---|
| P1-1 | Sidebar tab vs page naming · `Intentional/dashboard.html:4937` (tab "Goals") vs `:9712,9749` ("Open Plan →"), `:5131` ("Loading planning view…") | Tab says **Goals**; links on Today say **Open Plan →** | Same destination, two names. User looks for a "Plan" tab that doesn't exist. | "Open Goals →" / "Loading your goals…" |
| P1-2 | Sidebar blocking pill · `Intentional/dashboard.html:4965,8937` | "No rules blocking" | Reads backwards ("rules blocking what?"). | "No blocks active right now" |
| P1-3 | Today, coach card · `Intentional/dashboard.html:5018`, also "What the coach will see" `:12088`, "helps coach judge relevance" `:10903` | "Coach context" | Who is "coach"? Concept never introduced anywhere in the UI. | "What the app knows about you" (and pick ONE name for the AI across the app — currently "AI", "coach", "scorer"). |
| P1-4 | Today, profile card + Settings copy · `Intentional/dashboard.html:5068,5384,9894,9902,10045,14202` | "…judge which tabs and apps are relevant", "Drives local AI relevance scoring for this goal.", "Used by AI relevance scoring during sessions.", "Specifics the AI uses to score relevance" | "Relevance scoring" is the engine's name for itself; five surfaces use four phrasings. | One phrasing everywhere: "Helps the app tell work from distraction." |
| P1-5 | Goal editor delete confirm · `Intentional/dashboard.html:10248` | "Delete this weekly goal? Past sessions stay; future sessions become unlinked." | "Become unlinked" is database-speak. | "Delete this goal? Your past sessions are kept; upcoming ones just won't have a goal attached." |
| P1-6 | Rule modal field label · `Intentional/dashboard.html:9333` | "Treatment" | Medical/dev term for "what happens to it". | "What happens" |
| P1-7 | Rule treatment hint · `Intentional/dashboard.html:9377` | "Never blocked, never swept — even mid-session." | "Swept" never explained on this page (sweep concept lives elsewhere). | "Never blocked — and we never close its tabs." |
| P1-8 | Allowance editor field · `Intentional/dashboard.html:5170` | "Earn rate (1–20) — 5 focused min = 1 allowance min" | Label leads with the variable name and a range, not the meaning. | "How you earn time — every 5 focused minutes adds 1 minute" |
| P1-9 | Strictness desc (custom) · `Intentional/dashboard.html:10694` | "Custom mix — individual interventions are set under Advanced below." | "Interventions" is clinical. | "Custom — you've fine-tuned what happens under Advanced." |
| P1-10 | Strictness toast · `Intentional/dashboard.html:10679,10681` | "Enforcement settings saved" / "Failed to save enforcement settings" | "Enforcement" anywhere user-visible fails the test. | "Strictness saved" / "Couldn't save strictness" |
| P1-11 | Settings → Sensitive Content sub · `Intentional/dashboard.html:5645` | "On-device NSFW detection. When enabled, an overlay covers the screen and your accountability partner is notified." | "NSFW" + "on-device" + "overlay" in one breath. | "Detects explicit content on your screen — privately, on your Mac. If found, the screen is covered and your partner is notified." |
| P1-12 | Settings card title duplication · `Intentional/dashboard.html:5644 vs 5647` | Page titled "Sensitive Content", card inside titled "Content Safety" | Two names for the same feature, same screen. | Use "Sensitive Content" for both. |
| P1-13 | Strict Mode (App Persistence) · toast `Intentional/dashboard.html:8048`, menu `Intentional/AppDelegate.swift` ("App Persistence is On") | "App persistence enabled" | "Persistence" is dev vocabulary. | "Intentional now stays running" / "Can't be quit while Strict Mode is on". |
| P1-14 | Accountability → planning prompt toast · `Intentional/dashboard.html:6162` | "Plan-first prompt: ON" | Feature flag naming style, internal feature name. | "Planning reminders on" |
| P1-15 | Accountability "How it works" step 2 · `Intentional/dashboard.html:7946` | "Choose what's shared — Revocations, emergency unlocks, weekly summary." | "Revocations" is legal-speak. | "When they're notified — unlock requests, big changes, a weekly summary." |
| P1-16 | Journal entries · `Intentional/dashboard.html:8779` | "Free Browse" / "No intent set" | "Free Browse" is a retired feature name; "intent" leaks the old Intentions vocab. | "Break time" / "No note added" |
| P1-17 | Sweep toast + stash window · `Intentional/dashboard.html:6353`, `Intentional/StashInspectorWindow.swift:35,98` | "Stashed 22 tabs · hid 3 apps", "Session Stash", "Nothing in this stash." | "Stash" is unexplained slang for "saved your tabs as bookmarks"; the toast then explains it in sentence two anyway. | "Put away 22 tabs · hid 3 apps" / window: "Tabs we put away" / "Nothing put away yet." |
| P1-18 | Relevance log action text · `Intentional/dashboard.html:12627-12628`, FocusMonitor "Red shift" strings | "red shift on" / "red shift off" | Astronomy term for "screen turned red". | "screen tinted red" / "tint removed" |
| P1-19 | Intervention overlay validation · `Intentional/InterventionOverlayController.swift:606` | "Use real words (need spaces)" | Snarky robot-teacher tone at the user's lowest moment. | "Write a short sentence" |
| P1-20 | Stage-one intent window subtitle · `Intentional/StageOneIntentWindow.swift:120` | "Two questions. Specific answers help the AI scoring decide what to close." | "AI scoring" + threatens closing things before the session starts. | "Two questions. The more specific you are, the better we can guard your focus." |
| P1-21 | Pill bedtime button · `Intentional/DeepWorkTimerController.swift:2376` | "Push 10" | Push what? Gym vocabulary. | "+10 min" |
| P1-22 | Pill block-type labels · `Intentional/DeepWorkTimerController.swift:2641-2642,2046,2052` | "DEEP FOCUS" vs "FOCUS" (and quick-block buttons "Deep Focus" / "Focus") | The two-tier distinction is never explained anywhere a user can read; the words differ by one adjective. | Keep "Deep Focus" but caption the difference at point of choice ("stricter blocking") — or collapse to one label if tiers merge. |
| P1-23 | Menu bar · `Intentional/AppDelegate.swift:~1447` | "Status: Active ✓" | Active *what*? Sounds like a license check. | "Protection on ✓" |
| P1-24 | onboarding platform card · `Intentional/onboarding.html:1229` | "Block Mode" | Names a mode, not an outcome; never referenced again post-onboarding. | "When to block" |
| P1-25 | onboarding Instagram toggle · `Intentional/onboarding.html:1290` | "NSFW Filter" | A parent may not know the acronym; a 15-year-old definitely does — wrong direction. | "Hide adult content" |
| P1-26 | Blocking-profiles prompt (legacy, hidden UI) · `Intentional/dashboard.html:6972` | `prompt('New profile name:')` | `prompt()` has no WKWebView handler in MainWindow (only alert/confirm at `MainWindow.swift:354,362`) — returns null, so this flow silently does nothing. Copy that can never appear. | Delete with the rest of the profiles UI, or use the `.ns-modal-overlay` pattern. |
| P1-27 | Rules page subtitle · `Intentional/dashboard.html:5154` | "What's blocked, limited, and always fine — synced to your iPhone." | Mostly good — but "synced to your iPhone" is wrong for Mac-only users and stale if no iPhone is paired. | "What's blocked, limited, and always fine." (append iPhone clause only when an iOS device exists on the account) |
| P1-28 | Today empty assessments · `Intentional/dashboard.html:5058` | "No assessments yet" | "Assessments" = school exams to a teen. | "Nothing checked yet" |
| P1-29 | Goal status vocabulary · `Intentional/dashboard.html:9724-9726` + Plan React cards | statuses render as "planned / in progress / done / slipped / dropped" | "Slipped" and "dropped" are PM-speak; "slipped" reads as a fall. | "behind" / "let go" (or keep "done/in progress/planned" only on cards). |
| P1-30 | Unscheduled-time overlay heading pair · `Intentional/FocusOverlayWindow.swift:353,359` | Eyebrow "Unscheduled time" over "You're not in a focus session" | Two abstractions stacked; "focus session" vs sidebar's "session" vs pill's "block" — pick one. Body copy below is the approved canonical line and is good. | Eyebrow "Free time" · heading "You're not in a session". |

---

## P2 — Polish

| # | Location | Current text | Why it fails | Suggested replacement |
|---|---|---|---|---|
| P2-1 | Pill noPlan header · `Intentional/DeepWorkTimerController.swift:1969` | "NO PLAN" | Shouty; mild blame tone. | "NOTHING PLANNED" |
| P2-2 | Pill celebration encouragement · `Intentional/DeepWorkTimerController.swift:874-875` | "We'll get there. Keep showing up." | Fine for adults; slightly self-helpy for a teen — borderline, keeping P2. | "Next one's yours." |
| P2-3 | Settings → Bedtime sub · `Intentional/dashboard.html:5332` | "Configure" | Verb with no object. | "11:00 PM – 7:00 AM" (show the actual times) |
| P2-4 | Reset detail sub · `Intentional/dashboard.html:5715` | "Careful — these actions can't be undone" | Good tone, just longer than house style (7-word cap). | "These can't be undone" |
| P2-5 | Uninstall verify button · `Intentional/dashboard.html:8748` | "Verify & Uninstall" | "Verify" is system-speak. | "Confirm & Uninstall" |
| P2-6 | Menu bar · `Intentional/AppDelegate.swift` | "Toggle Focus (⌘⇧P)" | "Toggle" is switch-speak. | "Start / Stop Session (⌘⇧P)" |
| P2-7 | Plan React drag hint · `Intentional/dashboard.html:14931` | "No sessions planned · drag weekly goals here" | OK, but "weekly goals" vs the cards just labeled "Your goals". | "Nothing planned · drag a goal here" |
| P2-8 | New session modal section · `Intentional/dashboard.html:5772` | "Done looks like" (collapsed summary) | Insider shorthand as a bare label; placeholder inside explains it, summary doesn't. | "What does done look like?" |
| P2-9 | Goal editor back link · `Intentional/dashboard.html:9883` | "‹ All Weekly Goals" | Page it returns to is titled "Your goals". | "‹ Your goals" |
| P2-10 | blocked.html title · `Intentional/blocked.html:6` | "Site Blocked - Intentional" | Hyphen instead of em dash; cold phrasing (minor). | "Blocked for now — Intentional" |

---

## Inconsistency clusters (same concept, multiple names)

1. **Weekly Goal / Focus Mode / Intention / Goal** — picker says "Weekly Goal" (`dashboard.html:11995`), create-sheet says "New Focus Mode" (`:14193`), legacy page says "focus mode" + "Untitled focus mode" (`:13454,13463`), comments and bridge say "Intention". → Standardize on **Goal / Weekly Goal**.
2. **Session / Focus Session / Block / Focus Mode (state)** — sidebar "Session", overlay "focus session", pill "block", quick actions "Quick Block" (`DeepWorkTimerController.swift:2029`) vs overlay "Quick session" (`FocusOverlayWindow.swift:407`). → **Session** for the activity, **block** only for calendar rectangles.
3. **AI / coach / scorer / relevance scoring** — "AI Assessments", "Coach context", "the AI can judge", "AI relevance scoring". → One persona, suggest plain "the app".
4. **Sensitive Content / Content Safety / Content protection** — Settings title vs card title vs sidebar footer. → **Sensitive Content** everywhere.
5. **Allowance / Bank / Earned Browse / Leisure pool** — UI mostly says Allowance now, but "Bank" survives in the card + editor; "Free Browse" survives in journal entries (`dashboard.html:8779`). → **Allowance** everywhere; "saved for tomorrow" instead of "bank".
6. **Plan / Goals (the tab)** — tab "Goals", links "Open Plan →", loader "planning view". → **Goals**.
7. **Brand: Intentional vs Puck** — login.html is fully Puck-branded; dashboard footer names the Puck device with zero introduction. → Intentional everywhere; mention Puck only where a Puck exists.

## Notes

- `confirm()`/`alert()` dialogs DO render (MainWindow implements both delegates at `MainWindow.swift:354,362`) — but `prompt()` has no delegate, so `dashboard.html:6972` is dead (P1-26).
- The canonical unscheduled-overlay body copy ("Pick something to work on so you don't end up with 30 tabs open…", `FocusOverlayWindow.swift:366`) is on-spec and good — only the headings above it need alignment (P1-30).
- Debug menu items ("Run Sweep Now (debug)", benchmarks) are `#if DEBUG`-gated — excluded from findings.
- SwitchOverlay quote cards ("Each switch costs ~23 min of deep focus.") pass the audience test — no change recommended.
