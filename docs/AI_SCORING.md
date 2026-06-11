# AI Scoring (RelevanceScorer)

## Scoring Pipeline (in order)
1. **Keyword overlap** — fast path, checks title words against block title/description (excludes stop words)
2. **User-approved whitelist** — pages user explicitly approved (cleared on block change)
3. **Cache lookup** — key: `"intention|pageTitle"`, cleared on block change
4. **LLM metadata pass** — MLX Qwen3-4B (hardcoded); Apple Foundation Models is the automatic fallback if MLX fails to load
5. **OCR verification pass** — second-chance rescore for off-task verdicts on container apps (see below)

## Content Types
- `.webpage` — scores browser tab page title
- `.application` — scores desktop app name

## AI Models
**There is no user-facing model picker.** The AI Scoring settings page (and its Apple-vs-Qwen dropdown) was removed in the Settings Consolidation pass (2026-06-10); `SET_AI_MODEL` survives as a no-op bridge handler for one release cycle. The model is hardcoded:

| Model | Role | Notes |
|-------|------|-------|
| MLX Qwen3-4B (`mlx-community/Qwen3-4B-Instruct-2507-4bit`) | THE model — always tried first | Via `MLXLLM` + `MLXLMCommon`. `RelevanceScorer.currentModelId`. |
| Apple Foundation Models | Automatic in-code fallback only | macOS 26+, via `FoundationModels` framework. Used only when the MLX model fails to load/score — never user-selected. |

## Fail-Closed Policy
On LLM parse error: `relevant = false`, `confidence = 0`. This ensures broken AI doesn't silently allow everything. Combined with the confidence gate (below), a parse-error verdict is let through as "no signal" rather than enforced.

## OCR Verification Pass
For container apps (Safari/Chrome tabs, Electron shells) where the window title is often uninformative, an off-task metadata verdict triggers a second-chance rescore against on-screen OCR text.

**Capture strategy: serial, on-demand.**
Capture is invoked via `ScreenCapture().captureFrontmostWindow()` only inside the OCR branch, after the metadata verdict comes back off-task and `shouldVerifyWithOCR` returns true. No parallel pre-capture runs during metadata scoring — this avoids window-server contention with `ContentSafetyMonitor`'s 2s `CGWindowListCreateImage` poll and keeps the Neural Engine queue clear for OpenNSFW.

**PID drift guard.** The frontmost-app PID is sampled at scoring entry (`startPID`) and compared to `capture.pid` after capture returns. If they differ, the user switched apps mid-scoring and the OCR output is discarded — the metadata off-task verdict stands.

**OCR prompt (Flag 2).** The rescore builds a fresh prompt containing the OCR excerpt. It does NOT reference the prior verdict or anchor the model on a previous decision.

## ScoringPath
Every verdict is tagged with a `ScoringPath` (see `Intentional/ScoringPath.swift`) for instrumentation:

| Path | Meaning |
|------|---------|
| `metadataRelevant` | Metadata said relevant — no OCR performed |
| `metadataOffTask` | Metadata said off-task, confidence ≥ threshold, enforced |
| `metadataOffTaskLowConf` | Metadata said off-task below confidence threshold — let through (not enforced) |
| `ocrVerifiedRelevant` | OCR rescore overturned off-task metadata verdict |
| `ocrVerifiedOffTask` | OCR rescore confirmed off-task — enforced regardless of confidence |

## Confidence Gate
See `Intentional/ConfidenceGate.swift`. Pure function `shouldEnforceOffTask(relevant:confidence:path:)` encodes the asymmetric-cost policy: a wrong block is much worse than a wrong pass.

- `relevant == true` → never enforce (any path, any confidence)
- `relevant == false && path == .ocrVerifiedOffTask` → enforce (OCR already resolved uncertainty)
- `relevant == false && confidence >= 50` → enforce
- `relevant == false && confidence < 50` → let through; log as `.metadataOffTaskLowConf`

Threshold = 50 (inclusive). Tests: `IntentionalTests/ConfidenceGateTests.swift`.
