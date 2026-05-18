import Foundation

#if DEBUG
/// Accuracy benchmark for the close-the-noise sweep's AI scoring.
///
/// Loads test cases from disk (IntentionalTests/sweep-test-cases/*.json), runs
/// each tab list through the live RelevanceScorer.scoreTabBatch (or
/// single-tab scoreRelevance), and reports per-case accuracy / false-positive
/// rate / false-negative rate so we can measure the impact of changes (model
/// size, confidence threshold, prompt edits, batch vs single).
///
/// Triggered from the menubar "Run Sweep Benchmark (debug)" item. Output
/// streams to postLog so it lands in /tmp/intentional-fresh.log.

struct SweepTestTab: Codable {
    let title: String
    let url: String
    let expected: String          // "keep" or "stash"
    let borderline: Bool
    let rationale: String

    var expectedKeep: Bool { expected == "keep" }
}

struct SweepTestCase: Codable {
    let name: String
    let capturedAt: String
    let notes: String
    let intent: String
    let tabs: [SweepTestTab]
}

enum SweepBenchmarkMode: String {
    case batch              // scoreTabBatch — one prompt, N tabs
    case single             // scoreRelevance per tab — N prompts
}

struct SweepBenchmarkResult {
    let caseName: String
    let mode: SweepBenchmarkMode
    let modelId: String
    let totalTabs: Int
    let truePositive: Int     // expected stash, AI said stash
    let trueNegative: Int     // expected keep,  AI said keep
    let falsePositive: Int    // expected keep,  AI said stash (the bad kind — closed a relevant tab)
    let falseNegative: Int    // expected stash, AI said keep  (left noise around)
    let elapsedSeconds: Double
    let errors: [(tab: SweepTestTab, aiVerdict: String, aiConfidence: Int)]

    var accuracy: Double {
        guard totalTabs > 0 else { return 0 }
        return Double(truePositive + trueNegative) / Double(totalTabs)
    }

    /// Of tabs the AI said "stash", how many actually should have been kept?
    /// This is the metric the user cares about most — false-stash burns trust.
    var falseStashRate: Double {
        let totalStashed = truePositive + falsePositive
        guard totalStashed > 0 else { return 0 }
        return Double(falsePositive) / Double(totalStashed)
    }

