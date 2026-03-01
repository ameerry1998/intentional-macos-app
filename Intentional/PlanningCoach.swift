import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

import MLXLLM
import MLXLMCommon

/// LLM-powered conversational day planner.
/// Uses the same dual-model pattern as RelevanceScorer (Apple FM on macOS 26+, MLX Qwen3-4B fallback)
/// but maintains its own conversation session for multi-turn planning dialogue.
/// Persists LLM-curated coaching insights across sessions.
class PlanningCoach {

    weak var appDelegate: AppDelegate?

    // MLX: separate ChatSession but reuses model from RelevanceScorer
    private var mlxSession: ChatSession?
    private var mlxSystemPromptSent = false

    #if canImport(FoundationModels)
    private var _fmSession: Any? = nil

    @available(macOS 26.0, *)
    private var fmSession: LanguageModelSession {
        get {
            if let s = _fmSession as? LanguageModelSession { return s }
            let s = LanguageModelSession(instructions: buildSystemPrompt())
            _fmSession = s
            return s
        }
        set { _fmSession = newValue }
    }
    #endif

    // MARK: - Memory

    struct PlanningMemory: Codable {
        var lastUpdated: String = ""
        var insights: [String] = []             // max 8, LLM-curated observations
        var preferredBlockDuration: Int = 75    // rolling average in minutes

        // Migration: gracefully handle old format with recurringTasks
        enum CodingKeys: String, CodingKey {
            case lastUpdated, insights, preferredBlockDuration, recurringTasks
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastUpdated = (try? c.decode(String.self, forKey: .lastUpdated)) ?? ""
            preferredBlockDuration = (try? c.decode(Int.self, forKey: .preferredBlockDuration)) ?? 75
            if let new = try? c.decode([String].self, forKey: .insights) {
                insights = new
            } else if let old = try? c.decode([String].self, forKey: .recurringTasks), !old.isEmpty {
                insights = ["Recurring tasks from previous sessions: \(old.joined(separator: ", "))"]
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(lastUpdated, forKey: .lastUpdated)
            try c.encode(insights, forKey: .insights)
            try c.encode(preferredBlockDuration, forKey: .preferredBlockDuration)
        }
    }

    private var memory = PlanningMemory()
    var currentMemory: PlanningMemory { memory }
    private let memoryFileURL: URL
    private var conversationLog: [(role: String, text: String)] = []
    private var conversationDate: String = ""  // "yyyy-MM-dd" of current conversation

    // MARK: - Types

    struct PlanResponse {
        var message: String
        var blocks: [SuggestedBlock]
        var error: String?
    }

    struct SuggestedBlock {
        var title: String
        var description: String
        var startHour: Int
        var startMinute: Int
        var endHour: Int
        var endMinute: Int
        var blockType: String  // "deepWork", "focusHours", "freeTime"
    }

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memoryFileURL = dir.appendingPathComponent("planning_memory.json")

        loadMemory()
        appDelegate?.postLog("💬 PlanningCoach initialized (memory: \(memory.insights.count) insights)")
    }

    /// Send a user message and get a planning response (conversational, multi-turn).
    /// Auto-resets on new day (extracts memories from yesterday's conversation first).
    func chat(userMessage: String) async -> PlanResponse {
        // Auto-reset if the day has changed since the conversation started
        let today = Self.todayString()
        if !conversationDate.isEmpty && conversationDate != today {
            appDelegate?.postLog("💬 PlanningCoach: New day detected, auto-resetting conversation")
            let oldConversation = conversationLog
            resetSession()
            if oldConversation.count > 2 {
                await extractMemories(from: oldConversation)
            }
        }
        if conversationDate.isEmpty {
            conversationDate = today
        }

        conversationLog.append((role: "user", text: userMessage))
        let aiModel = appDelegate?.scheduleManager?.aiModel ?? "apple"

        var response: PlanResponse?

        if aiModel == "qwen" {
            // MLX path: reuse model from RelevanceScorer
            if let scorer = appDelegate?.relevanceScorer {
                await scorer.loadMLXModelIfNeeded()
                if scorer.mlxModelLoaded, let ctx = scorer.modelContext {
                    if mlxSession == nil {
                        mlxSession = ChatSession(ctx)
                    }
                    do {
                        response = try await chatWithMLX(userMessage: userMessage)
                    } catch {
                        appDelegate?.postLog("⚠️ PlanningCoach MLX error (likely context overflow): \(error)")
                        // Context overflow recovery: reset session and retry once
                        resetSession()
                        conversationDate = today
                        conversationLog = [(role: "user", text: userMessage)]
                        if let ctx2 = scorer.modelContext {
                            mlxSession = ChatSession(ctx2)
                            do {
                                response = try await chatWithMLX(userMessage: userMessage)
                            } catch {
                                appDelegate?.postLog("⚠️ PlanningCoach MLX retry also failed: \(error)")
                            }
                        }
                    }
                }
            }
        }

        if response == nil {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                do {
                    response = try await chatWithFoundationModels(userMessage: userMessage)
                } catch {
                    appDelegate?.postLog("⚠️ PlanningCoach FM error: \(error)")
                }
            }
            #endif
        }

