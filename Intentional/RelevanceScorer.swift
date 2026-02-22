import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

import MLXLLM
import MLXLMCommon  // LanguageModel protocol
import MLX          // GPU cache configuration

/// Scores activity relevance against the current work block intention
/// using Apple Foundation Models (on-device ~3B LLM, macOS 26+).
/// Falls back to "always relevant" on older macOS versions.
///
/// Supports two content types:
/// - `.webpage`: Scores a browser tab's page title
/// - `.application`: Scores a desktop application name (e.g., "Messages", "Xcode")
class RelevanceScorer {

    weak var appDelegate: AppDelegate?

    enum ContentType {
        case webpage
        case application
    }

    struct Result {
        var relevant: Bool
        var confidence: Int  // 0-100
        var reason: String
    }

    // Cache: "intention|pageTitle" → Result
    private var cache: [String: Result] = [:]
    private var currentIntention: String = ""

    // MLX model state
    private var mlxContext: ModelContext?
    private var mlxSession: ChatSession?
    private var mlxModelLoading = false
    private var mlxModelLoaded = false

    // User-approved pages (survives cache clears within a block, cleared on block change)
    private var userApproved: Set<String> = []

    // Stop words excluded from keyword overlap matching
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "have", "some",
        "work", "working", "doing", "make", "get", "use", "using", "look",
        "find", "check", "need", "want", "will", "can", "all", "any", "more"
    ]

    // System prompt — focused solely on task vs. activity matching (no profile)
    private let systemPrompt = """
    Determine if the user's current activity (a webpage or desktop application) is \
    directly related to their current work task.
    The task title is LITERAL — treat it as the specific name of a project, topic, or activity. \
    Do NOT reinterpret the task title as a general concept or stretch its meaning. \
    For example, "Working on intentional" means working on a project called "Intentional" \
    (likely a software project), NOT doing things "intentionally" or anything related to \
    "deliberate decision-making" or "strategic thinking".
    Relevant activities: tools, docs, code, research, forums, and resources that DIRECTLY \
    help with the specific task described. Learning materials count only if they are about \
    the task's specific subject matter.
    NOT relevant: entertainment, news, social media, videos, or content that requires \
    creative interpretation to connect to the task. If you have to construct a chain of \
    reasoning to justify relevance, it is NOT relevant.
    CRITICAL: Judge the ACTUAL page content shown in the title, not the platform's POTENTIAL. \
    A generic homepage like "YouTube", "Reddit", or "Twitter" is NOT relevant just because \
    the platform COULD be used for the task. The title must show specific content related to \
    the task. "YouTube" alone is NOT relevant to "Studying for chemistry exam" — but \
    "Organic Chemistry Lecture - YouTube" IS relevant. \
    Similarly, "Reddit" is NOT relevant to "Learning Python" — but \
    "r/learnpython - How to use decorators" IS relevant.
    The task title is what the user EXPLICITLY chose to work on right now. \
    If the activity clearly matches what the block title literally describes, it IS relevant. \
    For example, if the block is "watching YouTube" then YouTube videos are relevant. \
    If the block is "reading news" then news sites are relevant. \
    If the block is "doing taxes" then tax preparation sites and tax-related pages are relevant.
    """

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct RelevanceOutput {
        @Guide(description: "One sentence explaining why this activity is or isn't related to the task")
        var reason: String
        @Guide(description: "Is this activity relevant to the user's current work intention?")
        var relevant: Bool
        @Guide(description: "Confidence from 0 to 100", .range(0...100))
        var confidence: Int
    }

    private var _session: Any? = nil

    @available(macOS 26.0, *)
    private var session: LanguageModelSession {
        get {
            if let s = _session as? LanguageModelSession { return s }
            let s = LanguageModelSession(instructions: systemPrompt)
            _session = s
            return s
        }
        set { _session = newValue }
    }
    #endif

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
        appDelegate?.postLog("🧠 RelevanceScorer initialized")
    }

    /// Clear the relevance cache (call when block changes)
    func clearCache() {
        cache.removeAll()
        userApproved.removeAll()
        currentIntention = ""
        // Reset the LLM session so it doesn't carry context from previous block
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            _session = nil
        }
        #endif
        // MLX: reset session so it doesn't carry context from previous block
        mlxSession = mlxContext.map { ChatSession($0) }
        appDelegate?.postLog("🧠 Relevance cache cleared")
    }

    /// Approve a page title for the current intention (user justified it).
    /// Persists until block changes (cleared by clearCache()).
    func approvePageTitle(_ pageTitle: String, for intention: String) {
        let cacheKey = "\(intention)|\(pageTitle)"
        let result = Result(relevant: true, confidence: 100, reason: "User-approved")
        cache[cacheKey] = result
        userApproved.insert(cacheKey)
        appDelegate?.postLog("🧠 User approved: \"\(pageTitle)\" for \"\(intention)\"")
    }

    /// Score a page title or app name against the current work intention.
    /// Returns cached result if available.
    func scoreRelevance(
        pageTitle: String,
        intention: String,
        intentionDescription: String = "",
        profile: String,
        dailyPlan: String,
        contentType: ContentType = .webpage
    ) async -> Result {
        let cacheKey = "\(intention)|\(pageTitle)"

        // Keyword overlap: catch obvious matches without hitting the LLM
        if hasKeywordOverlap(intention: intention, pageTitle: pageTitle) {
            let result = Result(relevant: true, confidence: 95, reason: "Keyword match with task")
            cache[cacheKey] = result
            return result
        }

        // User-approved whitelist (from justification)
        if userApproved.contains(cacheKey) {
            return Result(relevant: true, confidence: 100, reason: "User-approved")
        }

        // Check cache
        if let cached = cache[cacheKey] {
            return cached
        }

        // Track intention changes — clear cache when block switches
        if intention != currentIntention {
            cache.removeAll()
            currentIntention = intention
        }

        // Check which AI model to use
        let aiModel = appDelegate?.scheduleManager?.aiModel ?? "apple"

        if aiModel == "qwen" {
            // MLX path: load model if needed, then score
            await loadMLXModelIfNeeded()
            if mlxModelLoaded {
                do {
                    let result = try await scoreWithMLX(
                        pageTitle: pageTitle,
                        intention: intention,
                        intentionDescription: intentionDescription,
                        contentType: contentType
                    )
                    cache[cacheKey] = result
                    return result
                } catch {
                    appDelegate?.postLog("⚠️ RelevanceScorer: MLX scoring error: \(error)")
                    // Fall through to Foundation Models if MLX fails
                }
            }
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let result = try await scoreWithFoundationModels(
                    pageTitle: pageTitle,
                    intention: intention,
                    intentionDescription: intentionDescription,
                    profile: profile,
                    dailyPlan: dailyPlan,
                    contentType: contentType
                )
                cache[cacheKey] = result
                return result
            } catch {
                appDelegate?.postLog("⚠️ RelevanceScorer: Foundation Models error: \(error)")
            }
        }
        #endif

        // Fallback: assume relevant (don't block if scoring unavailable)
        let fallback = Result(relevant: true, confidence: 0, reason: "Scoring unavailable on this macOS version")
        return fallback
    }

    // MARK: - Keyword Overlap

    /// Check if any keyword from the intention shares a common stem with a word in the page title.
    /// Uses prefix matching (min 3 chars) to handle basic morphological variants (e.g. "taxes" ↔ "tax").
    private func hasKeywordOverlap(intention: String, pageTitle: String) -> Bool {
        let intentWords = extractKeywords(intention)
        let titleWords = extractKeywords(pageTitle)
        for iw in intentWords {
            for tw in titleWords {
                if iw.count >= 3 && tw.count >= 3 && (iw.hasPrefix(tw) || tw.hasPrefix(iw)) {
                    return true
                }
            }
        }
        return false
    }

    /// Extract meaningful keywords from text (3+ chars, no stop words).
    private func extractKeywords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 3 && !Self.stopWords.contains($0) }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func scoreWithFoundationModels(
        pageTitle: String,
        intention: String,
        intentionDescription: String = "",
        profile: String,
        dailyPlan: String,
        contentType: ContentType = .webpage
    ) async throws -> Result {
        let contentLabel = contentType == .webpage ? "Webpage title" : "Application in use"
        let descLine = intentionDescription.isEmpty ? "" : "\nBlock description: \(intentionDescription)"
        // Clean page title: strip HTML entities and non-ASCII punctuation that confuse the model
        let cleanTitle = pageTitle
            .replacingOccurrences(of: #"&[a-zA-Z0-9#]+;"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "™", with: "")
            .trimmingCharacters(in: .whitespaces)
        let userMessage = """
        Current time block task: "\(intention)"\(descLine)
        \(contentLabel): "\(cleanTitle)"
        """

        let response = try await session.respond(to: userMessage, generating: RelevanceOutput.self)
        let output = response.content

        let result = Result(
            relevant: output.relevant,
            confidence: output.confidence,
            reason: output.reason
        )

        appDelegate?.postLog("🧠 Score: \"\(pageTitle)\" → \(result.relevant ? "relevant" : "NOT relevant") (\(result.confidence)%) — \(result.reason)")
        return result
    }
    #endif

    // MARK: - MLX (Qwen3-4B)

    /// Lazily load the MLX Qwen3-4B model on first use.
    private func loadMLXModelIfNeeded() async {
        guard !mlxModelLoaded && !mlxModelLoading else { return }
        mlxModelLoading = true
        do {
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
            let model = try await loadModel(
                id: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
            )
            mlxContext = model
            mlxSession = ChatSession(model)
            mlxModelLoaded = true
            appDelegate?.postLog("🧠 MLX Qwen3-4B loaded successfully")
        } catch {
            appDelegate?.postLog("⚠️ MLX model load failed: \(error)")
        }
        mlxModelLoading = false
    }

    /// Score relevance using MLX Qwen3-4B model.
    private func scoreWithMLX(
        pageTitle: String,
        intention: String,
        intentionDescription: String,
        contentType: ContentType
    ) async throws -> Result {
        guard let session = mlxSession else {
            throw NSError(domain: "RelevanceScorer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "MLX model not loaded"])
        }

        let contentLabel = contentType == .webpage ? "Webpage title" : "Application in use"
        let descLine = intentionDescription.isEmpty ? "" : "\nBlock description: \(intentionDescription)"
        let cleanTitle = pageTitle
            .replacingOccurrences(of: #"&[a-zA-Z0-9#]+;"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "™", with: "")
            .trimmingCharacters(in: .whitespaces)

        let prompt = """
        \(systemPrompt)

        Current time block task: "\(intention)"\(descLine)
        \(contentLabel): "\(cleanTitle)"

        Respond with ONLY a JSON object: {"reason":"...","relevant":true/false,"confidence":0-100}
        """

        let response = try await session.respond(to: prompt)

        // Parse JSON from response
        let result = parseMLXResponse(response)
        appDelegate?.postLog("🧠 MLX Score: \"\(pageTitle)\" → \(result.relevant ? "relevant" : "NOT relevant") (\(result.confidence)%) — \(result.reason)")
        return result
    }

    /// Parse JSON response from MLX model output.
    private func parseMLXResponse(_ text: String) -> Result {
        // Try to extract JSON object from the response
        guard let jsonStart = text.firstIndex(of: "{"),
              let jsonEnd = text[jsonStart...].lastIndex(of: "}") else {
            return Result(relevant: false, confidence: 0, reason: "Could not assess - AI model error")
        }

        let jsonString = String(text[jsonStart...jsonEnd])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let relevant = json["relevant"] as? Bool,
              let reason = json["reason"] as? String else {
            return Result(relevant: false, confidence: 0, reason: "Could not assess - AI model error")
        }

        let confidence = json["confidence"] as? Int ?? 0
        return Result(relevant: relevant, confidence: confidence, reason: reason)
    }

    // MARK: - Justification Assessment

    /// Assess whether a user's justification for visiting social media is work-related.
    /// Used by EarnedBrowseManager to determine 1x vs 2x cost multiplier.
    func assessJustification(text: String, intention: String, intentionDescription: String = "") async -> (approved: Bool, reason: String) {
        let userMessage = """
        The user is working on: "\(intention)"\(intentionDescription.isEmpty ? "" : " — \(intentionDescription)")
        They want to visit social media and gave this reason: "\(text)"

        Is this reason DIRECTLY related to their work task?
        Only approve if the social media visit would genuinely help with the specific task.
        Do NOT approve vague reasons like "I need a break" or "checking something".

        Respond with JSON: {"approved": true/false, "reason": "one sentence explanation"}
        """

        // Try MLX model first if configured
        let aiModel = appDelegate?.scheduleManager?.aiModel ?? "apple"
        if aiModel == "qwen" && mlxModelLoaded, let session = mlxSession {
            do {
                let response = try await session.respond(to: userMessage)
                if let jsonStart = response.firstIndex(of: "{"),
                   let jsonEnd = response[jsonStart...].lastIndex(of: "}") {
                    let jsonString = String(response[jsonStart...jsonEnd])
                    if let data = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let approved = json["approved"] as? Bool,
                       let reason = json["reason"] as? String {
                        appDelegate?.postLog("🧠 Justification assessed (MLX): approved=\(approved), reason=\(reason)")
                        return (approved: approved, reason: reason)
                    }
                }
            } catch {
                appDelegate?.postLog("⚠️ MLX justification assessment error: \(error)")
            }
        }

        // Try Apple Foundation Models
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let response = try await session.respond(to: userMessage, generating: RelevanceOutput.self)
                let approved = response.content.relevant
                let reason = response.content.reason
                appDelegate?.postLog("🧠 Justification assessed (Apple FM): approved=\(approved), reason=\(reason)")
                return (approved: approved, reason: reason)
            } catch {
                appDelegate?.postLog("⚠️ Foundation Models justification error: \(error)")
            }
        }
        #endif

        // Fallback: deny by default (conservative)
        return (approved: false, reason: "Scoring unavailable — defaulting to standard rate")
    }
}