    func report() -> String {
        let pct = { (d: Double) in String(format: "%.0f%%", d * 100) }
        let secs = String(format: "%.2fs", elapsedSeconds)
        let perTab = totalTabs > 0 ? String(format: "%.2fs", elapsedSeconds / Double(totalTabs)) : "n/a"
        let modelLabel = modelId.isEmpty ? "" : "  model: \(modelId.split(separator: "/").last ?? "?")"
        var lines = [
            "════════════════════════════════════════════════",
            "📊 Benchmark: \(caseName)  [mode: \(mode.rawValue)\(modelLabel)]",
            "════════════════════════════════════════════════",
            "  Total tabs:        \(totalTabs)",
            "  ⏱️  Elapsed:        \(secs)   (\(perTab) per tab)",
            "  ✅ Correct keep:   \(trueNegative)",
            "  ✅ Correct stash:  \(truePositive)",
            "  ❌ False stash:    \(falsePositive)  (kept-relevant-tab closed — bad UX)",
            "  ⚠️  False keep:    \(falseNegative)  (noise left around)",
            "  📈 Accuracy:       \(pct(accuracy))",
            "  📉 False-stash %:  \(pct(falseStashRate))  (of all stashed tabs)"
        ]
        if !errors.isEmpty {
            lines.append("──── Errors (\(errors.count)) ────")
            for (i, e) in errors.enumerated() {
                let mark = e.tab.expectedKeep ? "❌ stashed-but-keep" : "⚠️  kept-but-stash"
                let bd = e.tab.borderline ? " (borderline)" : ""
                lines.append("  \(i+1). \(mark)\(bd)  conf=\(e.aiConfidence)")
                lines.append("      title: \(e.tab.title.prefix(80))")
                lines.append("      url:   \(e.tab.url.prefix(80))")
                lines.append("      truth: \(e.tab.rationale)")
            }
        }
        lines.append("════════════════════════════════════════════════")
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class SweepBenchmark {
    weak var appDelegate: AppDelegate?
    private var scorer: RelevanceScorer? { appDelegate?.relevanceScorer }

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Locate the test-cases dir. Looks in the worktree dir (dev launches) and
    /// falls back to the app bundle (PKG installs). Test cases aren't in the
    /// PKG today; this is dev-only.
    private func testCasesDirectoryURL() -> URL? {
        // Worktree path — works when running the dev build from DerivedData.
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            URL(fileURLWithPath: cwd).appendingPathComponent("IntentionalTests/sweep-test-cases"),
            URL(fileURLWithPath: "/Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/prototype-to-production/IntentionalTests/sweep-test-cases"),
            URL(fileURLWithPath: "/Users/arayan/Documents/GitHub/intentional-macos-app/IntentionalTests/sweep-test-cases")
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            return c
        }
        return nil
    }

    func runAll(mode: SweepBenchmarkMode = .batch) async {
        await runAll(mode: mode, modelIds: [scorer?.currentModelId ?? "(current)"])
    }

    /// Run every test case against each modelId in turn. Hot-swaps the model
    /// in place via RelevanceScorer.reloadModel so we can directly compare
    /// e.g. Qwen3-4B vs Qwen3-8B on the same case without restarting the app.
    func runAll(mode: SweepBenchmarkMode, modelIds: [String]) async {
        guard let dir = testCasesDirectoryURL() else {
            appDelegate?.postLog("📊 SweepBenchmark: no test-cases dir found")
            return
        }
        guard let scorer = scorer else {
            appDelegate?.postLog("📊 SweepBenchmark: RelevanceScorer not ready")
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        if files.isEmpty {
            appDelegate?.postLog("📊 SweepBenchmark: no .json test cases in \(dir.path)")
            return
        }

        for modelId in modelIds {
            appDelegate?.postLog("📊 SweepBenchmark: swapping to model \(modelId)...")
            await scorer.reloadModel(id: modelId)
            appDelegate?.postLog("📊 SweepBenchmark: running \(files.count) case(s) on \(modelId) [mode=\(mode.rawValue)]")
            for url in files {
                guard let data = try? Data(contentsOf: url),
                      let testCase = try? JSONDecoder().decode(SweepTestCase.self, from: data) else {
                    appDelegate?.postLog("📊 SweepBenchmark: failed to load \(url.lastPathComponent)")
                    continue
                }
                let result = await runCase(testCase, mode: mode, scorer: scorer, modelId: modelId)
                appDelegate?.postLog(result.report())
            }
        }
    }

    private func runCase(_ tc: SweepTestCase,
                         mode: SweepBenchmarkMode,
                         scorer: RelevanceScorer,
                         modelId: String = "") async -> SweepBenchmarkResult {
        // Pre-pass: apply intent-keyword auto-keep so the benchmark mirrors
        // the production sweep's decision flow. Tabs whose host/URL/title
        // contains a token extracted from the intent skip the AI entirely.
        let intentKeywords = IntentKeywordExtractor.extract(from: tc.intent)
        var preKeptIndices = Set<Int>()
        if !intentKeywords.isEmpty {
            let scope = ResolvedScope(domains: [], bundleIds: [], voiceIntent: tc.intent, intentKeywords: intentKeywords)
            for (i, tab) in tc.tabs.enumerated() {
                let host = URL(string: tab.url)?.host ?? ""
                if scope.matchesIntentKeyword(host: host, url: tab.url, title: tab.title) {
                    preKeptIndices.insert(i)
                }
            }
            let kwJoined = intentKeywords.sorted().joined(separator: ", ")
            appDelegate?.postLog("📊 SweepBenchmark: intent-keyword auto-keep matched \(preKeptIndices.count) tab(s); keywords=\(kwJoined)")
        }

        // Tabs that didn't auto-keep go through the AI.
        let aiTabIndices = (0..<tc.tabs.count).filter { !preKeptIndices.contains($0) }
        let aiTabs: [(title: String, url: String)] = aiTabIndices.map { (title: tc.tabs[$0].title, url: tc.tabs[$0].url) }
        let aiVerdicts: [RelevanceScorer.TabVerdict]

        let startTime = Date()

        switch mode {
        case .batch:
            aiVerdicts = await scorer.scoreTabBatch(intent: tc.intent, tabs: aiTabs)
        case .single:
            // Run one prompt per tab — slower but uses the model's full attention per tab.
            // Reuses the production single-tab scoreRelevance path via a thin shim:
            // we treat each as a webpage with the intent as 'intention' + intent text.
            var out: [RelevanceScorer.TabVerdict] = []
            for tab in aiTabs {
                let r = await scorer.scoreRelevance(
                    pageTitle: tab.title,
                    intention: tc.intent,
                    intentionDescription: "",
                    intentText: tc.intent,
                    aiScoringEnabled: true,
                    profile: "",
                    dailyPlan: "",
                    url: tab.url,
                    pageDescription: "",
                    contentType: .webpage,
                    bundleIdentifier: ""
                )
                out.append(RelevanceScorer.TabVerdict(
                    title: tab.title, url: tab.url,
                    relevant: r.relevant, confidence: r.confidence
                ))
            }
            aiVerdicts = out
        }

        // Build a tab-index → verdict map. Tabs that passed the intent-keyword
        // gate get an implicit (keep, conf=100) verdict. Tabs that went to AI
        // get their actual verdict.
        var verdictByIndex: [Int: RelevanceScorer.TabVerdict] = [:]
        for keptIndex in preKeptIndices {
            verdictByIndex[keptIndex] = RelevanceScorer.TabVerdict(
                title: tc.tabs[keptIndex].title, url: tc.tabs[keptIndex].url,
                relevant: true, confidence: 100
            )
        }
        for (j, aiIndex) in aiTabIndices.enumerated() {
            if j < aiVerdicts.count {
                verdictByIndex[aiIndex] = aiVerdicts[j]
            }
        }

        // Mirror the live sweep orchestrator's asymmetric rule:
        // STASH only when the model is HIGH-confidence off-task.
        // (NOT relevant AND confidence >= 65 → stash; everything else → keep.)
        // False-stashes burn user trust ~5x harder than false-keeps.
        let stashConfidenceFloor = 65
        var tp = 0, tn = 0, fp = 0, fn = 0
        var errors: [(tab: SweepTestTab, aiVerdict: String, aiConfidence: Int)] = []

        for (i, tab) in tc.tabs.enumerated() {
            let v = verdictByIndex[i] ?? RelevanceScorer.TabVerdict(
                title: tab.title, url: tab.url, relevant: false, confidence: 0
            )
            let highConfidenceStash = !v.relevant && v.confidence >= stashConfidenceFloor
            let aiVerdict = highConfidenceStash ? "stash" : "keep"
            switch (tab.expected, aiVerdict) {
            case ("stash", "stash"): tp += 1
            case ("keep",  "keep"):  tn += 1
            case ("keep",  "stash"):
                fp += 1
                errors.append((tab: tab, aiVerdict: aiVerdict, aiConfidence: v.confidence))
            case ("stash", "keep"):
                fn += 1
                errors.append((tab: tab, aiVerdict: aiVerdict, aiConfidence: v.confidence))
            default: break
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return SweepBenchmarkResult(
            caseName: tc.name,
            mode: mode,
            modelId: modelId,
            totalTabs: tc.tabs.count,
            truePositive: tp,
            trueNegative: tn,
            falsePositive: fp,
            falseNegative: fn,
            elapsedSeconds: elapsed,
            errors: errors
        )
    }
}
#endif
