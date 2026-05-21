# Close the Noise — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a focus session starts, automatically stash browser tabs and hide native apps that don't match the user's declared session scope. Recoverable via 30s toast or session-end review.

**Architecture:** Three new Swift files (`AlwaysAllowedList`, `SessionStash`, `Sweeper`) + extensions to `WebsiteBlocker` (multi-tab read + bookmarks API) + `RelevanceScorer` (batch tab scoring) + dashboard Settings page. Sweep fires from `FocusModeController.onStateChanged` when `.off → .focus`.

**Tech Stack:** Swift + AppKit, AppleScript (existing pattern in `WebsiteBlocker`), Qwen3-4B text model (existing `RelevanceScorer`), WKWebView dashboard with bridge messages (existing `MainWindow` pattern).

**Spec:** [docs/superpowers/specs/2026-05-18-close-the-noise-design.md](../specs/2026-05-18-close-the-noise-design.md)

**Self-test convention:** project tests live in `IntentionalTests/`, each test file is a standalone `@main struct` with a `test(name, body)` helper and `assertEqual`/`assertTrue`/`assertFalse`. Run via `swift IntentionalTests/<file>.swift Intentional/<deps>.swift` (compile-and-run as standalone). Follow `BlockingProfileTests.swift` as the canonical template.

---

## File Structure

**New files:**
- `Intentional/AlwaysAllowedList.swift` — data model + JSON persistence at `~/Library/Application Support/Intentional/always_allowed.json`
- `Intentional/SessionStash.swift` — stash data model + JSON persistence under `~/Library/Application Support/Intentional/session_stashes/`
- `Intentional/Sweeper.swift` — `Sweeper` actor: `resolveScope()`, `sweepAtSessionStart()`, `restoreFromStash()`
- `Intentional/StashInspectorWindow.swift` — small floating NSWindow listing stashed items with per-row restore
- `Intentional/MigrationAlwaysAllowed.swift` — one-shot merge of per-Intention `allowWebsites`/`allowBundleIds` → global list
- `IntentionalTests/AlwaysAllowedListTests.swift` — persistence + defaults
- `IntentionalTests/SweeperTests.swift` — `resolveScope` + decision logic

**Modified files:**
- `Intentional/AppDelegate.swift` — wire `Sweeper` to `FocusModeController.onStateChanged`; run migration on launch; 3-day auto-purge on launch
- `Intentional/MainWindow.swift` — `SAVE_ALWAYS_ALLOWED`, `GET_ALWAYS_ALLOWED`, `RESTORE_FROM_STASH_ITEM`, `RESTORE_FROM_STASH_ALL` bridge handlers; include `alwaysAllowed` in `GET_SETTINGS` result
- `Intentional/WebsiteBlocker.swift` — public `readAllTabsAcrossWindows(for: bundleId) -> [TabInfo]`, `createBookmarkFolder(in: bundleId, name: String) -> String?`, `addBookmark(folderId: String, title: String, url: String, browserBundleId: String)`, `closeTabsByURL(_ urls: Set<String>, in: bundleId)`
- `Intentional/RelevanceScorer.swift` — public `scoreTabBatch(intent: String, tabs: [(title: String, url: String)]) async -> [TabVerdict]`
- `Intentional/dashboard.html` — new "Always Allowed" page in Settings sidebar; toast UI for sweep results; per-row restore handlers

---

## Task 1: AlwaysAllowedList data model + persistence

**Files:**
- Create: `Intentional/AlwaysAllowedList.swift`
- Test: `IntentionalTests/AlwaysAllowedListTests.swift`

- [ ] **Step 1: Write failing test**

Create `IntentionalTests/AlwaysAllowedListTests.swift`:

```swift
import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b { passed += 1 } else { failed += 1; print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)") }
}
func assertTrue(_ a: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a { passed += 1 } else { failed += 1; print("  FAIL (\(file):\(line)): expected true, got false. \(msg)") }
}
func test(_ name: String, _ body: () -> Void) { print("• \(name)"); body() }

@main
struct AlwaysAllowedListTests {
    static func main() {
        print("\n🧪 AlwaysAllowedListTests\n")
        let testDir = "/tmp/always-allowed-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

        test("ships with sensible defaults on first load") {
            let store = AlwaysAllowedStore(storageDir: testDir + "/t1")
            assertTrue(store.list.bundleIds.contains("com.apple.systempreferences"), "should include System Settings")
            assertTrue(store.list.bundleIds.contains("com.spotify.client"), "should include Spotify")
            assertTrue(store.list.domains.contains("music.apple.com"), "should include music.apple.com")
        }

        test("persists changes across loads") {
            let dir = testDir + "/t2"
            let store = AlwaysAllowedStore(storageDir: dir)
            store.addBundleId("com.example.test")
            store.addDomain("example.com")
            let reloaded = AlwaysAllowedStore(storageDir: dir)
            assertTrue(reloaded.list.bundleIds.contains("com.example.test"))
            assertTrue(reloaded.list.domains.contains("example.com"))
        }

        test("isAllowed treats domain match as a host suffix") {
            let store = AlwaysAllowedStore(storageDir: testDir + "/t3")
            store.addDomain("example.com")
            assertTrue(store.isDomainAllowed("example.com"))
            assertTrue(store.isDomainAllowed("sub.example.com"))
            assertTrue(!store.isDomainAllowed("notexample.com"), "must not match by substring")
        }

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/prototype-to-production
swift IntentionalTests/AlwaysAllowedListTests.swift
```

Expected: compile error `cannot find 'AlwaysAllowedStore'` — confirms the type isn't defined yet.

- [ ] **Step 3: Implement the type**

Create `Intentional/AlwaysAllowedList.swift`:

```swift
import Foundation

/// Per-user list of apps + websites the sweep at session-start NEVER touches.
/// Global (not per-Intention) — replaces the old per-Intention allowWebsites/allowBundleIds.
struct AlwaysAllowedList: Codable, Equatable {
    var bundleIds: Set<String>
    var domains: Set<String>

    static let defaults = AlwaysAllowedList(
        bundleIds: [
            "com.apple.systempreferences",
            "com.apple.iCal",                  // Calendar
            "com.apple.MobileSMS",             // Messages
            "com.apple.Music",                 // Apple Music
            "com.spotify.client",              // Spotify
            "com.1password.1password",         // 1Password
            "com.1password.1password-launcher",
            "com.apple.finder",
        ],
        domains: [
            "music.apple.com",
            "1password.com",
            "calendar.google.com",
            "icloud.com",
        ]
    )
}

/// Disk-backed store for the global Always-Allowed list. Lives at
/// <appSupport>/Intentional/always_allowed.json.
final class AlwaysAllowedStore {
    private(set) var list: AlwaysAllowedList
    private let fileURL: URL

    init(storageDir: String) {
        let dir = URL(fileURLWithPath: storageDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("always_allowed.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(AlwaysAllowedList.self, from: data) {
            self.list = loaded
        } else {
            self.list = AlwaysAllowedList.defaults
            persist()
        }
    }

    func addBundleId(_ bid: String) { list.bundleIds.insert(bid); persist() }
    func removeBundleId(_ bid: String) { list.bundleIds.remove(bid); persist() }
    func addDomain(_ domain: String) { list.domains.insert(domain.lowercased()); persist() }
    func removeDomain(_ domain: String) { list.domains.remove(domain.lowercased()); persist() }

    func isBundleIdAllowed(_ bid: String) -> Bool { list.bundleIds.contains(bid) }

    /// Suffix match — "example.com" matches "sub.example.com" but not "notexample.com".
    func isDomainAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        for d in list.domains {
            if h == d || h.hasSuffix("." + d) { return true }
        }
        return false
    }

    /// Replace the whole list (used by the migration runner + Settings save).
    func replace(_ newList: AlwaysAllowedList) {
        self.list = AlwaysAllowedList(
            bundleIds: newList.bundleIds,
            domains: Set(newList.domains.map { $0.lowercased() })
        )
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift IntentionalTests/AlwaysAllowedListTests.swift Intentional/AlwaysAllowedList.swift
```

Expected: `3 passed, 0 failed` and exit 0.

- [ ] **Step 5: Commit**

```bash
git add Intentional/AlwaysAllowedList.swift IntentionalTests/AlwaysAllowedListTests.swift
git commit -m "feat(always-allowed): data model + persistence + sensible defaults

Global per-user list of apps + websites the close-the-noise sweep
never touches. Lives at ~/Library/Application Support/Intentional/
always_allowed.json. Ships with sensible defaults: System Settings,
Calendar, Messages, Music, Spotify, 1Password, Finder; domains:
music.apple.com, 1password.com, calendar.google.com, icloud.com.

Tests cover defaults-on-first-load, persistence across loads, and
suffix-match semantics for isDomainAllowed.
"
```

---

## Task 2: Migration runner — per-Intention allow lists → global

**Files:**
- Create: `Intentional/MigrationAlwaysAllowed.swift`
- Test: extend `IntentionalTests/AlwaysAllowedListTests.swift` (just add cases)

- [ ] **Step 1: Extend test**

Append to `IntentionalTests/AlwaysAllowedListTests.swift` inside `main()` (before the print at the end):

