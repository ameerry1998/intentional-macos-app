# Gamification Brainstorm: Focus Sessions as a Video Game

> Your workday should feel like a game you're winning, not a chore you're surviving.

The core insight: video games are masters of engagement through real-time feedback, progressive challenge, and visible progress. Focus sessions already have all the raw ingredients (timers, goals, success/failure states) — they just need the game design layer on top.

---

## 1. Damage Vignette (Red Edge Glow)

When you drift to an irrelevant app or site, the edges of your screen start glowing red — exactly like the "you got shot" effect in FPS games like Call of Duty or Halo. The glow intensifies the longer you stay distracted. Subtle at first (barely noticeable red tint in the corners), it gradually creeps inward and deepens in opacity until it feels urgent. The moment you return to relevant work, the red fades out over 2-3 seconds with a satisfying "healing" feel.

**Technical implementation:** Create a new `DamageVignetteController` that manages a borderless, transparent, click-through `NSWindow` at `.floating` level with `ignoresMouseEvents = true`. The content view uses a `CAGradientLayer` configured as a radial gradient — transparent in the center, red (`#FF2020`) at the edges. Animate the gradient's `opacity` and `locations` properties using `CABasicAnimation` based on `FocusMonitor.cumulativeDistractionSeconds`. Thresholds: 5s = corners only at 15% opacity, 15s = edges at 35%, 30s = creeping inward at 55%, 60s+ = heavy vignette at 75%. The window frame matches the union of all `NSScreen.screens` frames. On return to relevant content, run a 2-second `CABasicAnimation` easing opacity back to 0. The FocusMonitor already tracks cumulative distraction and polls every 10 seconds, so hook into the existing `handleDeepWorkBrowserIrrelevance()` / `handleFocusHoursBrowserIrrelevance()` methods to call `damageVignetteController?.setIntensity(cumulativeDistractionSeconds)`.

---

## 2. Video Game HUD (Heads-Up Display)

A persistent, translucent HUD overlay in the top-left corner of the screen — just like in an open-world RPG. It shows your Focus Score (a number 0-100 that updates in real-time), your current streak (e.g., "12 min focused"), earned browse minutes remaining, and the current block type icon. The HUD uses a dark frosted-glass aesthetic with monospaced numbers that tick up/down smoothly. It's always visible but never intrusive — small enough to live alongside your menubar.

**Technical implementation:** Extend the existing `DeepWorkTimerController` pattern — a new `FocusHUDController` that creates a borderless `NSWindow` at `.floating` level, positioned top-left (20px from edges). The content is a SwiftUI `View` with `@ObservedObject` binding to a `FocusHUDViewModel`. The view model is updated by `FocusMonitor` on every poll (10s interval). Layout: vertical stack of 3-4 stat rows, each with an SF Symbol icon + label + value. Use `.monospacedDigit()` font for numbers so they don't jitter as values change. Background: `VisualEffectView` wrapping `NSVisualEffectView` with `.hudWindow` material for the frosted glass look. Total size ~180x100px. The window uses `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]` so it follows across spaces. Make it draggable via `isMovableByWindowBackground = true`. Persist position in UserDefaults.

---

## 3. Focus Score with Real-Time Ticker

A single number (0-100) that represents how focused you are *right now*, displayed prominently in the floating timer pill. It's calculated from a rolling window of the last 10 minutes: 100 = perfectly focused the whole time, drops by ~3 points per distracted poll (10s), recovers by ~1.5 points per focused poll. The number has a subtle color gradient — green (80-100), yellow (50-79), orange (30-49), red (0-29). Seeing "Focus: 94" feels like maintaining a high score. Watching it drop to 67 feels like losing health.

**Technical implementation:** Add a `focusScore: Double` property to `FocusMonitor`. Maintain a circular buffer of the last 60 relevance poll results (10s each = 10 minutes). On each poll, push `true` (relevant) or `false` (irrelevant). The score = `(relevantCount / totalCount) * 100`, with a minimum of 6 entries before displaying (avoids wild swings at block start). Expose the score via a callback `onFocusScoreChanged: ((Int) -> Void)?` that the `DeepWorkTimerController` (or the new HUD) subscribes to. In the SwiftUI view, display as `Text("Focus: \(score)")` with `.foregroundColor()` driven by the threshold ranges. Animate transitions with `.animation(.easeInOut(duration: 0.5))` so the number doesn't jump harshly.

---

## 4. Combo Multiplier System

Chain together consecutive minutes of focused work to build a combo. "5x COMBO" appears as a glowing badge on the floating timer. The combo breaks instantly on distraction (with a dramatic shatter animation — the number fragments and fades). Higher combos earn browse minutes faster: 5x combo = 1.5x earning rate, 10x = 2x, 20x = 3x. This makes you protective of your combo — "I can't check Twitter, I have a 15x combo going!"

