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

/// Synchronously await an async closure so tests stay flat.
///
/// Uses `Task.detached` so the awaited work runs on a background executor —
/// blocking the calling thread with a semaphore while a non-detached Task
/// is scheduled on the same actor would deadlock.
func sync<T>(_ body: @Sendable @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = UncheckedBox<T?>(value: nil)
    Task.detached {
        let result = await body()
        box.value = result
        sem.signal()
    }
    sem.wait()
    return box.value!
}

/// Escape hatch for capturing the async result back across the semaphore
/// without fighting `Sendable` checks in tests.
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(value: T) { self.value = value }
}

@main
struct ProjectStoreTests {
    static func main() {
        print("\n🧪 ProjectStoreTests\n")

        let testDir = "/tmp/project-store-tests-\(UUID().uuidString)"

        // ── Test 1: empty on fresh init ──
        test("empty on fresh init") {
            let store = ProjectStore(settingsDir: testDir + "/t1")
            let items = sync { await store.list() }
            assertEqual(items.count, 0, "fresh store should be empty")
        }

        // ── Test 2: create returns a project with palette[0], 14-zero weekly, empty history + learnedSites ──
        test("create sets defaults correctly") {
            let store = ProjectStore(settingsDir: testDir + "/t2")
            let blockId = UUID()
            let p = sync {
                await store.create(title: "Apollo", desc: "ship v1", blocklistId: blockId, allowed: [])
            }
            assertEqual(p.title, "Apollo")
            assertEqual(p.desc, "ship v1")
            assertEqual(p.blocklistId, blockId)
            assertEqual(p.accent, ProjectStore.accentPalette[0], "first accent should be palette[0]")
            assertEqual(p.weekly.count, 14, "weekly must have 14 entries")
            assertTrue(p.weekly.allSatisfy { $0 == 0 }, "weekly should all be zero on create")
            assertEqual(p.history.count, 0, "history should be empty on create")
            assertEqual(p.learnedSites.count, 0, "learnedSites should be empty on create")
            assertEqual(p.sessions, 0)
            assertEqual(p.focusedMinutes, 0)

            let listed = sync { await store.list() }
            assertEqual(listed.count, 1, "list should contain the new project")
            assertEqual(listed[0].id, p.id)
        }

        // ── Test 3: second create uses palette[1] ──
        test("accent rotates: second gets palette[1]") {
            let store = ProjectStore(settingsDir: testDir + "/t3")
            let _ = sync { await store.create(title: "A", desc: "", blocklistId: UUID(), allowed: []) }
            let p2 = sync { await store.create(title: "B", desc: "", blocklistId: UUID(), allowed: []) }
            assertEqual(p2.accent, ProjectStore.accentPalette[1])
        }

        // ── Test 4: 5th create wraps to palette[0] ──
        test("accent rotation wraps") {
            let store = ProjectStore(settingsDir: testDir + "/t4")
            let fifth: Project = sync {
                var last: Project!
                for i in 0..<5 {
                    last = await store.create(title: "p\(i)", desc: "", blocklistId: UUID(), allowed: [])
                }
                return last
            }
            assertEqual(fifth.accent, ProjectStore.accentPalette[0], "5th project should wrap to palette[0]")
        }

        // ── Test 5: update patches only provided fields ──
        test("update patches only provided fields") {
            let store = ProjectStore(settingsDir: testDir + "/t5")
            let origBlock = UUID()
            let created = sync {
                await store.create(title: "Orig", desc: "orig-desc", blocklistId: origBlock, allowed: [
                    HostItem(value: "github.com", sub: nil, kind: .site)
                ])
            }
            var patchLocal = ProjectPatch()
            patchLocal.title = "NewTitle"
            let patch = patchLocal
            let createdId = created.id
            let updated = sync { await store.update(id: createdId, patch: patch) }
            assertTrue(updated != nil)
            assertEqual(updated?.title, "NewTitle")
            assertEqual(updated?.desc, "orig-desc", "desc unchanged")
            assertEqual(updated?.blocklistId, origBlock, "blocklistId unchanged")
            assertEqual(updated?.allowed.count, 1, "allowed unchanged")
            assertEqual(updated?.allowed[0].value, "github.com")
        }

        // ── Test 6: delete removes project ──
        test("delete removes project") {
            let store = ProjectStore(settingsDir: testDir + "/t6")
            let p = sync { await store.create(title: "Die", desc: "", blocklistId: UUID(), allowed: []) }
            let removed = sync { await store.delete(id: p.id) }
            assertTrue(removed, "delete should return true")
            let fetched = sync { await store.get(id: p.id) }
            assertTrue(fetched == nil, "get after delete should return nil")
            let list = sync { await store.list() }
            assertEqual(list.count, 0)
        }

        // ── Test 7: recordSessionEnd bumps counters and weekly[13] ──
        test("recordSessionEnd bumps counters and weekly[13]") {
            let store = ProjectStore(settingsDir: testDir + "/t7")
            let p = sync { await store.create(title: "S", desc: "", blocklistId: UUID(), allowed: []) }
            let start = Date()
            let end = start.addingTimeInterval(45 * 60)
            sync { () -> Void in
                await store.recordSessionStart(projectId: p.id, goal: "finish feature", at: start)
                await store.recordSessionEnd(projectId: p.id, startedAt: start, endedAt: end, focusScore: 88)
            }
            let fetched = sync { await store.get(id: p.id) }!
            assertEqual(fetched.sessions, 1)
            assertEqual(fetched.focusedMinutes, 45)
            assertEqual(fetched.history.count, 1)
            assertEqual(fetched.history[0].focusScore, 88)
            assertEqual(fetched.history[0].goal, "finish feature")
            assertEqual(fetched.weekly[13], 45, "today's slot should have 45 minutes")
        }

        // ── Test 8: history cap at 20 ──
        test("history capped at 20 most recent") {
            let store = ProjectStore(settingsDir: testDir + "/t8")
            let p = sync { await store.create(title: "H", desc: "", blocklistId: UUID(), allowed: []) }
            let base = Date()
            sync { () -> Void in
                for i in 0..<22 {
                    // Each session is 1 minute long, spaced 2 minutes apart, all within "today"
                    let s = base.addingTimeInterval(Double(i) * 120)
                    let e = s.addingTimeInterval(60)
                    await store.recordSessionStart(projectId: p.id, goal: "g\(i)", at: s)
                    await store.recordSessionEnd(projectId: p.id, startedAt: s, endedAt: e, focusScore: i)
                }
            }
            let fetched = sync { await store.get(id: p.id) }!
            assertEqual(fetched.sessions, 22, "sessions counter should equal 22")
            assertEqual(fetched.history.count, 20, "history should be capped at 20")
            // After the cap, the oldest kept should be session index 2 (g2, focusScore=2).
            assertEqual(fetched.history.first?.focusScore, 2)
            assertEqual(fetched.history.last?.focusScore, 21)
        }

        // ── Test 9: weekly shifts by 1 when last session was yesterday ──
        test("weekly shifts by 1 for yesterday") {
            let store = ProjectStore(settingsDir: testDir + "/t9")
            let p = sync { await store.create(title: "W", desc: "", blocklistId: UUID(), allowed: []) }

            let cal = Calendar.current
            let now = Date()
            let todayStart = cal.startOfDay(for: now)
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
            let yesterdayEnd = yesterdayStart.addingTimeInterval(30 * 60) // 30 min session
            sync {
                await store.recordSessionStart(projectId: p.id, goal: "y", at: yesterdayStart)
                await store.recordSessionEnd(projectId: p.id, startedAt: yesterdayStart, endedAt: yesterdayEnd, focusScore: 50)
            }

            let todayTime = todayStart.addingTimeInterval(10 * 60 * 60) // 10am today
            let todayEnd = todayTime.addingTimeInterval(45 * 60)
            sync {
                await store.recordSessionStart(projectId: p.id, goal: "t", at: todayTime)
                await store.recordSessionEnd(projectId: p.id, startedAt: todayTime, endedAt: todayEnd, focusScore: 60)
            }

            let fetched = sync { await store.get(id: p.id) }!
            assertEqual(fetched.weekly[13], 45, "today should be 45")
            assertEqual(fetched.weekly[12], 30, "yesterday should have shifted into slot 12")
        }

        // ── Test 10: weekly shifts by 3 for a 3-day gap ──
        test("weekly shift with gap of 3 days") {
            let store = ProjectStore(settingsDir: testDir + "/t10")
            let p = sync { await store.create(title: "G", desc: "", blocklistId: UUID(), allowed: []) }

            let cal = Calendar.current
            let now = Date()
            let todayStart = cal.startOfDay(for: now)
            let threeDaysAgoStart = cal.date(byAdding: .day, value: -3, to: todayStart)!
            let threeDaysAgoEnd = threeDaysAgoStart.addingTimeInterval(60 * 60) // 60 min
            sync {
                await store.recordSessionStart(projectId: p.id, goal: "g1", at: threeDaysAgoStart)
                await store.recordSessionEnd(projectId: p.id, startedAt: threeDaysAgoStart, endedAt: threeDaysAgoEnd, focusScore: 50)
            }

            let todayTime = todayStart.addingTimeInterval(10 * 60 * 60)
            let todayEnd = todayTime.addingTimeInterval(20 * 60)
            sync {
                await store.recordSessionStart(projectId: p.id, goal: "g2", at: todayTime)
                await store.recordSessionEnd(projectId: p.id, startedAt: todayTime, endedAt: todayEnd, focusScore: 60)
            }

            let fetched = sync { await store.get(id: p.id) }!
            assertEqual(fetched.weekly[13], 20, "today=20")
            assertEqual(fetched.weekly[12], 0, "1 day ago should be 0")
            assertEqual(fetched.weekly[11], 0, "2 days ago should be 0")
            assertEqual(fetched.weekly[10], 60, "3 days ago should be 60")
        }

        // ── Test 11: recordLearnedHit upserts (github.com x2 → hits=2) ──
        test("recordLearnedHit upserts") {
            let store = ProjectStore(settingsDir: testDir + "/t11")
            let p = sync { await store.create(title: "L", desc: "", blocklistId: UUID(), allowed: []) }
            sync {
                await store.recordLearnedHit(projectId: p.id, host: "github.com", kind: .site)
                await store.recordLearnedHit(projectId: p.id, host: "github.com", kind: .site)
            }
            let fetched = sync { await store.get(id: p.id) }!
            assertEqual(fetched.learnedSites.count, 1, "should upsert — one entry only")
            assertEqual(fetched.learnedSites[0].value, "github.com")
            assertEqual(fetched.learnedSites[0].hits, 2)
        }

        // ── Test 12: recordLearnedHit sorts by hits desc ──
        test("recordLearnedHit sorted by hits desc") {
            let store = ProjectStore(settingsDir: testDir + "/t12")
            let p = sync { await store.create(title: "LS", desc: "", blocklistId: UUID(), allowed: []) }
            sync { () -> Void in
                for _ in 0..<3 { await store.recordLearnedHit(projectId: p.id, host: "a", kind: .site) }
                for _ in 0..<5 { await store.recordLearnedHit(projectId: p.id, host: "b", kind: .site) }
            }
            let fetched = sync { await store.get(id: p.id) }!
            assertEqual(fetched.learnedSites[0].value, "b", "highest hits should be first")
            assertEqual(fetched.learnedSites[0].hits, 5)
            assertEqual(fetched.learnedSites[1].value, "a")
            assertEqual(fetched.learnedSites[1].hits, 3)
        }

        // ── Test 13: promoteLearnedSite moves entry to allowed ──
        test("promoteLearnedSite moves to allowed") {
            let store = ProjectStore(settingsDir: testDir + "/t13")
            let p = sync { await store.create(title: "P", desc: "", blocklistId: UUID(), allowed: []) }
            sync { await store.recordLearnedHit(projectId: p.id, host: "example.com", kind: .site) }
            let promoted = sync { await store.promoteLearnedSite(projectId: p.id, value: "example.com") }
            assertTrue(promoted != nil)
            assertEqual(promoted?.learnedSites.count, 0, "learnedSites should be empty")
            assertEqual(promoted?.allowed.count, 1, "allowed should have one entry")
            assertEqual(promoted?.allowed[0].value, "example.com")
            assertEqual(promoted?.allowed[0].kind, .site)
        }

        // ── Test 14: promoteLearnedSite deduplicates if already in allowed ──
        test("promoteLearnedSite dedupes when already allowed") {
            let store = ProjectStore(settingsDir: testDir + "/t14")
            let p = sync {
                await store.create(title: "D", desc: "", blocklistId: UUID(), allowed: [
                    HostItem(value: "dup.com", sub: nil, kind: .site)
                ])
            }
            sync { await store.recordLearnedHit(projectId: p.id, host: "dup.com", kind: .site) }
            let promoted = sync { await store.promoteLearnedSite(projectId: p.id, value: "dup.com") }
            assertTrue(promoted != nil)
            assertEqual(promoted?.learnedSites.count, 0, "learnedSites cleared")
            assertEqual(promoted?.allowed.count, 1, "allowed should not gain a duplicate")
            assertEqual(promoted?.allowed[0].value, "dup.com")
        }

        // ── Test 15: listSummary projection ──
        test("listSummary hours and omissions") {
            let store = ProjectStore(settingsDir: testDir + "/t15")
            let p = sync { await store.create(title: "Sum", desc: "sum-desc", blocklistId: UUID(), allowed: []) }
            let start = Date()
            let end = start.addingTimeInterval(75 * 60) // 75 min → 1.3 hours
            sync {
                await store.recordSessionStart(projectId: p.id, goal: "x", at: start)
                await store.recordSessionEnd(projectId: p.id, startedAt: start, endedAt: end, focusScore: 80)
            }
            let summaries = sync { await store.listSummary() }
            assertEqual(summaries.count, 1)
            let s = summaries[0]
            assertEqual(s.title, "Sum")
            assertEqual(s.desc, "sum-desc")
            assertEqual(s.sessions, 1)
            assertEqual(s.hours, 1.3, "75 min → 1.3h")
            assertEqual(s.weekly.count, 14)
            // Summary lastUsed should humanize to "today"
            assertEqual(s.lastUsed, "today")
        }

        // ── Test 16: humanLastUsed buckets ──
        test("humanLastUsed buckets") {
            let now = Date()
            let cal = Calendar.current

            // nil → "new"
            assertEqual(ProjectStore.humanLastUsed(nil, now: now), "new")

            // today
            let today = cal.startOfDay(for: now).addingTimeInterval(60 * 60)
            assertEqual(ProjectStore.humanLastUsed(today, now: now), "today")

            // yesterday
            let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
            assertEqual(ProjectStore.humanLastUsed(yesterday, now: now), "yesterday")

            // 3 days ago
            let threeDays = cal.date(byAdding: .day, value: -3, to: now)!
            assertEqual(ProjectStore.humanLastUsed(threeDays, now: now), "3d ago")

            // 10 days ago → "1w ago"
            let tenDays = cal.date(byAdding: .day, value: -10, to: now)!
            assertEqual(ProjectStore.humanLastUsed(tenDays, now: now), "1w ago")

            // 90 days ago → month+day formatted
            let ninety = cal.date(byAdding: .day, value: -90, to: now)!
            let result = ProjectStore.humanLastUsed(ninety, now: now)
            let fmt = DateFormatter()
            fmt.setLocalizedDateFormatFromTemplate("MMM d")
            assertEqual(result, fmt.string(from: ninety))
        }

        // ── Test 17: projectsReferencing(blocklistId:) ──
        test("projectsReferencing returns matching summaries") {
            let store = ProjectStore(settingsDir: testDir + "/t17")
            let blockA = UUID()
            let blockB = UUID()
            sync { () -> Void in
                _ = await store.create(title: "uses A #1", desc: "", blocklistId: blockA, allowed: [])
                _ = await store.create(title: "uses A #2", desc: "", blocklistId: blockA, allowed: [])
                _ = await store.create(title: "uses B", desc: "", blocklistId: blockB, allowed: [])
            }
            let refsA = sync { await store.projectsReferencing(blocklistId: blockA) }
            let refsB = sync { await store.projectsReferencing(blocklistId: blockB) }
            assertEqual(refsA.count, 2)
            assertEqual(refsB.count, 1)
            assertEqual(refsB[0].title, "uses B")
            let unknown = sync { await store.projectsReferencing(blocklistId: UUID()) }
            assertEqual(unknown.count, 0, "no projects reference a random UUID")
        }

        // ── Test 18: persistence roundtrip ──
        test("persistence roundtrip across store instances") {
            let dir = testDir + "/t18"
            let store1 = ProjectStore(settingsDir: dir)
            let p = sync { await store1.create(title: "Persisted", desc: "d", blocklistId: UUID(), allowed: [
                HostItem(value: "foo.com", sub: "docs", kind: .site)
            ]) }
            let start = Date()
            let end = start.addingTimeInterval(30 * 60)
            sync {
                await store1.recordSessionStart(projectId: p.id, goal: "persist-goal", at: start)
                await store1.recordSessionEnd(projectId: p.id, startedAt: start, endedAt: end, focusScore: 77)
            }

            let store2 = ProjectStore(settingsDir: dir)
            let reloaded = sync { await store2.get(id: p.id) }
            assertTrue(reloaded != nil, "project should be persisted and reloaded")
            assertEqual(reloaded?.title, "Persisted")
            assertEqual(reloaded?.sessions, 1)
            assertEqual(reloaded?.focusedMinutes, 30)
            assertEqual(reloaded?.history.count, 1)
            assertEqual(reloaded?.history[0].goal, "persist-goal")
            assertEqual(reloaded?.allowed.count, 1)
            assertEqual(reloaded?.allowed[0].sub, "docs")
        }

        // ── Test 19: corrupt file → empty list, no crash ──
        test("corrupt file yields empty list") {
            let dir = testDir + "/t19"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let garbage = "not valid json at all { ] } [ :".data(using: .utf8)!
            fm.createFile(atPath: "\(dir)/projects.json", contents: garbage)

            let store = ProjectStore(settingsDir: dir)
            let list = sync { await store.list() }
            assertEqual(list.count, 0, "should recover gracefully from corrupt json")
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
