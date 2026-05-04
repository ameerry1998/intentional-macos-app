# Spec — Anti-Tamper Strategy (Initial Draft)

**Date:** 2026-05-03
**Status:** Draft handoff brief — many open questions, several concerns about the ICP itself
**Predecessor:** Spec 1 (Intentions), Spec 2 (Time Blocks), Scheduled Intentions Redesign brief
**To research before locking:** the Perplexity prompt at the bottom of this doc

---

## What we're trying to do

Make Intentional **actually unbypassable in the moment of weakness** — which is the entire point of the product per the ICP brief, and which the current implementation does NOT deliver.

The user (Ameer) said it himself: *"the only anti-tamper I have now is that the session can't be deleted after it's started, which is annoying af and leads to annoying situations but there's no real anti-tamper strategy."*

This spec is the first attempt to define what "real" looks like.

---

## Why this is hard (read this before designing)

**There is no such thing as a fully tamper-proof userland app on a device the user controls.** A determined developer with admin access can always defeat enforcement. Saying "make it unbypassable" is naive. The realistic question is:

> **Is the friction higher than the user's willpower deficit during a 5-minute craving window?**

If yes, the product works for most cravings most of the time. If no, the product is theatre.

Every design decision below should be evaluated against that question, not "is this perfectly tamper-proof."

---

## The ICP — concerns to call out

The spec brief at `~/.claude/projects/.../memory/project_intentional_icp.md` describes one person (Ameer) and his experience. Before we design for "ADHD knowledge worker who can't override his willpower," I want to flag honest concerns that affect the design:

1. **Sample size is one.** The ICP describes Ameer specifically. "ADHD knowledge worker" attracts very different sub-types (high-functioning founders who tinker with their tools vs low-functioning users who can't set anything up). The anti-tamper bar that works for one bounces the other.

2. **The "doesn't pre-plan" claim is at odds with the entire product.** We just shipped Spec 1 + Spec 2 — recurring weekly Time Blocks, synced calendars, schedule-driven Sessions. All of which require pre-planning. The ICP brief explicitly says *"any UI that requires upfront weekly scheduling will go unused"* and *"manual / puck-tap / cross-device live state are the load-bearing surfaces."* Either the ICP is partial or the product is misaligned with it. Worth explicitly resolving before piling more anti-tamper UX onto the schedule layer.

3. **Partner-as-executive-function requires a willing, available, prefrontal-cortex-functional partner.** The pattern works for Ameer (Caity is admin on his Mac, holds YubiKey, can be reached). For a user without a partner — single, between relationships, partner not technical, partner emotionally checked-out — the entire architectural premise collapses. Need to design for users who don't have one.

4. **"Anti-tamper that requires admin password / partner unlock / cool-down" is precisely the friction the ICP says causes bouncing.** The product wants strict enforcement that actually works AND wants to feel low-friction. These tensions cannot both be maximized. The design must place friction at the *bypass attempt* (acceptable) and not at *everyday use* (catastrophic).

5. **The "moment of weakness" is not always Twitter at 11pm.** Sometimes it's "I have a real deadline and need to disable AI scoring because it's flagging Stack Overflow as off-task." That's legitimate. The product probably cannot distinguish it from rationalization. We will, sometimes, prevent legitimate work. We need to decide how often that's acceptable.

6. **Personal lockdown (FileVault + non-admin account + partner-as-admin + YubiKey) is a high bar.** It works for Ameer's personal setup. Most users won't do any of it. The default product gives MUCH weaker guarantees than Ameer's personal install. We should be honest about that distinction in product copy and onboarding, not pretend they're equivalent.

7. **"For ADHD users" is a clinical framing with liability implications.** Are we claiming therapeutic value? Replacing professional treatment? Marketing copy needs care; the product is not a medical device.

8. **The premise "right-now-self can't be trusted" can become infantilizing fast.** If users feel patronized by their own software, they bounce — and quietly resent the product even before they uninstall. The line between "external executive function" and "this app is treating me like a child" is thin and matters.

These are not blockers to designing anti-tamper; they're framing constraints. We design with these tensions visible, not papered over.

---

## Catalog of bypass paths

Honest enumeration of every way a determined user can defeat current enforcement, ranked by how easy and how often it'll be tried:

### Trivial (any user, no skill required, in the moment of weakness)

1. **Cmd+Q the Mac app.** Watchdog daemon restarts it but there's a window of unenforced state. User can re-Cmd+Q in a loop.
2. **Force-quit the iOS app from the app switcher.** ManagedSettings shield is supposed to persist, but the user can wait for the 12h TTL to expire and have a clean state.
3. **End Session early** — currently a single tap. The `requirePartnerToEndSessionEarly` setting *hook* exists but the actual mechanism to gate stop-flows is not wired.
4. **Disable accountability partner** in settings. If partner-unlock is the only real gate, removing the partner removes the gate. Trivial defeat.
5. **Toggle off enforcement** for a specific mechanism (overlay, AI scoring, etc.) in app settings — many of these are user-toggleable today.
6. **Don't install the iOS app at all.** Mac sessions still work but the phone is a free pass. The phone is the highest-leverage device for most users.
7. **Use a different browser** that the AppleScript blocker doesn't know about (Arc, Vivaldi, Brave, browser extensions in Safari).
8. **VPN through a tunnel** the Network Extension content filter doesn't see (some VPN clients install profiles that override our filter).

### Low-skill (web-search-able in 2 minutes)

9. **Delete and reinstall the iOS app** — clears bindings, re-pair takes ~60 seconds.
10. **Sign out and sign in as a different account** to reset state.
11. **Change the system clock** to fast-forward through a Time Block's end time so the Session "auto-completes."
12. **Use a different device** that doesn't have the app installed (work laptop, iPad, partner's phone).
13. **Right-click → Open** to bypass Gatekeeper warnings on a developer-built or un-notarized PKG.
14. **Quit + reopen** the Mac app rapidly to catch it in an unloaded state.