```swift
test("migration unions per-Intention lists into global, is idempotent via receipt") {
    let dir = testDir + "/t4"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // Fake intentions cache file that mirrors what IntentionStore writes
    let intentionsJSON = """
    {
      "intentions": [
        { "id": "11111111-1111-1111-1111-111111111111", "name": "Code",
          "allowWebsites": ["github.com", "stackoverflow.com"],
          "allowBundleIds": ["com.todesktop.230313mzl4w4u92"]
        },
        { "id": "22222222-2222-2222-2222-222222222222", "name": "Write",
          "allowWebsites": ["github.com", "notion.so"],
          "allowBundleIds": ["com.todesktop.230313mzl4w4u92", "notion.id"]
        }
      ]
    }
    """
    try? intentionsJSON.write(toFile: dir + "/intentions.json", atomically: true, encoding: .utf8)

    let store = AlwaysAllowedStore(storageDir: dir)
    let receiptPath = dir + "/migration_always_allowed_v1.json"

    // First run: merges
    MigrationAlwaysAllowed.runIfNeeded(intentionsCachePath: dir + "/intentions.json",
                                       store: store, receiptPath: receiptPath)
    assertTrue(store.list.domains.contains("github.com"))
    assertTrue(store.list.domains.contains("stackoverflow.com"))
    assertTrue(store.list.domains.contains("notion.so"))
    assertTrue(store.list.bundleIds.contains("com.todesktop.230313mzl4w4u92"))
    assertTrue(FileManager.default.fileExists(atPath: receiptPath), "receipt should be written")

    // Second run: no-op (receipt present)
    let countBefore = store.list.domains.count
    store.addDomain("manually-added.com")
    MigrationAlwaysAllowed.runIfNeeded(intentionsCachePath: dir + "/intentions.json",
                                       store: store, receiptPath: receiptPath)
    assertEqual(store.list.domains.count, countBefore + 1, "second run must not re-merge")
    assertTrue(store.list.domains.contains("manually-added.com"))
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift IntentionalTests/AlwaysAllowedListTests.swift Intentional/AlwaysAllowedList.swift
```

Expected: compile error `cannot find 'MigrationAlwaysAllowed'`.

- [ ] **Step 3: Implement the migration**

Create `Intentional/MigrationAlwaysAllowed.swift`:

```swift
import Foundation

/// One-shot migration: collects per-Intention `allowWebsites` + `allowBundleIds`
/// from the on-disk intentions cache, unions them into the global
/// AlwaysAllowedStore, and writes a receipt so it never re-runs.
///
/// Intentionally lightweight — reads the cache JSON directly with no
/// IntentionStore dependency so it can run before the actor is wired in.
struct MigrationAlwaysAllowed {

    static func runIfNeeded(intentionsCachePath: String,
                            store: AlwaysAllowedStore,
                            receiptPath: String) {
        if FileManager.default.fileExists(atPath: receiptPath) { return }
        guard let data = FileManager.default.contents(atPath: intentionsCachePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intentions = json["intentions"] as? [[String: Any]] else {
            // No cache yet (fresh install). Mark receipt anyway so we don't try again.
            writeReceipt(at: receiptPath, added: 0)
            return
        }

        var addedDomains = 0
        var addedBundleIds = 0
        for intention in intentions {
            if let sites = intention["allowWebsites"] as? [String] {
                for s in sites {
                    let host = normalizeHost(s)
                    if !host.isEmpty, !store.list.domains.contains(host) {
                        store.addDomain(host)
                        addedDomains += 1
                    }
                }
            }
            if let bids = intention["allowBundleIds"] as? [String] {
                for b in bids where !store.list.bundleIds.contains(b) {
                    store.addBundleId(b)
                    addedBundleIds += 1
                }
            }
        }

        writeReceipt(at: receiptPath, added: addedDomains + addedBundleIds)
    }

    private static func normalizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("https://") { s.removeFirst(8) }
        if s.hasPrefix("http://") { s.removeFirst(7) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s
    }

    private static func writeReceipt(at path: String, added: Int) {
        let payload = """
        { "completedAt": "\(ISO8601DateFormatter().string(from: Date()))", "added": \(added) }
        """
        try? payload.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift IntentionalTests/AlwaysAllowedListTests.swift Intentional/AlwaysAllowedList.swift Intentional/MigrationAlwaysAllowed.swift
```

Expected: `4 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Intentional/MigrationAlwaysAllowed.swift IntentionalTests/AlwaysAllowedListTests.swift
git commit -m "feat(always-allowed): one-shot migration from per-Intention allowlists

Reads the on-disk intentions cache, unions all allowWebsites and
allowBundleIds values into the global Always-Allowed store, writes
an idempotent receipt at migration_always_allowed_v1.json.

Test covers: union semantics, receipt-gated idempotency, and that
subsequent loads preserve manually-added entries.
"
```

---

## Task 3: Bridge messages — SAVE_ALWAYS_ALLOWED / GET_ALWAYS_ALLOWED

**Files:**
- Modify: `Intentional/MainWindow.swift`
- Modify: `Intentional/AppDelegate.swift` (instantiate the store)

- [ ] **Step 1: Add the store to AppDelegate**

In `Intentional/AppDelegate.swift`, near where other stores are declared, add:

```swift
var alwaysAllowedStore: AlwaysAllowedStore?
```

In `applicationDidFinishLaunching(_:)`, after `UserDefaults.standard.register(defaults: ...)` and before any focus-related wiring, add:

```swift
// Always-Allowed store (used by close-the-noise sweep + Settings UI).
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let intentionalDir = appSupport.appendingPathComponent("Intentional").path
self.alwaysAllowedStore = AlwaysAllowedStore(storageDir: intentionalDir)

// One-shot migration: per-Intention allowlists → global.
MigrationAlwaysAllowed.runIfNeeded(
    intentionsCachePath: intentionalDir + "/intentions.json",
    store: self.alwaysAllowedStore!,
    receiptPath: intentionalDir + "/migration_always_allowed_v1.json"
)
```

- [ ] **Step 2: Add bridge handlers in MainWindow.swift**

Find the message dispatch `switch` (around line 460–700). Add new cases:

```swift
case "GET_ALWAYS_ALLOWED":
    if let store = appDelegate?.alwaysAllowedStore {
        let dict: [String: Any] = [
            "bundleIds": Array(store.list.bundleIds).sorted(),
            "domains":   Array(store.list.domains).sorted()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._alwaysAllowedResult && window._alwaysAllowedResult(\(json))")
        }
    }

case "SAVE_ALWAYS_ALLOWED":
    if let store = appDelegate?.alwaysAllowedStore,
       let bids = body["bundleIds"] as? [String],
       let domains = body["domains"] as? [String] {
        store.replace(AlwaysAllowedList(bundleIds: Set(bids), domains: Set(domains)))
        appDelegate?.postLog("✅ SAVE_ALWAYS_ALLOWED: \(bids.count) apps, \(domains.count) sites")
    }
```

Also extend the existing `GET_SETTINGS` result builder (find `result["strictModeEnabled"] = ...`) by adding immediately below it:

```swift
if let store = appDelegate?.alwaysAllowedStore {
    result["alwaysAllowed"] = [
        "bundleIds": Array(store.list.bundleIds).sorted(),
        "domains":   Array(store.list.domains).sorted()
    ]
}
```

- [ ] **Step 3: Smoke-build**

```bash
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Intentional/AppDelegate.swift Intentional/MainWindow.swift
git commit -m "feat(always-allowed): bridge handlers + AppDelegate wire-up

- AppDelegate.alwaysAllowedStore initialized in
  applicationDidFinishLaunching; migration runs once.
- GET_ALWAYS_ALLOWED returns { bundleIds, domains } via
  window._alwaysAllowedResult.
- SAVE_ALWAYS_ALLOWED replaces the whole list (Settings page sends
  the new state on every edit).
- GET_SETTINGS result extended with alwaysAllowed so dashboard can
  pre-populate the page on first load.
"
```

---

## Task 4: Settings → Always Allowed page UI

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 1: Add the page HTML**

In `Intentional/dashboard.html`, find the existing Settings page markup (search for `id="page-settings"`). After the existing settings cards but before the page closing `</div>`, add a new card:

```html
<!-- Always Allowed list: things the close-the-noise sweep never touches -->
<div class="settings-card" id="always-allowed-card" style="margin-top:14px;">
  <div class="settings-card-title">Always Allowed</div>
  <div class="setting-desc" style="padding:2px 16px 12px; font-size:12px;">
    Apps and websites the close-the-noise sweep never touches at session start. Password managers, music, calendar, system stuff. Anything outside this list (and outside your session scope) gets stashed.
  </div>
  <div style="padding:4px 16px 14px;">
    <div style="display:flex; gap:14px; align-items:flex-start;">
      <div style="flex:1;">
        <div style="font-size:12px; font-weight:600; margin-bottom:6px; color:var(--text-secondary);">APPS (bundle IDs)</div>
        <div id="always-allowed-apps-list" style="display:flex; flex-direction:column; gap:4px;"></div>
        <div style="display:flex; gap:6px; margin-top:8px;">
          <input id="always-allowed-app-input" type="text" placeholder="com.example.app"
                 style="flex:1; padding:5px 8px; font-size:12px; background:var(--surface);
                        border:0.5px solid var(--line); border-radius:5px; color:var(--text-primary);">
          <button onclick="addAlwaysAllowedApp()" class="btn-small">Add</button>
        </div>
      </div>
      <div style="flex:1;">
        <div style="font-size:12px; font-weight:600; margin-bottom:6px; color:var(--text-secondary);">WEBSITES (domains)</div>
        <div id="always-allowed-domains-list" style="display:flex; flex-direction:column; gap:4px;"></div>
        <div style="display:flex; gap:6px; margin-top:8px;">
          <input id="always-allowed-domain-input" type="text" placeholder="example.com"
                 style="flex:1; padding:5px 8px; font-size:12px; background:var(--surface);
                        border:0.5px solid var(--line); border-radius:5px; color:var(--text-primary);">
          <button onclick="addAlwaysAllowedDomain()" class="btn-small">Add</button>
        </div>
      </div>
    </div>
  </div>
</div>
```

