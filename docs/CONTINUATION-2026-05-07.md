# Continuation Brief — Mid-Slice-10 Testing

**Last updated:** 2026-05-07 02:20 (after extensive interactive testing)

This is a single-page brief for an agent picking up the work after a context compact. Read this top-to-bottom and you have the whole picture.

---

## 1. What we're doing

A 13-slice redesign of the Intentional Mac focus enforcement app + iOS Puck companion + FastAPI backend. **Master spec, plan, and decisions log live in `docs/`** — read them in this order if you have time:

1. `docs/superpowers/specs/2026-05-05-app-redesign-design.md` — full design spec, 28 user-approved decisions captured
2. `docs/superpowers/plans/2026-05-05-app-redesign-plan.md` — master plan, 13 vertical slices
3. `docs/test-plan-2026-05-05.md` — **live test checklist** with bug log + fix commit hashes
4. `docs/integration-tests-backlog.md` — 75-test backlog for future automated coverage
5. `docs/dev-build-and-launch.md` — how to actually run the new build (the watchdog/sudo issue)

If short on time, skim only this file and `docs/test-plan-2026-05-05.md`.

---

## 2. Branch state — top of stack per repo

The user wants ALL changes stacked, so each repo has ONE top branch with everything:

| Repo | Path | Top branch | Has |
|---|---|---|---|
| Backend | `/Users/arayan/Documents/GitHub/intentional-backend` | `slice-06-focus-lock` | Slices 1+2+3+4+5+6+7. 7 migrations (021-025), entitlement + budget + taxonomy + focus_lock endpoints, Stripe webhooks. |
| Mac | `/Users/arayan/Documents/GitHub/intentional-macos-app` | `slice-13-cleanup` | Slices 1+2+3+7+8+9+10 + Settings sub-pages + Focus Mode editor v3 + ~12 fixes. |
| iOS | `/Users/arayan/Documents/GitHub/puck-ios` | `slice-12-puck-alarm-only` | Slices 1+2+3+11+12. |
| puck-site | `/Users/arayan/Documents/GitHub/puck-site` | `staging` | Slice 0 site rewrite (subscription model). |

The user runs the Mac app via the DerivedData binary (NOT `/Applications`). See §3.

---

## 3. Running the Mac app (the build/launch dance)

Critical pattern. The watchdog at `/Library/LaunchAgents/com.intentional.agent.plist` respawns `/Applications/Intentional.app` constantly, AND macOS won't run two apps with the same bundle ID, so the new build dies if the OLD is alive.

**The sequence that works without sudo (user does NOT have sudo):**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | grep -E "error:|BUILD " | tail -3

# Kill old aggressively (loop because watchdog respawns):
for i in 1 2 3 4 5 6 7 8; do pkill -9 -f "/Applications/Intentional.app" 2>/dev/null; sleep 0.2; done
sleep 1
pgrep -f "/Applications/Intentional.app" || echo "OLD DEAD"

# Kill any prior DerivedData process:
pkill -9 -f "Intentional-cjpaicwfawcwqgepfrsxstqebhev" 2>/dev/null
sleep 0.5

