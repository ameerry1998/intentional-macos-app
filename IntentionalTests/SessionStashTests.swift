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
