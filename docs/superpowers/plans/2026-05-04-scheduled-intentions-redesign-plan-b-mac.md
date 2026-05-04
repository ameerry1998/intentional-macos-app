# Scheduled Intentions Redesign — Mac Implementation Plan (Plan B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use `- [ ]` checkbox syntax. Build after every step; commit after every task.

**Goal:** On Mac, replace the block editor's Blocking Profiles chips with an Intention picker, add a per-Intention strictness preset (Strict / Standard / Soft) with direction-locked friction, restructure the sidebar (Today / Intentions / Schedule / Distractions / Sensitive Content / Weekly Planning / Accountability / Settings), render bedtime + wake as solid bands on the calendar, and migrate all existing block→profile bindings to block→intention bindings idempotently. Calendar gestures (drag-to-create / edge-resize / move) are explicitly DEFERRED to v1.5 per D13.

**Architecture:** Spec 1's `IntentionStore` actor gains a `strictnessPreset` field. The block editor reads/writes `intentionId` directly via the existing Spec 2 bridge (`UPDATE_BLOCK` already accepts `intention_id` from Plan B Task 8 of Spec 2). Strictness lives only on Intentions, edited from the new "Intentions" sidebar tab — never in the block editor. New bridge messages `UPDATE_INTENTION_STRICTNESS` / `CANCEL_PENDING_STRICTNESS_CHANGE` route via Plan A's new endpoints (`PUT /intentions/{id}/strictness`, etc.). The existing `BedtimeUnlockRequestView` is generalized so the Strict-step-down path can reuse the partner-code flow with an `intention_strictness_unlock` request type. The deprecated Profiles chips UI is hidden (data layer left intact per D14). One-shot migration `BlockingProfilesToIntentionsMigration` runs once per device, stamps a receipt, and binds each existing block's `profileIds` to a freshly created (or merged) Intention.

**Tech Stack:** Swift 5.9+, AppKit, SwiftUI for the strictness picker sheets, WKWebView dashboard, actor-based `IntentionStore`, URLSession.

**Worktree:** `/Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/scheduled-intentions-redesign` on branch `feat/scheduled-intentions-redesign`. Base: merge of `feat/intentions-spec1` + `feat/time-blocks-spec2` + the bug-fix commit `8bcf18b` (calendar tap-to-create draft pattern fix). The merge happens in Task 0.

**Backend dependency:** Sibling Plan A (in `intentional-backend`) defines new endpoints:
- `PUT /intentions/{id}/strictness` — body `{ to_preset: "strict"|"standard"|"soft", partner_unlock_code?: string }`
- `GET /intentions/{id}/pending_strictness_change` — returns the row from `intention_strictness_changes` if any pending exists for this intention
- `DELETE /intentions/{id}/pending_strictness_change` — cancel a pending softening
- `POST /intention_strictness_unlock_requests` — partner-unlock email flow (mirrors `bedtime_unlock_requests`)
- `POST /intention_strictness_unlock_requests/{id}/verify` — verify partner code
- The `intentions` DTO grows two fields: `strictness_preset: "strict"|"standard"|"soft"`, `pending_strictness_change?: { to_preset, takes_effect_at }` plus the D9 budget-prep fields `weekly_budget_hours: number|null`, `budget_enforcement: string|null`.

Plan A's branch must merge first OR this branch internally merges Plan A as Task 0.2. We assume Plan A merges first; if not, swap Task 0.2 to a `git merge feat/scheduled-intentions-redesign-backend` (the executor will know which by reading the cross-repo log).

**Spec reference:** `docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md`

**Cross-repo log:** `docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md` (created/appended by Task 22).

---

## File map

| File | Op | Purpose |
|---|---|---|
| `Intentional/Intention.swift` | MODIFY | Add `strictnessPreset: StrictnessPreset` enum + `pendingStrictnessChange: PendingChange?` + `weeklyBudgetHours: Double?` + `budgetEnforcement: String?` fields with backwards-compat decoder |
| `Intentional/BackendClient.swift` | MODIFY | Add `updateIntentionStrictness`, `getPendingStrictnessChange`, `cancelPendingStrictnessChange`, `requestIntentionStrictnessUnlock`, `verifyIntentionStrictnessUnlock` |
| `Intentional/IntentionStore.swift` | MODIFY | Add `updateStrictness(...)` + `cancelPendingStrictnessChange(...)`, propagate `pendingStrictnessChange` |
| `Intentional/MainWindow.swift` | MODIFY | New bridge handlers: `UPDATE_INTENTION_STRICTNESS`, `CANCEL_PENDING_STRICTNESS_CHANGE`, `OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET`. Update `emitIntentionsList` to include strictness + pending change + budget fields. Add `OPEN_INTENTION_EDITOR` deep-link bridge. |
| `Intentional/BedtimeUnlockRequestView.swift` | MODIFY | Generalize to take a `UnlockRequestKind` enum (`.bedtime` vs `.intentionStrictness(intentionId)`) so we don't duplicate the entire view |
| `Intentional/AppDelegate.swift` | MODIFY | Add `openIntentionStrictnessUnlockSheet(intentionId:)` mirror of bedtime sheet. Wire one-shot migration runner |
| `Intentional/BlockingProfilesToIntentionsMigration.swift` | CREATE | One-shot block→intention rebinding migration; idempotent receipt at `~/Library/Application Support/Intentional/migration_profiles_to_intentions_v1.json` |
| `Intentional/dashboard.html` | MODIFY | (1) Remove `editor-profiles-row` chips. (2) Remove "Block Type" segmented control. (3) Add Intention picker dropdown sourced from new `_intentionsList` payload. (4) Add active-days toggle pills (Mon–Sun) defaulting to `[1..5]`. (5) Add caption for bound Intention's strictness with click-to-deep-link. (6) Add inline "+ Create new Intention" mini-editor. (7) Restructure sidebar (Today / Intentions / Schedule / Distractions / Sensitive Content / Weekly Planning / Accountability / Settings) and rename Projects → Intentions. (8) Promote Sensitive Content card from Settings to its own page. (9) Add `page-weekly-planning` placeholder. (10) Add Intentions tab strictness 3-segment picker + 24h cool-down dialog + reuse Strict→softer partner-unlock bridge. (11) Render bedtime/wake bands as solid colors on the calendar (deep navy bottom + warm coral top, no gradients). (12) Reserve "Weekly target — coming soon" greyed row at bottom of Intention edit screen. (13) Reserve empty horizontal row in Schedule header above Day/Week toggle. |
| `CLAUDE.md` | MODIFY | New section under "Intentions (Spec 1)": "Strictness Presets + Calendar/Sidebar Redesign (May 2026)" |

Approximate change footprint: ~1,400 lines net added across Swift + JS + HTML, ~300 lines removed (Profiles chip code + Block Type segmented control + duplicated bedtime overlay handling).

---

## Task 0: Worktree + base merge

**Files:** none (git ops)

- [ ] **Step 0.1: Create worktree from `puck`**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git fetch
git worktree add -b feat/scheduled-intentions-redesign .claude/worktrees/scheduled-intentions-redesign puck
cd .claude/worktrees/scheduled-intentions-redesign
git status
git log --oneline -5
```

Expected: clean worktree, branch `feat/scheduled-intentions-redesign` checked out.

- [ ] **Step 0.2: Merge in Spec 1 + Spec 2 + the calendar tap-to-create fix**

`puck` is the integration branch and may already include Spec 1 + Spec 2. Verify before merging:

```bash
git log --oneline puck | grep -E "intentions-spec1|time-blocks-spec2|8bcf18b" | head -10
```

If Spec 1 + Spec 2 are already merged into `puck`, no merges needed — just confirm `8bcf18b` is in history. If Spec 2 is not yet merged, run:

```bash
git merge --no-ff feat/intentions-spec1 -m "merge: feat/intentions-spec1 into scheduled-intentions-redesign"
git merge --no-ff feat/time-blocks-spec2 -m "merge: feat/time-blocks-spec2 into scheduled-intentions-redesign"
git cherry-pick 8bcf18b   # if not already in either branch
```

Resolve any conflicts (likely zero — they were designed to compose).

- [ ] **Step 0.3: Empty initial commit for the redesign branch marker**

```bash
git commit --allow-empty -m "spec3(scheduled-intentions): start Mac client implementation

Per spec docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md
and plan docs/superpowers/plans/2026-05-04-scheduled-intentions-redesign-plan-b-mac.md."
```

- [ ] **Step 0.4: Build + verify base is healthy**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`. If it fails, fix the merge before continuing.

---

## Task 1: Extend `Intention` with strictness + pending change + budget fields

**Files:**
- Modify: `Intentional/Intention.swift`

- [ ] **Step 1.1: Add `StrictnessPreset` enum + `PendingStrictnessChange` struct**

At the top of `Intention.swift`, after the `import Foundation` line and before `struct Intention`, add:

```swift
enum StrictnessPreset: String, Codable, Equatable {
    case strict
    case standard
    case soft
}

struct PendingStrictnessChange: Codable, Equatable {
    let toPreset: StrictnessPreset
    let takesEffectAt: Date

    private enum CodingKeys: String, CodingKey {
        case toPreset = "to_preset"
        case takesEffectAt = "takes_effect_at"
    }
}
```

- [ ] **Step 1.2: Add the new fields to `Intention`**

Find the `Intention` struct. After `var deletedAt: Date?` add:

```swift
    /// Per-Intention strictness preset (D4). Defaults `.standard`.
    /// Direction-locked: tightening is instant; softening Standard→Soft has a 24h
    /// cool-down; softening from Strict requires partner unlock (D5).
    var strictnessPreset: StrictnessPreset

    /// If non-nil, a softening change is queued and will apply when `takesEffectAt`
    /// passes (server-side cron). Mac shows a "scheduled" banner until then.
    var pendingStrictnessChange: PendingStrictnessChange?

    /// D9 budget prep — backend column exists but no enforcement code yet.
    var weeklyBudgetHours: Double?
    var budgetEnforcement: String?
```

- [ ] **Step 1.3: Update CodingKeys + the keyed init**

Add four keys to `enum CodingKeys`:

```swift
        case strictnessPreset = "strictness_preset"
        case pendingStrictnessChange = "pending_strictness_change"
        case weeklyBudgetHours = "weekly_budget_hours"
        case budgetEnforcement = "budget_enforcement"
```

If `Intention` doesn't already use a custom `init(from decoder:)`, add one immediately after the synthesized init that tolerates missing keys:

```swift
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.macWebsites = try c.decodeIfPresent([String].self, forKey: .macWebsites) ?? []
        self.macBundleIds = try c.decodeIfPresent([String].self, forKey: .macBundleIds) ?? []
        self.iosAppTokensB64 = try c.decodeIfPresent(String.self, forKey: .iosAppTokensB64)
        self.iosCategoryTokensB64 = try c.decodeIfPresent(String.self, forKey: .iosCategoryTokensB64)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        // NEW (Spec 3): tolerate older payloads that lack these fields
        self.strictnessPreset = try c.decodeIfPresent(StrictnessPreset.self, forKey: .strictnessPreset) ?? .standard
        self.pendingStrictnessChange = try c.decodeIfPresent(PendingStrictnessChange.self, forKey: .pendingStrictnessChange)
        self.weeklyBudgetHours = try c.decodeIfPresent(Double.self, forKey: .weeklyBudgetHours)
        self.budgetEnforcement = try c.decodeIfPresent(String.self, forKey: .budgetEnforcement)
    }
```

