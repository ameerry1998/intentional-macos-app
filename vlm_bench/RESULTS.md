# Local-VLM bake-off — Focus Agent vision tier

**Date:** 2026-06-12 · **Machine:** Apple M4 Pro, 24 GB unified memory (`sysctl -n machdep.cpu.brand_string` → `Apple M4 Pro`)
**Task:** screenshot → ONE descriptive sentence + ONE category (`work | communication | entertainment | shopping | neutral`), to feed the coaching agent.
**Dataset:** 30 screenshots, all 1440 px wide (production capture size): 15 reused app/onboarding shots + 15 fresh full-screen captures of the live machine over ~30 min (terminal coding sessions, YouTube videos/feeds). Shots + models stay local and are gitignored. Ground truth: `labels.json` (hand-labeled by inspecting every image; ambiguous shots carry an `alt_category`).
**Stack:** `mlx-vlm 0.6.3`, `mlx 0.31.2`, Python 3.12 venv at `vlm_bench/.venv`. Harness: `run_vlm_bench.py` (temperature 0, max 120 tokens, one model per process). Scoring: `score_results.py` + `grades.json` (every description hand-graded 0/1/2 vs truth; hallucination ⇒ automatic 0).

## Results

| Model | Cat acc | Cat acc (+alt) | Desc grade /2 | Halluc | Load s | Median s | p90 s | Max cadence (p90×1.5) | Metal peak GB |
|---|---|---|---|---|---|---|---|---|---|
| **mlx-community/Qwen3-VL-4B-Instruct-4bit** | **90%** | **93%** | **1.93** | 0 | 2.0 | 6.8 | 16.0 | every ~24 s | 4.7 |
| mlx-community/Qwen3.5-4B-4bit | 77% | 80% | 1.90 | 0 | 2.4 | 6.9 | 8.5 | every ~13 s | 5.8 |
| apple/FastVLM-1.5B (fp16) | 10%* | 10%* | 1.70 | 1 | 1.7 | 1.2 | 1.4 | every ~2.2 s | 4.3 |
| apple/FastVLM-0.5B (fp16) | 17%* | 17%* | 1.13 | 3 | 0.6 | 0.5 | 0.7 | every ~1.1 s | 2.2 |

\* FastVLM's category score is dominated by an **instruction-following failure**, not blindness: it usually emits only the sentence and skips the category line entirely (parsed as wrong). Its underlying scene understanding is better than 10% suggests — the 1.5B's descriptions average 1.70/2.