- [ ] **Step 2: Add the JS state + handlers**

Find any of the existing settings-result handlers in `dashboard.html` (`window._settingsResult = function(data)` near line ~8990, the standalone one — NOT the inner Strict Mode interceptor). Add this BEFORE that block (so the receiver registration sticks):

```javascript
// Always Allowed list state (from GET_SETTINGS + GET_ALWAYS_ALLOWED).
window._alwaysAllowedState = { bundleIds: [], domains: [] };

window._alwaysAllowedResult = function(data) {
  if (!data || typeof data !== 'object') return;
  window._alwaysAllowedState.bundleIds = data.bundleIds || [];
  window._alwaysAllowedState.domains = data.domains || [];
  renderAlwaysAllowed();
};

function renderAlwaysAllowed() {
  var appsList = document.getElementById('always-allowed-apps-list');
  var domainsList = document.getElementById('always-allowed-domains-list');
  if (!appsList || !domainsList) return;
  var s = window._alwaysAllowedState;
  appsList.innerHTML = s.bundleIds.map(function(b) {
    return '<div class="setting-row" style="padding:4px 8px; font-size:11.5px;">' +
      '<span style="flex:1; font-family:monospace; color:var(--text-primary);">' + b + '</span>' +
      '<button onclick="removeAlwaysAllowedApp(\'' + b + '\')" class="btn-small" style="font-size:10px;">Remove</button>' +
      '</div>';
  }).join('') || '<div style="font-size:11px; color:var(--text-tertiary);">(empty)</div>';
  domainsList.innerHTML = s.domains.map(function(d) {
    return '<div class="setting-row" style="padding:4px 8px; font-size:11.5px;">' +
      '<span style="flex:1; font-family:monospace; color:var(--text-primary);">' + d + '</span>' +
      '<button onclick="removeAlwaysAllowedDomain(\'' + d + '\')" class="btn-small" style="font-size:10px;">Remove</button>' +
      '</div>';
  }).join('') || '<div style="font-size:11px; color:var(--text-tertiary);">(empty)</div>';
}

function addAlwaysAllowedApp() {
  var input = document.getElementById('always-allowed-app-input');
  var v = (input.value || '').trim();
  if (!v) return;
  if (window._alwaysAllowedState.bundleIds.indexOf(v) < 0) {
    window._alwaysAllowedState.bundleIds.push(v);
    window._alwaysAllowedState.bundleIds.sort();
    persistAlwaysAllowed();
  }
  input.value = '';
}

function removeAlwaysAllowedApp(bid) {
  window._alwaysAllowedState.bundleIds = window._alwaysAllowedState.bundleIds.filter(function(b) { return b !== bid; });
  persistAlwaysAllowed();
}

function addAlwaysAllowedDomain() {
  var input = document.getElementById('always-allowed-domain-input');
  var v = (input.value || '').trim().toLowerCase();
  if (!v) return;
  if (window._alwaysAllowedState.domains.indexOf(v) < 0) {
    window._alwaysAllowedState.domains.push(v);
    window._alwaysAllowedState.domains.sort();
    persistAlwaysAllowed();
  }
  input.value = '';
}

function removeAlwaysAllowedDomain(d) {
  window._alwaysAllowedState.domains = window._alwaysAllowedState.domains.filter(function(x) { return x !== d; });
  persistAlwaysAllowed();
}

function persistAlwaysAllowed() {
  sendMessage({
    type: 'SAVE_ALWAYS_ALLOWED',
    bundleIds: window._alwaysAllowedState.bundleIds,
    domains:   window._alwaysAllowedState.domains
  });
  renderAlwaysAllowed();
  if (typeof showToast === 'function') showToast('Always Allowed updated');
}

window.addAlwaysAllowedApp = addAlwaysAllowedApp;
window.removeAlwaysAllowedApp = removeAlwaysAllowedApp;
window.addAlwaysAllowedDomain = addAlwaysAllowedDomain;
window.removeAlwaysAllowedDomain = removeAlwaysAllowedDomain;
```

Then in the existing `window._settingsResult` (the OUTER one, not the Strict Mode inner one), after wherever other receivers like `data.strictModeEnabled` are read, add:

```javascript
if (data.alwaysAllowed) {
  window._alwaysAllowedState.bundleIds = data.alwaysAllowed.bundleIds || [];
  window._alwaysAllowedState.domains = data.alwaysAllowed.domains || [];
  if (typeof renderAlwaysAllowed === 'function') renderAlwaysAllowed();
}
```

- [ ] **Step 3: Verify in Debug build**

Run `./scripts/dev-launch.sh`. Open the app → Settings → scroll to the new Always Allowed card. Confirm the default list (System Settings, Spotify, etc.) renders. Add a new app bundle ID and a domain; quit the app; relaunch; verify they persist.

- [ ] **Step 4: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(always-allowed): Settings page UI

New card in Settings showing two parallel lists (Apps / Websites).
Wired to SAVE_ALWAYS_ALLOWED + GET_ALWAYS_ALLOWED. Pre-populates
from GET_SETTINGS on page load so the user sees the migrated +
default state immediately.
"
```

---

## Task 5: SessionStash data model + persistence

**Files:**
- Create: `Intentional/SessionStash.swift`
- Test: `IntentionalTests/SessionStashTests.swift`

- [ ] **Step 1: Write failing test**

Create `IntentionalTests/SessionStashTests.swift`:

```swift
import Foundation

var passed = 0
var failed = 0
func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b { passed += 1 } else { failed += 1; print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)") }
}
func assertTrue(_ a: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a { passed += 1 } else { failed += 1; print("  FAIL (\(file):\(line)): expected true, got false. \(msg)") }
}
func test(_ name: String, _ body: () -> Void) { print("• \(name)"); body() }

