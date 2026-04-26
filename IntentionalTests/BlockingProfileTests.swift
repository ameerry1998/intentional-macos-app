import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)")
    }
}

func assertTrue(_ a: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(file):\(line)): expected true, got false. \(msg)")
    }
}

func assertFalse(_ a: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if !a {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(file):\(line)): expected false, got true. \(msg)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    print("  ▸ \(name)")
    body()
}

@main
struct BlockingProfileTests {
    static func main() {
        print("\n🧪 BlockingProfileTests\n")

        // Use a unique temp dir for each test run to avoid cross-contamination
        let testDir = "/tmp/blocking-profile-tests-\(UUID().uuidString)"

        // ── Test 1: default profile exists on init ──
        test("default profile exists on init") {
            let mgr = BlockingProfileManager(settingsDir: testDir + "/t1")
            assertEqual(mgr.profiles.count, 1, "should have exactly 1 profile on init")
            assertEqual(mgr.profiles[0].isDefault, true, "first profile should be default")
            assertEqual(mgr.profiles[0].name, "Distracting Apps & Sites")
        }

        // ── Test 2: default profile has social media domains ──
        test("default profile has social media domains") {
            let mgr = BlockingProfileManager(settingsDir: testDir + "/t2")
            let defaultProfile = mgr.profiles[0]
            assertTrue(defaultProfile.blockedDomains.contains("reddit.com"), "should contain reddit.com")
            assertTrue(defaultProfile.blockedDomains.contains("youtube.com"), "should contain youtube.com")
            assertTrue(defaultProfile.blockedDomains.contains("twitter.com"), "should contain twitter.com")
        }

        // ── Test 3: create custom profile ──
        test("create custom profile") {
            let mgr = BlockingProfileManager(settingsDir: testDir + "/t3")
            let custom = mgr.createProfile(
                name: "Work Focus",
                domains: ["news.ycombinator.com", "reddit.com"],
                appBundleIds: ["com.tinyspeck.slackmacgap"]
            )
            assertEqual(mgr.profiles.count, 2, "should have 2 profiles after create")
            assertEqual(custom.name, "Work Focus")
            assertEqual(custom.blockedDomains, ["news.ycombinator.com", "reddit.com"])
            assertEqual(custom.blockedAppBundleIds, ["com.tinyspeck.slackmacgap"])
            assertFalse(custom.isDefault, "custom profile should not be default")
        }

        // ── Test 4: delete custom profile ──
        test("delete custom profile") {
            let mgr = BlockingProfileManager(settingsDir: testDir + "/t4")
            let custom = mgr.createProfile(name: "Temp", domains: ["example.com"], appBundleIds: [])
            assertEqual(mgr.profiles.count, 2)
            let deleted = mgr.deleteProfile(id: custom.id)
            assertTrue(deleted, "deleteProfile should return true for custom profile")
            assertEqual(mgr.profiles.count, 1, "should be back to 1 after delete")
        }

        // ── Test 5: cannot delete default profile ──
        test("cannot delete default profile") {
            let mgr = BlockingProfileManager(settingsDir: testDir + "/t5")
            let defaultId = mgr.profiles[0].id
            let deleted = mgr.deleteProfile(id: defaultId)
            assertFalse(deleted, "deleteProfile should return false for default profile")
            assertEqual(mgr.profiles.count, 1, "default profile should still exist")
        }

        // ── Test 6: merge multiple profiles deduplicates domains ──
        test("merge multiple profiles deduplicates domains") {
            let mgr = BlockingProfileManager(settingsDir: testDir + "/t6")
            let defaultId = mgr.profiles[0].id
            let custom = mgr.createProfile(
                name: "Extra",
                domains: ["reddit.com", "hackernews.com"],
                appBundleIds: ["com.tinyspeck.slackmacgap"]
            )
            let merged = mgr.mergedBlockList(profileIds: [defaultId, custom.id])
            // reddit.com is in both profiles — should appear only once
            let redditCount = merged.domains.filter { $0 == "reddit.com" }.count
            assertEqual(redditCount, 1, "reddit.com should appear exactly once after merge")
            // hackernews.com from custom should be present
            assertTrue(merged.domains.contains("hackernews.com"), "merged should contain hackernews.com")
            // apps from both should be merged too
            assertTrue(merged.appBundleIds.contains("com.tinyspeck.slackmacgap"))
            assertTrue(merged.appBundleIds.contains("com.spotify.client"))
        }

        // ── Test 7: merge with unknown UUID ignores it gracefully ──
        test("merge with unknown UUID ignores it gracefully") {
            let mgr = BlockingProfileManager(settingsDir: testDir + "/t7")
            let defaultId = mgr.profiles[0].id
            let bogusId = UUID()
            let merged = mgr.mergedBlockList(profileIds: [defaultId, bogusId])
            // Should still return the default profile's domains without crashing
            assertTrue(merged.domains.contains("reddit.com"), "should still have default domains")
            assertFalse(merged.domains.isEmpty, "merged should not be empty")
        }

        // ── Test 8: update profile changes domains and apps ──
        test("update profile changes domains and apps") {
            let mgr = BlockingProfileManager(settingsDir: testDir + "/t8")
            let custom = mgr.createProfile(name: "Mutable", domains: ["old.com"], appBundleIds: ["old.bundle"])
            mgr.updateProfile(
                id: custom.id,
                name: "Updated",
                domains: ["new.com", "also-new.com"],
                appBundleIds: ["new.bundle"]
            )
            let updated = mgr.profile(for: custom.id)!
            assertEqual(updated.name, "Updated")
            assertEqual(updated.blockedDomains, ["new.com", "also-new.com"])
            assertEqual(updated.blockedAppBundleIds, ["new.bundle"])
        }

        // ── Results ──
        print("\n\(passed) passed, \(failed) failed\n")
        if failed > 0 {
            print("❌ TESTS FAILED")
            exit(1)
        } else {
            print("✅ ALL TESTS PASSED")
            exit(0)
        }
    }
}
