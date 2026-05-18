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