- [ ] **Step 1.4: Update the memberwise init signature with defaults**

Find the existing `init(id: UUID, name: String, ...)` initializer and add four new defaulted parameters at the end:

```swift
    init(id: UUID, name: String, description: String? = nil,
         colorHex: String? = nil, icon: String? = nil,
         macWebsites: [String] = [], macBundleIds: [String] = [],
         iosAppTokensB64: String? = nil, iosCategoryTokensB64: String? = nil,
         version: Int = 1, createdAt: Date = Date(),
         updatedAt: Date = Date(), deletedAt: Date? = nil,
         strictnessPreset: StrictnessPreset = .standard,
         pendingStrictnessChange: PendingStrictnessChange? = nil,
         weeklyBudgetHours: Double? = nil,
         budgetEnforcement: String? = nil) {
        // ... existing assignments ...
        self.strictnessPreset = strictnessPreset
        self.pendingStrictnessChange = pendingStrictnessChange
        self.weeklyBudgetHours = weeklyBudgetHours
        self.budgetEnforcement = budgetEnforcement
    }
```

- [ ] **Step 1.5: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/Intention.swift
git commit -m "feat(scheduled-intentions): add strictnessPreset + pendingStrictnessChange + budget-prep fields to Intention"
```

---

## Task 2: BackendClient — strictness mutation + partner-unlock helpers

**Files:**
- Modify: `Intentional/BackendClient.swift`

- [ ] **Step 2.1: Append the new methods after the existing intentions section**

Locate the end of the `// MARK: - Intentions (Spec 1)` block. Insert before the next MARK or class-closing brace:

```swift
    // MARK: - Intention Strictness (Spec 3 — May 2026)

    enum StrictnessUpdateError: Error, LocalizedError {
        case requiresPartnerUnlock           // 423 from server
        case requires24hCooldown             // 425 from server
        case sessionInProgress               // 409 from server (D6)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .requiresPartnerUnlock: return "Stepping down from Strict requires partner unlock"
            case .requires24hCooldown:   return "Softening Standard→Soft is queued for 24h"
            case .sessionInProgress:     return "Cannot change strictness while a session of this Intention is running"
            case .network(let s):        return s
            }
        }
    }

    /// PUT /intentions/{id}/strictness
    /// - 200 (instant tightening or queued softening — server returns updated Intention with optional pending_strictness_change)
    /// - 409 if a session is in progress (D6)
    /// - 423 if going from Strict requires partner unlock (caller must use partner flow)
    /// - 425 if Standard→Soft and the 24h cool-down was implicitly accepted (we still surface to UI as info)
    func updateIntentionStrictness(
        id: UUID,
        toPreset: StrictnessPreset,
        partnerUnlockCode: String? = nil
    ) async throws -> Intention {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)/strictness") else {
            throw StrictnessUpdateError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        var body: [String: Any] = ["to_preset": toPreset.rawValue]
        if let code = partnerUnlockCode { body["partner_unlock_code"] = code }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch code {
        case 200: return try intentionsJSONDecoder().decode(Intention.self, from: data)
        case 409: throw StrictnessUpdateError.sessionInProgress
        case 423: throw StrictnessUpdateError.requiresPartnerUnlock
        case 425: throw StrictnessUpdateError.requires24hCooldown
        default:  throw StrictnessUpdateError.network("HTTP \(code)")
        }
    }

    /// GET /intentions/{id}/pending_strictness_change → returns nil if none pending.
    func getPendingStrictnessChange(id: UUID) async -> PendingStrictnessChange? {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)/pending_strictness_change") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try intentionsJSONDecoder().decode(PendingStrictnessChange.self, from: data)
        } catch {
            return nil
        }
    }

    /// DELETE /intentions/{id}/pending_strictness_change — cancel a queued softening.
    @discardableResult
    func cancelPendingStrictnessChange(id: UUID) async -> Bool {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)/pending_strictness_change") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? -1) == 204
        } catch { return false }
    }

    // MARK: - Intention Strictness Partner Unlock (mirrors bedtime_unlock)

    struct IntentionStrictnessUnlockRequestResult {
        let requestId: String
        let sentTo: String
    }

    func requestIntentionStrictnessUnlock(
        intentionId: UUID,
        toPreset: StrictnessPreset,
        reason: String,
        note: String?
    ) async throws -> IntentionStrictnessUnlockRequestResult {
        guard let url = URL(string: "\(baseURL)/intention_strictness_unlock_requests") else {
            throw StrictnessUpdateError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        var body: [String: Any] = [
            "intention_id": intentionId.uuidString,
            "to_preset": toPreset.rawValue,
            "reason": reason,
        ]
        if let note { body["note"] = note }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw StrictnessUpdateError.network("HTTP \(code)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rid = json["request_id"] as? String,
              let to = json["sent_to"] as? String else {
            throw StrictnessUpdateError.network("Malformed response")
        }
        return IntentionStrictnessUnlockRequestResult(requestId: rid, sentTo: to)
    }

    /// Verify the 6-digit code the partner emailed; on success the server flips strictness AND
    /// returns the updated Intention.
    func verifyIntentionStrictnessUnlock(
        requestId: String,
        code: String
    ) async throws -> Intention {
        guard let url = URL(string: "\(baseURL)/intention_strictness_unlock_requests/\(requestId)/verify") else {
            throw StrictnessUpdateError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, response) = try await URLSession.shared.data(for: req)
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpCode == 200 else { throw StrictnessUpdateError.network("HTTP \(httpCode)") }
        return try intentionsJSONDecoder().decode(Intention.self, from: data)
    }
```

- [ ] **Step 2.2: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/BackendClient.swift
git commit -m "feat(scheduled-intentions): BackendClient strictness PUT + partner-unlock + pending-change endpoints"
```

---

## Task 3: `IntentionStore` — strictness mutation + cancel pending

**Files:**
- Modify: `Intentional/IntentionStore.swift`

- [ ] **Step 3.1: Add `updateStrictness` to the actor**

After the existing `update(id:payload:)` method, add:

```swift
    /// Update strictness preset. The server applies tightening instantly and queues
    /// softening (with a 24h cool-down or partner unlock). Returns the updated
    /// Intention reflecting either the new preset or the queued pending change.
    @discardableResult
    func updateStrictness(
        id: UUID,
        toPreset: StrictnessPreset,
        partnerUnlockCode: String? = nil
    ) async throws -> Intention {
        guard let backend else { throw BackendClient.IntentionError.network("No backend") }
        let updated = try await backend.updateIntentionStrictness(
            id: id, toPreset: toPreset, partnerUnlockCode: partnerUnlockCode
        )
        byId[id] = updated
        persistToDisk()
        await notifyChanged()
        return updated
    }

    /// Cancel a queued softening (e.g. user changed their mind during the 24h window).
    @discardableResult
    func cancelPendingStrictnessChange(id: UUID) async -> Bool {
        guard let backend else { return false }
        let ok = await backend.cancelPendingStrictnessChange(id: id)
        if ok {
            // Mirror server: refetch and clear the local pending field
            if let fresh = await backend.getIntention(id: id) {
                byId[id] = fresh
                persistToDisk()
                await notifyChanged()
            }
        }
        return ok
    }
```

- [ ] **Step 3.2: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/IntentionStore.swift
git commit -m "feat(scheduled-intentions): IntentionStore.updateStrictness + cancelPendingStrictnessChange"
```

---

## Task 4: Generalize `BedtimeUnlockRequestView` for both bedtime + intention strictness

**Files:**
- Modify: `Intentional/BedtimeUnlockRequestView.swift`

The existing view does the entire partner-unlock dance for bedtime. For Strict→softer we need the same flow but pointed at the new endpoint. Don't duplicate; add a `kind` enum.

- [ ] **Step 4.1: Add the kind enum + plumb through**

At the top of the file, before `struct BedtimeUnlockRequestView`, add:

```swift
enum UnlockRequestKind: Equatable {
    case bedtime
    case intentionStrictness(intentionId: UUID, toPreset: StrictnessPreset, intentionName: String)

    var titleText: String {
        switch self {
        case .bedtime: return "Ask your partner to unlock early"
        case .intentionStrictness(_, let to, let name):
            return "Ask your partner to soften \(name) → \(to.rawValue.capitalized)"
        }
    }

    var captionText: String {
        switch self {
        case .bedtime: return "They'll get an email with a 6-digit code."
        case .intentionStrictness:
            return "They'll get an email with a 6-digit code. Once entered, the change applies immediately."
        }
    }
}
```

- [ ] **Step 4.2: Add a `kind` property + initializer override**

In `struct BedtimeUnlockRequestView`, add at the top:

```swift
    let kind: UnlockRequestKind

    init(kind: UnlockRequestKind = .bedtime) {
        self.kind = kind
    }
```

(Existing call sites use `BedtimeUnlockRequestView()` — the default keeps them working.)

- [ ] **Step 4.3: Use `kind.titleText` / `kind.captionText` in the view body**

Find the existing `Text("Ask your partner to unlock early")` and replace:

```swift
                Text(kind.titleText)
                    .font(.title3.weight(.semibold))
                Text(kind.captionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
```

- [ ] **Step 4.4: Branch the request submission on `kind`**

Find the existing `sendRequest()` async method (or whichever name handles the POST). Wrap the body:

```swift
    private func sendRequest() async {
        sending = true; errorText = nil
        defer { sending = false }
        switch kind {
        case .bedtime:
            // existing bedtime path
            await sendBedtimeRequest()
        case .intentionStrictness(let intentionId, let toPreset, _):
            await sendIntentionStrictnessRequest(intentionId: intentionId, toPreset: toPreset)
        }
    }

    private func sendBedtimeRequest() async {
        // Move the existing bedtime POST body here unchanged.
    }

    private func sendIntentionStrictnessRequest(intentionId: UUID, toPreset: StrictnessPreset) async {
        guard let backend = (NSApp.delegate as? AppDelegate)?.backendClient else {
            errorText = "Not connected"
            return
        }
        do {
            let result = try await backend.requestIntentionStrictnessUnlock(
                intentionId: intentionId,
                toPreset: toPreset,
                reason: reason,
                note: note.isEmpty ? nil : note
            )
            sentToPartner = result.sentTo
        } catch BackendClient.StrictnessUpdateError.network(let msg) {
            errorText = msg
        } catch {
            errorText = error.localizedDescription
        }
    }
```

