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

## Round 2 (2026-06-12) — Qwen3.5 prompt tuning + OCR-text baseline

Two additions, same 30 shots, same ground truth (`labels.json` and the grading rubric untouched):
**(1)** prompt-tune Qwen3.5-4B's category accuracy (was 77%); **(2)** add the missing comparison
row — the OCR+text pipeline the app actually shipped (Apple Vision OCR → first 600 chars →
Qwen3-4B text model), replicated in `run_ocr_text_bench.py`.

### Updated comparison table

| Pipeline | Cat acc | Cat acc (+alt) | Desc grade /2 | Halluc | Median s | p90 s | Worst s | Metal peak GB |
|---|---|---|---|---|---|---|---|---|
| **Qwen3.5-4B-4bit + tuned prompt (v2_catfirst)** | **100%** | **100%** | 1.87 | 0 | 8.5 | 9.5 | 10.4 | 5.9 |
| Qwen3-VL-4B-Instruct-4bit (Round 1 winner) | 90% | 93% | 1.93 | 0 | 6.8 | 16.0 | ~30 | 4.7 |
| Qwen3.5-4B-4bit, original prompt (Round 1) | 77% | 80% | 1.90 | 0 | 6.9 | 8.5 | 8.8 | 5.8 |
| OCR + Qwen3-4B text (shipped pipeline) | 23% | 37% | 1.37 | 0 | 1.5 | 1.9 | 2.4 | 2.9 |

### Qwen3.5 prompt tuning (Job 1)

Three variants run over all 30 shots (mlx-vlm, temp 0, max 120 tokens, `enable_thinking=False`),
categories graded mechanically vs `labels.json` (alt_category counts):

| Variant | Cat acc (strict) | Cat acc (+alt) | Median s | p90 s | Notes |
|---|---|---|---|---|---|
| v1_defs — sentence first + inline category definitions/rules | 100% | 100% | 8.1 | 19.5 | rambles on dense shots (worst 25.8 s) |
| **v2_catfirst — category FIRST, then sentence, same definitions** | **100%** | **100%** | 8.5 | 9.5 | tight tail; 1/30 emitted category only, no sentence |
| v3_fewshot — definitions + 3 worked example outputs | 97% | 100% | 6.8 | 7.9 | one miss is an ambiguous shot (Goals tab, work→neutral) |

The category-definitions block is what does the work — all three variants fix all 6 baseline
errors (signup screens → "communication", serious-topic YouTube → "work"/"neutral", terminal →
"neutral", Rules settings page → "entertainment"). Ordering matters for latency: category-first
keeps the worst case at 10.4 s vs 25.8 s sentence-first.

**Winner: v2_catfirst** — 100% categories, tightest tail among the 100% variants. Description
quality hand-graded per the Round-1 rubric: **1.87/2, zero hallucinations** (27× grade 2;
live-13/14 graded 1 for attributing the interview to Tucker Carlson instead of the ex-CIA guest;
live-1 graded 0 because the model emitted only the bare category word — production should retry
or min-length-check that case). Winning prompt verbatim:

```
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
```

**Overfitting caveat:** the rules were written by looking at this 30-shot set's failure modes and
then scored on the same 30 shots. 100% on the training distribution ≠ 100% in the wild — but the
rules encode genuine product policy (YouTube = entertainment regardless of topic, settings pages
are neutral), not shot-specific trivia, so most of the gain should transfer. Expand `labels.json`
with held-out shots before treating 100% as real.

### OCR+text baseline (Job 2)

`run_ocr_text_bench.py`: Apple Vision `VNRecognizeTextRequest` (accurate mode, via
pyobjc-framework-Vision) → first 600 chars → `mlx-community/Qwen3-4B-Instruct-2507-4bit` with the
original v0 prompt adapted for text input. This is the pipeline the app shipped.

**23% categories (37% +alt), 1.37/2 descriptions.** It is 5–6× faster (1.5 s median end-to-end,
OCR is 0.1–0.8 s of that) and half the memory — and it is the wrong tool for exactly the shots
that matter:

- **Visually-dominant shots crater.** On the 11 entertainment shots (YouTube videos/feeds):
  **0/11 categories correct** and 0.64/2 descriptions, vs 11/11 and 1.82/2 for tuned Qwen3.5.
  Failure mode: a video frame has almost no OCR-able text, so the first 600 chars are the menu
  bar, tab strip, and a sliver of a background terminal pane — the model concludes the user is
  "troubleshooting a bash script" (live-13) or "working on a Linux terminal session" (live-4)
  while they're actually watching YouTube. These misreads are exactly the in-session distractions
  the coach exists to catch — the shipped pipeline is blind to them.
- **Text-dense screens hold up.** On the 15 Intentional-app shots the OCR row reads fine
  (descriptions mostly 2/2) — when the screen IS text, OCR+text is competitive and fast. Its
  category misses there are the same "neutral vs work/communication" drift the untuned VLM had
  (it never saw the category definitions; it ran the shipped v0 prompt by design).
- Zero hallucinations in the strict sense: every wrong claim traces to text genuinely on screen
  (e.g. the macOS 15 update banner, the onboarding placeholder text). The failure is *sampling* —
  the 600-char window reads the wrong part of the screen — not fabrication.

### Updated recommendation

The in-session/out-of-session split means the text relevance scorer and the screen describer
never need to be resident at the same time — so the "two models in memory" objection to running
both Qwen3-VL and Qwen3-4B-text is mostly moot. The real choice:

1. **One-model strategy (recommended): `Qwen3.5-4B-4bit` with the v2_catfirst prompt for vision,
   same checkpoint for text-only relevance scoring.** Round 2 closed the only gap: 100%/1.87 vs
   Qwen3-VL's 90%/1.93 on this set, with a *tighter* latency tail than Qwen3-VL (10.4 s worst vs
   ~30 s). One checkpoint to download/cache/load, no model swap on session boundaries. Guard the
   1/30 category-only output with a retry. Validate the prompt on held-out shots first.
2. **Dedicated `Qwen3-VL-4B`** is no longer clearly better — its 90% category accuracy was beaten
   by tuned Qwen3.5, its descriptions are +0.06 better, and its latency tail is worse. Only pick
   it if Qwen3.5's tuned numbers don't replicate off this 30-shot set (it never saw the tuned
   prompt; give it the same definitions before deciding — it would likely also improve).
3. **Keep OCR+text** only as the out-of-session cheap tier or a change-detection pre-filter. At
   23% categories and 0/11 on entertainment it cannot be the in-session coach's eyes: it
   systematically mistakes "watching YouTube" for "working in a terminal" — the worst possible
   failure direction for a focus product.

### Round 2 caveats

- Same 30 shots as Round 1 — all Round-1 caveats apply, plus the prompt-overfitting caveat above.
- The OCR row's 600-char truncation matches the shipped pipeline; a smarter OCR selection
  (largest-text-first, exclude menu bar) would score better but isn't what shipped.
- Description grades for both new rows are one grader's judgment, recorded per-item in
  `grades.json` under `mlx-community/Qwen3.5-4B-4bit__v2_catfirst` and
  `ocr-text/mlx-community/Qwen3-4B-Instruct-2507-4bit` for audit.

### Bench caveats (honest limits)

- 30 shots, single machine, single day; no `shopping` or true `communication` shots ended up in the live set (category coverage: work, entertainment, neutral dominate). Accuracy on those two categories is untested.
- 15/30 shots are the Intentional app itself (onboarding/dashboard) — labeled `neutral` mostly; this inflates the difficulty of the neutral/work boundary and is exactly the ambiguity the `alt_category` column tracks.
- Description grades are one grader's judgment (recorded per-item in `grades.json` for audit).
- First-inference warm-up is recorded but flagged (`warmup: true`) and excluded from latency stats.