**Technical implementation:** Add `comboCount: Int` and `comboMultiplier: Double` to `FocusMonitor`. Increment `comboCount` on each focused poll (every 10s), reset to 0 on any irrelevant poll. Multiplier tiers: 1-4 = 1.0x, 5-9 = 1.5x, 10-19 = 2.0x, 20+ = 3.0x. Feed the multiplier into `EarnedBrowseManager.tickEarning()` as an additional factor. In the floating timer SwiftUI view, add a conditional `Text("x\(combo)")` with a pulsing scale animation (`.scaleEffect()` with `Animation.easeInOut.repeatForever()`) when combo >= 5. On combo break, trigger a `CAKeyframeAnimation` on the text layer — scale up to 1.3x, rotate +-5 degrees, fade to 0 over 0.8s, then remove. Sound effect optional via `NSSound` or `AVAudioPlayer` for combo milestones (5, 10, 20).

---

## 5. XP & Leveling System

Earn XP for every minute of focused work. XP accumulates across days and weeks — you're leveling up your "focus character." Level 1 starts at 0 XP, each level requires progressively more (100, 250, 500, 1000...). Level-ups trigger a satisfying notification with a level badge. Your level is displayed in the HUD and the dashboard. Over weeks, watching yourself go from Level 1 to Level 15 creates a persistent sense of progression that transcends any single day.

**Technical implementation:** Create a `FocusXPManager` class persisted to `~/Library/Application Support/Intentional/focus_xp.json`. Schema: `{ totalXP: Int, level: Int, xpForNextLevel: Int, levelHistory: [{ level, achievedAt }] }`. XP earning: 1 XP per 10s focused poll (6 XP/min base, modified by combo multiplier). Level thresholds follow `floor(100 * 1.5^(level-1))` curve. On level-up, post an `NSUserNotification` (or `UNUserNotificationCenter`) with the new level and a fun title ("Level 7: Flow State Warrior"). Store the level in the backend via a new field on `daily_usage` sync so it can display in the dashboard chart. The `FocusMonitor` calls `focusXPManager.addXP(amount)` on each focused poll. Display in the floating timer pill as a small "Lv.7" badge next to the focus score.

---

## 6. Health Bar (Focus HP)

Replace the abstract "earned minutes" concept with a visual health bar. You start each block at full HP. Every second on an irrelevant app drains HP. When HP hits 0, the intervention overlay triggers (you "died"). HP regenerates slowly when you return to relevant content. The bar is rendered as a classic red/green game health bar with chunky segments — instantly readable at a glance from across the room.