(For the intention-strictness path, the duration slider doesn't apply — leave it visually present but disabled when `kind` is non-bedtime. Optional: hide it via `if case .bedtime = kind { durationSelector }`.)

- [ ] **Step 4.5: Hide the duration selector when not bedtime**

Find where `durationSelector` is rendered. Wrap:

```swift
            if case .bedtime = kind {
                durationSelector
            }
```

- [ ] **Step 4.6: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -15
git add Intentional/BedtimeUnlockRequestView.swift
git commit -m "feat(scheduled-intentions): generalize BedtimeUnlockRequestView with UnlockRequestKind enum"
```

---

## Task 5: AppDelegate — `openIntentionStrictnessUnlockSheet`

**Files:**
- Modify: `Intentional/AppDelegate.swift`

- [ ] **Step 5.1: Add the sheet opener**

Find the existing `openBedtimeUnlockRequestSheet()` (around line 1520). Below it, add:

```swift
    /// Hosts BedtimeUnlockRequestView in `.intentionStrictness` mode.
    /// Singleton window so the user can't open multiple. Closes when the request
    /// is verified or cancelled.
    private var intentionStrictnessUnlockWindow: NSWindow?

    func openIntentionStrictnessUnlockSheet(
        intentionId: UUID,
        toPreset: StrictnessPreset,
        intentionName: String
    ) {
        if let existing = intentionStrictnessUnlockWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let kind: UnlockRequestKind = .intentionStrictness(
            intentionId: intentionId, toPreset: toPreset, intentionName: intentionName
        )
        let host = NSHostingController(rootView: BedtimeUnlockRequestView(kind: kind))
        let win = NSWindow(contentViewController: host)
        win.title = "Soften \(intentionName)"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 460, height: 520))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        intentionStrictnessUnlockWindow = win
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            self?.intentionStrictnessUnlockWindow = nil
        }
    }
```

- [ ] **Step 5.2: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/AppDelegate.swift
git commit -m "feat(scheduled-intentions): AppDelegate.openIntentionStrictnessUnlockSheet wraps BedtimeUnlockRequestView"
```

---

## Task 6: MainWindow bridge handlers — strictness control + deep-link open

**Files:**
- Modify: `Intentional/MainWindow.swift`

- [ ] **Step 6.1: Add the new switch cases**

In `userContentController(_:didReceive:)`, find the Spec 1 intentions block. Below `case "START_INTENTION_SESSION":`, add:

```swift
        case "UPDATE_INTENTION_STRICTNESS":
            if let body = message.body as? [String: Any] {
                handleUpdateIntentionStrictness(body)
            }

        case "CANCEL_PENDING_STRICTNESS_CHANGE":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleCancelPendingStrictnessChange(id: id)
            }

        case "OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String, let id = UUID(uuidString: idStr),
               let toStr = body["to_preset"] as? String,
               let to = StrictnessPreset(rawValue: toStr),
               let name = body["intention_name"] as? String {
                appDelegate?.openIntentionStrictnessUnlockSheet(
                    intentionId: id, toPreset: to, intentionName: name
                )
            }

        case "OPEN_INTENTION_EDITOR":
            // Deep-link from the block editor's "Coding · Standard" caption tap →
            // navigate the dashboard to the Intentions tab and open this intention.
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String {
                callJS("window._navigateToIntentionEditor && window._navigateToIntentionEditor('\(idStr)')")
            }
```

- [ ] **Step 6.2: Add the handlers**

At the bottom of `MainWindow` near the existing intention handlers, add:

```swift
    // MARK: - Intentions (Spec 3 — strictness control)

    private func handleUpdateIntentionStrictness(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else {
            emitIntentionMutationResult(["status": "error", "error": "Missing id"])
            return
        }
        guard let toStr = body["to_preset"] as? String,
              let to = StrictnessPreset(rawValue: toStr) else {
            emitIntentionMutationResult(["status": "error", "error": "Missing to_preset"])
            return
        }
        let partnerCode = body["partner_unlock_code"] as? String
        Task {
            do {
                let updated = try await IntentionStore.shared.updateStrictness(
                    id: id, toPreset: to, partnerUnlockCode: partnerCode
                )
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "updated",
                        "id": updated.id.uuidString,
                        "strictness_preset": updated.strictnessPreset.rawValue,
                        "pending": updated.pendingStrictnessChange.map { pc -> [String: Any] in
                            [
                                "to_preset": pc.toPreset.rawValue,
                                "takes_effect_at": ISO8601DateFormatter().string(from: pc.takesEffectAt)
                            ]
                        } as Any? ?? NSNull()
                    ])
                }
            } catch BackendClient.StrictnessUpdateError.requiresPartnerUnlock {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "requires_partner_unlock",
                        "id": id.uuidString,
                        "to_preset": to.rawValue
                    ])
                }
            } catch BackendClient.StrictnessUpdateError.sessionInProgress {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "session_in_progress",
                        "id": id.uuidString
                    ])
                }
            } catch BackendClient.StrictnessUpdateError.requires24hCooldown {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "queued_24h",
                        "id": id.uuidString,
                        "to_preset": to.rawValue
                    ])
                }
            } catch {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "error", "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    private func handleCancelPendingStrictnessChange(id: UUID) {
        Task {
            let ok = await IntentionStore.shared.cancelPendingStrictnessChange(id: id)
            await MainActor.run {
                self.emitIntentionMutationResult([
                    "status": ok ? "pending_cancelled" : "error",
                    "id": id.uuidString
                ])
            }
        }
    }
```

- [ ] **Step 6.3: Update `emitIntentionsList` to include strictness + pending + budget**

Find the existing `handleGetIntentions()` method and update the dictionary it builds:

```swift
            let items = intentions.map { i -> [String: Any] in
                var dict: [String: Any] = [
                    "id": i.id.uuidString,
                    "name": i.name,
                    "description": i.description ?? "",
                    "color_hex": i.colorHex ?? "",
                    "icon": i.icon ?? "",
                    "mac_websites": i.macWebsites,
                    "mac_bundle_ids": i.macBundleIds,
                    "version": i.version,
                    "created_at": ISO8601DateFormatter().string(from: i.createdAt),
                    "updated_at": ISO8601DateFormatter().string(from: i.updatedAt),
                    // NEW (Spec 3):
                    "strictness_preset": i.strictnessPreset.rawValue,
                    "weekly_budget_hours": i.weeklyBudgetHours as Any? ?? NSNull(),
                    "budget_enforcement": i.budgetEnforcement as Any? ?? NSNull(),
                ]
                if let pc = i.pendingStrictnessChange {
                    dict["pending_strictness_change"] = [
                        "to_preset": pc.toPreset.rawValue,
                        "takes_effect_at": ISO8601DateFormatter().string(from: pc.takesEffectAt)
                    ]
                }
                return dict
            }
```

Apply the same enrichment to `handleGetIntention(id:)`.

- [ ] **Step 6.4: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -15
git add Intentional/MainWindow.swift
git commit -m "feat(scheduled-intentions): MainWindow strictness handlers + emit strictness/budget in intentions list"
```

---

## Task 7: One-shot migration — `BlockingProfile` → Intention bindings on existing blocks

**Files:**
- Create: `Intentional/BlockingProfilesToIntentionsMigration.swift`
- Modify: `Intentional/AppDelegate.swift`

This is *separate* from Spec 1's `IntentionMigration` (which migrated `projects.json`). This one rebinds **time blocks** that still have `profileIds: [UUID]` so they get an `intentionId` instead. The Spec 2 backend already accepts `intention_id`; we just need to hydrate it.

- [ ] **Step 7.1: Create the migration file**

```swift
// BlockingProfilesToIntentionsMigration.swift
//
// One-shot migration: for each existing FocusBlock that still references
// BlockingProfile UUIDs (via the legacy local `profileIds` field surfaced by
// the dashboard's _editorSelectedProfiles), look up the named profile, find or
// create an Intention with the same name + merged blocklist, set the block's
// intentionId to that Intention.
//
// Idempotent: writes a receipt at
//   ~/Library/Application Support/Intentional/migration_profiles_to_intentions_v1.json
// If the receipt is present, the migration is a no-op.
//
// After migration, the Profiles chips UI is hidden in dashboard.html. Per D14,
// BlockingProfileManager and its data file are LEFT INTACT (cleanup is a
// future PR — this preserves rollback safety for one release).
//
// Resumable: partial-receipt writes the set of already-processed block IDs
// after every success, so a network failure on block N restarts at N+1 next
// launch instead of re-creating duplicate Intentions for blocks 1..N-1.

import Foundation

@MainActor
final class BlockingProfilesToIntentionsMigration {
    private let scheduleManager: ScheduleManager
    private let blockingProfileManager: BlockingProfileManager
    private let intentionStore: IntentionStore
    private let backend: BackendClient
    private let receiptURL: URL

    init(scheduleManager: ScheduleManager,
         blockingProfileManager: BlockingProfileManager,
         intentionStore: IntentionStore,
         backend: BackendClient,
         settingsDir: URL) {
        self.scheduleManager = scheduleManager
        self.blockingProfileManager = blockingProfileManager
        self.intentionStore = intentionStore
        self.backend = backend
        self.receiptURL = settingsDir.appendingPathComponent("migration_profiles_to_intentions_v1.json")
    }

