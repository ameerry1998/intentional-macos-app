//
//  VLMDescriber.swift
//  Intentional
//
//  Vision-model screen describer for Focus Agent telemetry.
//  Bench winner (vlm_bench/RESULTS.md): the v2_catfirst prompt scored 100%
//  categories / 1.87 desc on tuned Qwen3.5-4B, but the pinned mlx-swift-lm
//  revision (a3e1bf4) has no qwen3_5 vision support — MLXVLM's registry tops
//  out at qwen3_vl. So we run the Round-1 winner Qwen3-VL-4B-Instruct-4bit
//  (90% cat / 1.93 desc / 0 hallucinations) with the same tuned prompt; the
//  category-definitions block is what does the work and transfers.
//
//  Owned by RelevanceScorer. Serialization contract: the CALLER
//  (RelevanceScorer.describeScreenForTelemetry) checks isInferenceBusy and
//  wraps describe() in beginInference/endInference — vision describes always
//  yield to in-session scoring (skip, never queue). This class only guards
//  its own load single-flight.
//

import Foundation
import CoreImage
import CoreGraphics
import MLXVLM
import MLXLMCommon
import MLX

final class VLMDescriber {

    /// Rung 2 of the feasibility ladder: qwen3_5 (vision) is not in the pinned
    /// MLXVLM registry; qwen3_vl is. mlx-community 4-bit quant — same repo the
    /// bench ran (Metal peak 4.7 GB transient at 1440 px).
    static let modelId = "mlx-community/Qwen3-VL-4B-Instruct-4bit"
    static var engineTag: String { "vlm:\(modelId)" }

    /// Winning prompt VERBATIM from vlm_bench/RESULTS.md Round 2 (v2_catfirst).
    static let prompt = """
    Classify what the user is doing on this screen.

    Categories (pick exactly ONE):
    - work: coding, terminals, IDEs, code-assistant sessions, documents, professional tools, job tasks
    - communication: actively reading or writing email, chat, or messages in an inbox or conversation view
    - entertainment: watching any video (YouTube etc.), browsing video or social feeds, games, streaming
    - shopping: browsing online stores or products
    - neutral: app settings or configuration pages, onboarding/setup/signup screens, system dialogs, idle desktops

    Rules:
    - Watching a YouTube video or browsing a video feed is entertainment even if the topic seems serious, educational, or news-like.
    - A settings page that merely lists or mentions websites/apps is neutral, not the category of the sites it lists.
    - Signup, verification-code, and onboarding screens are neutral, not communication.
    - A terminal or coding session is work even if the text is hard to read.

    Output format — exactly two lines:
    Line 1: the single category word.
    Line 2: one sentence describing what the user is doing.
    """

    /// Bench guard: 1/30 v2_catfirst runs emitted only the bare category word.
    /// Retry instruction appended verbatim per the production recommendation.
    static let retryInstruction = "Respond with the category line AND a one-sentence description."

    private static let categories: Set<String> = [
        "work", "communication", "entertainment", "shopping", "neutral",
    ]

    // MARK: - Model state (lock-guarded; load is fire-and-forget)

    private let stateLock = NSLock()
    private var context: ModelContext?
    private var loading = false
    private var loadFailed = false