### Medium-skill (developer comfort)

15. **`launchctl unload` the daemon** as admin — kills the watchdog, app stops being restarted.
16. **Modify or delete the LaunchAgent / LaunchDaemon plist** files.
17. **Edit the local `intentions.json` cache** to remove blocklist entries for the active session.
18. **Open Activity Monitor → kill the daemon process** repeatedly until the user notices and stops.
19. **Disable the Network Extension content filter** in System Settings.
20. **Revoke FamilyControls / ManagedSettings authorization** in iOS Settings (the OS surfaces a way to do this — it's not protected).

### High-skill (the user is ALSO the developer)

21. **Patch the binary** to no-op the enforcement code paths.
22. **Write a kext / DriverKit driver** to intercept and reverse our blocks (unrealistic but mentioned for completeness).
23. **Backup, uninstall, restore from backup that pre-dated the install.**

The interesting design space is items 1–14: trivial-to-low-skill defeats that any moment-of-weakness user can pull off in seconds. That's where the product loses today.

---

## What we already have (existing partial defenses)

- **Watchdog daemon** restarts the Mac app if killed (defeats #1 partially — defeats Cmd+Q-once but not Cmd+Q-loop).
- **Network Extension content filter** blocks at packet level (defeats some browser-level workarounds but not VPN bypass #8).
- **iOS ManagedSettings shield** is OS-enforced (defeats some force-quit scenarios, but the user can revoke FamilyControls authorization — #20).
- **Bedtime lock-loop** via `SACLockScreenImmediate` every 10s (the only piece of real anti-tamper enforcement currently shipped — and it's only for bedtime).
- **Partner-unlock-code flow** (6-digit code emailed + APNs pushed to partner) — used today only for bedtime end-early and for extra-time requests.
- **Strict Mode** flag in UserDefaults + login item + flag file (partial protection against uninstall).
- **PKG installer drops a root daemon** that the user-account user can't easily kill without admin password (defeats #15 for non-admin users; useless for admin users).

This is the foundation to build on.

---

## Proposed strategy — layered defense

Five layers, in order of how much friction they add. The product should default to layer 1-2 for ALL users, layer 3-4 for users who opt in, and layer 5 for the personal-lockdown tier.

### Layer 1 — Universally on (no opt-in)

- **Sessions can no longer be ended early with a single tap.** Stopping requires holding a button for 5 seconds with a confirmation. Friction. Not unbypassable but enough to break the impulse.
- **The "disable enforcement" toggles in settings get a 1-hour cool-down.** Toggle off → settings shows "Will take effect in 60 minutes" + countdown. User can cancel during the countdown but not skip it.
- **Removing an accountability partner gets a 7-day cool-down.** "Removing your partner takes effect in 7 days. You can cancel during this time." Partner is also notified by email when the request is made.
- **The seeded "Focus" Intention cannot be deleted.** It can be renamed, blocklist edited — but it always exists as a fallback.

### Layer 2 — Universally on, partner-required where partner exists

- **Stopping a Session early (within first 25 min) requires partner unlock IF a partner is paired.** The existing setting hook (`requirePartnerToEndSessionEarly`) gets actually wired. If no partner, fall back to layer 1's 5-second hold.
- **Disabling the iOS app shielding (revoking FamilyControls authorization) triggers a partner notification within 1 minute.** Detection, not prevention — but partner gets pinged and can have a conversation.
- **Uninstalling the iOS app triggers a partner notification within 5 minutes** (we won't know exactly because the app is gone, but the backend will see the device stop heart-beating + APNs failures + can email the partner).

### Layer 3 — Opt-in "Hard Mode" (partner enrollment required)

- **Multi-device requirement.** App refuses to function unless paired with both Mac AND iPhone. Dashboard shows "Pair your iPhone to enable focus." Without iPhone paired, Mac enforcement is degraded (just nudges, no shielding).
- **Partner can lock specific Intentions.** Once locked, the user cannot edit the blocklist, change strictness preset, or delete the Intention without partner unlock.
- **Time-of-day "vulnerable hours" enforcement.** User defines hours (e.g. 10pm-7am) when settings changes require partner unlock regardless of cool-down. Defeats #11 (clock changes) since partner approval is real-time.
- **Re-pair lockdown.** Once iPhone is paired, un-pairing requires partner unlock + 24h delay.

### Layer 4 — Opt-in "Lockdown Mode" (PKG-installed daemon required)

- **The watchdog daemon refuses to be unloaded** without partner-issued admin code. Re-launch on `launchctl unload` attempts.
- **Settings file integrity check.** Daemon hashes settings files, detects manual edits (#17), restores from backend snapshot, partner notified.
- **Bypass attempt logging.** Every Cmd+Q, every force-quit, every settings toggle in cool-down is logged + sent to backend + counted toward partner-visible "tamper attempts" stat. Pattern detection: 3+ attempts in 24h → partner alerted.
- **Network Extension cannot be disabled** without partner code (re-enable on each tick if user disables).

### Layer 5 — Personal lockdown (user is responsible for this; the product just supports it)

What Ameer has personally set up — should be documented as a tier the product enables but doesn't enforce:
- FileVault enabled
- User runs as non-admin
- Partner / second person holds the only admin credentials
- YubiKey for admin authentication
- PKG installed by the partner-admin, not the user

The product design should:
- Document this clearly as "Maximum Lockdown" tier
- Provide a pre-flight checklist on first launch ("Is your account non-admin? Is your partner the admin?")
- Refuse to disable certain things on this tier even with the "user's" credentials (because they don't have admin)

---

## Locked product decisions (so far)

| # | Decision | Rationale |
|---|---|---|
| **AT1** | Layer 1 ships as the default. No opt-in required. | Universal baseline; doesn't depend on partner enrollment. |
| **AT2** | Partner removal always has a 7-day cool-down. No exceptions. Partner is notified on the request. | The "remove partner to bypass" path is the most common defeat for accountability tools. Closing it is load-bearing. |
| **AT3** | The 5-second stop-button hold is the universal stop friction. Layer 2's partner-gated stop is in addition for partner users. | Always present even without partner. |
| **AT4** | Detection + partner notification for iOS uninstall, FamilyControls revocation, and tamper-attempt patterns. | Shame is a bad motivator (per ICP) but a partner who knows can have a real conversation. Detection is the floor for layers 2+. |

---

## Open product questions (CRITICAL — these gate the design)

1. **What happens to a user without a partner?**
   - Block the most-aggressive features behind partner enrollment (the current direction)?
   - Allow self-imposed cool-downs that the user themselves can't shorten ("I commit, in advance, to a 24h delay on un-blocking")?
   - Refuse to onboard them at all (clinical risk too high)?
   - Provide a "rent-a-partner" service (real-money tier)?

2. **What happens when the partner rubber-stamps every unlock request?** Spouse at 11pm just types the code without thinking. The product fails silently.
   - Make the partner approval flow include friction (e.g. "are you sure? this is the third unlock this week")?
   - Show the partner the user's tamper-attempt count alongside the unlock request?
   - Add a "partner accountability" layer — partner has to justify why they unlocked?

3. **How do we handle the "I have a deadline, I need to disable AI scoring legitimately" case?**
   - Always require partner unlock for disable (high false-positive friction)?
   - Provide a "1-time bypass with reason logged" that partner sees later (lower friction, lower protection)?
   - Don't try to distinguish — accept that we'll prevent some legitimate work?

4. **Multi-device requirement (Hard Mode L3) — is this too aggressive?** A user without an iPhone can't use the app at all in Hard Mode. Acceptable for a paid tier, lethal for free users.

5. **What's the right default cool-down length?**
   - Settings disable: 1h (proposed) vs 4h vs 24h
   - Partner removal: 7d (proposed) vs 30d (clinically aligned with relapse cycles)
   - Strictness preset softening: 24h (already locked in scheduled-intentions spec D5)

6. **How do we handle partner death / divorce / unreachable?**
   - Hard requirement: every account must have an emergency reset path
   - Soft: 30-day no-contact triggers automatic partner removal (defeats AT2)
   - Manual: support email with verification (slow but rigorous)

7. **Should "tamper attempts" be visible to the user too?**
   - Yes: transparency, no surprises when partner brings it up
   - No: makes them defensive, feels like surveillance
   - Partial: count visible, individual events only to partner

8. **What's the marketing position on "this won't work without a partner"?**
   - Honest: lead with it, scare off solo users
   - Soft: present partner as a "stronger mode" feature
   - Marketing-safe: don't mention until onboarding, after they've already invested

9. **What does the spec say about the "ADHD" framing?** Liability question. Marketing question. Real ICP question.

10. **Tamper budget definition.** What's the friction-vs-willpower-deficit calibration we're targeting? Pick a metric: e.g. "user gives up after attempting bypass for 90 seconds in 80% of moments-of-weakness." Without a metric we have no way to evaluate any of these design choices.

---

## Out of scope (for THIS spec)

- **Anti-tamper for the iOS DeviceActivity extension.** That's an Apple-controlled surface; we use what they give us. Separate research.
- **Network-level defenses.** VPN bypass, custom DNS, etc. are real but require infrastructure we don't have. Future spec.
- **Therapeutic / clinical content.** This product is not a medical device. Don't blur lines.
- **Hardware tamper detection.** Out of scope; not a hardware product (the Puck is just NFC, not a security key).

---

## Perplexity prompt — to be run before locking layer 3+ decisions

Copy into Perplexity. The answer feeds back into this spec.

````markdown
# Anti-tamper strategy for an ADHD focus app on macOS + iOS

I'm building "Intentional" — a cross-device focus / blocking app for ADHD knowledge workers. macOS + iOS + a shared backend. The promise: be **an external executive function the user cannot override in moments of weakness.**

## ICP context (matters — without it the answer goes generic)

Target user: ADHD knowledge worker (founder/engineer type) who has tried Cold Turkey, Freedom, Opal, Apple Screen Time, and bypassed every one of them in moments of weakness. Pattern: every existing tool ultimately relies on the user's willpower to enforce itself, and at the moment of crisis the user's willpower is exactly the thing that's broken.

The accepted SOLUTION direction: "non-self executive function" — handing the steering wheel to someone whose prefrontal cortex actually works (an accountability partner). Existing partner mechanism in our app: 6-digit unlock codes, emailed + APNs-pushed to the partner, who decides whether to release.

For one specific use case (bedtime), we have a "lock-loop" that calls macOS's `SACLockScreenImmediate` (the same primitive the OS Lock Screen menu item uses) every 10 seconds during the locked period. Apps and downloads keep running, but user has to re-enter password / Touch ID every 10s to do anything. They can't bypass without partner-issued code. Works because: (a) lock screen is OS-level, can't be intercepted by userland; (b) loop runs from a daemon the user can't easily kill; (c) `SACLockScreenImmediate` ignores FileVault password-after-sleep delays.

## Current architecture

**macOS app:** PKG installer drops `Intentional.app` in `/Applications/`, `syspolicyd_helper` daemon in `/usr/local/libexec/`, LaunchDaemon + LaunchAgent plists. Daemon is a watchdog. Developer-ID signed. Network Extension content filter for browser blocking. AppleScript for tab control. Does NOT use Endpoint Security or System Extensions for process monitoring.

**iOS app:** Apple FamilyControls / ManagedSettings for shielding. DeviceActivityMonitor extension fires shielding when app is closed. APNs silent push (`content-available: 1`) from backend triggers cross-device sync. Standard App Store / TestFlight install (NOT MDM-managed).

**Backend:** FastAPI / Postgres / Railway. Account-scoped state. Email (Resend) + APNs for partner-unlock flow.

## Current bypass paths (sorted by severity)

[Trivial:] Cmd+Q Mac app, force-quit iOS, end session early (one tap), disable partner in settings, toggle off enforcement, don't install iOS at all, use different browser, VPN.

[Low-skill:] Delete + reinstall iOS app, sign out + sign in different account, change system clock, use different device, right-click → Open to bypass Gatekeeper, quit + reopen rapidly.

[Medium-skill:] `launchctl unload` daemon (admin), modify LaunchAgent plist, edit local cache files, kill daemon repeatedly via Activity Monitor, disable Network Extension in System Settings, revoke FamilyControls authorization in iOS Settings.

[High-skill:] Binary patch, kext/DriverKit driver, restore from older backup.

## What I want you to think through

For each, give: (a) what's possible on macOS / iOS / backend respectively, (b) what's security theater vs. real protection, (c) what existing apps in this category have tried, (d) tradeoffs on UX and the user's sense of agency.

1. **The "moment of weakness" problem.** Determined user will try every path. What architectural patterns survive that? Evaluate: kernel extensions / DriverKit / Endpoint Security on macOS; MDM-required install on iOS; partner-locked stop flows; cool-down delays; biometric re-auth on every disable; geofencing; time-of-day scheduling that locks out admin actions.

2. **The "delete + reinstall" loophole.** What deters a user who deletes the iOS app to clear the shield, or uninstalls the Mac PKG? On iOS without MDM, is there ANY way to make the app harder to uninstall, or to detect uninstall + alert partner before re-binding is allowed? On Mac: how do other apps prevent or detect their own uninstall (Tile, ProtonVPN, etc.)?

3. **The "no second device" loophole.** Many users will install Mac only — the phone (most distracting device) is unprotected. How do other accountability tools force or strongly nudge full multi-device coverage? Pattern where Mac app degrades unless iPhone is paired?

4. **Partner-as-non-self-executive-function design.** Currently 6-digit unlock codes emailed/pushed to partner. Better architectural patterns? (Time-locked unlock — request now, available 6h later; dual-approval — partner + therapist; partner sees real-time activity feed; cool-down on partner-pairing changes — un-pairing requires 7-day delay so user can't remove the partner during a moment of weakness.)

5. **Cool-downs as soft anti-tamper.** Instead of "you cannot disable this," what about "disabling this takes effect 4 hours from now"? Empirical evidence on cool-downs in addiction / habit-change software?

6. **Detection vs. prevention.** When prevention fails, can detection + partner notification be a meaningful deterrent? E.g., "user uninstalled iOS app at 11:47pm — partner gets email 12 minutes later."

7. **macOS APIs ranked by tamper resistance.** For my use case: Network Extension content filter, System Extensions, Endpoint Security framework, DriverKit, AppleScript, accessibility-API monitoring, MDM-managed configuration profiles. Which are bypassable by admin user, which by any user, which require kernel extension or MDM enrollment to defeat? Cite Apple docs.

8. **iOS APIs ranked by tamper resistance.** Family Controls / ManagedSettings / DeviceActivity: what does Apple guarantee about persistence after force-quit, app deletion, device restart, profile removal? Actual security model: shield enforced by OS, or just by our app being able to apply it? What happens if user revokes Family Controls authorization?

9. **MDM if you're really serious.** Apple Business Manager / Jamf-style MDM enrollment can lock down iOS hard but requires managed-organization enrollment. Realistic for consumer product, or only B2B / school deployments? Apple Configurator for personal devices?

10. **The "partner cannot be your spouse forever" problem.** Real-world: spouse will get tired of being accountability partner. Therapist? AA-style sponsor? Paid service? Should the product support multiple partners with different unlock authority?

11. **Personal lockdown vs. shipping-as-product.** Some defenses (FileVault, non-admin account, YubiKey, partner-as-admin, MDM) work for me personally but won't fly for general users. Where's the line — what should be the product's default opinionated stance, and what should be opt-in "hard mode"?

12. **What's the actual tamper budget?** Don't tell me "make it unbypassable." A determined user with technical skills can ALWAYS bypass userland enforcement on a device they control. What's the realistic bar? "More friction than the user's willpower-deficit allows during a 5-min craving window"? If yes, what specific friction mechanisms achieve that bar?

## Format

Per question: 200-400 words. Cite specific frameworks, APIs, or other apps where relevant. Where you're uncertain, say so. Where there's no good answer, say so.

End with a prioritized 5-item list: "if you only build five things to harden this product, build these five" — ordered by ratio of (real protection delivered) ÷ (engineering effort + UX cost).
````

---

## Acceptance criteria (when this work is done)

A user with this spec implemented:

1. Cannot end a Session within the first 25 min by tapping a single button — requires either a 5-second hold (no partner) or partner unlock code (partner enrolled).
2. Cannot toggle off enforcement settings instantly — change is queued for 1 hour, partner notified.
3. Cannot remove their partner instantly — change is queued for 7 days, partner notified.
4. Cannot delete the seeded "Focus" Intention.
5. Receives a partner notification within 5 minutes of force-quitting iOS app, revoking FamilyControls authorization, or uninstalling either app.
6. In Hard Mode (opt-in): the Mac app refuses to function unless iPhone is also paired.
7. In Hard Mode (opt-in): partner can lock specific Intentions so blocklist + strictness cannot be edited without partner unlock.
8. In Lockdown Mode (PKG + admin-separation tier): daemon cannot be unloaded without partner-issued admin code, settings file edits trigger restore from backend, bypass attempts pattern-detected and partner-alerted.
9. In any tier: the product clearly communicates which tier the user is on and what guarantees that tier provides.
10. The product cannot be installed by a brand-new user without a clear honest description of what it can and cannot prevent. No "magically unbreakable" copy.

If those 10 are true, ship it.