    var isCompleted: Bool {
        guard let data = try? Data(contentsOf: receiptURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let completed = json["completed_at"] as? String, !completed.isEmpty else {
            return false
        }
        return true
    }

    func run(log: @escaping (String) -> Void = { _ in }) async {
        guard !isCompleted else {
            log("🔁 BlockingProfilesToIntentions: receipt present, skipping")
            return
        }

        // Hydrate Intentions cache so name-based merge sees fresh data.
        await intentionStore.pull()

        // The schedule's blocks may have a sidecar `profileIds` populated by
        // the dashboard JSON file before the redesign. Read the on-disk schedule
        // to find them (ScheduleManager's in-memory model already drops the
        // field after Spec 2's BackendClient round-trip).
        let blocksWithProfiles = await loadLegacyProfileBindings()
        log("🔁 BlockingProfilesToIntentions: \(blocksWithProfiles.count) blocks with legacy profileIds to migrate")

        if blocksWithProfiles.isEmpty {
            await stampReceipt(processedIds: [])
            log("🔁 BlockingProfilesToIntentions: nothing to migrate, stamping receipt")
            return
        }

        let alreadyProcessed = loadPartialReceipt()
        let pending = blocksWithProfiles.filter { !alreadyProcessed.contains($0.blockId) }

        var processedIds = Array(alreadyProcessed)

        for binding in pending {
            // For each profileId on this block, find or merge into an Intention
            // with the same name. If the block had multiple profiles, we union
            // their blocklists into ONE Intention named after the profile that
            // was sorted alphabetically first.
            let profiles = binding.profileIds.compactMap { id -> BlockingProfile? in
                blockingProfileManager.profiles.first(where: { $0.id == id })
            }
            guard let primary = profiles.sorted(by: { $0.name < $1.name }).first else {
                log("🔁 BlockingProfilesToIntentions: skipping block \(binding.blockId) — no resolvable profiles")
                processedIds.append(binding.blockId)
                continue
            }

            let mergedDomains = profiles.flatMap { $0.blockedDomains }.sorted().reduce(into: [String]()) { acc, d in
                if acc.last != d { acc.append(d) }
            }
            let mergedApps = profiles.flatMap { $0.blockedAppBundleIds }.sorted().reduce(into: [String]()) { acc, b in
                if acc.last != b { acc.append(b) }
            }

            let intention: Intention
            if let existing = await intentionStore.active(named: primary.name) {
                // Set-union with existing
                let unionDomains = Set(existing.macWebsites).union(mergedDomains).sorted()
                let unionApps = Set(existing.macBundleIds).union(mergedApps).sorted()
                let payload = IntentionUpdatePayload(
                    name: existing.name,
                    description: existing.description,
                    colorHex: existing.colorHex,
                    icon: existing.icon,
                    macWebsites: unionDomains,
                    macBundleIds: unionApps,
                    iosAppTokensB64: existing.iosAppTokensB64,
                    iosCategoryTokensB64: existing.iosCategoryTokensB64,
                    version: existing.version
                )
                do {
                    intention = try await intentionStore.update(id: existing.id, payload: payload)
                } catch {
                    log("🔁 BlockingProfilesToIntentions: merge failed for '\(primary.name)' (\(error.localizedDescription))")
                    persistPartialReceipt(processedIds)
                    return
                }
            } else {
                let payload = IntentionCreatePayload(
                    name: primary.name,
                    description: nil,
                    colorHex: nil,
                    icon: nil,
                    macWebsites: mergedDomains,
                    macBundleIds: mergedApps,
                    iosAppTokensB64: nil,
                    iosCategoryTokensB64: nil
                )
                do {
                    intention = try await intentionStore.create(payload)
                } catch {
                    log("🔁 BlockingProfilesToIntentions: create failed for '\(primary.name)' (\(error.localizedDescription))")
                    persistPartialReceipt(processedIds)
                    return
                }
            }

            // Now bind the block to this Intention.
            await scheduleManager.setBlockIntention(blockId: binding.blockId, intentionId: intention.id)
            processedIds.append(binding.blockId)
        }

        await stampReceipt(processedIds: processedIds)
        log("🔁 BlockingProfilesToIntentions: complete (\(processedIds.count) blocks processed)")
    }

    // MARK: - Helpers

    private struct LegacyBinding {
        let blockId: String
        let profileIds: [UUID]
    }

    /// Read legacy schedule JSON (pre-Spec-2) which may still contain `profileIds`
    /// on each block. After Spec 2 the field is dropped at decode time, so we read
    /// the raw JSON instead of using the typed model.
    private func loadLegacyProfileBindings() async -> [LegacyBinding] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Intentional", isDirectory: true)
        let candidates = [
            dir.appendingPathComponent("daily_schedule.json"),
            dir.appendingPathComponent("daily_schedule.legacy.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = root["blocks"] as? [[String: Any]] else { continue }
            var out: [LegacyBinding] = []
            for b in blocks {
                guard let id = b["id"] as? String,
                      let pids = b["profileIds"] as? [String], !pids.isEmpty else { continue }
                let uuids = pids.compactMap { UUID(uuidString: $0) }
                if !uuids.isEmpty { out.append(LegacyBinding(blockId: id, profileIds: uuids)) }
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    private func stampReceipt(processedIds: [String]) async {
        let body: [String: Any] = [
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "version": 1,
            "block_ids_processed": processedIds,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])) ?? Data()
        try? data.write(to: receiptURL, options: .atomic)
    }

    private func loadPartialReceipt() -> Set<String> {
        guard let data = try? Data(contentsOf: receiptURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["partial_processed"] as? [String] else { return [] }
        return Set(arr)
    }

    private func persistPartialReceipt(_ processed: [String]) {
        let body: [String: Any] = [
            "partial_processed": processed,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])) ?? Data()
        try? data.write(to: receiptURL, options: .atomic)
    }
}
```

- [ ] **Step 7.2: Add `setBlockIntention` to ScheduleManager**

In `ScheduleManager.swift`, add a small mutation method (callers from migration + future picker):

```swift
    /// Set the bound Intention for a block by id. No-op if block not found.
    /// Persists locally and pushes to backend.
    @MainActor
    func setBlockIntention(blockId: String, intentionId: UUID?) async {
        guard var schedule = todaySchedule,
              let idx = schedule.blocks.firstIndex(where: { $0.id == blockId }) else { return }
        schedule.blocks[idx].intentionId = intentionId
        todaySchedule = schedule
        persistToDisk()
        await pushToBackend()
    }
```

- [ ] **Step 7.3: Wire migration in AppDelegate**

In `AppDelegate.applicationDidFinishLaunching` (or wherever the Spec 1 `IntentionMigration` is dispatched — search `IntentionMigration`), add a follow-on Task right after that migration completes:

```swift
        Task {
            // ... existing IntentionMigration.run() ...

            // Spec 3: rebind any block.profileIds → block.intentionId
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = support.appendingPathComponent("Intentional", isDirectory: true)
            guard let scheduleManager = self.scheduleManager,
                  let bpm = self.blockingProfileManager,
                  let store = self.intentionStore,
                  let backend = self.backendClient else { return }
            let mig = await BlockingProfilesToIntentionsMigration(
                scheduleManager: scheduleManager,
                blockingProfileManager: bpm,
                intentionStore: store,
                backend: backend,
                settingsDir: dir
            )
            await mig.run(log: { msg in
                Task { @MainActor in self.postLog(msg) }
            })
        }
```

- [ ] **Step 7.4: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -15
git add Intentional/BlockingProfilesToIntentionsMigration.swift Intentional/ScheduleManager.swift Intentional/AppDelegate.swift
git commit -m "feat(scheduled-intentions): one-shot migration block.profileIds → block.intentionId (idempotent + resumable)"
```

---

## Task 8: Dashboard — sidebar restructure (Today / Intentions / Schedule / Distractions / Sensitive Content / Weekly Planning / Accountability / Settings)

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 8.1: Replace the sidebar block (~line 4338)**

Find:
```html
  <div class="sidebar-item active" data-page="today" onclick="navigateTo('today')">
    <span class="sidebar-item-icon">◉</span> Today
  </div>
  <div class="sidebar-item" data-page="projects" onclick="navigateTo('projects')">
    <span class="sidebar-item-icon">◎</span> Projects
  </div>
  <div class="sidebar-item" data-page="distractions" onclick="navigateTo('distractions')">
    <span class="sidebar-item-icon">⊘</span> Distractions
  </div>
  <div class="sidebar-item" data-page="lock" onclick="navigateTo('lock')">
    <span class="sidebar-item-icon">◫</span> Accountability
  </div>
  <div class="sidebar-item" data-page="settings" onclick="navigateTo('settings')">
    <span class="sidebar-item-icon">⚙</span> Settings
  </div>
```

Replace with:
```html
  <div class="sidebar-item active" data-page="today" onclick="navigateTo('today')">
    <span class="sidebar-item-icon">◉</span> Today
  </div>
  <div class="sidebar-item" data-page="intentions" onclick="navigateTo('intentions')">
    <span class="sidebar-item-icon">◎</span> Intentions
  </div>
  <div class="sidebar-item" data-page="schedule" onclick="navigateTo('schedule')">
    <span class="sidebar-item-icon">▤</span> Schedule
  </div>
  <div class="sidebar-item" data-page="distractions" onclick="navigateTo('distractions')">
    <span class="sidebar-item-icon">⊘</span> Distractions
  </div>
  <div class="sidebar-item" data-page="sensitive" onclick="navigateTo('sensitive')">
    <span class="sidebar-item-icon">◔</span> Sensitive Content
  </div>
  <div class="sidebar-item" data-page="weekly" onclick="navigateTo('weekly')">
    <span class="sidebar-item-icon">◐</span> Weekly Planning
  </div>
  <div class="sidebar-item" data-page="lock" onclick="navigateTo('lock')">
    <span class="sidebar-item-icon">◫</span> Accountability
  </div>
  <div class="sidebar-item" data-page="settings" onclick="navigateTo('settings')">
    <span class="sidebar-item-icon">⚙</span> Settings
  </div>
```

- [ ] **Step 8.2: Update the `page-projects` div id to `page-intentions`**

Find `<div class="page" id="page-projects">` (around line 4552). Change to:

```html
  <div class="page" id="page-intentions">
```

Also update the page title inside `ProjectsController` render (search `>Projects<` ~line 10317) → `>Intentions<`.

- [ ] **Step 8.3: Add `navigateTo('intentions')` aliasing**

In `navigateTo(pageId)` (~line 5271), after the existing `if (pageId === 'projects')` block, add:

```javascript
  if (pageId === 'intentions') {
    ProjectsController.onEnter();   // same controller; UI label changed only
  }
```

- [ ] **Step 8.4: Build (HTML doesn't compile but just verify dashboard loads later)**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -5
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): sidebar restructure (Today/Intentions/Schedule/Distractions/Sensitive/Weekly/Accountability/Settings)"
```

---

## Task 9: Dashboard — "Schedule" page surfaces the calendar

**Files:**
- Modify: `Intentional/dashboard.html`

The calendar already lives inside `page-today`. We add a sibling `page-schedule` that hosts the same calendar. Two implementation options: (a) move the calendar entirely; (b) clone-and-re-host. Option (a) is cleaner — the calendar belongs on Schedule by D8 — but Today still needs the daily summary above it. Pragmatic resolution: move the calendar to `page-schedule`; replace the Today page calendar with a compact "Today's Schedule" preview + "Open Schedule →" button.

- [ ] **Step 9.1: Add the new `page-schedule` shell after `page-today`**

After the closing `</div>` of `page-today` (search for the next `<div class="page"`), insert:

```html
  <!-- Page: Schedule (D8) — full calendar lives here now -->
  <div class="page" id="page-schedule">
    <div class="page-header" style="display:flex;align-items:center;justify-content:space-between;padding:20px 28px 12px;">
      <div class="page-title">Schedule</div>
      <div style="display:flex;gap:8px;align-items:center;">
        <!-- Reserved horizontal row above Day/Week toggle (D9 prep — collapses to 0 when no budgets) -->
        <div id="schedule-budget-row" style="height:0;overflow:hidden;display:flex;gap:8px;align-items:center;"></div>
        <div class="segmented" id="schedule-view-toggle">
          <button class="segmented-btn selected" data-view="day" onclick="setScheduleView('day')">Day</button>
          <button class="segmented-btn" data-view="week" onclick="setScheduleView('week')">Week</button>
        </div>
      </div>
    </div>
    <div id="schedule-day-host" style="padding:0 28px 32px;"></div>
    <div id="schedule-week-host" style="display:none;padding:0 28px 32px;color:rgba(255,255,255,0.4);font-size:13px;">
      Week view — coming soon. Day view shows today's blocks.
    </div>
  </div>
```

- [ ] **Step 9.2: Mount the existing calendar into the Schedule page on entry**

In `navigateTo`, after the existing pages handlers, add:

```javascript
  if (pageId === 'schedule') {
    var host = document.getElementById('schedule-day-host');
    var cal = document.getElementById('calendar-container');
    if (host && cal && !host.contains(cal)) {
      host.appendChild(cal);    // physically move (single instance)
    }
    renderCalendar();
    sendMessage({ type: 'GET_SCHEDULE_STATE' });
  }
  if (pageId === 'today') {
    // Keep calendar visible on Today too — move it back if user navigates back.
    var todayHost = document.getElementById('today-calendar-host');
    var calT = document.getElementById('calendar-container');
    if (todayHost && calT && !todayHost.contains(calT)) {
      todayHost.appendChild(calT);
    }
  }
```

- [ ] **Step 9.3: Add `today-calendar-host` wrapper around the existing calendar in `page-today`**

Find the existing `<div class="calendar-container" id="calendar-container"></div>` (~line 4404) and wrap it:

```html
    <div id="today-calendar-host">
      <div class="calendar-container" id="calendar-container"></div>
    </div>
```

- [ ] **Step 9.4: Add `setScheduleView` no-op stub** (Day/Week toggle wires up later — Week view is deferred per spec optional)

```javascript
function setScheduleView(view) {
  document.querySelectorAll('#schedule-view-toggle .segmented-btn').forEach(function(b) {
    b.classList.toggle('selected', b.dataset.view === view);
  });
  document.getElementById('schedule-day-host').style.display = view === 'day' ? '' : 'none';
  document.getElementById('schedule-week-host').style.display = view === 'week' ? '' : 'none';
}
```

- [ ] **Step 9.5: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): Schedule sidebar page hosts the calendar (Day/Week toggle stub + budget-row reserve)"
```

---

## Task 10: Dashboard — `page-sensitive` (promote from Settings)

**Files:**
- Modify: `Intentional/dashboard.html`

The existing `content-safety-card` lives inside `page-settings`. Move (don't clone) the entire card into a new `page-sensitive`. Settings stops showing it.

- [ ] **Step 10.1: Add `page-sensitive` after `page-schedule`**

```html
  <!-- Page: Sensitive Content (D8 — promoted from Settings) -->
  <div class="page" id="page-sensitive">
    <div class="page-header" style="padding:20px 28px 12px;">
      <div class="page-title">Sensitive Content</div>
      <div style="color:rgba(255,255,255,0.5);font-size:13px;margin-top:6px;">
        On-device NSFW detection. When enabled, an overlay covers the screen and your accountability partner is notified.
      </div>
    </div>
    <div style="padding:0 28px 32px;" id="sensitive-content-host"></div>
  </div>
```

- [ ] **Step 10.2: Move the content-safety card on `navigateTo('sensitive')`**

```javascript
  if (pageId === 'sensitive') {
    var host = document.getElementById('sensitive-content-host');
    var card = document.getElementById('content-safety-card');
    if (host && card && !host.contains(card)) {
      host.appendChild(card);
    }
  }
```

(The card stays mounted in DOM whether on Settings or Sensitive page; the move just relocates it. It will no longer appear in Settings because it physically isn't there.)

- [ ] **Step 10.3: On launch, default the card to live in `page-sensitive`**

In the JS bootstrap (search `DOMContentLoaded` or wherever the dashboard initializes), add:

```javascript
  // Spec 3: relocate Sensitive Content card to its own page on first load
  var senseHost = document.getElementById('sensitive-content-host');
  var csCard = document.getElementById('content-safety-card');
  if (senseHost && csCard && !senseHost.contains(csCard)) {
    senseHost.appendChild(csCard);
  }
```

- [ ] **Step 10.4: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): page-sensitive promoted from Settings (single content-safety-card relocates on nav)"
```

---

## Task 11: Dashboard — `page-weekly` placeholder

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 11.1: Add `page-weekly`**

```html
  <!-- Page: Weekly Planning (D8 — placeholder for D9 budgets) -->
  <div class="page" id="page-weekly">
    <div class="page-header" style="padding:20px 28px 12px;">
      <div class="page-title">Weekly Planning</div>
    </div>
    <div style="padding:0 28px 64px;text-align:center;">
      <div style="margin:48px auto 24px;width:88px;height:88px;border-radius:50%;background:rgba(255,255,255,0.04);display:flex;align-items:center;justify-content:center;font-size:32px;color:rgba(255,255,255,0.3);">◐</div>
      <div style="color:rgba(255,255,255,0.85);font-size:18px;margin-bottom:8px;">Plan your week</div>
      <div style="color:rgba(255,255,255,0.5);font-size:14px;line-height:1.5;max-width:420px;margin:0 auto 24px;">
        Coming soon. Set weekly targets on individual Intentions to enable. We'll auto-schedule them around your existing blocks.
      </div>
      <button class="btn-small" onclick="navigateTo('intentions')">Go to Intentions →</button>
    </div>
  </div>
```

- [ ] **Step 11.2: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): page-weekly empty state with Go-to-Intentions CTA"
```

---

## Task 12: Dashboard — block editor: remove Profiles chips + Block Type segmented control

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 12.1: Excise the "Block Type" row + the `editor-profiles-row` chips**

In `openBlockEditor` (~line 9103), find these two `<div class="block-editor-row">` blocks and DELETE both:

```html
    '<div class="block-editor-row">' +
    '<label style="...">Block Type</label>' +
    '<div class="block-type-selector" id="editor-block-type">' +
    '<button ... data-type="focusHours" ...>Focus</button>' +
    '<button ... data-type="freeTime" ...>Free Time</button>' +
    '</div>' +
    '</div>' +
    '<div class="block-editor-row" id="editor-profiles-row" ...>' +
    '<label ...>Blocking Profiles</label>' +
    '<div id="editor-profile-chips" class="chip-list" ...></div>' +
    '</div>' +
```

- [ ] **Step 12.2: Remove the `selectBlockType` + `renderEditorProfileChips` JS functions**

Both are dead after the chips disappear. Delete from the file.

- [ ] **Step 12.3: Remove block-type save logic in `saveBlockEdit`**

Find this block in `saveBlockEdit` (~line 9332):
```javascript
  // Read block type from segmented control
  var selectedBtn = document.querySelector('#editor-block-type .block-type-btn.selected');
  if (selectedBtn && !selectedBtn.disabled) {
    block.blockType = selectedBtn.dataset.type;
    block.isFree = block.blockType === 'freeTime';
  }

  // Save selected blocking profile IDs
  if (window._editorSelectedProfiles) {
    block.profileIds = Array.from(window._editorSelectedProfiles);
  }
```

Delete both. Default `block.blockType` to `'focusHours'` for any code that still reads it. (Spec 2 dropped `.freeTime` from BlockType; the dashboard's residual `freeTime` strings can stay until the next cleanup pass — they no-op against the backend's `intensity` enum.)

- [ ] **Step 12.4: Hide the chip-population block in `openBlockEditor`**

The block that does `if (chipContainer && blockingProfiles.length > 0)` (~line 9152) is now dead. Delete it.

- [ ] **Step 12.5: Build (verify dashboard.html still parses by loading the app)**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -5
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): block editor — remove Profiles chips + Block Type segmented control (D1+D10)"
```

---

## Task 13: Dashboard — block editor: Intention picker dropdown + read-only strictness caption

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 13.1: Add a state slot for cached intentions list**

Near the top JS state (search `var focusState`), add:

```javascript
var intentionsCache = [];   // list of {id, name, color_hex, strictness_preset, ...}

window._intentionsList = function(items) {
  intentionsCache = Array.isArray(items) ? items : [];
  // If the block editor is open, refresh its dropdown
  if (focusState.editingBlockId) {
    var sel = document.getElementById('editor-intention-picker');
    if (sel) populateIntentionPicker(sel, getEditingBlock());
  }
  // If Intentions page is open, re-render
  if (typeof ProjectsController !== 'undefined' && ProjectsController.refresh) {
    ProjectsController.refresh();
  }
};

function getEditingBlock() {
  return focusState.blocks.find(function(b) { return b.id === focusState.editingBlockId; });
}
```

- [ ] **Step 13.2: Insert the picker into the block editor markup**

In `openBlockEditor`, where the deleted Profiles row used to be, insert:

```html
    '<div class="block-editor-row">' +
    '<label>Intention</label>' +
    '<select id="editor-intention-picker" class="block-editor-input" onchange="onEditorIntentionChange(this)"></select>' +
    '<div id="editor-intention-strictness-caption" style="margin-top:4px;font-size:11px;color:rgba(255,255,255,0.5);"></div>' +
    '</div>' +
    '<div class="block-editor-row">' +
    '<label>Active days</label>' +
    '<div id="editor-active-days" class="active-days-row" style="display:flex;gap:6px;"></div>' +
    '</div>' +
```

- [ ] **Step 13.3: Populate picker + caption + active-days at editor open**

After the editor is appended and chips were previously rendered, add:

```javascript
  // Populate Intention picker
  var sel = document.getElementById('editor-intention-picker');
  if (sel) populateIntentionPicker(sel, block);