    /// True once the VLM weights are resident. While false, the caller stays
    /// on the OCR+text fallback path.
    var isLoaded: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return context != nil
    }

    /// Kick off the lazy download+load without blocking the caller. The model
    /// lands in the MLX cache convention (~/Library/Caches/models/<repo>/ via
    /// MLXLMCommon.defaultHubApi) — first call downloads ~3 GB, so describes
    /// keep falling back to OCR+text until this finishes. Single-flight;
    /// a failed load is terminal for this app run (fallback stays on).
    func startLoadingIfNeeded(log: @escaping (String) -> Void) {
        stateLock.lock()
        guard context == nil, !loading, !loadFailed else {
            stateLock.unlock()
            return
        }
        loading = true
        stateLock.unlock()

        Task { [weak self] in
            do {
                log("🖼️ VLMDescriber: loading \(Self.modelId) (downloads to ~/Library/Caches/models on first use — may take minutes)")
                MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
                let ctx = try await loadModel(id: Self.modelId)
                guard let self else { return }
                self.stateLock.lock()
                self.context = ctx
                self.loading = false
                self.stateLock.unlock()
                log("🖼️ VLMDescriber: loaded \(Self.modelId) — screen descriptions now run on the vision model")
            } catch {
                guard let self else { return }
                self.stateLock.lock()
                self.loadFailed = true
                self.loading = false
                self.stateLock.unlock()
                log("⚠️ VLMDescriber: load failed (\(error)) — descriptions stay on OCR+text fallback")
            }
        }
    }

    // MARK: - Describe

    /// One vision inference: v2_catfirst prompt + the (pre-downscaled) window
    /// capture, temp 0, maxTokens 80. Returns "sentence [category]" — the same
    /// wire format the OCR+text path produces — or nil when the model isn't
    /// loaded or the output stays degenerate after one retry (caller falls
    /// back to OCR+text).
    func describe(image: CGImage) async -> String? {
        stateLock.lock()
        let ctx = context
        stateLock.unlock()
        guard let ctx else { return nil }

        guard let resized = Self.downscale(image, maxWidth: 1440) else { return nil }
        let ciImage = CIImage(cgImage: resized)

        if let result = await runOnce(context: ctx, prompt: Self.prompt, image: ciImage) {
            return result
        }
        // Output guard from the bench: bare category word / <15 chars → retry
        // once with an explicit two-line demand (fresh session — don't let the
        // degenerate first answer pollute history).
        let retryPrompt = Self.prompt + "\n\n" + Self.retryInstruction
        return await runOnce(context: ctx, prompt: retryPrompt, image: ciImage)
    }

    private func runOnce(context: ModelContext, prompt: String, image: CIImage) async -> String? {
        // Fresh one-shot session per call (no history pollution). processing
        // resize is nil: we already downscaled to ≤1440 px wide — the bench's
        // production capture size — and ChatSession's default would crush the
        // image to 512×512.
        let session = ChatSession(context, processing: UserInput.Processing(resize: nil))
        session.generateParameters.temperature = 0.0
        session.generateParameters.maxTokens = 80

        guard let raw = try? await session.respond(to: prompt, image: .ciImage(image)) else {
            return nil
        }
        guard !Self.isDegenerate(raw) else { return nil }
        return Self.parseCatFirstResponse(raw)
    }

    // MARK: - Output guard + parsing (internal for testability)

    /// Bench failure mode live-1: model emits only the bare category word.
    /// Every category word is <15 chars, so the length check subsumes the
    /// bare-word check — both kept for clarity.
    static func isDegenerate(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 15 { return true }
        if categories.contains(trimmed.lowercased()) { return true }
        return false
    }

    /// Parse v2_catfirst output (category line, then sentence line) into the
    /// existing "sentence [category]" wire format. Returns nil if no usable
    /// sentence (≥15 chars) is present.
    static func parseCatFirstResponse(_ raw: String) -> String? {
        // Strip <think>...</think> defensively (mirrors the text parser).
        var cleaned = raw
        while let thinkStart = cleaned.range(of: "<think>"),
              let thinkEnd = cleaned.range(of: "</think>"),
              thinkStart.lowerBound < thinkEnd.upperBound {
            cleaned.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }
        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var category: String?
        var sentence: String?
        for line in lines {
            let token = line.lowercased()
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if category == nil, categories.contains(token) {
                category = token
                continue
            }
            if sentence == nil, line.count >= 15 {
                sentence = line
            }
        }
        guard let sentence else { return nil }
        return "\(String(sentence.prefix(200))) [\(category ?? "neutral")]"
    }

    // MARK: - Image downscale

    /// Downscale to at most `maxWidth` px wide (aspect preserved) before
    /// inference — vision-token count scales ~quadratically with resolution
    /// and 1440 px is the size the bench validated.
    static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: maxWidth, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return ctx.makeImage()
    }
}