**Technical implementation:** Add a `HealthBarView` to the floating timer SwiftUI view. The health value maps directly from `cumulativeDistractionSeconds` relative to the intervention threshold (300s for both deep work and focus hours). HP percentage = `max(0, 1.0 - (cumulativeDistraction / interventionThreshold))`. Render as an `HStack` of 10 `RoundedRectangle` segments — filled segments are green (#34D399) fading to red (#EF4444) as HP drops, empty segments are dark gray. Total width ~120px, height 8px. When HP reaches critical (< 25%), add a pulsing animation on the remaining segments. When HP hits 0, flash the entire timer pill red 3 times before the intervention overlay appears. The health bar is purely visual — it reads from `FocusMonitor.cumulativeDistractionSeconds` without changing any enforcement logic.

---

## 7. Boss Battles for Deep Work Blocks

Reframe each deep work block as a boss fight. The block's intention becomes the boss name ("Build Auth Module" → "THE AUTH MODULE"). A boss health bar appears below the floating timer — it depletes as you put in focused time. Completing the block without intervention = boss defeated. A satisfying "VICTORY" animation plays. If you fail (intervention triggers), you "wiped" — the boss resets for next time. Multi-hour blocks are "raid bosses" with multiple health bar segments.

**Technical implementation:** Create a `BossBattleController` activated only during deep work blocks. The boss HP = block duration in seconds. Each focused 10s poll reduces boss HP by 10. Display as a wide bar (200px) below the floating timer with the "boss name" (block intention in ALL CAPS) above it. Use a custom `BossBattleView` SwiftUI view with dramatic styling: dark red gradient background, boss name in bold with a slight glow effect (`.shadow(color: .red, radius: 4)`), health bar with yellow-to-red gradient. On completion (HP = 0 or block ends while focused), show a "VICTORY" overlay — a centered `Text("VICTORY")` in gold with scale-in animation + particle emitter (use `CAEmitterLayer` for gold sparkle particles). On "wipe" (intervention triggered), show "DEFEATED" in red with screen shake (animate the window frame origin +-3px rapidly 5 times).

---

## 8. Achievement System with Badges

Unlock achievements for focus milestones: "First Blood" (first deep work block completed), "Untouchable" (full block with 0 distraction), "Marathon" (4+ hours cumulative focus in a day), "Streak Master" (7-day focus streak), "Night Owl" (deep work after 10 PM), "Early Bird" (deep work before 7 AM). Badges display in a trophy case on the dashboard. New achievements trigger a toast notification with badge artwork.

**Technical implementation:** Create an `AchievementManager` with a registry of `Achievement` structs: `{ id, name, description, iconName, condition, unlockedAt? }`. Persist unlocked achievements to `~/Library/Application Support/Intentional/achievements.json`. Check conditions at key moments: block completion (in `FocusMonitor.blockDidEnd()`), daily summary computation, streak updates. For the toast notification, use a new `AchievementToastController` — a borderless `NSWindow` that slides in from the top-right with the badge icon (SF Symbol), name, and description, auto-dismisses after 5 seconds. The dashboard trophy case is a new HTML section in `dashboard.html` showing a grid of badge icons (grayed out = locked, colored = unlocked) with hover tooltips. Sync achievement data to the backend via a new `achievements` field in the settings sync JSONB blob.

---

## 9. Focus Aura — Ambient Screen Border Glow

A subtle, beautiful glow around the edges of your screen that reflects your current focus state. Deep indigo/purple when you're in flow, shifting to green when your combo is high, fading to gray when you're idle, and — critically — shifting to warning amber and then red when distracted (distinct from the damage vignette, which is dramatic; this is always-on and ambient). The aura pulses gently, like breathing, creating a meditative "I'm in the zone" feeling when things are going well.

**Technical implementation:** Create a `FocusAuraController` managing a borderless, transparent, click-through `NSWindow` covering all screens at `.floating` level. The content view has 4 `CAGradientLayer` sublayers — one for each edge (top, bottom, left, right). Each gradient goes from the aura color (at the screen edge) to transparent (20-40px inward). Color is driven by focus state: flow = `#6366F1` (indigo), high combo = `#10B981` (emerald), idle = `#6B7280` (gray), distracted = `#F59E0B` (amber) → `#EF4444` (red). Use `CABasicAnimation` on the gradient colors with 3-second duration for smooth transitions. Add a subtle "breathing" pulse: animate opacity between 0.6 and 0.9 with a 4-second `autoreverses` animation. Update color on each `FocusMonitor` poll via `focusAuraController?.setState(.flow | .distracted | .combo(15))`.

---

## 10. Kill Feed — Distraction Defeated Log

A scrolling log in the corner of the screen (like a multiplayer FPS kill feed) that shows each time you successfully resisted distraction: "Defeated: Twitter (was browsing 8s)" or "Blocked: Instagram attempt." It makes every avoided distraction feel like a victory. The entries fade in, scroll up, and fade out after 5 seconds. Satisfying to watch stack up during a good session.

**Technical implementation:** Create a `KillFeedController` with a borderless `NSWindow` in the bottom-right corner. Content is a SwiftUI `List` with `ForEach` over a `@Published var entries: [KillFeedEntry]` array in the view model. Each `KillFeedEntry` has `{ platform, duration, timestamp, id }`. Entries are added when `FocusMonitor` detects a return to relevant content after a distraction period — call `killFeedController?.addKill(platform: lastDistractionPlatform, duration: distractionDuration)`. New entries animate in with `.transition(.move(edge: .trailing).combined(with: .opacity))`. A 5-second `Timer` removes old entries. Max 5 visible entries. Style: dark translucent background, white text, platform icon (favicon or SF Symbol), "+6 XP" bonus text in green. Keep the window at `.floating` level, ~200x150px.

---

## 11. Daily Quest Board

Each morning, generate 3 random daily quests tailored to your schedule: "Complete 2 deep work blocks without intervention," "Maintain a 10x combo for 5 minutes," "Earn 30 browse minutes today." Completing quests gives bonus XP and a special daily badge. The quest board appears briefly at the first block start of the day and is accessible from the dashboard anytime.

**Technical implementation:** Create a `DailyQuestManager` that generates quests at midnight (or first app launch of the day). Quest templates are parameterized: `{ type: "combo_duration", target: 300, xpReward: 50 }`, `{ type: "blocks_completed", target: 2, xpReward: 30 }`, etc. Pool of ~15 quest templates, randomly select 3 daily (weighted by schedule — no "complete 3 deep work blocks" quest if there's only 1 scheduled). Track progress via hooks in `FocusMonitor` and `EarnedBrowseManager`. Persist to `~/Library/Application Support/Intentional/daily_quests.json` with `{ date, quests: [{ template, target, progress, completed }] }`. Display as a SwiftUI overlay on first block start — a dark card with 3 rows, each showing quest text + progress bar + XP reward. Also render in `dashboard.html` as a "Today's Quests" section. Quest completion triggers achievement toast + XP grant.

---

## 12. Streak Counter with Fire Animation

Show your current focus streak (consecutive days meeting your focus goal) as a number with a fire animation that grows more intense with longer streaks. Day 1 = small ember, Day 3 = campfire, Day 7 = bonfire, Day 14 = inferno, Day 30 = supernova. Breaking a streak shows a dramatic "streak lost" animation. The streak number appears in the HUD and the dashboard. This creates powerful loss aversion — "I can't break my 12-day streak."

**Technical implementation:** Track in `FocusXPManager` or a dedicated `StreakManager`. A day "counts" if total focused minutes >= a configurable threshold (default: 60 min, adjustable in settings). Check at end of day (midnight) or on first launch. Persist `{ currentStreak, longestStreak, lastQualifyingDate }`. In the floating timer/HUD SwiftUI view, render the streak number with a `CAEmitterLayer` behind it emitting flame-colored particles. Particle configuration scales with streak length: `birthRate` (2 → 20), `lifetime` (1.0 → 3.0), `velocity` (20 → 80), `emissionRange` (0.3 → 1.0). Colors shift from orange/yellow (short streaks) to blue/white (long streaks, > 21 days — "cold fire"). On streak break, play a 1.5s animation: the fire extinguishes (birthRate → 0, particles turn gray, streak number shakes and fades). Dashboard shows a flame icon calendar heatmap.

---

## 13. Power-Up Drops

At random intervals during sustained focus (minimum 15 minutes focused), a "power-up" notification drops: "DOUBLE XP — Next 10 minutes!" or "SHIELD — Next distraction forgiven!" or "TIME WARP — +5 bonus earned minutes!" These are rare enough to feel special (1-2 per day) but frequent enough to create anticipation. The randomness exploits the same variable-ratio reinforcement that makes games addictive — except here it reinforces focus.

**Technical implementation:** Create a `PowerUpManager` with a set of power-up types: `{ doubleXP(duration: 600), shield(charges: 1), timeWarp(minutes: 5), comboFreeze(duration: 300) }`. On each focused poll in `FocusMonitor`, roll a random chance: `Double.random(in: 0...1) < 0.003` (~1.8% chance per poll, ~1 per 55 min of focus). Guard: minimum 15 min continuous focus, max 2 per day, minimum 30 min between drops. When triggered, show a `PowerUpToastController` — a flashy SwiftUI overlay with the power-up icon spinning in, name pulsing in gold text, auto-dismiss after 4s. Active power-ups display as small icons in the HUD. Effects: `doubleXP` multiplies `FocusXPManager.addXP()` by 2, `shield` skips one `cumulativeDistractionSeconds` increment in `FocusMonitor`, `timeWarp` calls `EarnedBrowseManager.addBonusMinutes(5)`, `comboFreeze` prevents combo reset for its duration.

---

## 14. Screen Desaturation as "Poison" Effect

This reimagines the existing grayscale feature through a game lens. Instead of just "the screen goes gray," frame it as a "poison" debuff. When distracted during focus hours, the screen starts losing color progressively (not instant) — 10% saturation loss per 10 seconds. A "POISONED" status icon appears in the HUD with a dripping green effect. The antidote: return to relevant work for 30 seconds to start "healing" (color slowly returns). This makes grayscale feel like a game mechanic rather than a punishment.

**Technical implementation:** This builds on the existing `GrayscaleOverlayController` but makes the transition gradual. Since the current CIFilter `backgroundFilters` approach doesn't work and the UAGrayscale API is binary (on/off), implement a hybrid: use a transparent overlay `NSWindow` (like the damage vignette) with a semi-opaque gray fill whose alpha increases with distraction duration. Start at `backgroundColor = NSColor.gray.withAlphaComponent(0.0)` and animate to `0.6` over 60 seconds using `NSAnimationContext`. This creates a "fading to gray" effect without the system notification. The HUD shows a "POISONED" status using a green skull SF Symbol (`exclamationmark.triangle.fill` tinted green) with a drip animation (translate Y by 2px, repeat). When the user returns to relevant content, reverse the animation over 3 seconds. If `backgroundFilters` is fixed in a future macOS update, swap the gray overlay for a real CIFilter desaturation with `inputSaturation` animated from 1.0 → 0.0. Keep both the commented-out UAGrayscale code AND this new approach — never delete either.

---

## 15. Territory Control Map

Your daily schedule is visualized as a map of "territories" (blocks) on the dashboard. Each territory is colored based on how well you focused during that block: bright green = dominated (90%+ focus), yellow = contested (60-89%), red = lost (< 60%), gray = upcoming. Completed territories show a flag icon. The map feels like a Risk or Civilization game board — you're conquering your day, one block at a time.

**Technical implementation:** Render in `dashboard.html` as a horizontal bar divided into segments proportional to block duration. Each segment is a rounded rectangle with the block name, time range, and focus percentage. Colors use CSS custom properties driven by the focus score per block. Data source: the existing block assessment data in `FocusMonitor.blockAssessments` or the relevance log. Add a new JS → Swift message `GET_TERRITORY_MAP` that returns `[{ blockId, title, startTime, endTime, focusPercent, status: "completed" | "active" | "upcoming" }]`. Completed blocks show a small flag SVG icon. The active block has a pulsing border animation. A tooltip on hover shows detailed stats (focus score, distraction count, combo max). Use CSS `grid` layout for even spacing. Animation: when a block completes, its segment fills with color in a left-to-right sweep (CSS `@keyframes` on `background-size`).

---

## 16. Sound Design — Ambient Game Audio

Subtle, non-intrusive audio cues that reinforce the game feel. A soft chime when focus score crosses 90. A gentle "ding" for each combo milestone (5x, 10x, 20x). A satisfying "whoosh" when earning browse minutes. A low warning tone when focus score drops below 50. A triumphant fanfare on block completion. All sounds are optional (settings toggle), short (< 1 second), and quiet enough to use with headphones while working.

**Technical implementation:** Create a `GameAudioManager` singleton with a library of short audio clips stored as `.wav` or `.aiff` files in the app bundle. Use `AVAudioPlayer` for playback with volume set to 0.3 (subtle). Sound categories: `combo(level: Int)`, `focusHigh`, `focusLow`, `earning`, `blockComplete`, `achievement`, `powerUp`, `comboBreak`. Each has a cooldown (minimum 30s between same-category sounds) to prevent audio spam. Call from relevant managers: `FocusMonitor` for focus/distraction events, `EarnedBrowseManager` for earning events. Store enabled/disabled + volume in `UserDefaults` (key: `gamificationSoundsEnabled`, `gamificationSoundsVolume`). Add a toggle in the dashboard settings page. Load sounds lazily on first use. Preload critical sounds (combo, focus) at app launch to avoid playback delay.

---

## 17. "Ghost" Rival — Race Against Yesterday's Self

Display a ghost of your yesterday's focus performance — like racing against your own ghost in Mario Kart. The ghost appears as a faded progress indicator in the HUD: "Yesterday at this time: Focus 78, Earned 22 min." If you're beating yesterday, the ghost text is green. If you're behind, it's red. This creates a natural competitive drive against yourself without needing social features.

**Technical implementation:** Add a `GhostRivalManager` that loads yesterday's hourly focus data from the backend (`GET /usage/history?days=1`) or local persistence. On each poll, compute "yesterday's cumulative focus score at this exact time of day" by interpolating the stored data. Store as `[{ hour, focusScore, earnedMinutes }]` in `focus_xp.json`. Display in the HUD as a secondary row: a small ghost icon (SF Symbol `figure.walk` with low opacity) + "Ghost: 72" vs your current "You: 85". Color the comparison: green if you're ahead by 5+, yellow if within 5, red if behind by 5+. In the dashboard, show a dual-line chart: your performance today vs yesterday, with the gap shaded. Only activate if there's data from yesterday (skip on first day).

---

## 18. Loot Boxes for Block Completion

When you complete a deep work or focus hours block, a "loot chest" appears. It opens with an animation to reveal your rewards: XP earned, badges unlocked, and a random cosmetic item (timer pill theme, aura color, HUD skin). The chest has rarity levels: bronze (any completion), silver (80%+ focus), gold (95%+ focus, no interventions). This adds a moment of anticipation and delight at the end of each work block.

**Technical implementation:** Create a `LootBoxController` triggered by `FocusMonitor.blockDidEnd()`. Determine rarity from block stats: `focusPercent >= 95 && interventionCount == 0 → gold`, `>= 80 → silver`, else `bronze`. Each rarity has a weighted reward table: bronze = `[{ xp: 10-20, 80% }, { theme: random, 20% }]`, silver = `[{ xp: 30-50, 60% }, { theme: random, 30% }, { badge: random, 10% }]`, gold = `[{ xp: 80-120, 50% }, { theme: rare, 30% }, { badge: rare, 20% }]`. The UI is a SwiftUI overlay window: dark background with a 3D-styled chest that "opens" via scale and rotation animations. Contents fly out one by one with 0.5s delays. Cosmetic items (themes, aura colors) persist in `customization.json` and are applied in the relevant controllers. Auto-dismiss after 6 seconds or on click.

---

## 19. Focus Zones — Progressive Screen Border Colors

A more sophisticated version of the aura: the entire feel of your screen environment shifts based on your focus state. **Flow Zone** (15+ min unbroken focus): borders glow calm blue, breathing slowly. **Danger Zone** (active distraction): borders pulse orange-red, breathing fast. **Neutral Zone** (just started or returned): no border. **Legendary Zone** (30+ min unbroken + 20x combo): borders shimmer gold with subtle sparkle particles. The zones create a visceral, ambient awareness of your state without needing to read any numbers.

**Technical implementation:** Reuse the `FocusAuraController` architecture (borderless, click-through window). Define zone states as an enum: `.neutral, .flow(duration), .danger(intensity), .legendary`. `FocusMonitor` determines the zone on each poll based on consecutive focused polls (flow), distraction state (danger), or combo + duration thresholds (legendary). Each zone maps to a color palette + animation parameters: `.flow` = blue, 4s breathing cycle; `.danger` = orange→red, 1.5s pulse; `.legendary` = gold + `CAEmitterLayer` with small gold dot particles (birthRate: 5, velocity: 15, lifetime: 3, size: 2). Transition between zones with a 1.5s `CABasicAnimation` on colors. The `.neutral` zone sets opacity to 0 (invisible). Border width: 3px for flow, 5px for danger, 4px for legendary. The shimmer effect on legendary uses a moving `CAGradientLayer` with `.locations` animated in a loop.

---

## 20. Battle Report — End-of-Day Summary

At the end of your last scheduled block (or when you close the app), show a dramatic "Battle Report" screen — like the post-game stats screen in Call of Duty or League of Legends. Stats include: Focus Score (avg), Total XP Earned, Longest Combo, Distractions Defeated, Browse Minutes Earned, Blocks Completed, and a letter grade (S/A/B/C/D/F). The report has cinematic styling: stats reveal one by one with sound effects and dramatic pauses. An overall verdict: "LEGENDARY DAY" / "SOLID PERFORMANCE" / "ROOM FOR IMPROVEMENT."

**Technical implementation:** Create a `BattleReportController` that presents a large centered `NSWindow` (600x500) with a SwiftUI view. Data is aggregated from `FocusMonitor.blockAssessments`, `FocusXPManager`, `EarnedBrowseManager`, and `ComboTracker` at end-of-day. The SwiftUI view uses a `TimelineView(.animation)` to reveal stats sequentially — each stat appears with a `.transition(.scale.combined(with: .opacity))` at 0.8s intervals. The letter grade uses a large, bold font with a color gradient (S = gold, A = green, B = blue, C = yellow, D = orange, F = red). The verdict text types out letter by letter (typewriter effect via a timer toggling character count). A "Share" button generates a screenshot of the report (via `NSBitmapImageRep` from the window's backing store) for sharing. Persist daily reports in `battle_reports.json` for the dashboard history view.

---

## 21. Skill Tree — Unlock Focus Abilities

A visual skill tree (like in an RPG) where you spend accumulated XP to unlock focus abilities. Branches: **Endurance** (longer focus streaks earn more), **Resilience** (faster distraction recovery), **Awareness** (earlier/gentler nudges), **Rewards** (better loot, more power-ups). Each branch has 5 tiers. Unlocking a skill feels like a meaningful choice and permanent progression.

**Technical implementation:** Create a `SkillTreeManager` with a static tree definition: `[{ branch: "endurance", skills: [{ id, name, cost, effect, prerequisite? }] }]`. Effects modify constants in other managers: e.g., "Deep Breathing" (Resilience Tier 1) reduces `distractionDecayRatio` from 0.5 to 0.6 (faster recovery), "Loot Luck" (Rewards Tier 2) increases power-up drop rate by 50%. Persist unlocked skills in `skill_tree.json`. The skill tree UI is rendered in `dashboard.html` as an SVG diagram with nodes connected by lines — locked nodes are grayed, unlocked are colored, purchasable (have XP + prerequisites met) pulse. Clicking a purchasable node shows a confirmation modal with cost + effect description. On unlock, deduct XP via `FocusXPManager` and apply the effect by updating the relevant manager's constants. Effects are loaded at app startup from the persisted skill data. Sync to backend via settings JSONB blob.

---

## 22. Screen Shake on Distraction Detection

When the system detects you've switched to an irrelevant app, the floating timer pill (and optionally the entire screen frame) does a brief, aggressive shake — like a camera shake in a game when you take a hit. It's 0.3 seconds, subtle but visceral. It creates an immediate physical "oops" reaction that reinforces the feedback loop faster than any visual warning.

**Technical implementation:** Add a `shake()` method to `DeepWorkTimerController`. Implementation: get the window's current frame origin, then animate through 6 offset positions over 0.3s using `NSAnimationContext.runAnimationGroup`: [(+4,0), (-4,+2), (+3,-2), (-3,+1), (+2,-1), (0,0)] with each step taking 0.05s. Call from `FocusMonitor` on the first distraction detection of each distraction "burst" (don't shake continuously — only on the transition from relevant→irrelevant). Add a `lastShakeTime` guard with a 10-second cooldown to prevent shake fatigue. For full-screen shake (optional, settings toggle), apply the same offset animation to every visible `NSWindow` via `NSApp.windows.forEach { $0.setFrameOrigin(...) }` — but this is aggressive, so it should be opt-in. The mild version (timer pill only) is the default.

---

## 23. Mini-Map Timeline

A tiny horizontal timeline bar at the bottom of the floating timer showing your entire day's schedule as colored segments. The current time position is marked with a glowing dot that moves in real-time. Completed blocks are solid colored (green/yellow/red by focus quality), the current block is animated (striped or pulsing), and future blocks are outlined. It's like a video game mini-map — constant spatial awareness of where you are in your "quest."

**Technical implementation:** Add a `MiniMapView` to the floating timer SwiftUI view (or as a separate attached element below it). Width: match the timer pill (~200px), height: 12px. Data: `ScheduleManager.todayBlocks` provides `[{ title, startTime, endTime, blockType }]`. Each block becomes a proportional-width segment in an `HStack(spacing: 1)`. Current time indicator: a 2px-wide white rectangle overlaid at position `(currentTime - dayStart) / (dayEnd - dayStart) * totalWidth`. Focus quality colors come from `FocusMonitor.blockAssessments`. Current block segment uses `.opacity()` animation (0.6 ↔ 1.0, 1s cycle). The mini-map is always visible during any active block. Tap/click does nothing (pure display). Block type icons (tiny, 6px) can optionally appear inside segments for blocks longer than 30 minutes.

---

## 24. Respawn Mechanic After Intervention

When an intervention overlay triggers (the "you died" moment), instead of just closing it, frame it as a respawn. A 60-second "respawn timer" counts down with dramatic visuals — dark screen, countdown in the center, motivational text ("Refocusing in 60..."). When it hits 0, you "respawn" with a brief invulnerability period (30 seconds where distractions don't count against your score). This reframes failure as temporary and gives you a clean slate to restart.

**Technical implementation:** Modify the existing intervention overlay in `FocusMonitor` to include a "respawn" phase. After the user clicks "Return to Work" on the intervention, instead of immediately resuming normal tracking, set a `respawnInvulnerabilityUntil = Date().addingTimeInterval(30)` property. During invulnerability, `FocusMonitor` polls continue but distraction seconds are not incremented (the check: `if Date() < respawnInvulnerabilityUntil { return /* skip distraction counting */ }`). The floating timer shows a shield icon during invulnerability with a 30s countdown. The respawn countdown itself replaces the current intervention overlay's "continue" flow — after the user acknowledges, show a centered `Text("\(countdown)")` in large bold font, counting from 60 to 0 (or the escalated intervention duration), with a dark `NSVisualEffectView` background.

---

## 25. Focus Pet / Companion

A small animated creature (pixel art style, 32x32) that lives in the corner of your screen near the floating timer. When you're focused, it's happy (bouncing, sparkles). When you're distracted, it looks sad (drooping, gray). When your combo is high, it does a little dance. When you "die" (intervention), it faints. Over time, the pet evolves based on your focus consistency — egg → baby → teen → adult → legendary form. Each evolution is a milestone moment.

**Technical implementation:** Create a `FocusPetController` with a borderless `NSWindow` (48x48) near the floating timer. The pet is rendered as an animated `NSImageView` cycling through sprite frames. Sprite sheets for each evolution stage + emotion state (happy, sad, dancing, fainted) — stored as `.png` assets in the app bundle. Animation: 4-frame loop at 3 FPS for idle, 6-frame loop at 8 FPS for dancing. State driven by `FocusMonitor` callbacks: `.happy` when focus score > 70, `.sad` when < 40, `.dancing` when combo > 10, `.fainted` during intervention. Evolution tracked by `FocusPetManager` persisted to `focus_pet.json`: `{ stage: 0-4, happiness: 0-100, birthDate }`. Evolution triggers at happiness thresholds (maintained by daily focus meeting goals). Each stage has unique sprite sheets. The pet window follows the timer pill's position with a fixed offset. Optional: name your pet in settings.

---

## 26. Distraction Bounty Board

A list of your most common distractions ranked by how much focus time they've stolen. "Twitter: 47 min this week (WANTED)" / "YouTube: 23 min (BOUNTY: 50 XP)." Each distraction has a bounty — if you go a full day without visiting that platform during work blocks, you collect the bounty XP. It turns your worst habits into specific targets to beat.

**Technical implementation:** Create a `BountyBoardManager` that aggregates distraction data from `FocusMonitor.relevanceLog`. Group by hostname/app name, sum distraction seconds per week. Generate bounties: top 3 distractors get bounties scaled by their impact (`bountyXP = min(100, distractionMinutes * 2)`). Check at end-of-day: if a bountied platform had 0 distraction time during work blocks today, grant the XP. Persist in `bounty_board.json`: `{ week, bounties: [{ target, distractionMinutes, bountyXP, collected: bool }] }`. Refresh weekly (Monday). Display in the dashboard as a "WANTED" poster grid — each card has the platform favicon, name, distraction time, bounty amount, and a "COLLECTED" stamp overlay when earned. Also show as a compact list in the HUD (toggleable). Notification toast when a bounty is collected at end-of-day.

---

## 27. Time Dilation Visual Effect

When you enter deep flow state (20+ minutes unbroken focus, combo > 15), the floating timer's countdown text starts "glowing" and pulsing slowly — and the seconds tick visually slower (even though real time is unchanged). The background of the timer pill gets a subtle space/nebula gradient. This creates the perceptual feeling of "time expanding" that real flow states produce, reinforcing the sensation through visual design.

**Technical implementation:** In `DeepWorkTimerView`, detect flow state from the view model (`isInFlow: Bool`, set when consecutive focused polls > 120 and combo > 15). When in flow: apply `.shadow(color: .blue, radius: 8)` to the countdown text with a pulsing opacity animation, change the pill background from the static dark color to an animated `LinearGradient` with deep purple/blue space colors that slowly shift (animate gradient `.startPoint` and `.endPoint` positions over 10s). The "slower seconds" effect: instead of updating `timeDisplay` every 1.0s, update every 1.0s but animate the text change with a 0.8s ease-in-out transition (`.animation(.easeInOut(duration: 0.8))` on the `Text`), creating a smooth, dreamlike number transition instead of a sharp tick. Add subtle star particles behind the text using a `Canvas` view drawing 5-10 small white dots that drift slowly (1px/s).

---

## 28. Prestige System — Weekly Reset with Rewards

At the end of each week (Sunday night), you can "prestige" — reset your level back to 1 in exchange for a permanent prestige badge and a small permanent bonus (e.g., +5% base XP earning rate per prestige). Your prestige level (shown as a star count: 1 star, 2 stars, etc.) indicates your long-term commitment. This solves the "I'm already level 50, leveling is meaningless" problem by creating a repeating cycle of progression.

**Technical implementation:** Add prestige tracking to `FocusXPManager`: `{ prestigeLevel: Int, permanentXPMultiplier: Double, prestigeHistory: [{ level, date, bonusChosen }] }`. At end-of-week (Sunday 11:59 PM), if the user is level 5+, show a prestige prompt: "Prestige? Reset to Level 1, gain Star \(n+1) and +5% XP forever." If accepted: reset `totalXP` to 0 and `level` to 1, increment `prestigeLevel`, add 0.05 to `permanentXPMultiplier`. The multiplier applies in `addXP()`: `effectiveXP = baseXP * permanentXPMultiplier`. In the HUD, show prestige stars as small gold star SF Symbols next to the level number. In the dashboard, show a "Prestige History" section with a timeline of prestige events. The prestige prompt is a centered `NSWindow` with dramatic gold styling and a "PRESTIGE" button with a glow animation.

---

## 29. Environmental Storytelling — Dynamic Desktop Wallpaper

Your desktop wallpaper subtly changes based on your focus performance throughout the day. Morning start: sunrise landscape. Good focus: the scene becomes vibrant and lush (green trees, clear sky). Poor focus: the scene becomes stormy and desolate (dark clouds, dead trees). End of a great day: golden sunset with "congratulations" subtlety. This creates an ambient, ever-present reminder without any overlay UI.

**Technical implementation:** Create a `DynamicWallpaperManager` with 5-10 pre-rendered wallpaper variants stored in the app bundle (or `~/Library/Application Support/Intentional/wallpapers/`). Variants: sunrise, morning-clear, morning-stormy, midday-vibrant, midday-desolate, afternoon-clear, afternoon-stormy, sunset-golden, sunset-gray. Selection logic: time-of-day determines the base image, focus score determines the variant (clear vs stormy). Change wallpaper using `NSWorkspace.shared.setDesktopImageURL()` for each screen. Update every 30 minutes (not on every poll — wallpaper changes are expensive and noticeable). Smooth transition: macOS doesn't support animated wallpaper transitions natively, so change only when the user is in-app (not visible). Store the user's original wallpaper path on first activation to restore on app quit or feature disable. Settings toggle: "Dynamic Focus Wallpaper" (off by default — this is invasive, opt-in only).

---

## 30. Social Leaderboard with Accountability Partner

If you have an accountability partner, show a weekly leaderboard comparing your focus stats. "You: 14h focused, Partner: 11h focused — YOU'RE WINNING." The partner's stats come from the backend (they'd need to use the app too). Even without a real partner comparison, show a leaderboard against "Global Average" (anonymized aggregate data from all users). Competition drives performance, and pairing it with accountability adds social stakes.

**Technical implementation:** Add a new backend endpoint `GET /leaderboard/partner` that returns both users' weekly stats (total focused minutes, focus score avg, streak length) if both have accounts linked. The macOS app queries this in `BackendClient.getPartnerLeaderboard()`. Display in the dashboard as a side-by-side comparison card with bars showing relative performance. For the "Global Average" fallback (when partner doesn't use the app), compute server-side aggregates in the `/usage/history` endpoint — add an optional `?include_average=true` param that returns anonymized averages alongside personal data. Privacy: only share aggregate stats (total minutes, not specific app usage). The HUD shows a compact "You: 1st" or "You: 2nd" indicator. Backend schema: no new tables — compute from existing `daily_usage` data. Rate limit the leaderboard query to once per hour. Opt-in only (settings toggle + partner must also opt in).

---

## Priority Implementation Order

If implementing incrementally, this ordering maximizes impact per effort:

| Priority | Ideas | Why |
|----------|-------|-----|
| **P0 — Ship first** | #1 (Damage Vignette), #3 (Focus Score), #14 (Poison Grayscale) | Core feel. Transforms existing enforcement into game mechanics. Low effort, high impact. |
| **P1 — Core loop** | #4 (Combo), #5 (XP/Leveling), #6 (Health Bar), #2 (HUD) | Creates the progression loop that makes it addictive. |
| **P2 — Delight** | #12 (Streaks), #8 (Achievements), #10 (Kill Feed), #22 (Screen Shake) | Moment-to-moment rewards and feedback. |
| **P3 — Depth** | #7 (Boss Battles), #11 (Daily Quests), #13 (Power-Ups), #20 (Battle Report) | Adds variety and long-term engagement. |
| **P4 — Polish** | #9 (Aura), #16 (Sound), #23 (Mini-Map), #17 (Ghost Rival) | Refinement and ambient feel. |
| **P5 — Ambitious** | #21 (Skill Tree), #25 (Focus Pet), #18 (Loot Boxes), #29 (Wallpaper) | Big features for dedicated users. |