  // Populate active-days pills (default [1..5] for new blocks)
  var daysContainer = document.getElementById('editor-active-days');
  if (daysContainer) {
    var current = block.activeDays || [1, 2, 3, 4, 5];
    block.activeDays = current.slice();
    var labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    daysContainer.innerHTML = '';
    labels.forEach(function(lbl, i) {
      var iso = i + 1;
      var pill = document.createElement('button');
      pill.className = 'day-pill' + (current.indexOf(iso) >= 0 ? ' selected' : '');
      pill.textContent = lbl;
      pill.style.cssText = 'flex:1;padding:6px 0;border-radius:6px;border:1px solid rgba(255,255,255,0.1);background:transparent;color:rgba(255,255,255,0.6);cursor:pointer;font-size:12px;' +
        (current.indexOf(iso) >= 0 ? 'background:rgba(var(--accent-primary-rgb),0.15);border-color:rgba(var(--accent-primary-rgb),0.4);color:var(--accent-primary);' : '');
      pill.addEventListener('click', function() {
        var idx = block.activeDays.indexOf(iso);
        if (idx >= 0) block.activeDays.splice(idx, 1);
        else { block.activeDays.push(iso); block.activeDays.sort(); }
        pill.classList.toggle('selected');
        // Re-style on toggle
        if (block.activeDays.indexOf(iso) >= 0) {
          pill.style.cssText = pill.style.cssText.replace(/background:transparent/g, 'background:rgba(var(--accent-primary-rgb),0.15)') ;
        }
        markFocusDirty();
      });
      daysContainer.appendChild(pill);
    });
  }
```

- [ ] **Step 13.4: Implement `populateIntentionPicker` + change handler**

```javascript
function populateIntentionPicker(sel, block) {
  if (!sel) return;
  sel.innerHTML = '';
  // Default option (no binding)
  var opt0 = document.createElement('option');
  opt0.value = '';
  opt0.textContent = '(none)';
  sel.appendChild(opt0);
  intentionsCache.forEach(function(i) {
    var opt = document.createElement('option');
    opt.value = i.id;
    opt.textContent = i.name;
    sel.appendChild(opt);
  });
  // "+ Create new Intention" sentinel
  var optNew = document.createElement('option');
  optNew.value = '__create_new__';
  optNew.textContent = '+ Create new Intention…';
  sel.appendChild(optNew);
  // Select current binding
  sel.value = block.intentionId || '';
  renderEditorStrictnessCaption(block.intentionId);
}

function onEditorIntentionChange(sel) {
  var block = getEditingBlock();
  if (!block) return;
  if (sel.value === '__create_new__') {
    sel.value = block.intentionId || '';
    openIntentionMiniEditor(function(newId) {
      if (newId) {
        block.intentionId = newId;
        sel.value = newId;
        renderEditorStrictnessCaption(newId);
        markFocusDirty();
      }
    });
    return;
  }
  block.intentionId = sel.value || null;
  renderEditorStrictnessCaption(block.intentionId);
  markFocusDirty();
}

function renderEditorStrictnessCaption(intentionId) {
  var el = document.getElementById('editor-intention-strictness-caption');
  if (!el) return;
  if (!intentionId) { el.textContent = ''; return; }
  var i = intentionsCache.find(function(x) { return x.id === intentionId; });
  if (!i) { el.textContent = ''; return; }
  var preset = (i.strictness_preset || 'standard');
  // Caption is a clickable deep-link to the Intention's edit screen.
  el.innerHTML = escapeHtml(i.name) + ' · <span style="text-decoration:underline;cursor:pointer;color:var(--accent-primary);" ' +
    'onclick="sendMessage({type:\'OPEN_INTENTION_EDITOR\',id:\'' + i.id + '\'})">' +
    preset.charAt(0).toUpperCase() + preset.slice(1) + '</span>';
}
```

- [ ] **Step 13.5: Persist `activeDays` in `saveBlockEdit`**

Already done because `block.activeDays` is mutated directly in the click handler. Just verify that the `UPDATE_BLOCK` payload (Spec 2's bridge) sends it. Find the place where `addFocusBlock`/`saveBlockEdit` dispatches its bridge message — append `active_days: block.activeDays || [1,2,3,4,5]` to the payload.

- [ ] **Step 13.6: Hook the dashboard up to receive intentions on page load**

In `DOMContentLoaded` (or wherever bootstrap runs):

```javascript
  sendMessage({ type: 'GET_INTENTIONS' });
```

(The Spec 1 handler already responds via `_intentionsList`, which we wired in Step 13.1.)

- [ ] **Step 13.7: Add CSS for `.day-pill.selected` + `.active-days-row`**

In the style block, append:

```css
.day-pill { transition: all 0.15s ease; }
.day-pill:hover { border-color: rgba(255,255,255,0.25); }
.day-pill.selected { color: var(--accent-primary); }
```

- [ ] **Step 13.8: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): block editor — Intention picker + active-days pills + read-only strictness caption + deep-link"
```

---

## Task 14: Dashboard — inline "+ Create new Intention" mini-editor

**Files:**
- Modify: `Intentional/dashboard.html`

The picker references `openIntentionMiniEditor` — implement it as a slide-in sheet that doesn't close the block editor.

- [ ] **Step 14.1: Add the mini-editor markup as a hidden overlay**

Append near the end of `<body>`:

```html
<div id="intention-mini-editor" style="display:none;position:fixed;top:0;right:0;bottom:0;width:380px;background:#1a1a1a;border-left:1px solid rgba(255,255,255,0.08);box-shadow:-8px 0 24px rgba(0,0,0,0.4);z-index:9999;padding:24px;transform:translateX(100%);transition:transform 0.25s ease;">
  <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:16px;">
    <div style="font-size:16px;font-weight:600;">New Intention</div>
    <button class="btn-small" onclick="closeIntentionMiniEditor(null)">×</button>
  </div>
  <div class="block-editor-row">
    <label>Name</label>
    <input class="block-editor-input" id="mini-intention-name" placeholder="e.g. Coding, Email, Writing">
  </div>
  <div class="block-editor-row">
    <label>Description (optional)</label>
    <textarea class="block-editor-input" id="mini-intention-desc" rows="2" placeholder="Specifics the AI uses to score relevance"></textarea>
  </div>
  <div class="block-editor-actions" style="margin-top:16px;">
    <button class="btn-small" onclick="submitIntentionMiniEditor()">Create</button>
    <button class="btn-small" onclick="closeIntentionMiniEditor(null)">Cancel</button>
  </div>
  <div id="mini-intention-error" style="color:#e55;font-size:12px;margin-top:8px;"></div>
</div>
```

- [ ] **Step 14.2: Open / close / submit JS**

```javascript
var _miniEditorCallback = null;

function openIntentionMiniEditor(cb) {
  _miniEditorCallback = cb;
  var sheet = document.getElementById('intention-mini-editor');
  if (!sheet) return;
  document.getElementById('mini-intention-name').value = '';
  document.getElementById('mini-intention-desc').value = '';
  document.getElementById('mini-intention-error').textContent = '';
  sheet.style.display = 'block';
  // Animate in
  requestAnimationFrame(function() { sheet.style.transform = 'translateX(0)'; });
  document.getElementById('mini-intention-name').focus();
}

function closeIntentionMiniEditor(newIdOrNull) {
  var sheet = document.getElementById('intention-mini-editor');
  if (sheet) {
    sheet.style.transform = 'translateX(100%)';
    setTimeout(function() { sheet.style.display = 'none'; }, 250);
  }
  if (_miniEditorCallback) {
    _miniEditorCallback(newIdOrNull);
    _miniEditorCallback = null;
  }
}

function submitIntentionMiniEditor() {
  var name = document.getElementById('mini-intention-name').value.trim();
  var desc = document.getElementById('mini-intention-desc').value.trim();
  if (!name) {
    document.getElementById('mini-intention-error').textContent = 'Name is required';
    return;
  }
  // Listen ONCE for the next mutation result (status === 'created')
  var origCb = window._intentionMutationResult;
  window._intentionMutationResult = function(res) {
    window._intentionMutationResult = origCb;   // restore
    if (origCb) origCb(res);
    if (res && res.status === 'created') {
      sendMessage({ type: 'GET_INTENTIONS' });  // refresh cache
      closeIntentionMiniEditor(res.id);
    } else {
      document.getElementById('mini-intention-error').textContent =
        (res && res.error) || 'Create failed';
    }
  };
  sendMessage({
    type: 'CREATE_INTENTION',
    name: name,
    description: desc,
    color_hex: null,
    icon: null,
    mac_websites: [],
    mac_bundle_ids: []
  });
}
```

- [ ] **Step 14.3: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): inline +Create-new-Intention slide-in mini-editor in block editor picker"
```

---

## Task 15: Dashboard — Intentions tab: 3-segment strictness picker + 24h cool-down + Strict-step-down partner unlock

**Files:**
- Modify: `Intentional/dashboard.html`

The Intentions page is rendered by `ProjectsController.openDashboard(id)`. Add a "Strictness" section there.

- [ ] **Step 15.1: Find the Intention edit-screen render**

```bash
grep -n "renderProjectDashboard\|renderProjectEdit\|projects-back-link\|openDashboard" Intentional/dashboard.html | head
```

In `ProjectsController.openDashboard` (or whichever method renders the per-Intention edit screen), inside the existing fields, add a section. Insert before the existing save / delete buttons:

```javascript
        + renderStrictnessSection(p)
        + renderWeeklyTargetSection(p)
