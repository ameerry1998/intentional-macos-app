# ICP Adversarial Review — how real users ignore, game, resent, and abandon Intentional

**Date:** 2026-06-12
**Status:** review complete — 6 rounds, converged at round 6
**Reviews:** `2026-06-12-daily-focus-and-coach-powers-design.md` + `2026-06-12-focus-agent-design.md`, taking `2026-06-12-adhd-critique-loop.md` (7 internal rounds) as the starting state — nothing from those rounds is re-litigated here.
**Deliverable:** the numbered design deltas in §"Converged deltas". This document changes no other file; the deltas are inputs to the next plan revision.

---

## Method (honest accounting)

| Critic | Status | What was actually used |
|---|---|---|
| OpenAI GPT-5 API | **UNAVAILABLE** — `OPENAI_API_KEY` exists in the environment but every call returns `insufficient_quota` (verified 2026-06-12 with a minimal probe). The critic harness (persona prompts + design-state round-tripping) was built and is at `/tmp/icp-review/` if quota is restored. | Nothing. No GPT criticisms appear below. |
| Perplexity API | **UNAVAILABLE** — no key in `intentional-backend/.env` or the environment. | Nothing. |
| Web evidence | **USED, extensively** — ~12 searches + targeted page fetches on Opal, Freedom, One Sec, Forest, Cold Turkey, Screen Time, Beeminder, Duolingo streaks, PDA/demand-avoidance, screens-as-reward research, parent-teen surveillance, Focusmate/body-doubling. | All `[web]`-tagged attacks. Quotes + URLs in the Evidence Appendix. |
| Internal adversarial personas | **USED** — rules-lawyer, rage-quitter, shame-spiral, novelty-junkie, parent-bought-it-teen-hates-it, plus a skeptical-quitter persona grounded in the web evidence (not free-floating). | All `[persona]`-tagged attacks. |

So: **no live external LLM critics; the external pressure is real-world user evidence from the web, which is arguably stronger** (these are people who actually quit these apps, not a model role-playing them). Every persona attack below had to cite or be consistent with a web finding to count.

Triage rule per round: an attack only "lands" if it forces a concrete design change that the three existing spec docs do not already contain. Attacks the specs already answer are listed and dismissed explicitly, to prove they were considered.

---

## ROUND 1 — Bypass & abandonment reality (what actually kills these apps)

### Attacks