        guard let result = response else {
            return PlanResponse(
                message: "I'm not able to connect to the AI model right now. Try again in a moment.",
                blocks: [],
                error: "No AI model available"
            )
        }

        conversationLog.append((role: "coach", text: result.message))

        // Extract preferred block duration from response blocks
        if !result.blocks.isEmpty {
            extractAndSavePatterns(from: result.blocks)
        }

        return result
    }

    /// Clear conversation context (new conversation).
    /// Fires async LLM extraction to curate insights from the conversation.
    func reset() {
        let conversationToProcess = conversationLog
        resetSession()

        // Extract insights if conversation was non-trivial (>2 entries = at least 1 full exchange)
        if conversationToProcess.count > 2 {
            Task { [weak self] in
                await self?.extractMemories(from: conversationToProcess)
            }
        }
    }

    /// Clear all LLM-curated insights. Called from dashboard "Clear memories" button.
    func clearMemory() {
        memory.insights = []
        saveMemory()
        appDelegate?.postLog("💬 PlanningCoach: Memories cleared by user")
    }

    /// Reset LLM sessions and conversation log without triggering extraction.
    private func resetSession() {
        conversationLog = []
        conversationDate = ""
        mlxSession = nil
        mlxSystemPromptSent = false
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            _fmSession = nil
        }
        #endif
        appDelegate?.postLog("💬 PlanningCoach conversation reset")
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - Memory Persistence

    private func loadMemory() {
        guard FileManager.default.fileExists(atPath: memoryFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: memoryFileURL)
            memory = try JSONDecoder().decode(PlanningMemory.self, from: data)
        } catch {
            appDelegate?.postLog("⚠️ PlanningCoach: Failed to load memory: \(error)")
        }
    }

    private func saveMemory() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        memory.lastUpdated = formatter.string(from: Date())
        do {
            let data = try JSONEncoder().encode(memory)
            try data.write(to: memoryFileURL)
        } catch {
            appDelegate?.postLog("⚠️ PlanningCoach: Failed to save memory: \(error)")
        }
    }

    /// Extract curated insights from a completed conversation using Qwen LLM.
    /// Runs async after reset() — writes to memory.insights when done.
    private func extractMemories(from conversation: [(role: String, text: String)]) async {
        guard let scorer = appDelegate?.relevanceScorer else { return }

        // Format conversation
        let conversationText = conversation.map { entry in
            entry.role == "user" ? "Me: \(entry.text)" : "Coach: \(entry.text)"
        }.joined(separator: "\n\n")

        // Format existing insights
        let existingInsights: String
        if memory.insights.isEmpty {
            existingInsights = "None yet — first conversation"
        } else {
            existingInsights = memory.insights.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }

        let extractionPrompt = """
        You are updating a user's coaching memory file based on their planning conversation.

        EXISTING MEMORIES:
        \(existingInsights)

        TODAY'S CONVERSATION:
        \(conversationText)

        Update the memories. You may ADD new observations, UPDATE existing ones, or REMOVE stale ones.

        WORTH REMEMBERING:
        - Work patterns: productive times, preferred block lengths, break habits
        - Active projects and deadlines
        - Self-awareness: "I always underestimate...", "I tend to skip breaks..."
        - Coaching preferences: what they adjusted or pushed back on

        NOT WORTH REMEMBERING:
        - Today's specific schedule (saved separately)
        - One-off events ("meeting at 2pm today")
        - Things already captured unchanged in existing memories

        Rules:
        - Max 8 observations, one sentence each
        - If conversation was trivial, return existing memories unchanged
        - Update > append: if user's project changed, replace the old entry

        Return ONLY a JSON array of strings: ["observation 1", "observation 2", ...]
        """

        // Always use Qwen for extraction (needs 32K context for full conversation)
        await scorer.loadMLXModelIfNeeded()
        guard scorer.mlxModelLoaded, let ctx = scorer.modelContext else {
            appDelegate?.postLog("⚠️ PlanningCoach: MLX not available for memory extraction")
            return
        }

        do {
            let session = ChatSession(ctx)
            let response = try await session.respond(to: extractionPrompt)
            appDelegate?.postLog("💬 PlanningCoach extraction response: \(response.prefix(300))")

            // Parse JSON array from response
            let cleaned = cleanMessage(response)
            if let jsonStart = cleaned.firstIndex(of: "["),
               let jsonEnd = cleaned[jsonStart...].lastIndex(of: "]") {
                let jsonString = String(cleaned[jsonStart...jsonEnd])
                if let data = jsonString.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    let capped = Array(parsed.prefix(8))
                    memory.insights = capped
                    saveMemory()
                    appDelegate?.postLog("💬 PlanningCoach: Saved \(capped.count) insights to memory")
                    return
                }
            }
            appDelegate?.postLog("⚠️ PlanningCoach: Failed to parse extraction response as JSON array")
        } catch {
            appDelegate?.postLog("⚠️ PlanningCoach: Memory extraction failed: \(error)")
        }
    }

    /// Update preferred block duration from suggested blocks (rolling average).
    private func extractAndSavePatterns(from blocks: [SuggestedBlock]) {
        let workBlocks = blocks.filter { $0.blockType != "freeTime" }
        if !workBlocks.isEmpty {
            let durations = workBlocks.map { ($0.endHour * 60 + $0.endMinute) - ($0.startHour * 60 + $0.startMinute) }
            let avgDuration = durations.reduce(0, +) / durations.count
            // Rolling average: 70% existing, 30% new
            memory.preferredBlockDuration = Int(Double(memory.preferredBlockDuration) * 0.7 + Double(avgDuration) * 0.3)
        }
        saveMemory()
    }

    // MARK: - System Prompt

    private func buildSystemPrompt() -> String {
        let now = Date()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeStr = timeFormatter.string(from: now)

        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)

        let profile = appDelegate?.scheduleManager?.profile ?? ""
        let existingBlocks = formatExistingBlocks()

        // Build context sections
        let userContext = buildUserContext(profile: profile)
        let historyContext = buildHistoryContext()
        let yesterdayContext = buildYesterdayContext()
        let todayContext = buildTodayContext(existingBlocks: existingBlocks)

        return """
        You are a focused productivity coach. Warm, brief, evidence-based.

        \(userContext)

        \(historyContext)

        \(yesterdayContext)

        \(todayContext)
        Current time: \(timeStr)

        COACHING APPROACH:
        - Reference past wins to build confidence: "You hit 85% focus on coding yesterday"
        - Suggest continuing unfinished tasks from yesterday (Zeigarnik effect)
        - Front-load demanding/creative work in morning, admin/lighter tasks after 2pm
        - Default 60-90 min work blocks with 15-min freeTime breaks
        - If the user's input is vague (e.g., "plan my day" with no tasks), ask ONE clarifying question like "What's the ONE thing that would make today a win?"
        - If the user gives tasks but no timing info, ask briefly about their schedule: "When do you want to start? Any fixed commitments?" — then generate blocks.
        - If the user gives tasks WITH times (e.g., "code my app then groceries at 10"), generate blocks IMMEDIATELY — do not ask clarifying questions. You already have what you need.
        - Never ask more than ONE question per response. Get to blocks as fast as possible.
        - Keep responses concise (2-3 sentences max for the message)
        - If the user message starts with "[PRIORITIES]", generate a full day schedule immediately — do NOT ask clarifying questions. Include 3-5 blocks with breaks. Keep the message to one encouraging sentence.

        RULES:
        - BLOCK TITLES MUST USE THE USER'S OWN WORDS. If they say "coding my app", title it "Coding my app". If they say "groceries", title it "Groceries". NEVER invent specific sub-tasks, project names, or technical details the user didn't say. Wrong: user says "work on my app" → "Implement authentication flow". Right: user says "work on my app" → "Work on my app".
        - Suggest 3-5 blocks covering the remaining hours of the day
        - Include breaks (freeTime blocks) between work sessions
        - Work blocks should be 45-120 minutes
        - Don't schedule blocks before the current time (\(hour):\(String(format: "%02d", minute)))
        - NEVER generate overlapping blocks. Each block must end at or before the next block starts. Verify this before returning.
        - When the user states a specific time (e.g., "groceries at 10 pm"), treat it as a hard constraint — schedule surrounding blocks to end before that time.
        - Blocks must be in chronological order in the array.

        RESPONSE FORMAT (always valid JSON):
        {
          "message": "Your conversational response here",
          "blocks": [
            {
              "title": "Block title",
              "description": "What to focus on",
              "startHour": 9, "startMinute": 0,
              "endHour": 10, "endMinute": 30,
              "blockType": "focusHours"
            }
          ]
        }

        blockType must be one of: "focusHours", "deepWork", "freeTime"

        If you're asking questions and not yet suggesting blocks, return "blocks": [].
        """
    }

    private func buildUserContext(profile: String) -> String {
        var lines: [String] = ["ABOUT THIS USER:"]
        if !profile.isEmpty {
            lines.append("- Work profile: \(profile)")
        }
        lines.append("- Preferred block length: ~\(memory.preferredBlockDuration)min")
        if !memory.insights.isEmpty {
            for insight in memory.insights {
                lines.append("- \(insight)")
            }
        } else {
            lines.append("- New user, no coaching history yet")
        }
        return lines.joined(separator: "\n")
    }

    private func buildHistoryContext() -> String {
        guard let scheduleManager = appDelegate?.scheduleManager else {
            return "RECENT HISTORY (last 7 days):\nNo history available."
        }

        let history = scheduleManager.getRecentHistory(days: 7)
        guard !history.isEmpty else {
            return "RECENT HISTORY (last 7 days):\nNo history yet — this is a new user."
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEE MMM d"

        var lines = ["RECENT HISTORY (last 7 days):"]
        for day in history {
            let dateDisplay: String
            if let date = dayFormatter.date(from: day.date) {
                dateDisplay = displayFormatter.string(from: date)
            } else {
                dateDisplay = day.date
            }
            let blockTitles = day.blocks.filter { !$0.isFree }.map { $0.title }
            let goalsStr = day.goals.isEmpty ? "" : ", goals: \(day.goals.joined(separator: ", "))"
            let blocksStr = blockTitles.isEmpty ? "" : " — \(blockTitles.joined(separator: ", "))"
            lines.append("\(dateDisplay): \(day.blocks.count) blocks\(blocksStr)\(goalsStr)")
        }
        return lines.joined(separator: "\n")
    }

    private func buildYesterdayContext() -> String {
        guard let scheduleManager = appDelegate?.scheduleManager else {
            return "YESTERDAY:\nNo data available."
        }

        // Get yesterday's date
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let yesterdayStr = formatter.string(from: yesterday)

        if let yesterdaySchedule = scheduleManager.getScheduleForDate(yesterdayStr) {
            var lines = ["YESTERDAY:"]
            if !yesterdaySchedule.goals.isEmpty {
                lines.append("Goals: \(yesterdaySchedule.goals.joined(separator: ", "))")
            }
            let blockTitles = yesterdaySchedule.blocks.filter { !$0.isFree }.map { $0.title }
            if !blockTitles.isEmpty {
                lines.append("Blocks: \(blockTitles.joined(separator: ", "))")
            }
            return lines.joined(separator: "\n")
        }

        return "YESTERDAY:\nNo schedule data."
    }

    private func buildTodayContext(existingBlocks: String) -> String {
        var lines = ["TODAY SO FAR:"]

        if existingBlocks.isEmpty {
            lines.append("No blocks scheduled yet today.")
        } else {
            lines.append("Existing blocks today:")
            lines.append(existingBlocks)
        }

        // Add today's focus summary if available
        if let eb = appDelegate?.earnedBrowseManager {
            let summary = eb.todaySummary()
            if summary.blockCount > 0 {
                let focusedMins = Int(summary.focusedMinutes)
                lines.append("\(summary.blockCount) blocks done, \(summary.avgFocusScore)% avg focus, \(focusedMins) min focused")
            }

            // Add per-block focus scores for completed blocks
            let stats = eb.blockFocusStats
            if !stats.isEmpty {
                let scored = stats.values
                    .filter { $0.totalTicks > 0 }
                    .sorted { $0.blockTitle < $1.blockTitle }
                for s in scored {
                    lines.append("  \(s.blockTitle): \(s.focusScore)% focus (\(s.relevantTicks)/\(s.totalTicks) ticks)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatExistingBlocks() -> String {
        guard let blocks = appDelegate?.scheduleManager?.todaySchedule?.blocks, !blocks.isEmpty else {
            return ""
        }
        return blocks.map { b in
            let startStr = String(format: "%d:%02d", b.startHour, b.startMinute)
            let endStr = String(format: "%d:%02d", b.endHour, b.endMinute)
            let typeStr = b.isFree ? "Free Time" : b.blockType.rawValue
            return "- \(startStr)-\(endStr): \(b.title) (\(typeStr))"
        }.joined(separator: "\n")
    }

    // MARK: - Apple Foundation Models

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func chatWithFoundationModels(userMessage: String) async throws -> PlanResponse {
        let response = try await fmSession.respond(to: userMessage)
        let text = response.content
        appDelegate?.postLog("💬 PlanningCoach FM response: \(text.prefix(200))")
        return parseResponse(text)
    }
    #endif

    // MARK: - MLX (Qwen3-4B)

    private func chatWithMLX(userMessage: String) async throws -> PlanResponse {
        guard let session = mlxSession else {
            throw NSError(domain: "PlanningCoach", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "MLX session not initialized"])
        }

        // First message includes system prompt; subsequent messages are just user text
        let prompt: String
        if !mlxSystemPromptSent {
            prompt = buildSystemPrompt() + "\n\nUser: " + userMessage
            mlxSystemPromptSent = true
        } else {
            prompt = userMessage
        }

        let response = try await session.respond(to: prompt)
        appDelegate?.postLog("💬 PlanningCoach MLX response: \(response.prefix(200))")
        return parseResponse(response)
    }

    // MARK: - Response Parsing

    /// Parse JSON response from LLM. Graceful degradation: if JSON parsing fails,
    /// return the raw text as the message with no blocks.
    private func parseResponse(_ text: String) -> PlanResponse {
        // Try to find JSON object in response
        guard let jsonStart = text.firstIndex(of: "{"),
              let jsonEnd = text[jsonStart...].lastIndex(of: "}") else {
            // No JSON found — treat entire response as message
            return PlanResponse(message: cleanMessage(text), blocks: [])
        }

        let jsonString = String(text[jsonStart...jsonEnd])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PlanResponse(message: cleanMessage(text), blocks: [])
        }

        let message = (json["message"] as? String) ?? cleanMessage(text)
        var blocks: [SuggestedBlock] = []

        if let blocksArray = json["blocks"] as? [[String: Any]] {
            for b in blocksArray {
                guard let title = b["title"] as? String,
                      let startHour = b["startHour"] as? Int,
                      let startMinute = b["startMinute"] as? Int,
                      let endHour = b["endHour"] as? Int,
                      let endMinute = b["endMinute"] as? Int else {
                    continue
                }
                let blockType = (b["blockType"] as? String) ?? "focusHours"
                let description = (b["description"] as? String) ?? ""
                blocks.append(SuggestedBlock(
                    title: title,
                    description: description,
                    startHour: startHour,
                    startMinute: startMinute,
                    endHour: endHour,
                    endMinute: endMinute,
                    blockType: blockType
                ))
            }
        }

        return PlanResponse(message: message, blocks: blocks)
    }

    /// Strip markdown artifacts and thinking tags from LLM output.
    private func cleanMessage(_ text: String) -> String {
        var cleaned = text
        // Remove <think>...</think> blocks (Qwen thinking mode)
        if let thinkRange = cleaned.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            cleaned.removeSubrange(thinkRange)
        }
        // Remove ```json ... ``` wrappers
        cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