```

- [ ] **Step 15.2: Implement `renderStrictnessSection(p)`**

Add as a top-level function inside the controller's IIFE:

```javascript
function renderStrictnessSection(p) {
  var current = p.strictness_preset || 'standard';
  var pending = p.pending_strictness_change;
  var sessionActive = appIsRunningSessionFor(p.id); // see Step 15.5

  var pendingBanner = '';
  if (pending) {
    var when = new Date(pending.takes_effect_at);
    pendingBanner =
      '<div style="background:rgba(245,158,11,0.1);border:1px solid rgba(245,158,11,0.3);border-radius:6px;padding:10px;margin-top:10px;font-size:12px;color:rgba(255,255,255,0.85);">' +
      'Scheduled to soften to <b>' + escapeHtml(pending.to_preset) + '</b> at ' + when.toLocaleString() +
      ' <a href="#" onclick="cancelPendingStrictness(\'' + p.id + '\'); return false;" style="margin-left:8px;color:var(--accent-primary);text-decoration:underline;">Cancel</a>' +
      '</div>';
  }

  var disabledAttr = sessionActive ? 'disabled' : '';
  var tooltipAttr = sessionActive ? 'title="Cannot change while session is running"' : '';

  return '<div class="settings-card" style="margin-top:16px;">' +
    '<div class="settings-card-title" style="padding:14px 14px 8px;">Strictness</div>' +
    '<div style="padding:0 14px 14px;">' +
    '<div class="segmented strictness-seg" ' + tooltipAttr + ' style="' + (sessionActive ? 'opacity:0.45;pointer-events:none;' : '') + '">' +
    ['strict', 'standard', 'soft'].map(function(p) {
      return '<button class="segmented-btn ' + (p === current ? 'selected' : '') + '" data-preset="' + p + '" ' + disabledAttr + ' onclick="onChangeStrictness(\'' + p + '\', \'' + p + '\', \'' + escapeHtml(p) + '\')">' +
        p.charAt(0).toUpperCase() + p.slice(1) + '</button>';
    }).join('') +
    '</div>' +
    pendingBanner +
    '<div style="margin-top:8px;font-size:11px;color:rgba(255,255,255,0.4);line-height:1.5;">Strict: overlay + AI scoring + intervention exercise. Standard: nudge banners. Soft: nudges only, no blocking.</div>' +
    '</div>' +
    '</div>';
}
```

(Note the `onclick` arg ordering: in real JS we must pass `currentIntentionId`, `targetPreset`, `intentionName`. Adjust to:)

```javascript
'<button class="segmented-btn ' + (preset === current ? 'selected' : '') + '" data-preset="' + preset + '" ' + disabledAttr +
  ' onclick="onChangeStrictness(\'' + p.id + '\', \'' + preset + '\', \'' + escapeHtml(p.name) + '\', \'' + current + '\')">'