Raw per-inference records: `results/<model>.jsonl` (gitignored — they contain descriptions of the user's screen).

### Notes per model

- **Qwen3-VL-4B-Instruct-4bit** — clear quality winner. Reads on-screen text verbatim (video titles, tab names, dialog text), follows the two-line format on 29/30, zero hallucinations. One degenerate output (`!!!!…`) on the lowest-resolution VM screenshot. **Latency has a fat tail**: median 6.8 s but 13–30 s on dense full-screen pages (vision-token count scales with content at 1440 px).
- **Qwen3.5-4B-4bit** — the "one model replaces the text scorer too" candidate (Qwen3.5-4B is natively multimodal; this is the same checkpoint that can do text-only relevance scoring). Nearly identical description quality (1.90/2, zero hallucinations) and a much tighter latency distribution (worst case 8.8 s). Category accuracy lower (77%): it drifts into `communication`/`entertainment` on app-config screens and `work/neutral` on YouTube-with-terminal-visible screens. Ran with `enable_thinking=False`.
- **apple/FastVLM-1.5B** — 5× faster than the Qwens (1.2 s median), descriptions genuinely decent (1.70/2), one hallucination ("Discovery Channel website"). Ignores the category instruction. Would need a constrained-decoding category head or a tiny text-model second pass to be usable end-to-end.
- **apple/FastVLM-0.5B** — fastest (0.5 s) and smallest (2.2 GB peak) but vague, 3 hallucinations on UI-heavy screens, weakest descriptions (1.13/2). Fine at "YouTube vs terminal" granularity; unreliable below that.
- **Not run:** mlx-community quantized FastVLM repos (InsightKeeper FastVLM-*-MLX-4bit) are converted for an older mlx-vlm fastvlm architecture — projector + vision-tower key names don't match mlx-vlm 0.6.3 (3 load attempts, documented in harness comments). Official `apple/FastVLM-*` fp16 checkpoints load fine (need `torch`+`timm` in the venv for the HF remote processor code).

### RAM reality check (≤4 GB target)

Metal peak during inference at 1440 px input: only FastVLM-0.5B (2.2 GB) is under 4 GB. Qwen3-VL peaks at 4.7 GB, FastVLM-1.5B at 4.3 GB, Qwen3.5-4B at 5.8 GB — weights are ~3 GB (4-bit) but image-encoding buffers push the transient peak over. Mitigations if 4 GB is hard: capture at 1024 px instead of 1440 px (vision tokens scale ~quadratically), set `mx.set_cache_limit`, or use the 3-bit Qwen3-VL quant. Treat 4.7 GB transient on a 24 GB machine as acceptable for a background agent; on 8 GB Macs it is not.

## Recommendation

**(a) Best model overall: `mlx-community/Qwen3-VL-4B-Instruct-4bit`.** 90% category accuracy, 1.93/2 descriptions, zero hallucinations — it's the only candidate whose output you could hand to a coaching agent unedited. `Qwen3.5-4B-4bit` is the strategic runner-up: ~same description quality, predictable latency, and it can also replace the existing Qwen3-4B text scorer (one model in memory instead of two), at the cost of 13 points of category accuracy — likely recoverable with a better-anchored category prompt + few-shot examples.

**(b) Is 5 s / 10 s continuous cadence viable?** Not with either Qwen (median ~7 s, p90 8.5–16 s — a 5 s or even 10 s timer would pile up). FastVLM-0.5B/1.5B CAN sustain 1–2 s cadence on this M4 Pro, but their one-pass output isn't trustworthy enough to coach from. So: **fixed high-frequency cadence is only viable with a model we don't want to trust alone.**

**(c) Recommended architecture: change-gated, two-tier.**
1. **Gate (free):** poll frontmost app + window title / URL every 1–2 s (NSWorkspace + AppleScript — already exists in FocusMonitor). Only when context changes (or every 60 s heartbeat during dwell) capture a screenshot.
2. **Describe (Qwen3-VL-4B-4bit):** one inference per change event. Real context switches happen every couple of minutes, not every 5 s — measured 7–16 s inference is fine for a coaching narrative, and the GPU stays idle the rest of the time on a user-shared machine.
3. Optional fast tier: FastVLM-1.5B as a cheap "did the scene meaningfully change / is this obviously entertainment" pre-filter at 1–2 s if sub-second reaction is ever needed — but don't let its output reach the coach without the Qwen pass.

If memory pressure makes two resident models (text scorer + VLM) untenable, switch both roles to `Qwen3.5-4B-4bit` and invest a day in category-prompt tuning + a small eval expansion of `labels.json` (this bench is reusable: `./run_all.sh` then `score_results.py`).

### Bench caveats (honest limits)

- 30 shots, single machine, single day; no `shopping` or true `communication` shots ended up in the live set (category coverage: work, entertainment, neutral dominate). Accuracy on those two categories is untested.
- 15/30 shots are the Intentional app itself (onboarding/dashboard) — labeled `neutral` mostly; this inflates the difficulty of the neutral/work boundary and is exactly the ambiguity the `alt_category` column tracks.
- Description grades are one grader's judgment (recorded per-item in `grades.json` for audit).
- First-inference warm-up is recorded but flagged (`warmup: true`) and excluded from latency stats.