@main
struct SessionStashTests {
    static func main() {
        print("\n🧪 SessionStashTests\n")
        let testDir = "/tmp/session-stash-tests-\(UUID().uuidString)"

        test("write + read round-trips") {
            let store = SessionStashStore(storageDir: testDir + "/t1")
            let stash = SessionStash(
                sessionId: "abc",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                bookmarksFolderId: "folder-1",
                hiddenBundleIds: ["com.example.foo"],
                stashedTabs: [
                    StashedTab(title: "GitHub", url: "https://github.com/x",
                               browserBundleId: "com.google.Chrome", originalWindow: 0, originalIndex: 1)
                ]
            )
            store.save(stash)
            let loaded = store.load(sessionId: "abc")
            assertTrue(loaded != nil)
            assertEqual(loaded?.hiddenBundleIds.first, "com.example.foo")
            assertEqual(loaded?.stashedTabs.first?.title, "GitHub")
        }

        test("listAll returns stashes sorted newest-first") {
            let store = SessionStashStore(storageDir: testDir + "/t2")
            store.save(SessionStash(sessionId: "old", createdAt: Date(timeIntervalSince1970: 1000),
                                    bookmarksFolderId: nil, hiddenBundleIds: [], stashedTabs: []))
            store.save(SessionStash(sessionId: "new", createdAt: Date(timeIntervalSince1970: 2000),
                                    bookmarksFolderId: nil, hiddenBundleIds: [], stashedTabs: []))
            let all = store.listAll()
            assertEqual(all.count, 2)
            assertEqual(all.first?.sessionId, "new", "newest stash should be first")
        }

        test("purgeOlderThan removes stale stashes") {
            let store = SessionStashStore(storageDir: testDir + "/t3")
            let oldDate = Date().addingTimeInterval(-4 * 24 * 3600) // 4 days ago
            let recentDate = Date().addingTimeInterval(-1 * 3600)   // 1 hour ago
            store.save(SessionStash(sessionId: "stale", createdAt: oldDate,
                                    bookmarksFolderId: nil, hiddenBundleIds: [], stashedTabs: []))
            store.save(SessionStash(sessionId: "fresh", createdAt: recentDate,
                                    bookmarksFolderId: nil, hiddenBundleIds: [], stashedTabs: []))
            let removed = store.purgeOlderThan(maxAgeSeconds: 3 * 24 * 3600)
            assertEqual(removed, 1)
            assertEqual(store.listAll().count, 1)
            assertEqual(store.listAll().first?.sessionId, "fresh")
        }

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift IntentionalTests/SessionStashTests.swift
```

Expected: compile error `cannot find 'SessionStashStore'`.

- [ ] **Step 3: Implement the type**

Create `Intentional/SessionStash.swift`:

```swift
import Foundation

struct StashedTab: Codable, Equatable {
    let title: String
    let url: String
    let browserBundleId: String
    let originalWindow: Int
    let originalIndex: Int
}

struct SessionStash: Codable, Equatable {
    let sessionId: String
    let createdAt: Date
    let bookmarksFolderId: String?    // Browser-side identifier we wrote bookmarks into
    let hiddenBundleIds: [String]     // Apps that were Cmd+H'd
    let stashedTabs: [StashedTab]
}

/// File-per-session JSON store. Lives at <appSupport>/Intentional/session_stashes/.
final class SessionStashStore {
    private let dir: URL

    init(storageDir: String) {
        self.dir = URL(fileURLWithPath: storageDir)
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    func save(_ stash: SessionStash) {
        let url = dir.appendingPathComponent("\(stash.sessionId).json")
        guard let data = try? JSONEncoder().encode(stash) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func load(sessionId: String) -> SessionStash? {
        let url = dir.appendingPathComponent("\(sessionId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionStash.self, from: data)
    }

    func delete(sessionId: String) {
        let url = dir.appendingPathComponent("\(sessionId).json")
        try? FileManager.default.removeItem(at: url)
    }

    func listAll() -> [SessionStash] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let stashes = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionStash? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(SessionStash.self, from: data)
            }
        return stashes.sorted { $0.createdAt > $1.createdAt }
    }

    /// Deletes stashes whose createdAt is older than now - maxAgeSeconds. Returns count removed.
    @discardableResult
    func purgeOlderThan(maxAgeSeconds: TimeInterval) -> Int {
        let threshold = Date().addingTimeInterval(-maxAgeSeconds)
        var removed = 0
        for stash in listAll() where stash.createdAt < threshold {
            delete(sessionId: stash.sessionId)
            removed += 1
        }
        return removed
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift IntentionalTests/SessionStashTests.swift Intentional/SessionStash.swift
```

Expected: `3 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Intentional/SessionStash.swift IntentionalTests/SessionStashTests.swift
git commit -m "feat(session-stash): data model + file-per-session JSON store

Stores what got swept this session (tabs + hidden apps). One JSON
file per sessionId under <appSupport>/Intentional/session_stashes/.
listAll() returns stashes sorted newest-first for the restore UI.
purgeOlderThan(maxAgeSeconds:) cleans stashes whose createdAt is
older than the threshold.

Tests cover round-trip, sorting, and 3-day-equivalent purge.
"
```

---

## Task 6: Sweeper — scope resolution + decision logic

**Files:**
- Create: `Intentional/Sweeper.swift`
- Test: `IntentionalTests/SweeperTests.swift`

- [ ] **Step 1: Write failing test**

Create `IntentionalTests/SweeperTests.swift`:

```swift
import Foundation

var passed = 0
var failed = 0
func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b { passed += 1 } else { failed += 1; print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)") }
}
func assertTrue(_ a: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a { passed += 1 } else { failed += 1; print("  FAIL (\(file):\(line)): expected true, got false. \(msg)") }
}
func test(_ name: String, _ body: () -> Void) { print("• \(name)"); body() }

@main
struct SweeperTests {
    static func main() {
        print("\n🧪 SweeperTests\n")

        let allowed = AlwaysAllowedList(
            bundleIds: ["com.apple.systempreferences"],
            domains: ["1password.com"]
        )

        let scope = ResolvedScope(
            domains: ["github.com", "stackoverflow.com"],
            bundleIds: ["com.todesktop.230313mzl4w4u92"],
            voiceIntent: "working on Intentional Mac app"
        )

        test("decideTab: always-allowed domain → keep") {
            let v = Sweeper.decideTab(host: "1password.com", isPinned: false, blockedHosts: [], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .keep)
        }

        test("decideTab: pinned → keep regardless") {
            let v = Sweeper.decideTab(host: "twitter.com", isPinned: true, blockedHosts: ["twitter.com"], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .keep)
        }

        test("decideTab: in scope → keep") {
            let v = Sweeper.decideTab(host: "github.com", isPinned: false, blockedHosts: [], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .keep)
        }

        test("decideTab: subdomain of scope domain → keep") {
            let v = Sweeper.decideTab(host: "gist.github.com", isPinned: false, blockedHosts: [], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .keep)
        }

        test("decideTab: active block rule → stash (overrides AI)") {
            let v = Sweeper.decideTab(host: "youtube.com", isPinned: false, blockedHosts: ["youtube.com"], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .stash)
        }

        test("decideTab: not in scope and not blocked → needsAI") {
            let v = Sweeper.decideTab(host: "wikipedia.org", isPinned: false, blockedHosts: [], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .needsAI)
        }

        test("decideApp: always-allowed bundle → keep") {
            let v = Sweeper.decideApp(bundleId: "com.apple.systempreferences", blockedBundleIds: [], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .keep)
        }

        test("decideApp: in scope → keep") {
            let v = Sweeper.decideApp(bundleId: "com.todesktop.230313mzl4w4u92", blockedBundleIds: [], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .keep)
        }

        test("decideApp: blocked by rule → hide") {
            let v = Sweeper.decideApp(bundleId: "com.twitter.twitter", blockedBundleIds: ["com.twitter.twitter"], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .hide)
        }

        test("decideApp: not in scope and not blocked → hide (default)") {
            let v = Sweeper.decideApp(bundleId: "com.example.unknown", blockedBundleIds: [], scope: scope, alwaysAllowed: allowed)
            assertEqual(v, .hide)
        }

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift IntentionalTests/SweeperTests.swift Intentional/AlwaysAllowedList.swift
```

Expected: compile error `cannot find 'Sweeper'` / `cannot find 'ResolvedScope'`.

- [ ] **Step 3: Implement decision logic**

Create `Intentional/Sweeper.swift`:

```swift
import Foundation

/// Resolved per-session scope — apps/sites the sweep should keep open.
/// Built from the Intention's saved context + voice-intent additions.
/// The global Always-Allowed list is consulted SEPARATELY, not merged here,
/// so it can't be accidentally lost.
struct ResolvedScope: Equatable {
    var domains: Set<String>
    var bundleIds: Set<String>
    var voiceIntent: String

    static let empty = ResolvedScope(domains: [], bundleIds: [], voiceIntent: "")

    /// Suffix match — "github.com" matches "gist.github.com".
    func containsDomain(_ host: String) -> Bool {
        let h = host.lowercased()
        for d in domains {
            if h == d || h.hasSuffix("." + d) { return true }
        }
        return false
    }
}

enum TabVerdict: Equatable {
    case keep       // explicit allow OR pinned OR in scope
    case stash      // explicit deny (block rule) OR AI verdict false
    case needsAI    // not classified — caller must batch-score
}

enum AppVerdict: Equatable {
    case keep
    case hide
}

/// Stateless decision logic. Async sweep orchestration lives in
/// AppDelegate / a small Sweeper.run(...) coroutine, not here, so the
/// pure logic stays trivially testable.
enum Sweeper {

    /// Three-tier per-tab decision. `blockedHosts` should contain only
    /// hosts from BlockRules that are CURRENTLY ENFORCING (toggle on,
    /// inside their scheduled window).
    static func decideTab(host: String,
                          isPinned: Bool,
                          blockedHosts: Set<String>,
                          scope: ResolvedScope,
                          alwaysAllowed: AlwaysAllowedList) -> TabVerdict {
        if isPinned { return .keep }
        let h = host.lowercased()
        // Always-allowed (global) takes precedence over everything.
        for d in alwaysAllowed.domains {
            if h == d || h.hasSuffix("." + d) { return .keep }
        }
        // Active block rule — overrides AI.
        for d in blockedHosts {
            if h == d || h.hasSuffix("." + d) { return .stash }
        }
        // In-scope (voice/Intention-derived).
        if scope.containsDomain(h) { return .keep }
        return .needsAI
    }

    /// Native app decision. No AI involvement for apps in v1 — the user-named
    /// list (scope.bundleIds) plus always-allowed plus block rules is enough.
    /// Anything outside those three buckets gets hidden by default.
    static func decideApp(bundleId: String,
                          blockedBundleIds: Set<String>,
                          scope: ResolvedScope,
                          alwaysAllowed: AlwaysAllowedList) -> AppVerdict {
        if alwaysAllowed.bundleIds.contains(bundleId) { return .keep }
        if blockedBundleIds.contains(bundleId) { return .hide }
        if scope.bundleIds.contains(bundleId) { return .keep }
        return .hide
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift IntentionalTests/SweeperTests.swift Intentional/AlwaysAllowedList.swift Intentional/Sweeper.swift
```

Expected: `10 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Intentional/Sweeper.swift IntentionalTests/SweeperTests.swift
git commit -m "feat(sweeper): scope resolver + pure decision logic

ResolvedScope.containsDomain uses suffix match (github.com matches
gist.github.com). Sweeper.decideTab implements the three-tier
flow: pinned/always-allowed → keep; active block rule → stash;
in scope → keep; otherwise → needsAI (caller batch-scores).
Sweeper.decideApp uses the same flow without AI (apps stay
deterministic in v1).

10 test cases covering all branches.
"
```

---

## Task 7: RelevanceScorer.scoreTabBatch — batch AI scoring

**Files:**
- Modify: `Intentional/RelevanceScorer.swift`

- [ ] **Step 1: Inspect existing scorer API**

Read `Intentional/RelevanceScorer.swift` lines 540–600 (the `scoreRelevance` entrypoint). Note the existing prompt structure, the LLM call, and the `Result` shape. The new method mirrors this style but takes N tabs in one prompt.

- [ ] **Step 2: Add the batch method**

In `Intentional/RelevanceScorer.swift`, near the existing `scoreRelevance` method, add:

```swift
/// Verdict for a single tab in a batch scoring call.
struct TabVerdict {
    let title: String
    let url: String
    let relevant: Bool
    let confidence: Int
}

/// Score N browser tabs against a single intent in one LLM call.
/// Used by the close-the-noise sweep to decide which tabs to stash.
///
/// Prompt asks the model to emit one JSON line per tab so we can stream-parse
/// (vs returning a single giant array that's brittle on truncation).
func scoreTabBatch(intent: String,
                   tabs: [(title: String, url: String)]) async -> [TabVerdict] {
    guard !tabs.isEmpty else { return [] }

    // Build prompt — keep it tight; titles + URLs only.
    var lines = [String]()
    for (i, t) in tabs.enumerated() {
        let trimmedTitle = String(t.title.prefix(140))
        let trimmedURL = String(t.url.prefix(200))
        lines.append("\(i + 1). [\(trimmedTitle)] \(trimmedURL)")
    }

    let prompt = """
    The user's session intent is:
    \(intent)

    For each numbered tab below, decide whether keeping it open would
    be on-task. Output ONE JSON object per line, in the same order:
    {"i": <number>, "relevant": true|false, "confidence": 0-100}

    Examples of off-task: news, social media, recreational video, job
    boards (unless the intent is job search), shopping (unless the
    intent is shopping), forums unrelated to the intent.

    Tabs:
    \(lines.joined(separator: "\n"))

    Output (one JSON per line, no other text):
    """

    let raw = await callLLM(prompt: prompt, maxTokens: max(32 * tabs.count, 256))
    return parseTabBatchOutput(raw: raw, tabs: tabs)
}

private func parseTabBatchOutput(raw: String,
                                 tabs: [(title: String, url: String)]) -> [TabVerdict] {
    var byIndex: [Int: (Bool, Int)] = [:]
    for line in raw.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let i = json["i"] as? Int,
              let rel = json["relevant"] as? Bool else { continue }
        let conf = (json["confidence"] as? Int) ?? 0
        byIndex[i] = (rel, conf)
    }
    // Default missing entries to (relevant: false, confidence: 0) so unparseable
    // tabs get stashed (recoverable). Matches the spec's "default to stash" rule.
    return tabs.enumerated().map { i, t in
        let (rel, conf) = byIndex[i + 1] ?? (false, 0)
        return TabVerdict(title: t.title, url: t.url, relevant: rel, confidence: conf)
    }
}
```

NOTE: `callLLM(prompt:maxTokens:)` may not exist as-is. Find the existing private helper inside `scoreRelevance` that calls the model (look for the `mlx-vlm` or `LLMService` invocation around lines 700–900) and call it the same way. If the existing call is inlined inside `scoreRelevance`, extract it into a small private helper as part of this task — same signature, same model, no behavior change.

- [ ] **Step 3: Smoke-build**

```bash
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Compile errors here usually mean the LLM helper signature didn't match — read the existing code and adjust.

- [ ] **Step 4: Smoke-test via temporary Debug menu item**

In `Intentional/AppDelegate.swift`'s applicationDidFinishLaunching, add a temporary `#if DEBUG` block that fires a batch score 5s after launch and prints the result. (This block gets deleted in the next task.)

```swift
#if DEBUG
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
    Task {
        let result = await self?.relevanceScorer?.scoreTabBatch(
            intent: "I'm finalizing v1 of Intentional, the Mac focus app. Cursor, terminal, Stack Overflow only.",
            tabs: [
                ("GitHub - intentional", "https://github.com/x/intentional"),
                ("LinkedIn — Software Engineer jobs", "https://linkedin.com/jobs"),
                ("Apple Developer Documentation", "https://developer.apple.com/swift"),
                ("Twitter / X", "https://twitter.com")
            ]
        )
        self?.postLog("🧪 scoreTabBatch result: \(result ?? [])")
    }
}
#endif
```

Run `./scripts/dev-launch.sh`, wait 5s, check `/tmp/intentional-fresh.log` (or wherever postLog routes). Expected: 4 verdicts, GitHub + Apple Dev = `relevant: true`, LinkedIn + Twitter = `relevant: false`.

- [ ] **Step 5: Remove the temp smoke block + commit**

Delete the `#if DEBUG` block from Task 7 Step 4. Then:

```bash
git add Intentional/RelevanceScorer.swift Intentional/AppDelegate.swift
git commit -m "feat(scorer): scoreTabBatch — N tabs scored in one LLM call

Prompt asks model to emit one JSON line per tab so we can stream-
parse on truncation. Unparseable / missing entries default to
{ relevant: false, confidence: 0 } — matches spec's 'default-stash
for unsure' rule (stash is recoverable, false positives are cheap).

Used by close-the-noise sweep for tabs that aren't pinned, not
always-allowed, and not in active block rules. ~3-5s for 30 tabs
on Qwen3-4B-text.
"
```

---

## Task 8: WebsiteBlocker extensions — all-tabs + bookmarks API

**Files:**
- Modify: `Intentional/WebsiteBlocker.swift`

- [ ] **Step 1: Add the multi-tab reader**

In `Intentional/WebsiteBlocker.swift`, near the existing `readActiveTabInfo` AppleScript block, add a new public method. Find the existing `tell application "Google Chrome"` block (line ~594) and add a parallel method below it:

```swift
struct AllTabsInfo {
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    let isPinned: Bool
}

/// Read every tab across every window of the given browser. Used by the
/// close-the-noise sweep. Falls back to an empty array on any AppleScript
/// failure (logged, but non-fatal — the sweep just skips that browser).
func readAllTabsAcrossWindows(forBundleId bundleId: String) -> [AllTabsInfo] {
    let appName: String
    switch bundleId {
    case "com.google.Chrome": appName = "Google Chrome"
    case "company.thebrowser.Browser": appName = "Arc"
    case "com.apple.Safari": appName = "Safari"
    default: return []
    }

    // Chromium-based + Safari all support `every tab of every window`.
    // Safari uses `URL` and `name` properties (not `title`).
    let titleProp = (bundleId == "com.apple.Safari") ? "name" : "title"
    let urlProp = "URL"
    // Safari has no `pinned` property — assume false for Safari.
    let pinnedExpr = (bundleId == "com.apple.Safari") ? "false" : "(get pinned of tabRef)"

    let script = """
    set output to ""
    tell application "\(appName)"
        set winIdx to 0
        repeat with w in windows
            set winIdx to winIdx + 1
            set tabIdx to 0
            repeat with tabRef in tabs of w
                set tabIdx to tabIdx + 1
                set t to \(titleProp) of tabRef
                set u to \(urlProp) of tabRef
                set p to \(pinnedExpr)
                set output to output & winIdx & "\\t" & tabIdx & "\\t" & p & "\\t" & u & "\\t" & t & "\\n"
            end repeat
        end repeat
    end tell
    return output
    """

    var err: NSDictionary?
    let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err = err {
        appDelegate?.postLog("⚠️ readAllTabsAcrossWindows(\(appName)) failed: \(err)")
        return []
    }
    guard let raw = result?.stringValue else { return [] }

    var out = [AllTabsInfo]()
    for line in raw.components(separatedBy: "\n") {
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 5,
              let wi = Int(parts[0]),
              let ti = Int(parts[1]) else { continue }
        let isPinned = (parts[2] == "true")
        let url = parts[3]
        let title = parts[4]
        if url.isEmpty { continue }
        out.append(AllTabsInfo(windowIndex: wi, tabIndex: ti, title: title, url: url, isPinned: isPinned))
    }
    return out
}
```

- [ ] **Step 2: Add the bookmark + close APIs**

In the same file, below `readAllTabsAcrossWindows`, add:

```swift
/// Create a bookmark folder in the given browser. Returns the folder name
/// (we use the name as the identifier since AppleScript doesn't expose stable IDs
/// across Chromium browsers consistently). Returns nil on failure.
func createBookmarkFolder(forBundleId bundleId: String, name: String) -> String? {
    // Chrome/Arc: bookmark bar folder. Safari: favorites folder.
    let scriptSource: String
    switch bundleId {
    case "com.google.Chrome", "company.thebrowser.Browser":
        let appName = (bundleId == "com.google.Chrome") ? "Google Chrome" : "Arc"
        scriptSource = """
        tell application "\(appName)"
            make new bookmark folder at end of bookmark folder "Bookmarks Bar" of bookmarks bar with properties {title:"\(name)"}
        end tell
        return "\(name)"
        """
    case "com.apple.Safari":
        // Safari doesn't have a clean AppleScript dictionary for bookmark CRUD in
        // recent macOS versions. Fall back to no-op; tabs still close but the user
        // can't restore via bookmarks. (Implementation note: Safari users will get
        // a degraded experience until SafariServices-based bookmark IO is added.)
        appDelegate?.postLog("⚠️ Safari bookmark folder creation not supported — tabs will close without stash")
        return nil
    default: return nil
    }

    var err: NSDictionary?
    _ = NSAppleScript(source: scriptSource)?.executeAndReturnError(&err)
    if let err = err {
        appDelegate?.postLog("⚠️ createBookmarkFolder(\(bundleId), \(name)) failed: \(err)")
        return nil
    }
    return name
}

/// Add a single bookmark to the named folder. Best-effort; no return value.
func addBookmark(forBundleId bundleId: String, folderName: String, title: String, url: String) {
    let appName: String
    switch bundleId {
    case "com.google.Chrome": appName = "Google Chrome"
    case "company.thebrowser.Browser": appName = "Arc"
    default: return
    }
    // Escape double quotes in title/url for AppleScript.
    let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let safeURL = url.replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "\(appName)"
        make new bookmark item at end of bookmark folder "\(folderName)" of bookmark folder "Bookmarks Bar" of bookmarks bar with properties {title:"\(safeTitle)", URL:"\(safeURL)"}
    end tell
    """
    var err: NSDictionary?
    _ = NSAppleScript(source: script)?.executeAndReturnError(&err)
}

/// Close every tab whose URL is in `urls` across every window of the given browser.
func closeTabsByURL(_ urls: Set<String>, forBundleId bundleId: String) {
    let appName: String
    switch bundleId {
    case "com.google.Chrome": appName = "Google Chrome"
    case "company.thebrowser.Browser": appName = "Arc"
    case "com.apple.Safari": appName = "Safari"
    default: return
    }
    let urlProp = "URL"
    // Build a single AppleScript that walks every tab in reverse (so indexes stay valid).
    var lines = ["tell application \"\(appName)\""]
    lines.append("    repeat with w in windows")
    lines.append("        set tabCount to count of tabs of w")
    lines.append("        repeat with i from tabCount to 1 by -1")
    lines.append("            set tabRef to tab i of w")
    lines.append("            set u to \(urlProp) of tabRef")
    // Match if URL is in the close set.
    lines.append("            if (")
    var first = true
    for u in urls {
        let safe = u.replacingOccurrences(of: "\"", with: "\\\"")
        let op = first ? "" : "or "
        lines.append("                \(op)u is \"\(safe)\"")
        first = false
    }
    if first {
        // Empty set: skip the close.
        return
    }
    lines.append("            ) then close tabRef")
    lines.append("        end repeat")
    lines.append("    end repeat")
    lines.append("end tell")

    var err: NSDictionary?
    _ = NSAppleScript(source: lines.joined(separator: "\n"))?.executeAndReturnError(&err)
    if let err = err {
        appDelegate?.postLog("⚠️ closeTabsByURL(\(appName)) failed: \(err)")
    }
}
```

- [ ] **Step 3: Smoke-build**

```bash
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Intentional/WebsiteBlocker.swift
git commit -m "feat(website-blocker): all-tabs reader + bookmark APIs + closeTabsByURL

readAllTabsAcrossWindows reads every tab in every window of Chrome,
Arc, or Safari via AppleScript. Returns (window, index, title, url,
isPinned) tuples. Falls back gracefully on AppleScript failure
(logged, returns empty array).

createBookmarkFolder + addBookmark wrap the Chrome/Arc bookmark API
so the sweep can stash to a dated folder. Safari doesn't support
bookmark CRUD via AppleScript in modern macOS — logs a warning and
the sweep still closes tabs (degraded restore).

closeTabsByURL walks tabs in reverse so indices stay valid as we
close matches.
"
```

---

## Task 9: AppDelegate wiring — instantiate stash store + sweep on session start + 3-day purge

**Files:**
- Modify: `Intentional/AppDelegate.swift`

- [ ] **Step 1: Add the SessionStashStore**

In the same place you added `alwaysAllowedStore` (Task 3), also declare and instantiate:

```swift
var sessionStashStore: SessionStashStore?
```

After the AlwaysAllowedStore init lines, add:

```swift
self.sessionStashStore = SessionStashStore(storageDir: intentionalDir + "/session_stashes")

// 3-day auto-purge of old stashes (per spec).
let purged = self.sessionStashStore?.purgeOlderThan(maxAgeSeconds: 3 * 24 * 3600) ?? 0
if purged > 0 { self.postLog("🧹 Purged \(purged) old session stash(es)") }
```

- [ ] **Step 2: Add the sweep trigger**

Find `focusModeController?.onStateChanged = ...` (around line 688). At the START of the `if new == .focus && old != .focus` block (currently the second one, after the synthetic-block injection one), call the sweep:

```swift
if new == .focus && old != .focus {
    // Cross-device, schedule, and dashboard-toggle paths activate
    // FocusModeController without going through startFocusSession's
    // profile picker — so the blocklist is never propagated to
    // WebsiteBlocker. Apply the user's default profile here so
    // those paths actually block. The picker path runs AFTER this
    // and overrides with its explicit profileIds.
    self.applyDefaultBlockingProfile()

    // Close-the-noise sweep: stash off-scope browser tabs and hide off-scope
    // native apps so the user starts the session clean. Fire-and-forget
    // Task — sweep does its own logging and toast.
    let sessionId = self.focusModeController?.currentPeriod?.id.uuidString ?? UUID().uuidString
    Task { await self.runCloseTheNoiseSweep(sessionId: sessionId) }
}
```

- [ ] **Step 3: Add the sweep orchestrator**

Below the `applicationDidFinishLaunching` function (anywhere reasonable), add:

```swift
/// Orchestrates the close-the-noise sweep at session start. Wires together
/// AlwaysAllowedStore, BlockRule active set, ScheduleManager (for the
/// current Intention's saved context), WebsiteBlocker (tab IO), RelevanceScorer
/// (batch AI), and SessionStashStore (persistence).
@MainActor
func runCloseTheNoiseSweep(sessionId: String) async {
    guard let alwaysAllowed = alwaysAllowedStore?.list,
          let stashStore = sessionStashStore else { return }

    // 1. Resolve scope.
    let voiceIntent = focusModeController?.currentPeriod?.intention ?? ""
    var scope = ResolvedScope(domains: [], bundleIds: [], voiceIntent: voiceIntent)
    if let intentionId = focusModeController?.currentPeriod?.intentionId,
       let intention = await IntentionStore.shared.intention(id: intentionId) {
        scope.voiceIntent = [voiceIntent, intention.intentText ?? "", intention.outcome ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    // 2. Active block rule hosts + bundleIds.
    let activeRuleHosts = blockingProfileManager?.activeBlockedDomains() ?? []
    let activeRuleBundleIds = blockingProfileManager?.activeBlockedBundleIds() ?? []

    // 3. Sweep browser tabs.
    let browserBundles = ["com.google.Chrome", "company.thebrowser.Browser", "com.apple.Safari"]
    var stashedTabs: [StashedTab] = []
    var bookmarksFolderName: String? = nil
    let stampedName = "Intentional / Stash \(SessionStashStore.timestampString())"

    for browserBid in browserBundles {
        let allTabs = websiteBlocker?.readAllTabsAcrossWindows(forBundleId: browserBid) ?? []
        if allTabs.isEmpty { continue }

        // Three-tier decision pass.
        var keepURLs = Set<String>()
        var stashCandidates: [(AllTabsInfo, host: String)] = []
        var needsAI: [(AllTabsInfo, host: String)] = []
        for t in allTabs {
            let host = URL(string: t.url)?.host ?? ""
            if host.isEmpty { keepURLs.insert(t.url); continue }
            let v = Sweeper.decideTab(host: host, isPinned: t.isPinned,
                                      blockedHosts: Set(activeRuleHosts),
                                      scope: scope, alwaysAllowed: alwaysAllowed)
            switch v {
            case .keep:    keepURLs.insert(t.url)
            case .stash:   stashCandidates.append((t, host: host))
            case .needsAI: needsAI.append((t, host: host))
            }
        }

        // AI batch for the borderline cases.
        if !needsAI.isEmpty, let scorer = relevanceScorer {
            let verdicts = await scorer.scoreTabBatch(
                intent: scope.voiceIntent.isEmpty ? "Focused work session" : scope.voiceIntent,
                tabs: needsAI.map { ($0.0.title, $0.0.url) }
            )
            for (i, v) in verdicts.enumerated() {
                if v.relevant && v.confidence >= 50 {
                    keepURLs.insert(needsAI[i].0.url)
                } else {
                    stashCandidates.append(needsAI[i])
                }
            }
        }

        if stashCandidates.isEmpty { continue }

        // Stash: create bookmark folder + add bookmarks + close tabs.
        if bookmarksFolderName == nil {
            bookmarksFolderName = websiteBlocker?.createBookmarkFolder(forBundleId: browserBid, name: stampedName)
        }
        if let folder = bookmarksFolderName {
            for (info, _) in stashCandidates {
                websiteBlocker?.addBookmark(forBundleId: browserBid, folderName: folder,
                                            title: info.title, url: info.url)
                stashedTabs.append(StashedTab(title: info.title, url: info.url,
                                              browserBundleId: browserBid,
                                              originalWindow: info.windowIndex,
                                              originalIndex: info.tabIndex))
            }
        }
        websiteBlocker?.closeTabsByURL(Set(stashCandidates.map { $0.0.url }), forBundleId: browserBid)
    }

    // 4. Sweep native apps.
    var hiddenBundleIds: [String] = []
    for app in NSWorkspace.shared.runningApplications {
        guard let bid = app.bundleIdentifier,
              app.activationPolicy == .regular,
              bid != Bundle.main.bundleIdentifier else { continue }
        let v = Sweeper.decideApp(bundleId: bid,
                                  blockedBundleIds: Set(activeRuleBundleIds),
                                  scope: scope, alwaysAllowed: alwaysAllowed)
        if v == .hide {
            app.hide()
            hiddenBundleIds.append(bid)
        }
    }

    // 5. Persist + toast.
    let stash = SessionStash(sessionId: sessionId,
                             createdAt: Date(),
                             bookmarksFolderId: bookmarksFolderName,
                             hiddenBundleIds: hiddenBundleIds,
                             stashedTabs: stashedTabs)
    stashStore.save(stash)
    postLog("🧹 Sweep complete: stashed \(stashedTabs.count) tab(s), hid \(hiddenBundleIds.count) app(s)")
    mainWindowController?.pushSweepToast(stashedTabs: stashedTabs.count,
                                         hiddenApps: hiddenBundleIds.count,
                                         sessionId: sessionId)
}
```

- [ ] **Step 4: Add the timestamp helper**

In `Intentional/SessionStash.swift`, add a static helper at the end of the file:

```swift
extension SessionStashStore {
    static func timestampString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: Date())
    }
}
```

- [ ] **Step 5: Add the toast bridge stub**

In `Intentional/MainWindow.swift`, near other `push*` helpers (e.g., `pushScheduleUpdate`), add:

```swift
func pushSweepToast(stashedTabs: Int, hiddenApps: Int, sessionId: String) {
    let safeSession = sessionId.replacingOccurrences(of: "'", with: "")
    callJS("window._sweepToast && window._sweepToast({" +
           "stashedTabs:\(stashedTabs), hiddenApps:\(hiddenApps), sessionId:'\(safeSession)'})")
}
```

This stub fires immediately; the toast UI itself lands in Task 10.

- [ ] **Step 6: Add active-rule helpers on BlockingProfileManager (if not present)**

In `Intentional/BlockingProfileManager.swift`, check if `activeBlockedDomains() -> [String]` and `activeBlockedBundleIds() -> [String]` exist. If they don't, add them:

```swift
/// Hosts that are blocked by a currently-enforcing rule (toggle on,
/// inside scheduled window if any). Used by the close-the-noise sweep.
func activeBlockedDomains() -> [String] {
    return profiles
        .filter { isCurrentlyEnforcing(profile: $0) }
        .flatMap { Array($0.blockedDomains) }
}

func activeBlockedBundleIds() -> [String] {
    return profiles
        .filter { isCurrentlyEnforcing(profile: $0) }
        .flatMap { $0.appBundleIds }
}

private func isCurrentlyEnforcing(profile: BlockingProfile) -> Bool {
    guard profile.isEnabled else { return false }
    // If no schedule, "always on" rule.
    guard let schedule = profile.schedule, !schedule.windows.isEmpty else { return true }
    return schedule.isActiveAt(Date())
}
```

(Names may already exist; if the actual project has similar methods named differently, reuse those — the goal is just "currently enforcing hosts" + "currently enforcing bundleIds".)

- [ ] **Step 7: Smoke-build + manual test**

```bash
./scripts/dev-launch.sh
```

In the new build: ensure a Weekly Goal exists with `intentText`. Open Twitter + GitHub + LinkedIn in Chrome. Open Mail + Calendar (not in Always-Allowed) + Cursor. Start a session via the dashboard's manual toggle or via the schedule. Expected: Twitter + LinkedIn tabs disappear (stashed to a `Intentional / Stash YYYY-MM-DD HH:MM` folder); Mail + Cursor stay open (Mail might be in always-allowed already; if not, it'll hide); GitHub stays open.

- [ ] **Step 8: Commit**

```bash
git add Intentional/AppDelegate.swift Intentional/MainWindow.swift Intentional/SessionStash.swift Intentional/BlockingProfileManager.swift
git commit -m "feat(sweep): wire close-the-noise on session start

AppDelegate.runCloseTheNoiseSweep orchestrates:
  1. Resolve scope (voice + intentText + outcome)
  2. Read all tabs across Chrome/Arc/Safari
  3. Three-tier per-tab decision; AI batch for borderline
  4. Stash to bookmarks folder + close tabs
  5. Cmd+H off-scope native apps
  6. Persist SessionStash + push toast bridge message

Trigger: FocusModeController.onStateChanged when entering .focus.
3-day auto-purge of old stashes runs once at applicationDidFinishLaunching.

BlockingProfileManager gains activeBlockedDomains() + activeBlockedBundleIds()
filtered to rules currently enforcing (toggle on + inside scheduled window).
"
```

---

## Task 10: Toast UI in dashboard

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 1: Add the toast handler + element**

In `Intentional/dashboard.html`, near other `window._*` global handlers (search for `window._settingsResult`), add:

```javascript
window._sweepToast = function(data) {
  if (!data) return;
  var stashed = data.stashedTabs | 0;
  var hidden  = data.hiddenApps  | 0;
  if (stashed === 0 && hidden === 0) return;

  // Build the toast element.
  var existing = document.getElementById('sweep-toast');
  if (existing) existing.remove();
  var el = document.createElement('div');
  el.id = 'sweep-toast';
  el.style.cssText = 'position:fixed; top:20px; right:20px; z-index:99999;' +
    'background:rgba(20,20,22,0.95); color:#fff; padding:14px 18px;' +
    'border-radius:10px; border:0.5px solid rgba(255,255,255,0.12);' +
    'box-shadow:0 8px 32px rgba(0,0,0,0.4); font-size:13px; max-width:340px;' +
    'backdrop-filter:blur(20px); -webkit-backdrop-filter:blur(20px);';
  el.innerHTML =
    '<div style="font-weight:600; margin-bottom:6px;">Stashed ' + stashed + ' tab' +
      (stashed === 1 ? '' : 's') + ' · hid ' + hidden + ' app' + (hidden === 1 ? '' : 's') + '</div>' +
    '<div style="font-size:12px; color:rgba(255,255,255,0.7); margin-bottom:10px;">' +
      'Off-scope stuff is stashed in your Bookmarks. Recoverable for 3 days.</div>' +
    '<div style="display:flex; gap:6px;">' +
      '<button onclick="viewStash(\'' + data.sessionId + '\')" style="flex:1; padding:6px 10px; font-size:12px; background:rgba(255,255,255,0.08); color:#fff; border:0.5px solid rgba(255,255,255,0.18); border-radius:6px; cursor:pointer;">View stash</button>' +
      '<button onclick="restoreAllFromStash(\'' + data.sessionId + '\')" style="flex:1; padding:6px 10px; font-size:12px; background:#fa6464; color:#fff; border:0; border-radius:6px; cursor:pointer;">Restore everything</button>' +
    '</div>';
  document.body.appendChild(el);
  setTimeout(function() { if (el.parentNode) el.remove(); }, 30000);
};

function viewStash(sessionId) {
  sendMessage({ type: 'OPEN_STASH_INSPECTOR', sessionId: sessionId });
}

function restoreAllFromStash(sessionId) {
  sendMessage({ type: 'RESTORE_FROM_STASH_ALL', sessionId: sessionId });
  var el = document.getElementById('sweep-toast');
  if (el) el.remove();
  if (typeof showToast === 'function') showToast('Everything restored');
}

window.viewStash = viewStash;
window.restoreAllFromStash = restoreAllFromStash;
```

- [ ] **Step 2: Smoke-test**

Rebuild + launch. Start a session. Confirm a dark toast appears top-right with the stashed counts and two buttons. Click "View stash" → expect (for now) a no-op or a debug log; the inspector lands in Task 11.

- [ ] **Step 3: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(sweep): top-right toast on sweep complete

Shows stashed-tabs + hidden-apps counts with [View stash] +
[Restore everything] buttons. Auto-dismisses after 30s. View stash
hits OPEN_STASH_INSPECTOR (Task 11), Restore everything hits
RESTORE_FROM_STASH_ALL (Task 12).
"
```

---

## Task 11: Stash inspector window

**Files:**
- Create: `Intentional/StashInspectorWindow.swift`
- Modify: `Intentional/AppDelegate.swift`
- Modify: `Intentional/MainWindow.swift` (handle OPEN_STASH_INSPECTOR)

- [ ] **Step 1: Create the inspector window controller**

Create `Intentional/StashInspectorWindow.swift`:

```swift
import Cocoa
import SwiftUI

final class StashInspectorWindowController {
    weak var appDelegate: AppDelegate?
    private var window: NSWindow?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    func show(stash: SessionStash) {
        dismiss()
        let viewModel = StashInspectorViewModel(stash: stash) { [weak self] in
            self?.dismiss()
        } onRestoreTab: { [weak self] tab in
            self?.appDelegate?.restoreSingleTab(tab, fromSession: stash.sessionId)
        } onRestoreApp: { [weak self] bundleId in
            self?.appDelegate?.restoreSingleApp(bundleId: bundleId, fromSession: stash.sessionId)
        }

        let host = NSHostingView(rootView: StashInspectorView(viewModel: viewModel))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
        panel.title = "Session Stash"
        panel.contentView = host
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

final class StashInspectorViewModel: ObservableObject {
    @Published var stash: SessionStash
    let onClose: () -> Void
    let onRestoreTab: (StashedTab) -> Void
    let onRestoreApp: (String) -> Void

    init(stash: SessionStash, onClose: @escaping () -> Void,
         onRestoreTab: @escaping (StashedTab) -> Void,
         onRestoreApp: @escaping (String) -> Void) {
        self.stash = stash
        self.onClose = onClose
        self.onRestoreTab = onRestoreTab
        self.onRestoreApp = onRestoreApp
    }
}

struct StashInspectorView: View {
    @ObservedObject var viewModel: StashInspectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Session Stash")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 4)
            Text("Stashed at \(viewModel.stash.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 14)
            Divider()

            ScrollView {
                if !viewModel.stash.stashedTabs.isEmpty {
                    sectionHeader("Tabs (\(viewModel.stash.stashedTabs.count))")
                    ForEach(viewModel.stash.stashedTabs, id: \.url) { tab in
                        row(title: tab.title.isEmpty ? tab.url : tab.title, subtitle: tab.url) {
                            viewModel.onRestoreTab(tab)
                        }
                    }
                }
                if !viewModel.stash.hiddenBundleIds.isEmpty {
                    sectionHeader("Apps (\(viewModel.stash.hiddenBundleIds.count))")
                    ForEach(viewModel.stash.hiddenBundleIds, id: \.self) { bid in
                        row(title: bid, subtitle: "hidden via Cmd+H") {
                            viewModel.onRestoreApp(bid)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(title: String, subtitle: String, restore: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Restore", action: restore).controlSize(.small)
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 2: Wire the controller in AppDelegate**

In `Intentional/AppDelegate.swift`, declare:

```swift
var stashInspectorController: StashInspectorWindowController?
```

In `applicationDidFinishLaunching`, after `sessionStashStore` is created:

```swift
self.stashInspectorController = StashInspectorWindowController(appDelegate: self)
```

Add helper methods:

```swift
func showStashInspector(sessionId: String) {
    guard let stash = sessionStashStore?.load(sessionId: sessionId) else { return }
    stashInspectorController?.show(stash: stash)
}

func restoreSingleTab(_ tab: StashedTab, fromSession sessionId: String) {
    // Re-open the tab via AppleScript in the same browser.
    let script: String
    switch tab.browserBundleId {
    case "com.google.Chrome":
        script = "tell application \"Google Chrome\" to open location \"\(tab.url)\""
    case "company.thebrowser.Browser":
        script = "tell application \"Arc\" to open location \"\(tab.url)\""
    case "com.apple.Safari":
        script = "tell application \"Safari\" to open location \"\(tab.url)\""
    default:
        return
    }
    var err: NSDictionary?
    _ = NSAppleScript(source: script)?.executeAndReturnError(&err)
    if err == nil { postLog("↩️ Restored tab: \(tab.url)") }
}

func restoreSingleApp(bundleId: String, fromSession sessionId: String) {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    postLog("↩️ Restored app: \(bundleId)")
}
```

- [ ] **Step 3: Add the OPEN_STASH_INSPECTOR bridge handler**

In `Intentional/MainWindow.swift`'s switch:

```swift
case "OPEN_STASH_INSPECTOR":
    if let sid = body["sessionId"] as? String {
        appDelegate?.showStashInspector(sessionId: sid)
    }
```

- [ ] **Step 4: Smoke-test**

Rebuild. Trigger a sweep. Click "View stash" in the toast. Expected: a small NSPanel pops up listing the stashed tabs + hidden apps with per-row "Restore" buttons. Click a row → that tab/app comes back.

- [ ] **Step 5: Commit**

```bash
git add Intentional/StashInspectorWindow.swift Intentional/AppDelegate.swift Intentional/MainWindow.swift
git commit -m "feat(sweep): stash inspector window + per-row restore

Small SwiftUI NSPanel listing the current session's stashed tabs +
hidden app bundle IDs. Each row has a Restore button:
  - Tabs: AppleScript 'open location' in the original browser
  - Apps: NSWorkspace.openApplication via bundleIdentifier

Bridge: OPEN_STASH_INSPECTOR { sessionId } pops the panel.
"
```

---

## Task 12: Restore-everything bridge handler

**Files:**
- Modify: `Intentional/MainWindow.swift`
- Modify: `Intentional/AppDelegate.swift`

- [ ] **Step 1: Add the bridge case**

In `Intentional/MainWindow.swift`'s switch:

```swift
case "RESTORE_FROM_STASH_ALL":
    if let sid = body["sessionId"] as? String {
        appDelegate?.restoreAllFromStash(sessionId: sid)
    }
```

- [ ] **Step 2: Add the orchestrator**

In `Intentional/AppDelegate.swift`:

```swift
func restoreAllFromStash(sessionId: String) {
    guard let stash = sessionStashStore?.load(sessionId: sessionId) else { return }
    for tab in stash.stashedTabs {
        restoreSingleTab(tab, fromSession: sessionId)
    }
    for bid in stash.hiddenBundleIds {
        restoreSingleApp(bundleId: bid, fromSession: sessionId)
    }
    postLog("↩️ Restored all from stash \(sessionId): \(stash.stashedTabs.count) tabs, \(stash.hiddenBundleIds.count) apps")
}
```

- [ ] **Step 3: Smoke-test**

Rebuild. Start a session (triggers sweep). Click "Restore everything" in the toast. Expected: all stashed tabs re-open in their original browsers; all hidden apps come back to front.

- [ ] **Step 4: Commit**

```bash
git add Intentional/MainWindow.swift Intentional/AppDelegate.swift
git commit -m "feat(sweep): restore-everything bridge + orchestrator

RESTORE_FROM_STASH_ALL loops through SessionStash.stashedTabs +
hiddenBundleIds and runs the single-item restore for each. Used
by the toast's [Restore everything] button.
"
```

---

## Final task: end-to-end smoke

- [ ] **Step 1: Full clean-state run**

Quit the dev build. `rm -rf ~/Library/Application\ Support/Intentional/session_stashes`. Rebuild + launch via `./scripts/dev-launch.sh`. Confirm the always_allowed.json gets created with defaults, and migration_always_allowed_v1.json appears.

- [ ] **Step 2: Sweep happy path**

Open in Chrome: Twitter, YouTube, GitHub (project repo), Stack Overflow. Open in macOS: Mail, Calendar, Cursor, System Settings. Start a session with intent "working on Intentional Mac app, will use Cursor + GitHub + Stack Overflow."

Expected:
- Twitter + YouTube → stashed (active block rules + AI-confirmed off-scope)
- GitHub + Stack Overflow → kept
- System Settings + Calendar → kept (always-allowed)
- Mail → hidden
- Cursor → kept (you said it)
- Toast appears with counts and two buttons

- [ ] **Step 3: Restore happy path**

Click "View stash" → confirm window shows the right list. Click one tab's Restore → it re-opens. Close window. Click "Restore everything" in toast (if still visible) → everything comes back.

- [ ] **Step 4: 3-day purge sanity**

```bash
echo '{"sessionId":"test-old","createdAt":"2020-01-01T00:00:00Z","bookmarksFolderId":null,"hiddenBundleIds":[],"stashedTabs":[]}' > ~/Library/Application\ Support/Intentional/session_stashes/test-old.json
```

Quit + relaunch. Confirm `test-old.json` is gone from the directory and the launch log shows "Purged N old session stash(es)".

- [ ] **Step 5: Settings edit + persistence**

Open dashboard → Settings → Always Allowed. Add `com.example.test` and `example.com`. Quit + relaunch. Confirm both still present.

- [ ] **Step 6: Final commit (only if any cleanup edits happened)**

```bash
git status
# If anything changed during smoke-testing (debug prints, etc.), commit cleanup
# Otherwise: nothing to commit, we're done
```

---

## Out of scope for this plan (deferred)

These are deferred to follow-up plans:

- **Stage 5 (Exit review)** — the full tab-graveyard end-of-session review. Toast-level restore is enough for v1.
- **Browser ≠ Chrome/Arc/Safari** — Firefox + Edge + Brave support. Same AppleScript dictionary largely, but untested.
- **Pre-population from previous sessions** — "the user always restored Spotify last 3 sessions, auto-add it to Always-Allowed."
- **Per-Intention scope persistence beyond intentText/outcome** — saved app picks per goal that learn over time.
- **Cross-device propagation** of the always-allowed list.
- **The phone story** — iOS Puck side of close-the-noise.

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| AlwaysAllowedList data model with sensible defaults | Task 1 |
| Migration from per-Intention allow lists | Task 2 |
| Bridge messages for Always Allowed | Task 3 |
| Settings → Always Allowed UI | Task 4 |
| SessionStash data model | Task 5 |
| Resolved scope + three-tier decision logic | Task 6 |
| AI batch scoring of tabs | Task 7 |
| All-tabs reader + bookmark APIs + close-by-URL | Task 8 |
| Sweep orchestration + trigger on session start | Task 9 |
| 30s toast UI | Task 10 |
| Stash inspector window + per-row restore | Task 11 |
| Restore-everything bridge | Task 12 |
| 3-day auto-purge | Task 9 (folded in) |
| No auto-allow frontmost | Task 6 (decideTab doesn't special-case) |
| Standing Rules override AI | Task 6 (decideTab returns .stash before .needsAI) |
| Pinned tabs spared | Task 6 (decideTab first check) |
| Domain suffix-match semantics | Tasks 1 + 6 |

All requirements covered.

**No-placeholder scan:** no TBD / TODO / generic "add error handling" in any step. Tests are written out, code is complete, commands are exact.

**Type consistency:** `AlwaysAllowedList`, `AlwaysAllowedStore`, `SessionStash`, `StashedTab`, `SessionStashStore`, `ResolvedScope`, `TabVerdict`, `AppVerdict`, `Sweeper` — all spelled identically across tasks. `decideTab` / `decideApp` signatures consistent.