```

(I.e. include `intentionId`, `toPreset`, `intentionName`, `currentPreset`.)

- [ ] **Step 15.3: Implement `onChangeStrictness` with direction-locked friction**

```javascript
function onChangeStrictness(intentionId, toPreset, intentionName, currentPreset) {
  var order = { strict: 3, standard: 2, soft: 1 };
  var fromRank = order[currentPreset] || 2;
  var toRank = order[toPreset] || 2;

  if (toRank > fromRank) {
    // Tightening — instant
    sendStrictnessUpdate(intentionId, toPreset);
    return;
  }
  if (toRank === fromRank) return;
  // Softening
  if (currentPreset === 'strict') {
    // Strict → anything: partner unlock required.
    sendMessage({
      type: 'OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET',
      id: intentionId,
      to_preset: toPreset,
      intention_name: intentionName
    });
    return;
  }
  if (currentPreset === 'standard' && toPreset === 'soft') {
    // 24h cool-down: confirm dialog
    if (confirm("This change takes effect in 24 hours.\n\nSoftening from Standard to Soft requires a 24-hour cool-down. You can cancel any time before then.")) {
      sendStrictnessUpdate(intentionId, toPreset);
    }
    return;
  }
}

function sendStrictnessUpdate(intentionId, toPreset, partnerCode) {
  var origCb = window._intentionMutationResult;
  window._intentionMutationResult = function(res) {
    window._intentionMutationResult = origCb;
    if (origCb) origCb(res);
    if (!res) return;
    if (res.status === 'updated') {
      showToast('Strictness updated', 'success');
      sendMessage({ type: 'GET_INTENTIONS' });
    } else if (res.status === 'queued_24h') {
      showToast('Change queued — applies in 24 hours', 'info');
      sendMessage({ type: 'GET_INTENTIONS' });
    } else if (res.status === 'requires_partner_unlock') {
      sendMessage({
        type: 'OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET',
        id: intentionId, to_preset: toPreset, intention_name: ''
      });
    } else if (res.status === 'session_in_progress') {
      showToast('Cannot change strictness during an active session', 'error');
    } else {
      showToast(res.error || 'Update failed', 'error');
    }
  };
  var msg = { type: 'UPDATE_INTENTION_STRICTNESS', id: intentionId, to_preset: toPreset };
  if (partnerCode) msg.partner_unlock_code = partnerCode;
  sendMessage(msg);
}

function cancelPendingStrictness(intentionId) {
  if (!confirm("Cancel the queued strictness change?")) return;
  var origCb = window._intentionMutationResult;
  window._intentionMutationResult = function(res) {
    window._intentionMutationResult = origCb;
    if (origCb) origCb(res);
    if (res && res.status === 'pending_cancelled') {
      showToast('Pending change cancelled', 'success');
      sendMessage({ type: 'GET_INTENTIONS' });
    } else {
      showToast('Cancel failed', 'error');
    }
  };
  sendMessage({ type: 'CANCEL_PENDING_STRICTNESS_CHANGE', id: intentionId });
}
```

- [ ] **Step 15.4: Implement `renderWeeklyTargetSection(p)` — D9 placeholder**

```javascript
function renderWeeklyTargetSection(p) {
  return '<div class="settings-card" style="margin-top:16px;opacity:0.55;">' +
    '<div class="settings-card-title" style="padding:14px 14px 8px;">Weekly target</div>' +
    '<div style="padding:0 14px 14px;font-size:13px;color:rgba(255,255,255,0.4);" title="Weekly budgets coming in a future update.">' +
    '+ Add weekly target (coming soon)' +
    '</div>' +
    '</div>';
}
```

- [ ] **Step 15.5: Add `appIsRunningSessionFor(intentionId)` stub**

```javascript
function appIsRunningSessionFor(intentionId) {
  // The dashboard already tracks the active focus session via _focusModeUpdate
  // (sets window._activeIntentionId). If that matches, the segmented control greys out.
  return window._activeIntentionId === intentionId;
}
```

(Wire `window._activeIntentionId = state.intentionId` in the existing `_focusModeUpdate` JS receiver if not already done — search for `_focusModeUpdate` and add the assignment at the top.)

- [ ] **Step 15.6: Implement deep-link receiver `_navigateToIntentionEditor`**

```javascript
window._navigateToIntentionEditor = function(intentionId) {
  navigateTo('intentions');
  setTimeout(function() {
    if (typeof ProjectsController !== 'undefined' && ProjectsController.openDashboard) {
      ProjectsController.openDashboard(intentionId);
    }
  }, 50);
};
```

- [ ] **Step 15.7: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): Intentions tab — 3-segment strictness picker + 24h cool-down + Strict-step-down partner unlock + pending banner + cancel"
```

---

## Task 16: Dashboard — solid bedtime + wake bands on the calendar

**Files:**
- Modify: `Intentional/dashboard.html`

D11 final answer: solid colors, no gradients, full-bleed (no inset margins), bedtime band anchored to BOTTOM of day calendar, wake band anchored to TOP.

- [ ] **Step 16.1: Add CSS classes**

Append to the style block:

```css
/* D11: Bedtime + Wake bands on the calendar — solid colors, no gradients */
.calendar-bedtime-band,
.calendar-wake-band {
  position: absolute;
  left: 0;
  right: 0;
  z-index: 0;            /* below blocks */
  pointer-events: none;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  font-weight: 500;
  letter-spacing: 0.4px;
  color: rgba(255,255,255,0.85);
}
.calendar-bedtime-band {
  background: #1a1f3a;   /* deep navy, solid */
  bottom: 0;             /* anchored to BOTTOM */
}
.calendar-wake-band {
  background: #f4825c;   /* warm coral, solid */
  top: 0;                /* anchored to TOP */
}
.calendar-bedtime-band .band-icon,
.calendar-wake-band .band-icon { margin-right: 6px; opacity: 0.9; }
```

- [ ] **Step 16.2: Render the bands inside the calendar grid**

In `renderCalendar`, after `'<div class="calendar-grid" id="calendar-grid" style="height:' + gridHeight + 'px;">'` add the band template. But because bedtime/wake times can shift, render them in `renderCalendarBlocks` (called every refresh). Append at the END of `renderCalendarBlocks`:

```javascript
  renderBedtimeAndWakeBands();
```

Then add the function:

```javascript
function renderBedtimeAndWakeBands() {
  var grid = document.getElementById('calendar-grid');
  if (!grid) return;
  // Remove old bands
  grid.querySelectorAll('.calendar-bedtime-band, .calendar-wake-band').forEach(function(el) { el.remove(); });

  // Read bedtime config from settings cache (if present)
  var bedHour = (settings.bedtime_settings && settings.bedtime_settings.bedtime_hour) || 22;
  var bedMin = (settings.bedtime_settings && settings.bedtime_settings.bedtime_minute) || 0;
  var wakeHour = (settings.bedtime_settings && settings.bedtime_settings.wake_hour) || 7;
  var wakeMin = (settings.bedtime_settings && settings.bedtime_settings.wake_minute) || 0;

  // Bedtime band: from bed time → end of calendar (clamp to gridBottom)
  var calStart = CALENDAR_START_HOUR;
  var calEnd = CALENDAR_END_HOUR;
  var bedMinOfDay = bedHour * 60 + bedMin;
  var calStartMin = calStart * 60;
  var calEndMin = calEnd * 60;

  if (bedMinOfDay >= calStartMin && bedMinOfDay < calEndMin) {
    var topPx = ((bedMinOfDay - calStartMin) / 60) * CALENDAR_HOUR_HEIGHT;
    var heightPx = ((calEndMin - bedMinOfDay) / 60) * CALENDAR_HOUR_HEIGHT;
    var band = document.createElement('div');
    band.className = 'calendar-bedtime-band';
    band.style.top = topPx + 'px';
    band.style.height = heightPx + 'px';
    band.style.bottom = 'auto';
    band.innerHTML = '<span class="band-icon">☾</span> Bedtime · ' + formatFocusTime(bedHour, bedMin) + ' → ' + formatFocusTime(wakeHour, wakeMin);
    grid.appendChild(band);
  }

  // Wake band: from calStart → wake time
  var wakeMinOfDay = wakeHour * 60 + wakeMin;
  if (wakeMinOfDay > calStartMin && wakeMinOfDay <= calEndMin) {
    var heightW = ((wakeMinOfDay - calStartMin) / 60) * CALENDAR_HOUR_HEIGHT;
    var bandW = document.createElement('div');
    bandW.className = 'calendar-wake-band';
    bandW.style.top = '0';
    bandW.style.height = heightW + 'px';
    bandW.innerHTML = '<span class="band-icon">☀</span> Wake · ' + formatFocusTime(wakeHour, wakeMin);
    grid.appendChild(bandW);
  }
}
```

- [ ] **Step 16.3: Re-render bands when bedtime settings change**

The dashboard already receives bedtime settings via `_settingsUpdate` or similar. Make sure `renderBedtimeAndWakeBands()` is called from the settings receiver. Find the bedtime-settings JS receiver:

```bash
grep -n "bedtime_hour\|bedtime_minute\|_bedtimeSettings\|bedtime_settings" Intentional/dashboard.html | head
```

In whichever receiver populates `settings.bedtime_settings`, append:

```javascript
  if (typeof renderBedtimeAndWakeBands === 'function') renderBedtimeAndWakeBands();
```

- [ ] **Step 16.4: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): solid bedtime (deep navy bottom) + wake (warm coral top) bands on calendar (D11, no gradients)"
```

---

## Task 17: ProjectsController — render strictness preset on Intentions list cards

**Files:**
- Modify: `Intentional/dashboard.html`

The Intentions list (formerly Projects) shows cards. Add a small badge with the current strictness preset.

- [ ] **Step 17.1: Find the card render** (search `projects-card` ~line 10336)

In the per-card template, after the card title, insert:

```javascript
'<div class="strictness-badge" style="font-size:10px;color:rgba(255,255,255,0.5);background:rgba(255,255,255,0.04);border-radius:4px;padding:2px 6px;display:inline-block;margin-top:4px;">' +
  ((p.strictness_preset || 'standard').toUpperCase()) +
'</div>'
```

(Optional: tint by preset — strict=red, standard=neutral, soft=green. Keep it subtle.)

- [ ] **Step 17.2: Refresh on `_intentionsList`**

`window._intentionsList` already triggers `ProjectsController.refresh()` from Task 13.1; verify the cards re-render with the new badge.

- [ ] **Step 17.3: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(scheduled-intentions): Intentions list — show strictness preset badge per card"
```

---

## Task 18: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 18.1: Add a new section under the existing "Intentions" stuff**

Insert in the "Known Bug Fixes" or memory section:

```markdown
13. **Scheduled Intentions Redesign (May 2026).** Block editor's "Blocking Profiles" chips are gone — replaced by an Intention picker dropdown sourced from `IntentionStore`. Block editor also drops the Block Type segmented control (Free Time = absence of block per Spec 2). New active-days pill row (Mon–Sun, default `[1..5]`). Each Intention now has a `strictnessPreset` (Strict / Standard / Soft) edited from the Intentions tab. Tightening is instant; softening Standard→Soft has a 24h cool-down (server-side cron, cancellable); softening from Strict requires a partner unlock code (reuses generalized `BedtimeUnlockRequestView` with `UnlockRequestKind.intentionStrictness`). Strictness control greys out during an active Session of that Intention (D6). Sidebar restructured to 8 items: Today / Intentions / Schedule / Distractions / Sensitive Content / Weekly Planning / Accountability / Settings. Sensitive Content promoted from Settings to its own page; Weekly Planning is a placeholder for the deferred budgets feature (D9 schema prep landed; behavior deferred). Bedtime + Wake render as solid bands on the calendar (deep navy bottom, warm coral top, no gradients per D11). Calendar gestures (drag-to-create / edge-resize / move) explicitly DEFERRED to v1.5 per D13. One-shot migration `BlockingProfilesToIntentionsMigration` rebinds existing block→profile bindings to block→intention idempotently with a receipt at `~/Library/Application Support/Intentional/migration_profiles_to_intentions_v1.json`. Per D14, `BlockingProfileManager` and its data file are NOT removed in this redesign — only the chips UI is hidden. Cleanup (Profiles tab + dashboard handlers + `BlockingProfileManager`) deferred to a follow-up spec after ≥2 weeks of stability.

   **Architecture key points:**
   - `Intention.strictnessPreset` + `pendingStrictnessChange` + `weeklyBudgetHours` + `budgetEnforcement` fields decode tolerantly so older payloads still parse.
   - New `BackendClient` methods: `updateIntentionStrictness`, `getPendingStrictnessChange`, `cancelPendingStrictnessChange`, `requestIntentionStrictnessUnlock`, `verifyIntentionStrictnessUnlock`.
   - New `MainWindow` bridge messages: `UPDATE_INTENTION_STRICTNESS`, `CANCEL_PENDING_STRICTNESS_CHANGE`, `OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET`, `OPEN_INTENTION_EDITOR`.
   - `BedtimeUnlockRequestView` gains `kind: UnlockRequestKind` enum (`.bedtime` vs `.intentionStrictness(intentionId, toPreset, intentionName)`); duration slider hidden when not bedtime.
```

- [ ] **Step 18.2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(scheduled-intentions): CLAUDE.md section — strictness presets + sidebar restructure + bedtime bands"
```

---

## Task 19: Smoke-test build + dashboard load

**Files:** none (verification)

- [ ] **Step 19.1: Clean build**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' clean build 2>&1 | tail -25
```

Expected: `BUILD SUCCEEDED`. If it fails, fix before proceeding.

- [ ] **Step 19.2: Dashboard sanity check**

Run the app from Xcode (`xcrun open` against the built `.app`). Verify:
1. Sidebar shows 8 items (Today / Intentions / Schedule / Distractions / Sensitive Content / Weekly Planning / Accountability / Settings).
2. Clicking Intentions shows the page (renamed from Projects).
3. Clicking Schedule shows the calendar (moved from Today).
4. Clicking Sensitive Content shows the content-safety card (moved from Settings).
5. Clicking Weekly Planning shows the empty state with "Go to Intentions →".
6. Block editor (click any block on the Today calendar): no Block Type segmented, no Profiles chips, has Intention dropdown + active-days pills + strictness caption.
7. Bedtime/wake bands render at top + bottom of calendar.

- [ ] **Step 19.3: If everything renders, commit a checkpoint**

```bash
git commit --allow-empty -m "verify(scheduled-intentions): smoke test passes — sidebar/editor/calendar render OK"
```

---

## Task 20: Strictness round-trip smoke test (against Plan A backend)

**Files:** none (manual verification)

- [ ] **Step 20.1: Create an Intention via the inline + button in block editor.** Verify it appears in the dropdown and the cache.

- [ ] **Step 20.2: Open Intentions tab → click the new Intention → see the 3-segment strictness picker (default Standard).**

- [ ] **Step 20.3: Click Strict → expect instant update (toast: "Strictness updated"). Click Standard → instant. Click Soft → confirm dialog "This change takes effect in 24 hours" → confirm → toast: "Change queued — applies in 24 hours" + scheduled banner appears.**

- [ ] **Step 20.4: Cancel the queued change via the banner's Cancel link → banner clears.**

- [ ] **Step 20.5: Click Strict → instant. Click Soft → BedtimeUnlockRequestView opens in `.intentionStrictness` mode (title says "Ask your partner to soften ... → Soft"). Cancel.**

- [ ] **Step 20.6: Start a Session of this Intention from the dashboard. Re-open the Intentions tab → strictness picker is greyed out with tooltip "Cannot change while session is running."**

- [ ] **Step 20.7: Stop the session. Re-confirm picker is interactive again.**

If all 7 pass, commit a verification marker:

```bash
git commit --allow-empty -m "verify(scheduled-intentions): strictness round-trip + active-session lock + queued-change cancel verified manually"
```

---

## Task 21: Migration smoke test

**Files:** none (manual verification with seeded state)

- [ ] **Step 21.1: Quit the app. Manually edit `~/Library/Application Support/Intentional/daily_schedule.legacy.json`** (or `daily_schedule.json` if not yet renamed by Spec 2 init) to add a `profileIds: ["<some-existing-profile-uuid>"]` array on one block.

- [ ] **Step 21.2: Delete the receipt:**

```bash
rm -f ~/Library/Application\ Support/Intentional/migration_profiles_to_intentions_v1.json
```

- [ ] **Step 21.3: Launch the app. Watch logs for:**

```
🔁 BlockingProfilesToIntentions: N blocks with legacy profileIds to migrate
🔁 BlockingProfilesToIntentions: complete
```

- [ ] **Step 21.4: Open the block editor on the migrated block. Intention dropdown should be pre-selected to the Intention named after the original Profile.**

- [ ] **Step 21.5: Re-launch. Logs should say `receipt present, skipping`.**

- [ ] **Step 21.6: Verification commit:**

```bash
git commit --allow-empty -m "verify(scheduled-intentions): block.profileIds → block.intentionId migration runs idempotently"
```

---

## Task 22: Cross-repo log + push

**Files:**
- Create: `docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md`

- [ ] **Step 22.1: Write the cross-repo log**

```markdown
# Scheduled Intentions Redesign — Cross-repo log

**Date started:** 2026-05-04
**Repos:** intentional-macos-app (this), puck-ios, intentional-backend
**Spec:** docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md

## Branches
- intentional-macos-app: `feat/scheduled-intentions-redesign` (Plan B — Mac client)
- puck-ios: `feat/scheduled-intentions-redesign` (Plan C — iOS, sibling agent)
- intentional-backend: `feat/scheduled-intentions-redesign-backend` (Plan A — endpoints + migration 020)

## Mac (Plan B) — DONE / pending
- [ ] Intention.swift extended (strictnessPreset, pendingStrictnessChange, budget-prep fields)
- [ ] BackendClient strictness methods + partner-unlock helpers
- [ ] IntentionStore.updateStrictness + cancelPending
- [ ] BedtimeUnlockRequestView generalized (UnlockRequestKind)
- [ ] AppDelegate.openIntentionStrictnessUnlockSheet
- [ ] MainWindow bridge handlers (UPDATE_INTENTION_STRICTNESS / CANCEL / OPEN_*)
- [ ] BlockingProfilesToIntentionsMigration (idempotent receipt)
- [ ] dashboard.html: sidebar 8-item restructure
- [ ] dashboard.html: page-schedule, page-sensitive, page-weekly
- [ ] dashboard.html: block editor — picker + active-days + strictness caption + remove Profiles chips + Block Type
- [ ] dashboard.html: inline + Create new Intention slide-in
- [ ] dashboard.html: Intentions tab strictness picker + 24h cool-down + Strict-step-down unlock + pending banner + cancel
- [ ] dashboard.html: solid bedtime/wake bands (no gradients, anchored bottom/top)
- [ ] dashboard.html: per-card strictness badge on Intentions list
- [ ] CLAUDE.md updated

## Hand-off to morning
- Mac branch ready to merge IF Plan A is merged. Verify endpoint URLs match
  (PUT /intentions/{id}/strictness; intention_strictness_unlock_requests).
- Per D14, BlockingProfileManager and the Profiles tab are LEFT INTACT.
  Cleanup PR scheduled for ≥2 weeks after this redesign goes stable.
- Calendar gestures (drag-to-create / edge-resize / move) DEFERRED per D13.
- D9 budget-prep schema is in place; budget BEHAVIOR is its own future spec
  at docs/superpowers/specs/2026-05-03-weekly-budgets-future-spec.md.
```

- [ ] **Step 22.2: Commit + push**

```bash
git add docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md
git commit -m "log(scheduled-intentions): cross-repo log skeleton — Mac phase task list"
git push -u origin feat/scheduled-intentions-redesign
```

---

## Out of scope (DO NOT do in this plan)

- iOS (Plan C is the sibling agent's responsibility — do not edit `puck-ios` code).
- Backend (Plan A is its own branch — do not edit `intentional-backend` code).
- Removing `BlockingProfileManager` or the Profiles dashboard tab (D14 — explicit deferral, scheduled for ≥2 weeks after redesign stable).
- Calendar gestures: drag-to-create / edge-resize / block-move (D13 — explicit deferral to v1.5).
- Budget BEHAVIOR: Sunday-night ritual, auto-scheduling, behind-budget partner notification, weekly recap. (D9 schema prep + UI placeholders are in scope; behavior is its own future spec.)
- Week view rendering on the Schedule page (only the Day/Week toggle stub ships; week is a "coming soon" placeholder).
- Removing the deprecated `*_PROJECT_*` bridge handlers — kept for backwards compat per Spec 1's "deprecated alias" decision.
- Per-block strictness override (D10 — strictness lives only on the Intention; if you want a one-off stricter block, create a stricter Intention).
- Onboarding flows for Sensitive Content, Weekly Planning, or strictness — they're surfaced in nav but no first-run education layer.

## Required env vars

None new. Reuses existing `X-Device-ID` derived via `BackendClient.getDeviceId()`. `baseURL` already set.

## Acceptance check (matches spec §13 acceptance criteria)

After completion, all of these should be true on Mac:
1. ✅ Mac block editor has Intention dropdown — bound block syncs to iPhone within 60s (verified after Plan C ships).
2. ✅ Strict Intention enforces with overlay + AI scoring + intervention exercise (existing FocusMonitor mechanisms keyed by intention's strictness).
3. ✅ Strict→soft requires partner unlock (BedtimeUnlockRequestView in `.intentionStrictness` mode).
4. ✅ Standard→Soft queues 24h with banner + Cancel.
5. ✅ Strictness picker greys out during active Session of that Intention.
6. (iOS — Plan C's responsibility)
7. (iOS — Plan C's responsibility)
8. (DEFERRED per D13 — Mac calendar keeps existing click-to-create-30-min)
9. ✅ Active-days pills work on Mac block editor; backend `time_blocks.active_days` updated.
10. ✅ Profiles chips gone after migration (chips UI hidden; data layer kept per D14).
11. ✅ Sidebar shows new 8-item structure; Sensitive Content and Weekly Planning are sidebar-reachable.
12. ✅ Backend migration 020 applied (Plan A's responsibility); Mac decodes `weekly_budget_hours`/`budget_enforcement`/`derived_from_budget` tolerantly.
13. ✅ "+ Add weekly target (coming soon)" greyed row visible at bottom of every Intention edit screen.