1. **[web] "A speed bump, not a wall" — every friction tier habituates.** One Sec's own evidence chain: 57% average reduction in the PNAS study, but "the novelty wears off after a few weeks. The breathing exercise that felt meaningful on day one can feel like an annoying formality by week four… On bad days, you'll breathe through the exercise and scroll anyway." Intentional's overlay, soft-close, and nudges are all friction tiers. By week 4 the user has a motor pattern for each one.
2. **[web] The bypass is the off switch / the uninstall.** Freedom: "It's easy to bypass if you really want to. Just turn off wifi or delete the app." Opal users describe rage-deleting ("so consistently enraged… rage deleted it 3 times in the past 6 months"). The design's teeth all live inside an app the user can remove in 30 seconds. Anti-tamper exists only for the self-lockdown configuration (admin split) — the general user has none.
3. **[persona: rules-lawyer] The fake-declaration key.** At Strict, "lock until a Daily Focus is declared" means the lock's key is a declaration — so type "work stuff", tap, locks lift, drift all day. Ameer himself typed "Idk what to do" into the v1 prompt. A vague declaration also poisons relevance scoring (everything is sort-of-relevant to "work stuff"), so the coach goes blind exactly when gamed. The spec ends the lock at declaration and never re-arms it.
4. **[persona: rage-quitter, grounded in web] The Zoom-presentation kill shot.** A non-skippable full-screen overlay firing during a screen-share, client call, or presentation is a public humiliation delivered by the app. This is the single highest-certainty uninstall event in the whole design and **neither spec mentions suppression contexts**. (Category evidence: Opal users rage-delete over far less — wrong blocks during normal use.)
5. **[persona: rules-lawyer] Real-break chaining.** Overlay offers "real break (10 unblocked min, then re-ask)" — so pick it every time. 10 min break, re-ask, break, re-ask… the overlay becomes a metronome the user taps through (attack 1's habituation, accelerated), and the afternoon is gone with zero consequence and zero record of a *choice* having been made.
6. **[web] The phone is sitting right there.** Mac-only enforcement means the lock's practical effect is "pick up the phone." Freedom's post-session binge pattern shows blocked users displace, not stop. `shield_phone` is deferred in the focus-agent spec — fine as sequencing, but the *mirror* must not lie about it ("focused day" claimed from Mac data while the user scrolled 3h on the phone destroys the mirror's credibility the first time the user notices).
7. **[persona: skeptical-quitter] Day-1 cold start = "another app asking me what to do."** Day 1 the coach has no telemetry, no goals, no history. Its chips are generic. The first interaction is an ask, and the user installed the app precisely because asks don't work on them. The Whoop comparison in the focus-agent spec points the right way: passive measurement first, narrative before guidance — but no spec slice actually sequences the first coach moment after evidence exists.
8. **[web] Locked-out-with-no-escape backfires (the other pole).** Cold Turkey's Frozen Turkey: "no override, no emergency unlock, no 'I changed my mind' option… this rigidity can backfire badly" for anyone whose day can contain an emergency. Strict's lock needs a legitimate-need path that isn't "go uninstall."

### Triage

- (1) **Lands partially.** Habituation can't be designed away, but the design can stop *training* it: the overlay must never repeat the same form in the same stretch (see change R1-C), and the dial's honest framing is that Soft/Standard are speed bumps by choice — only Strict is a wall. No further change; this is the dial doing its job.
- (2) **Lands.** Needs the witnessed-uninstall mechanism (R1-E). Full anti-tamper for everyone is out of scope and wrong for a volunteer product.
- (3) **Lands hard.** Two changes: lock semantics (R1-A) and vague-intent handling (R1-B).
- (4) **Lands hard.** Highest-priority change of the round (R1-C′).
- (5) **Lands.** (R1-C)
- (6) **Lands as honesty constraint, not new enforcement.** (R1-D)
- (7) **Lands.** (R1-F)
- (8) **Lands.** Folded into R1-A's exits + Round 5's "I need this" mechanics.

### Design changes forced

- **R1-A — Declaration is a session key, not a day pass.** At Strict, the lock lifts *into a started session*. When no session is running and accumulated drift crosses the threshold again, the lock re-arms. A junk declaration buys one drift-window, not the day. Exits that are always honest: start a session, or take the recorded rest (R1-C). Never: locked with no path out (Cold Turkey lesson).
- **R1-B — Vague intent gets sharpened by proposal, never interrogation.** When typed intent can't anchor relevance scoring ("work stuff", "research"), the coach proposes a sharper chip built from telemetry ("Research = the Carr paper + notes?"). Declined → the vague intent stands, but the scorer falls back to a narrow work-shaped allowlist instead of everything-passes. No open questions, ever.
- **R1-C — Break chaining converts to declaration.** Second consecutive "real break" in one planless stretch: the chip becomes **"Take the afternoon off — recorded as rest"** (one tap, honored, witnessed, releases any lock). The loophole becomes an explicit recorded choice; there is no third identical overlay (no nag ladder). A chosen rest is NOT a "bad day" anywhere downstream.
- **R1-C′ — Hard suppression contexts, enforced in code, shipping before any overlay goes live:** no overlay / soft-close / nudge during active screen sharing, video calls (camera or mic live), presentation/fullscreen-presentation mode, or screen recording. Detection via live capture/camera/mic state, not "a Zoom window exists" (rules-lawyer would keep a dead call open all day).
- **R1-D — The mirror never overclaims.** All mirror/partner copy is scoped: "On the Mac: 2 sessions, 1h40m." The word "day" is never graded from Mac-only data. `shield_phone` is named in the spec as the #1 known leak and the first post-v1 slice.
- **R1-E — Witnessed off-switch (consented).** If partner reports are enabled and telemetry goes dark (uninstall, disable, permissions revoked), the partner gets one factual note: "Intentional stopped reporting as of Tuesday." Disclosed explicitly at partner setup; turning reports off in-app is always possible and is itself reported once ("reports turned off"). Uninstall stays possible — it just stops being *invisible*. This is the adult-grade tooth that survives the worst moment without becoming a warden.
- **R1-F — Day-1 aha is the mirror, not an ask.** The coach's first proactive moment is sight-proof: after ~2–3 hours of first-day telemetry, "Here's your morning, factually" — then the first session proposal. The coach earns the right to propose by demonstrating it sees.

### Explicitly NOT changing

- **Silence bias stays.** The evidence says more talking = faster habituation. The wrong-nudge 5× cost holds.
- **The overlay survives** (with R1-C/C′ bounds). One Sec's lesson is that *pure* friction fails on bad days — but removing the only mid-tier tooth makes Standard toothless. The overlay is one honest fork, shown once per stretch.
- **No general anti-tamper.** The volunteer principle is load-bearing; the answer to attack 2 is witness (R1-E), not walls.

---

## ROUND 2 — Behavioral mechanisms (the psych reviewer's pass)

### Attacks

1. **[web] The allowance economy is the screens-as-reward trap.** University of Guelph finding: kids given screen time as a reward use screens *more*; the overjustification effect makes the screen the prize and the work the barrier ("homework, chores… feel like barriers to the thing they really want: the screen"). "Focus 25, earn 5" is literally this contingency, self-administered. Risk: the app teaches that focus is the toll you pay for scrolling — raising scrolling's salience.
2. **[web] PDA/reactance: the demand is the trigger.** PDA literature: a demand — even one the person *wants* — is perceived as a threat and triggers avoidance; "direct commands, ultimatums, or repeated reminders create cycles where demand leads to avoidance… shutdown." Every coach prompt is a demand. The design is silence-biased, but there is no pressure valve when the user is in a reactance state: the only way to make the coach shut up entirely is the uninstall.
3. **[persona: shame-spiral, grounded in web] The "factual mirror" still grades — via the receiver.** "Most of the afternoon went sideways" IS an editorial (the spec's own example copy). And even perfectly neutral facts get editorialized by the parent who receives them ("why was your afternoon sideways?"). The shame arrives by human delivery. PDA sources: "If an app makes you feel guilty for missing a day, it is not designed for ADHD."
4. **[web] Streak display is a loss-frame liability.** Duolingo's own data: streak loss is demotivating enough to push lapsed users out entirely; Streak Freeze cut at-risk churn 21%. The design has decay-not-break (good) but doesn't say *where* the streak is displayed. A streak on the pill or Today page is a permanently visible loss-counter for an RSD brain.
5. **[persona: rage-quitter] One false accusation kills the coach.** The vision pipeline will misread a screen eventually. "Not related to your task" shown to someone who IS working burns trust at the 5×-cost rate, and there's no runtime correction path — only the offline bench.
6. **[persona: shame-spiral] The floor is a cage if it's enforced.** "25-min floor": what happens at minute 12 when the session is dead? If the app resists ending ("you committed to 25!") it's a warden; the Beeminder lesson is that pressure-collapse users quit the whole system, not the goal. If ending early is fine, what does "floor" even mean — and does the 24-minute session earn nothing (a cliff that manufactures sunk-cost resentment)?
7. **[persona: shame-spiral] A bad WEEK has no design.** Streak decay handles a bad day. After 5 bad days every surface is a reminder of the hole; the documented exit is deleting the app to escape its opinion. (Beeminder: "collapse under the pressure.")
8. **[psych] Midnight expiry punishes the chronotype.** Daily Focus expires at local midnight — the ADHD night owl's 11pm–2am hyperfocus block straddles the boundary; the day's identity should be sleep-anchored, not calendar-anchored.

### Triage

- (1) **Lands as repositioning, not removal.** The economy's *mechanic* survived 7 rounds for a reason (bounded relief beats both unbounded browsing and hard prohibition, which the Freedom binge evidence damns). What must die is the *framing* that makes scrolling the prize (R2-A).
- (2) **Lands.** (R2-B mute valve.)
- (3) **Lands.** (R2-C.)
- (4) **Lands.** (R2-D.)
- (5) **Lands.** (R2-E.)
- (6) **Lands.** (R2-F.)
- (7) **Lands.** (R2-G.)
- (8) **Lands.** (R2-H.)

### Design changes forced

- **R2-A — Allowance is bounded relief, never a prize.** Copy never says "earn screen time by focusing." Frame: "breaks are covered." Earning is continuous at 5:1 per focused minute (no 25-minute earning cliff). The allowance number is never the headline of any celebration (the work is). The 60-min bank cap stays.
- **R2-B — The mute valve.** One tap ("not today") silences the coach's *voice* — nudge/rescue/celebrate/plan cards — for the rest of the day. Structure (dial-bound overlay/soft-close/lock, rules, allowance) stays armed. The mute is recorded in the mirror as a fact, not a failure. Daily-mute patterns feed the profile (the coach adapts form rather than repeating what gets muted). This is the PDA pressure valve that isn't the uninstall.
- **R2-C — Mirror vocabulary is benched; positive-first; bad days compress.** "Went sideways"-class editorials are banned vocabulary — facts only ("2 sessions, 1h40m; longest stretch: YouTube 2h05m"). Every report leads with the best true thing. Bad days send *fewer* facts (smaller interrogation surface for the receiving parent), never more. Wrong-tone = wrong-act in the bench, same gate as speech.
- **R2-D — Streaks are weekly-view-only.** Never on the pill, never ambient on Today. Decay-not-break stays; a chosen rest day (R1-C) pauses rather than decays.
- **R2-E — Runtime correction on every accusation surface.** Every nudge/soft-close/overlay carries a one-tap "I need this / wrong call" that is honored instantly, logged as a live wrong-act label for the bench, and — after two uses on the same target in one stretch — moves that target to witness-only for the rest of the day (no third accusation). The coach apologizes by shutting up, not by talking.
- **R2-F — The floor is a default, not a cage.** Ending a session early is always one tap, recorded factually, never moralized, and earns its 5:1 minutes for the time actually focused. "25" is the default chip size and the streak-credit threshold only. The starter-mode 10-min session remains the shrink-the-ask tool.
- **R2-G — Fresh-start mechanic.** After ≥4 bad days in 7, the coach proposes once: "Archive the week — fresh start Monday" (one tap). The mirror NEVER displays cumulative deficit ("9 days off track" is banned everywhere, including the partner email). Bad-day counting excludes chosen rest days.
- **R2-H — The day boundary is 4am local (sleep-anchored), not midnight.** Daily Focus expiry, streak day-cut, mirror day-cut, "softer morning" trigger all use it. (Aligns with the bedtime machinery's model of a "night".)

### Explicitly NOT changing

- **The allowance economy survives.** Killing it (the pure-psych recommendation) removes the only sanctioned-break structure, and the Freedom evidence shows prohibition→binge is worse. Bounded + reframed beats removed.
- **The partner mirror stays daily** in parent mode. Weekly digests are where parent products go to die (no loop). Daily + compressed-on-bad-days is the balance.
- **The coach still speaks unprompted** (within caps). PDA logic taken to its end means total silence, which is the dead dashboard the teardown already buried.

---

## ROUND 3 — The rules-lawyer and the structure of teeth

### Attacks

1. **[persona: rules-lawyer] Sort-it-out chaining.** The 10-min sort-it-out session (notes/calendar count as on-task) ends with the card re-shown — pick sort-it-out again. Planning theater all afternoon, "in session" the whole time, coach silenced by its own "plan set" rule.
2. **[persona: rules-lawyer] Allowance farming with on-task-looking junk.** Sit in an IDE scrolling old code, or "read documentation" (a blog), minting 5:1 minutes. Relevance scoring is the gate, but vague Daily Focus text (Round 1, attack 3) weakens it — the two attacks compose.
3. **[persona: rage-quitter, grounded in web] Strict at onboarding is the motivated-moment trap.** The user who just lost a night to porn/Twitter installs at 2am and slams the dial to Strict. Three days later the lock fights them mid-emergency and the partner-code requirement to loosen converts frustration → uninstall. Evidence: stated intent "block me harder" anti-correlates with persistence (Cold Turkey power users warn newcomers to start with 30-minute locks; Beeminder's onboarding-overwhelm churn).
4. **[persona: novelty-junkie] Saturday is not drift.** The coach treats any planless stretch as a coaching surface. It's Saturday. The user is gaming *on purpose*. An overlay — or even a nudge — on a chosen day off is the app claiming the user's whole life. (PDA evidence: rigidity escalates avoidance.)
5. **[persona: rules-lawyer] The "1 prompt per planless stretch" reset.** What's a "stretch"? If an app-restart, a 5-min break, or a new hour resets it, the rules-lawyer manufactures resets; if it never resets, one ignored prompt at 9am means the coach is mute until midnight (the original disease: "one message then shuts the fuck up").
6. **[persona: novelty-junkie] Week 3: the toy is explored, nothing new happens.** All surfaces are known, the overlay is muscle-memory, the mirror says the same shape of thing. What is the *recurring* reason to keep the app — specifically for a brain that eats novelty?

### Triage

- (1) **Lands.** (R3-A.)
- (2) **Lands partially** — R1-B's narrow-fallback already covers the vague-intent half; the residual (plausible-looking junk inside a legit intent) is accepted as un-designable-away: the cap (60 min bank) bounds the damage, and grinding scorer accuracy past the cap's protection violates the 85% lesson. **No change beyond R1-B.**
- (3) **Lands.** (R3-B.)
- (4) **Lands.** (R3-C.)
- (5) **Lands as a definition requirement.** (R3-D.)
- (6) **Lands.** (R3-E.)

### Design changes forced

- **R3-A — Sort-it-out caps at one per planless stretch.** Its closing card's chips exclude another sort-it-out; the remaining chips are real focuses (or the rest declaration). Sessions started from sort-it-out's output are normal sessions with normal scoring.
- **R3-B — Strict is earned, not offered.** Onboarding offers Soft/Standard only (default Standard). Strict unlocks after 7 days of installed use AND takes effect 24h after selection, with explicit consequence copy ("locks distractions until you declare a focus; loosening needs your partner's code"). Tightening within Soft↔Standard stays free/instant. *Parent-mode exception is an open question for Ameer (Q1).*
- **R3-C — The work window.** Coach proactivity + locks operate inside a user-set work window (default Mon–Fri 9–18, one-drag adjustable at onboarding's single config moment). Outside it: witness only, no locks (bedtime machinery owns nights). Weekend/evening planless time is *free*, not drift. The coach may learn and propose window adjustments later, never silently change them.
- **R3-D — "Stretch" is defined and unmanufacturable.** A planless stretch = continuous wall-clock time inside the work window with no live session, surviving app restarts and breaks <30 min (persisted server-side, not in-memory). One *card* per stretch, but ambient state always reflects reality, and the drift-accumulator (not the card) drives the overlay — so the 9am-ignored-card afternoon still escalates structurally (this is exactly the §4 "drift accumulates" charter rule — restated here because the card-vs-structure distinction is what kills both the nag-ladder and the one-message-then-silence failure).
- **R3-E — The weekly earned insight.** One observation per week, maximum, only when statistically earned from profile data ("your starts stick after 10:30; your pre-noon sessions run 2× longer"), bench-gated like speech (a generic fortune cookie = wrong-act). This is the Whoop loop: the recurring payoff is self-knowledge that the user cannot get anywhere else, which compounds with usage — the only retention asset that *grows* over weeks instead of habituating.

### Explicitly NOT changing

- **No XP, no trees, no levels** for the novelty-junkie. Forest's evidence: gamification's failure is shame on miss + childishness on success. The insight loop (R3-E) is the novelty answer.
- **The 60-min allowance cap is not raised** to "reward" heavy focus days. The cap IS the safety property that makes farming pointless.
- **Rolling next-session planning stays** — no return of any day-grid even for "structured" users; scheduled Time Blocks already exist for them.

---

## ROUND 4 — Growth, retention, and the parent-teen wedge

### Attacks

1. **[persona: growth] What is day 2?** Day-1 aha is the mirror (R1-F). What *brings them back* day 2 — what's the morning hook before any habit exists? If the answer is "a notification," it dies in the notification shade.
2. **[persona: growth] Onboarding has too many decisions for a half-distracted installer.** Dial choice + work window + partner setup + weekly goals + privacy levels = the Beeminder corpse ("sign up, immediately feel overwhelmed, never create a single goal").
3. **[persona: teen] The teen sabotages activation.** Parent buys it; teen "can't get it to work," grants no permissions, keeps the Mac asleep. Buyer≠bypasser only matters if the bypasser must keep it running. On a teen-owned Mac with teen-admin, nothing holds.
4. **[web] Surveillance framing poisons the parent product.** OneZero/Life360 evidence: covert or unconditional monitoring → resentment, TikTok bypass culture, trust damage. The existing decision (teen sees the SAME report; user chooses which emails send) is right — but R1-E's "stopped reporting" notice and any parent-initiated config push toward warden territory if not consent-framed.
5. **[persona: growth] The pill is the product and it's invisible in the funnel.** Everything ambient lives in a tiny floating widget; a new user who minimizes it day 1 has no product. (Documented behavior: pill gets dismissed to dock and forgotten.)

### Triage

- (1) **Lands.** (R4-A.)
- (2) **Lands.** (R4-B.)
- (3) **Lands as honesty, not design** — the teen Mac with teen-admin is out of the threat model v1; the parent wedge requires parent-admin (the same admin split that Ameer's own machine uses). Named in the spec, no mechanism invented. **(R4-C, scope note.)**
- (4) **Lands as consent copy requirement,** folded into R1-E's disclosure + Q2. No new mechanism.
- (5) **Lands.** (R4-D.)

### Design changes forced

- **R4-A — Day 2 opens with the diary read-back.** The morning ritual's first real instance: "Yesterday, on the Mac: 4h37m total, longest focus 22 min, most time: X." One fact the user did not know about themselves + the single ask. The hook is the same asset as R3-E: sight. (No streaks, no grades, day 2 has neither.)
- **R4-B — Onboarding makes exactly one decision: the work window.** Dial defaults to Standard (changeable later, R3-B), partner/goals/privacy all deferred to natural moments (partner setup is proposed at the end of week 1 from inside the mirror: "want someone to see this?"). Day-1 required config beyond the window: zero.
- **R4-C — Scope note in the spec:** parent-teen mode presumes parent-admin on the machine (PKG + admin-split install, the machinery that already exists). Without it, Intentional is a consensual mirror, not a control — and is sold as such.
- **R4-D — The pill minimized must leave a trace.** If the pill is minimized/dismissed, ambient state moves to the menu bar item (icon state = focusing/unplanned/locked). The mirror and morning moments can re-summon the pill; nothing else can (no pop-up resurrection — that's the warden).

### Explicitly NOT changing

- **No engagement mechanics to manufacture day-2** (no points for opening the app, no "your coach misses you"). The growth persona's strongest tools are exactly the dopamine surfaces Round 5 of the critique loop banned. Retention rides on sight-value or the product deserves to churn.
- **Parent email stays opt-in-by-the-user** (consent-first decision from 2026-06-11 stands) even though parent-initiated would convert better.

---

## ROUND 5 — Attacking the fixes

### Attacks (each aimed at a change from rounds 1–4)

1. **[persona: shame-spiral → R1-C]** "Recorded as rest" still reads as a verdict if the record renders it like a sin ("took the afternoon off" in red). Also: does a chosen rest nuke the streak?
2. **[persona: rage-quitter → R1-A]** The re-arming lock becomes a harassment loop: declare → session dies at minute 9 → drift 25 min → locked → declare → … The user is being chased around their own computer by a deadbolt.
3. **[persona: rules-lawyer → R1-C′]** Suppression contexts are a bypass: keep a mic-live Zoom room open solo all day → coach permanently suppressed.
4. **[persona: rules-lawyer → R2-B]** Mute valve tapped every morning = coach voice is dead permanently; product degrades to a blocker with a diary. Toothless pole.
5. **[persona: rules-lawyer → R2-G]** Fresh-start farming: archive every week, no week ever looks bad, the partner mirror is laundered.
6. **[persona: parent → R3-B]** The parent who buys this FOR the lock can't have Strict for 7 days? The wedge buyer is gated out of the wedge feature.
7. **[persona: rage-quitter → R2-E]** "Two 'I need this' taps → witness-only for the day" is itself gameable (two taps and YouTube is exempt all day) — and the rules-lawyer knows it after day 3.

### Triage

- (1) **Lands.** Copy + streak semantics fix (R5-A).
- (2) **Lands.** Cadence bound (R5-B).
- (3) **Lands.** Definition tightening (R5-C).
- (4) **Does NOT force a structural change — it confirms the design.** If a user mutes the voice every day, the voice deserves to be dead for them; structure (dial, locks, allowance, mirror) carries the teeth. That IS the volunteer balance. The profile records the pattern; the weekly insight may name it once ("you've muted me 12 days straight — want me to default to quiet?" → one tap makes mute the default, honestly). Dignity over engagement.
- (5) **Lands.** Frequency bound (R5-D).
- (6) **Held as open question Q1** — parent-mode exception is plausible (the consenting strictness owner is the parent, who isn't in the 2am motivated-moment trap) but it's an Ameer/ICP call, not a design certainty.
- (7) **Lands, partially.** The exemption is per-target per-day and the *taps are in the mirror* ("needed YouTube twice during focus") — gaming it is visible to the only audiences that matter (self tomorrow, partner tonight). Add: targets that are 🚫-ruled (user's own standing rules) never get the witness-only exemption — "I need this" pauses a *coach* action, never a *rule* (R5-E).

### Design changes forced

- **R5-A — Rest renders as rest.** Chosen rest is first-class in mirror + Today ("Thursday afternoon: rest (chosen)"), neutral color, leads with what DID happen. Streak: chosen rest pauses (like the existing bad-day pause), never decays, and doesn't count toward fresh-start's bad-day tally (already in R2-G).
- **R5-B — Lock re-arm cadence bound:** max 2 re-arms per work window; after the second, the coach stops locking and the day proceeds in witness mode with the planless ambient state. The deadbolt never becomes a metronome. (The record shows the pattern; the weekly insight may name it.)
- **R5-C — Suppression requires *activity*, not just an open call:** screen-share or camera/mic live AND foreground meeting-app interaction within the last N min; a solo idle room decays back to normal coaching after ~15 min. Suppression state is shown on the pill ("paused — presenting") so it's legible, not magical.
- **R5-D — Fresh start is once per 30 days,** proposed by the coach only (never a button the user can reach for weekly). Archived weeks render in the partner mirror as "archived (fresh start)" — laundering is visible, factually.
- **R5-E — "I need this" pauses coach actions, never rules.** A 🚫 standing rule the user themselves set (or a parent set) is not overridable by the coach-action escape hatch. Keeps the constitution clean: the coach's hands tighten only; the escape hatch loosens only the coach's own grip, never the law.

### Explicitly NOT changing

- **The mute valve stays unconditional** (attack 4). A coach you cannot silence is a warden; a structure you cannot ignore is the product.
- **Suppression contexts stay generous** (better to miss coaching during a fake meeting than to fire one overlay into a real one — the 5× asymmetry applies squarely).

---

## ROUND 6 — Convergence check

Final pass with all personas against the revised design. Residual attacks:

1. **[persona: rules-lawyer]** "Declare a real-sounding focus, run a real session, alt-tab to junk inside allowed apps (Slack scroll, 'docs')." — Accepted residual. Relevance scoring + the 60-min cap bound it; grinding past it violates the 85% lesson. The mirror still shows where time went. **No change.**
2. **[persona: rage-quitter]** "The pill itself annoys me." — Pill minimizes to menu-bar state (R4-D); the coach voice mutes (R2-B); structure stays. Both poles already balanced. **No change.**
3. **[persona: shame-spiral]** "The parent's *reply* to the email shames me; you can't bench my mother." — True and out of product scope; mitigations already maxed (positive-first, compression, user-controlled sending, same-report transparency). The onboarding copy for partner setup should set receiver expectations ("this works best when you respond to good days, not bad ones") — copy, not mechanism. **No structural change.**
4. **[persona: novelty-junkie]** "Week 6: even the insights repeat." — Insights are gated on *new* statistically-earned patterns; when there's nothing new, the coach says nothing (silence bias applies to insights). Honest ceiling acknowledged. **No change.**
5. **[persona: growth]** "You still don't know your D7 number." — Correct; instrumentation (§6 of the daily-focus spec, `shown/engaged/ignored/dismissed`) is the answer and already specced. **No change.**

**Five consecutive no-change attacks across all personas → converged.**

---

## CONVERGED DESIGN DELTAS (vs the two spec docs — numbered, implementable)

Slice mapping refers to the daily-focus spec's sequencing (§"Sequencing").

| # | Delta | Specs touched | Slice |
|---|---|---|---|
| 1 | **Lock semantics:** declaration is a session key, not a day pass — lock lifts into a started session; re-arms on renewed accumulated drift; **max 2 re-arms per work window**, then witness mode. Exits always include rest declaration. | daily-focus §4 | 3 |
| 2 | **Vague-intent fallback:** unscoreable typed intent → coach proposes sharper chip from telemetry; declined → narrow work-shaped allowlist default, never everything-passes. | daily-focus §1, §3 | 1 |
| 3 | **Break-chaining conversion:** 2nd consecutive "real break" in a stretch becomes "Take the afternoon off — recorded as rest" (releases lock, renders neutrally, pauses streak, excluded from bad-day tallies). No third identical overlay. | daily-focus §4 | 2 |
| 4 | **Suppression contexts (ship BEFORE any overlay goes live):** no overlay/soft-close/nudge during active screen share, live camera/mic call, presentation mode, screen recording. Requires activity (not an idle open room; solo idle decays after ~15 min). Pill shows "paused — presenting." | daily-focus §4; focus-agent guardrails | 2 (gate) |
| 5 | **"I need this" escape on every enforcement surface:** honored instantly, logged as live bench label; 2 uses on one target in a stretch → that target is witness-only for the day. Pauses *coach actions only* — never standing rules. | daily-focus §4; focus-agent guardrails | 2 |
| 6 | **Mute valve:** one tap silences coach *voice* for the day; structure stays armed; recorded factually; chronic mute → coach offers quiet-by-default once. | focus-agent action space | 2 |
| 7 | **Allowance reframed:** copy is "breaks are covered," never "earn screen time"; earning continuous 5:1 (no 25-min cliff); allowance never the headline of a celebration. | daily-focus (vocab sweep); focus-agent "also shipping" | 1 |
| 8 | **Floor ≠ cage:** ending early is one tap, factual, unmoralized, keeps earned minutes; 25 = default chip + streak-credit threshold only. | daily-focus §2 | 1 |
| 9 | **Day boundary = 4am local** (sleep-anchored) for Daily Focus expiry, streak cut, mirror cut, softer-morning trigger. | daily-focus §1 | 1 |
| 10 | **Strict gated:** not offered at onboarding; unlocks after 7 days installed + 24h cooling-off + consequence copy. Soft↔Standard free. (Parent-mode exception = Q1.) | daily-focus §4 | 3 |
| 11 | **Work window:** the ONE onboarding decision (default Mon–Fri 9–18). Coach proactivity + locks live inside it; outside = witness only. Coach may propose changes, never silently make them. | both | 1 |
| 12 | **"Planless stretch" defined:** continuous in-window time without a live session, persisted server-side, surviving restarts and <30-min breaks. One card per stretch; the drift-accumulator (not the card) drives structure. | daily-focus §4 | 2 |
| 13 | **Sort-it-out: one per stretch;** closing chips exclude another sort-it-out. | daily-focus §3 | 1 |
| 14 | **Day-1 aha = mirror-first:** first proactive coach moment is "here's your morning, factually" (~2–3h in); first proposal comes after it. Day-2 opens with the diary read-back (one self-knowledge fact + the ask). | focus-agent bookends | 2 |
| 15 | **Onboarding = zero config beyond the window;** dial defaults Standard; partner setup proposed end of week 1 from inside the mirror. | both | 1 |
| 16 | **Witnessed off-switch:** with reports enabled, telemetry-dark → one factual partner note ("stopped reporting as of Tuesday"); disclosed at setup; turning reports off is itself reported once. | daily-focus §5; focus-agent constitution (amend: this is the ONE partner-touching event, pre-consented) | 3 |
| 17 | **Mirror honesty + tone bench:** all claims scoped "On the Mac:"; editorial vocabulary banned (facts only); positive-first ordering; bad days compress; wrong-tone = wrong-act in bench. `shield_phone` named the #1 leak, first post-v1 slice. | both | 1–3 |
| 18 | **Streaks weekly-view only** (never pill/Today-ambient); decay-not-break stays; rest pauses. | daily-focus §5 | 3 |
| 19 | **Fresh start:** coach-proposed only, ≥4 bad days in 7, max once/30 days; archived weeks visibly marked; cumulative-deficit displays banned everywhere. | daily-focus §5 | 3 |
| 20 | **Weekly earned insight:** ≤1/week, statistically earned, bench-gated; silence when nothing new. The retention loop is self-knowledge, not engagement mechanics. | focus-agent memory/profile | post-S4 |
| 21 | **Pill minimized → menu-bar state carries ambient truth;** only mirror/morning moments may re-summon the pill. | daily-focus §5 | 2 |
| 22 | **Spec consistency fix:** §5's "unplanned · earning nothing · tank −Nm" chip contradicts the critique-loop's "states not math" delta — resolve to state-only ("unplanned"); tank number only when binding (last 10 min). | daily-focus §5 | 1 |
| 23 | **Parent-mode scope note:** parent-teen control presumes parent-admin install (existing PKG/admin-split machinery); without it the product is a consensual mirror and is sold as such. | both (scope) | doc |

---

## Evidence appendix — the strongest real-world findings

1. **One Sec habituation:** "the novelty wears off after a few weeks. The breathing exercise that felt meaningful on day one can feel like an annoying formality by week four… On bad days, you'll breathe through the exercise and scroll anyway… a speed bump, not a wall." — https://www.blok.so/resources/one-sec-app-review-does-adding-friction-actually-reduce-screen-time (also cites the PNAS one-sec study's 57% average reduction: https://www.pnas.org/doi/10.1073/pnas.2213114120)
2. **Freedom bypass + impulse gap:** "It's easy to bypass if you really want to. Just turn off wifi or delete the app." / "The fundamental problem with Freedom is that blocking doesn't address the impulse" / post-session binge pattern. — https://www.blok.so/resources/freedom-app-review-does-blocking-websites-and-apps-actually-work
3. **Opal rage-deletion:** user "so consistently enraged" they "rage deleted it 3 times in the past 6 months" (VPN issues); blocking persisting after uninstall as a complaint theme. — https://justuseapp.com/en/app/1497465230/opal-save-time-daily/reviews ; https://community.opal.so/t/opal-is-still-blocking-my-apps-after-being-uninstalled/3058
4. **Cold Turkey's rigidity backfire:** Frozen Turkey has "no override, no emergency unlock, and no 'I changed my mind' option… this rigidity can backfire badly"; power users tell newcomers to start with 30-minute locks. — https://sipandscroll.app/blog/cold-turkey-blocker-review.html
5. **Blockers must survive the worst moment:** "A blocker should not be judged only by how it works when motivation is high… If a blocker has easy overrides, pause buttons, or time-based locks that expire automatically, it probably will not work for ADHD"; "flexible blocking backfires — extra choices create negotiation opportunities." — https://www.digitalzen.app/blog/why-most-website-blockers-dont-work-for-adhd/
6. **Screen Time's Ignore Limit reflex:** "Without a passcode, all it takes is a few taps on 'Ignore Limit' and you're back scrolling… to override, you need the passcode, and this small barrier makes a huge difference." — https://adhdcanada.ca/blog/struggling-with-screen-time-this-overlooked-iphone-feature-actually-works/
7. **Beeminder onboarding overwhelm:** "painfully common for a user to sign up, immediately feel overwhelmed, and never create a single goal"; users "collapse under the pressure" of overcommitment. — https://blog.beeminder.com/gatewaydrug/ ; https://forum.beeminder.com/t/review-forfeit-is-the-yoda-of-commitment-device-apps/11021
8. **PDA — demands as threats:** "the person's nervous system perceives demands (even minor ones) as threats, triggering a survival response… even if they genuinely want to do the thing"; "direct commands, ultimatums, or repeated reminders create cycles where demand leads to avoidance… shutdown"; flexibility reduces avoidance, rigidity escalates it. — https://add.org/demand-avoidance/ ; https://www.healthline.com/health/adhd/demand-avoidance-adhd ; https://www.scienceworkshealth.com/post/pda-and-adhd-when-demand-avoidance-shows-up-in-an-adhd-brain
9. **"Guilt = not designed for ADHD":** "If an app makes you feel guilty for missing a day, it is not designed for ADHD." — https://www.morgen.so/blog-posts/adhd-productivity-apps
10. **Duolingo streak loss → churn; freeze → −21%:** losing a streak "can have the opposite effect, and actually feel quite demotivating"; Streak Freeze reduced at-risk churn by 21%; streak revival exists because "resetting to zero can feel like a hurdle too big to clear." — https://blog.duolingo.com/how-streaks-keep-duolingo-learners-committed-to-their-language-goals/ ; https://www.strivecloud.io/blog/gamification-examples-boost-user-retention-duolingo
11. **Screens-as-reward backfires (Guelph study):** kids whose parents use screen time as reward/punishment use screens MORE; the overjustification effect; "giving screen time as a reward can make homework, chores and offline activities feel like barriers to the thing they really want: the screen." — https://www.psychologytoday.com/us/blog/the-art-of-talking-with-children/202407/when-we-use-screens-to-reward-kids-they-use-screens ; https://www.tryohana.com/en/blog/why-using-screen-time-as-a-reward-can-backfire ; https://studyfinds.org/parents-screen-time-reward-turning-kids-digital-junkies/
12. **Parent-surveillance trust damage:** "By installing parental control apps on their kids' phones, parents could be damaging their child's trust… and potentially hurting the child's ability to navigate risk"; teens publish Life360 bypass guides on TikTok; transparent + temporary use mitigates. — https://onezero.medium.com/the-case-against-spying-on-your-kids-with-apps-59760ec780e0 ; https://goodbaddad.com/2024/03/19/how-teens-evade-life-360-a-step-by-step-guide-for-parents/ ; https://www.bark.us/blog/parental-controls-vs-teen-privacy/
13. **Forest's shame-on-miss:** when a session collapses "the tree died, the task didn't happen, the shame is loud"; "Forest solves phone distraction but doesn't solve task initiation, time blindness, or the emotional patterns that make starting a task feel impossible." — https://calmevo.com/forest-app-review/ ; https://www.getinflow.io/post/best-alternatives-forest-app-adhd
14. **Body doubling / appointment effect (what WORKS):** "When you commit to a specific time slot with a real person waiting for you, that external accountability — someone expecting you to show up — is precisely the activation energy ADHD brains need." — https://www.focusmate.com/blog/adhd-body-double-productivity-accountability/ ; https://add.org/the-body-double/

---

## Open questions (only Ameer can answer — max 5)

1. **Parent-mode Strict exception (delta 10):** should a parent-admin install be allowed to set Strict on day 1 (the parent is the consenting strictness owner and isn't in the 2am trap), or does the 7-day gate apply to everyone?
2. **Witnessed off-switch (delta 16):** confirm the consent framing — does "stopped reporting" notice apply in self-use partner mode, parent mode, or both? (It amends the constitution's "never message the partner" with exactly one pre-consented event.)
3. **Allowance vocabulary (delta 7):** "breaks are covered" replaces "focus 25, earn 5" in user-facing copy — but "focus 25, earn 5" was the locked vocab from the teardown's state-sweep. Which wins?
4. **Work window default (delta 11):** Mon–Fri 9–18 as the single onboarding decision — right default for your launch audience (Instagram, non-parents)?
5. **Mute valve at Strict (delta 6):** confirm the voice is mutable at every dial level (structure persists, voice always yields) — or should Strict imply the voice can't be muted? (Recommended: mutable everywhere; a coach you can't silence is a warden.)
