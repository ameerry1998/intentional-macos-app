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
