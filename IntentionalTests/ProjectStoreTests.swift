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
/// would deadlock the caller's executor.
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

/// Escape hatch for passing async results back through the semaphore without
/// fighting Sendable checks.
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(value: T) { self.value = value }
}

/// Seed `<dir>/projects.json` with an array of Projects so tests can set up
/// historical `lastUsedAt` values before the store is initialized.
func seedProjectsFile(dir: String, projects: [Project]) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try! encoder.encode(projects)
    fm.createFile(atPath: "\(dir)/projects.json", contents: data)
}

/// Minimal project builder for seed-file tests.
func makeTestProject(name: String = "Seed",
                     lastUsedAt: Date?,
                     accent: String = "#E87461") -> Project {
    let now = Date()
    return Project(
        id: UUID(),
        name: name,
        intention: "seeded",
        accent: accent,
        allowed: [],
        learned: [],
        blocklistIds: [],
        allowSearchEnginesForThisProject: false,
        createdAt: now,
        updatedAt: now,
        lastUsedAt: lastUsedAt,
        sessions: [],
        weekMinutes: Array(repeating: 0, count: 14),
        weeklyAnchor: nil
    )
}

@main
struct ProjectStoreTests {
    static func main() {
        print("\n🧪 ProjectStoreTests\n")

        let testDir = "/tmp/project-store-tests-\(UUID().uuidString)"

        // ── 1: create appears in list ──
        test("create appears in list") {
            let store = ProjectStore(settingsDir: testDir + "/t1")
            let p = sync {
                await store.create(
                    name: "Apollo",
                    intention: "ship v1",
                    allowed: [],
                    blocklistIds: [],
                    allowSearchEngines: false
                )
            }
            let items = sync { await store.list() }
            assertEqual(items.count, 1)
            assertEqual(items[0].id, p.id)
            assertEqual(items[0].name, "Apollo")
            assertEqual(items[0].intention, "ship v1")
        }

        // ── 2: create assigns first palette accent, second assigns next ──
        test("create assigns palette accent by index") {
            let store = ProjectStore(settingsDir: testDir + "/t2")
            let p1 = sync {
                await store.create(name: "A", intention: "", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            assertEqual(p1.accent, "#E87461")
            let p2 = sync {
                await store.create(name: "B", intention: "", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            assertEqual(p2.accent, "#F0B060")
        }

        // ── 3: create truncates intention >140 chars ──
        test("create truncates intention to 140 chars") {
            let store = ProjectStore(settingsDir: testDir + "/t3")
            let long = String(repeating: "x", count: 200)
            let p = sync {
                await store.create(
                    name: "Long",
                    intention: long,
                    allowed: [],
                    blocklistIds: [],
                    allowSearchEngines: false
                )
            }
            assertEqual(p.intention.count, 140)
        }

        // ── 4: update name ──
        test("update name bumps updatedAt") {
            let store = ProjectStore(settingsDir: testDir + "/t4")
            let p = sync {
                await store.create(name: "Orig", intention: "i", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            let origUpdatedAt = p.updatedAt
            // Small sleep so updatedAt moves forward measurably
            usleep(10_000)
            var patch = ProjectPatch()
            patch.name = "X"
            let captured = patch
            let pid = p.id
            let updated = sync { await store.update(id: pid, patch: captured) }
            assertTrue(updated != nil)
            assertEqual(updated?.name, "X")
            let fetched = sync { await store.get(id: pid) }
            assertEqual(fetched?.name, "X")
            assertTrue((fetched?.updatedAt ?? Date.distantPast) > origUpdatedAt, "updatedAt should bump past createdAt")
        }

        // ── 5: update with empty patch leaves fields unchanged ──
        test("empty patch leaves fields unchanged") {
            let store = ProjectStore(settingsDir: testDir + "/t5")
            let origBlocklistId = UUID()
            let p = sync {
                await store.create(
                    name: "Keep",
                    intention: "stay",
                    allowed: [HostItem(id: UUID(), kind: .domain, value: "github.com", note: nil)],
                    blocklistIds: [origBlocklistId],
                    allowSearchEngines: true
                )
            }
            let emptyPatch = ProjectPatch()
            let pid = p.id
            let updated = sync { await store.update(id: pid, patch: emptyPatch) }
            assertTrue(updated != nil)
            assertEqual(updated?.name, "Keep")
            assertEqual(updated?.intention, "stay")
            assertEqual(updated?.allowed.count, 1)
            assertEqual(updated?.allowed[0].value, "github.com")
            assertEqual(updated?.blocklistIds, [origBlocklistId])
            assertEqual(updated?.allowSearchEnginesForThisProject, true)
            assertEqual(updated?.accent, p.accent)
        }

        // ── 6: delete returns true and removes from list ──
        test("delete removes project") {
            let store = ProjectStore(settingsDir: testDir + "/t6")
            let p = sync {
                await store.create(name: "Die", intention: "", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            let pid = p.id
            let removed = sync { await store.delete(id: pid) }
            assertTrue(removed)
            let list = sync { await store.list() }
            assertEqual(list.count, 0)
        }

        // ── 7: delete nonexistent returns false ──
        test("delete nonexistent returns false") {
            let store = ProjectStore(settingsDir: testDir + "/t7")
            let removed = sync { await store.delete(id: UUID()) }
            assertFalse(removed)
        }

        // ── 8: listSummary field mapping ──
        test("listSummary field mapping") {
            let store = ProjectStore(settingsDir: testDir + "/t8")
            let blockIds = [UUID(), UUID(), UUID()]
            let allowed = [
                HostItem(id: UUID(), kind: .domain, value: "a.com", note: nil),
                HostItem(id: UUID(), kind: .domain, value: "b.com", note: nil)
            ]
            let p = sync {
                await store.create(
                    name: "Sum",
                    intention: "go",
                    allowed: allowed,
                    blocklistIds: blockIds,
                    allowSearchEngines: false
                )
            }
            let summaries = sync { await store.listSummary() }
            assertEqual(summaries.count, 1)
            let s = summaries[0]
            assertEqual(s.id, p.id)
            assertEqual(s.name, "Sum")
            assertEqual(s.intention, "go")
            assertEqual(s.accent, p.accent)
            assertEqual(s.allowedCount, 2)
            assertEqual(s.blocklistCount, 3)
            assertEqual(s.humanLastUsed, "new")
            assertEqual(s.weekMinutes.count, 14)
            assertEqual(s.totalHours, 0.0)
        }

        // ── 9: humanLastUsed nil → "new" ──
        test("humanLastUsed nil is new") {
            let store = ProjectStore(settingsDir: testDir + "/t9")
            let _ = sync {
                await store.create(name: "N", intention: "", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            let summaries = sync { await store.listSummary() }
            assertEqual(summaries[0].humanLastUsed, "new")
        }

        // ── 10: humanLastUsed today ──
        test("humanLastUsed today after session end") {
            let store = ProjectStore(settingsDir: testDir + "/t10")
            let p = sync {
                await store.create(name: "T", intention: "", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            let pid = p.id
            let sid = sync { await store.recordSessionStart(projectId: pid, blockId: nil) }
            let _ = sync { await store.recordSessionEnd(projectId: pid, sessionId: sid, focusScore: 0.9) }
            let summaries = sync { await store.listSummary() }
            assertEqual(summaries[0].humanLastUsed, "today")
        }

        // ── 11: humanLastUsed yesterday (seeded file) ──
        test("humanLastUsed yesterday via seed") {
            let dir = testDir + "/t11"
            let cal = Calendar.current
            let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
            let seed = makeTestProject(name: "Yest", lastUsedAt: yesterday)
            seedProjectsFile(dir: dir, projects: [seed])
            let store = ProjectStore(settingsDir: dir)
            let summaries = sync { await store.listSummary() }
            assertEqual(summaries.count, 1)
            assertEqual(summaries[0].humanLastUsed, "yesterday")
        }

        // ── 12: humanLastUsed 3d ago ──
        test("humanLastUsed 3d ago via seed") {
            let dir = testDir + "/t12"
            let cal = Calendar.current
            let threeDays = cal.date(byAdding: .day, value: -3, to: Date())!
            let seed = makeTestProject(name: "3d", lastUsedAt: threeDays)
            seedProjectsFile(dir: dir, projects: [seed])
            let store = ProjectStore(settingsDir: dir)
            let summaries = sync { await store.listSummary() }
            assertEqual(summaries[0].humanLastUsed, "3d ago")
        }

        // ── 13: humanLastUsed 14d ago → "2w ago" ──
        test("humanLastUsed 14d ago is 2w ago") {
            let dir = testDir + "/t13"
            let cal = Calendar.current
            let fourteen = cal.date(byAdding: .day, value: -14, to: Date())!
            let seed = makeTestProject(name: "2w", lastUsedAt: fourteen)
            seedProjectsFile(dir: dir, projects: [seed])
            let store = ProjectStore(settingsDir: dir)
            let summaries = sync { await store.listSummary() }
            assertEqual(summaries[0].humanLastUsed, "2w ago")
        }

        // ── 14: recordSessionStart stores blockId ──
        test("recordSessionStart stores blockId") {
            let store = ProjectStore(settingsDir: testDir + "/t14")
            let p = sync {
                await store.create(name: "B", intention: "", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            let blockId = UUID()
            let pid = p.id
            let capturedBlockId = blockId
            let sid = sync { await store.recordSessionStart(projectId: pid, blockId: capturedBlockId) }
            let fetched = sync { await store.get(id: pid) }
            assertEqual(fetched?.sessions.count, 1)
            assertEqual(fetched?.sessions[0].id, sid)
            assertEqual(fetched?.sessions[0].blockId, blockId)
        }

        // ── 15: recordSessionEnd fills duration and focusScore ──
        test("recordSessionEnd fills duration and focusScore") {
            let store = ProjectStore(settingsDir: testDir + "/t15")
            let p = sync {
                await store.create(name: "E", intention: "", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            let pid = p.id
            let sid = sync { await store.recordSessionStart(projectId: pid, blockId: nil) }
            usleep(20_000)
            let ended = sync { await store.recordSessionEnd(projectId: pid, sessionId: sid, focusScore: 0.85) }
            assertTrue(ended != nil)
            assertTrue((ended?.durationSec ?? -1) >= 0, "durationSec should be non-negative")
            assertEqual(ended?.focusScore, 0.85)
            assertTrue(ended?.endedAt != nil)
        }

        // ── 16: recordLearnedHit dedupe ──
        test("recordLearnedHit dedupes and bumps hitCount") {
            let store = ProjectStore(settingsDir: testDir + "/t16")
            let p = sync {
                await store.create(name: "L", intention: "", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            let pid = p.id
            sync { () -> Void in
                await store.recordLearnedHit(projectId: pid, host: "github.com")
                await store.recordLearnedHit(projectId: pid, host: "github.com")
            }
            let fetched = sync { await store.get(id: pid) }
            assertEqual(fetched?.learned.count, 1)
            assertEqual(fetched?.learned[0].host, "github.com")
            assertEqual(fetched?.learned[0].hitCount, 2)
        }

        // ── 17: promoteLearnedSite appends to allowed and flags isPromoted ──
        test("promoteLearnedSite new host") {
            let store = ProjectStore(settingsDir: testDir + "/t17")
            let p = sync {
                await store.create(name: "P", intention: "", allowed: [], blocklistIds: [], allowSearchEngines: false)
            }
            let pid = p.id
            sync { await store.recordLearnedHit(projectId: pid, host: "example.com") }
            let ok = sync { await store.promoteLearnedSite(projectId: pid, host: "example.com") }
            assertTrue(ok)
            let fetched = sync { await store.get(id: pid) }
            assertEqual(fetched?.allowed.count, 1)
            assertEqual(fetched?.allowed[0].value, "example.com")
            assertEqual(fetched?.allowed[0].kind, .domain)
            assertEqual(fetched?.learned.count, 1)
            assertEqual(fetched?.learned[0].isPromoted, true)
        }

        // ── 18: promoteLearnedSite existing host no duplicate ──
        test("promoteLearnedSite existing host no duplicate") {
            let store = ProjectStore(settingsDir: testDir + "/t18")
            let existing = HostItem(id: UUID(), kind: .domain, value: "dup.com", note: nil)
            let p = sync {
                await store.create(
                    name: "D",
                    intention: "",
                    allowed: [existing],
                    blocklistIds: [],
                    allowSearchEngines: false
                )
            }
            let pid = p.id
            sync { await store.recordLearnedHit(projectId: pid, host: "dup.com") }
            let ok = sync { await store.promoteLearnedSite(projectId: pid, host: "dup.com") }
            assertTrue(ok)
            let fetched = sync { await store.get(id: pid) }
            assertEqual(fetched?.allowed.count, 1, "should not add duplicate allowed entry")
            assertEqual(fetched?.allowed[0].value, "dup.com")
            assertEqual(fetched?.learned.count, 1)
            assertEqual(fetched?.learned[0].isPromoted, true)
        }

        // ── 19: projectsReferencing returns matches ──
        test("projectsReferencing returns matching projects") {
            let store = ProjectStore(settingsDir: testDir + "/t19")
            let shared = UUID()
            let otherOnly = UUID()
            sync { () -> Void in
                _ = await store.create(name: "A", intention: "", allowed: [], blocklistIds: [shared], allowSearchEngines: false)
                _ = await store.create(name: "B", intention: "", allowed: [], blocklistIds: [shared, UUID()], allowSearchEngines: false)
                _ = await store.create(name: "C", intention: "", allowed: [], blocklistIds: [otherOnly], allowSearchEngines: false)
            }
            let refs = sync { await store.projectsReferencing(blocklistId: shared) }
            assertEqual(refs.count, 2)
            let names = Set(refs.map { $0.name })
            assertTrue(names.contains("A"))
            assertTrue(names.contains("B"))
            let noRefs = sync { await store.projectsReferencing(blocklistId: UUID()) }
            assertEqual(noRefs.count, 0)
        }

        // ── 20: create dedupes blocklistIds ──
        test("create dedupes blocklistIds") {
            let store = ProjectStore(settingsDir: testDir + "/t20")
            let blockId = UUID()
            let project = sync {
                await store.create(
                    name: "Dup",
                    intention: "",
                    allowed: [],
                    blocklistIds: [blockId, blockId, blockId],
                    allowSearchEngines: false
                )
            }
            assertEqual(project.blocklistIds.count, 1, "duplicates removed on create")
            let summary = sync { await store.listSummary() }.first!
            assertEqual(summary.blocklistCount, 1, "summary count reflects dedupe")
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