# Launch directly from DerivedData (NOT via 'open' which goes through LaunchServices and routes to /Applications):
/Users/arayan/Library/Developer/Xcode/DerivedData/Intentional-cjpaicwfawcwqgepfrsxstqebhev/Build/Products/Debug/Intentional.app/Contents/MacOS/Intentional &> /tmp/intentional-fresh.log &
sleep 2
pgrep -lf "Intentional-cjpaicwfawcwqgepfrsxstqebhev" | head -2 || echo "NEW DIED — try again, watchdog won the race"
```

If NEW DIED, pkill loop more aggressively (longer / more iterations) and retry.

DerivedData path is stable at `Intentional-cjpaicwfawcwqgepfrsxstqebhev` (it's hash of project location).

---

## 4. State of testing (what's tested vs what's NOT)

### ✅ Tested + working on Mac
- Build clean
- Sidebar 5 items: Today / Focus Modes / Sensitive Content / Accountability / Settings
- Today/Week toggle on Today page
- Bedtime/Wake bands hide when not configured
- Day toggle on Schedule page pops back to Today
- All sidebar pages render
- **Settings persistence:** confirmed working
- **Draft block autosave bug:** FIXED in commit `910cc55` (was firing markFocusDirty on intention picker change for new drafts → SET_SCHEDULE → premature enforcement)
- **Focus Mode editor v3 redesign** shipped at `09c9012` then strict-button fix at the latest commit on the branch
- **Strict-button click bug:** FIXED — segmented control now re-renders on click (was updating state but not visual selection)

### ⏳ Not yet tested but doable on Mac alone
- Strict-block-end-early gate (slice 9): set Mode to Strict, schedule a block, hit End Block in pill, expect refusal + console log `🚫 End Block ignored`
- Pill widget after 60s (EntitlementClient polling crash check)

### ⏳ Not yet tested — iOS
- App build + run on simulator
- Sign-in (currently blocked: Supabase OTP rate-limiting AND backend missing `/me/entitlements`)
- 3 tabs Today/Week/Settings
- Subscribe link on LandingView

### 🚫 Blocked on backend deploy (code shipped, not deployed)
- Subscription gating (lapsed banner) — backend `/me/entitlements` not on main yet
- Distraction Budget cross-device sync
- Stripe trial flow end-to-end
- Strict Mode constraint enforcement (bedtime / ai_scoring / always_blocked auto-correction)
- Settings → Distractions / Budget / Always-Blocked LIVE (UI built, but spins on "Loading…" since backend not deployed)
- iOS getEntitlements (currently 404s in user's logs)

### 🚫 Blocked on unfinished UI
- Focus Lock master toggle on Today page (~30 min build)
- 5-min extend prompt at block end (~30 min)
- Puck alarm-only lock-screen UI (multi-hour iOS feature)

---

## 5. Bugs found during testing (all fixed)

| Bug | Symptom | Fix commit |
|---|---|---|
| Bedtime/Wake bands always visible | Default 22:00/07:00 even with no config | `1f81c69` |
| Day toggle on Week view stayed there | Should pop back to Today | `1f81c69` |
| Draft block premature autosave | YouTube blocked while editor still open | `910cc55` |
| "Edit project" wording | Should say "Focus Mode" | `4dd1b5b` |
| Legacy Blocklists pulldown | Confused users vs new layered model | `3d49cfd` |
| Strict button no visual feedback | Click didn't update segmented control | (latest commit on slice-13-cleanup) |

All other items in test plan are still pending or blocked.

---

## 6. iOS sign-in current state (do NOT chase as a bug)

User reports "can't reach server" on iOS sign-in. Logs show:
- `sendOTP failed: For security purposes, you can only request this after 29 seconds.` → Supabase rate limit. Wait ~1 min between attempts.
- `getEntitlements failed: HTTP 404` → backend `/me/entitlements` not deployed yet (lives on `slice-06-focus-lock` not main).
- 401s on /intentions, /focus, etc. → user is mid-auth, JWT not active.

This is **expected** for the current backend-deploy-blocked state. Don't try to fix the iOS sign-in flow itself. The "can't reach server" UI string mapping is too generic for these failure modes — that's a small iOS bug to fix later (~10 min) but not urgent.

---

## 7. The user's working style (for the agent picking this up)

- Pushes hard for execution velocity. Hates "permission asks" between tasks. Per `CLAUDE.md` "Don't stop. Keep going. (MANDATORY)" section added 2026-05-06.
- Wants TL;DR at end of every response (per `CLAUDE.md`).
- Will tell you when to stop. If they say "keep going" — keep going until blocked or done.
- Does NOT have sudo. Don't suggest sudo commands; they won't run.
- Cares deeply about UX/copy. Recently iterated through 3 rounds of Focus Mode editor design via Claude Design.
- Skeptical of "vibe-coded" / AI-flavored design. Wants warmth, conversational copy, no subtitles, info icons instead.
- Owns Stripe + Railway + Supabase but hasn't deployed backend slice work yet (T7 manual task).

---

## 8. What I'd do next (if I were the agent)

1. Confirm the strict-button fix actually works in the running app (last commit on slice-13-cleanup).
2. Run the strict-block-end-early test — it's the only piece of slice 9's real new behavior testable on Mac standalone.
3. If time allows, build the Focus Lock master toggle UI on Today page (~30 min — backend ready, just needs JS + a single bridge call).
4. Stop pushing further visible UI changes. Suggest user deploys the backend (T7) so all the blocked-on-deploy tests become unblockable.

Do NOT:
- Try to fix iOS sign-in's "can't reach server" copy (low value)
- Try to delete deprecated code (slice 13 cleanup; needs backend stable first)
- Run anything requiring sudo
- Run the slice 12 (Puck alarm UI) work without budgeting hours for it

---

**TL;DR:** Run the build/launch sequence in §3 to test changes. Test plan + spec are the ground truth. User wants speed but cares about quality. Mac top branch is `slice-13-cleanup`. iOS top is `slice-12-puck-alarm-only`. Backend is `slice-06-focus-lock` and NOT deployed. Everything blocked on backend deploy or unfinished UI is documented in `docs/test-plan-2026-05-05.md` §6.5.
