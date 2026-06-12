#!/usr/bin/env python3
"""Local-VLM bake-off harness for the Intentional Focus Agent vision tier.

For one model x all screenshots in shots/: one-sentence description + category.
Measures model-load time, per-inference wall clock, peak RSS + Metal memory.
Writes JSONL to results/<model_safe_name>.jsonl.

Run one model per process so RSS / GPU memory measurements are clean:
    HF_HOME=$PWD/models .venv/bin/python run_vlm_bench.py --model <hf_repo>
"""

import argparse
import json
import re
import resource
import sys
import time
from pathlib import Path

PROMPT = (
    "Describe in one sentence what the user is doing on this screen, "
    "then on a new line output exactly one category: "
    "work | communication | entertainment | shopping | neutral."
)

# Round 2 (2026-06-12): prompt variants for Qwen3.5-4B category tuning.
# labels.json + rubric are ground truth and untouched; only the prompt changes.
_CATEGORY_DEFS = (
    "Categories (pick exactly ONE):\n"
    "- work: coding, terminals, IDEs, code-assistant sessions, documents, "
    "professional tools, job tasks\n"
    "- communication: actively reading or writing email, chat, or messages "
    "in an inbox or conversation view\n"
    "- entertainment: watching any video (YouTube etc.), browsing video or "
    "social feeds, games, streaming\n"
    "- shopping: browsing online stores or products\n"
    "- neutral: app settings or configuration pages, onboarding/setup/signup "
    "screens, system dialogs, idle desktops\n"
    "\n"
    "Rules:\n"
    "- Watching a YouTube video or browsing a video feed is entertainment "
    "even if the topic seems serious, educational, or news-like.\n"
    "- A settings page that merely lists or mentions websites/apps is "
    "neutral, not the category of the sites it lists.\n"
    "- Signup, verification-code, and onboarding screens are neutral, not "
    "communication.\n"
    "- A terminal or coding session is work even if the text is hard to read."
)

PROMPT_VARIANTS = {
    "v0": PROMPT,
    # v1: same ordering, category definitions + decision rules inline
    "v1_defs": (
        "Describe in one sentence what the user is doing on this screen, "
        "then on a new line output exactly one category word.\n\n"
        + _CATEGORY_DEFS
    ),
    # v2: category FIRST, then the sentence (decide before describing)
    "v2_catfirst": (
        "Classify what the user is doing on this screen.\n\n"
        + _CATEGORY_DEFS
        + "\n\nOutput format — exactly two lines:\n"
        "Line 1: the single category word.\n"
        "Line 2: one sentence describing what the user is doing."
    ),
    # v3: definitions + few-shot worked examples of the output format
    "v3_fewshot": (
        "Describe in one sentence what the user is doing on this screen, "
        "then on a new line output exactly one category word.\n\n"
        + _CATEGORY_DEFS
        + "\n\nExample outputs:\n"
        "The user is watching a YouTube video about a news documentary in Chrome.\n"
        "entertainment\n\n"
        "The user is running an AI coding session in a dark full-screen terminal.\n"
        "work\n\n"
        "The user is reviewing blocked-site settings in a productivity app.\n"
        "neutral"
    ),
    # v4: terse format-anchored ask, definitions only (no rules paragraph)
    "v4_anchor": (
        "Look at this screenshot of the user's screen.\n"
        "First line: one sentence — what is the user doing?\n"
        "Second line: 'Category: <word>' where <word> is exactly one of "
        "work, communication, entertainment, shopping, neutral.\n\n"
        + _CATEGORY_DEFS
    ),
}

CATEGORIES = {"work", "communication", "entertainment", "shopping", "neutral"}

THINK_RE = re.compile(r"<think>.*?(</think>|$)", re.DOTALL)


def peak_rss_gb() -> float:
    # ru_maxrss is bytes on macOS
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9


def parse_output(text: str):
    """Split model output into (sentence, category)."""
    cleaned = THINK_RE.sub("", text).strip()
    lines = [l.strip() for l in cleaned.splitlines() if l.strip()]
    category = ""
    sentence = cleaned
    # search from the end for a line that is/contains exactly one category
    for line in reversed(lines):
        norm = line.lower().strip(" .:*`'\"")
        norm = re.sub(r"^category\s*[:\-]?\s*", "", norm)
        if norm in CATEGORIES:
            category = norm
            sentence = " ".join(l for l in lines if l is not line)
            break
    if not category:
        # fallback: last category word mentioned anywhere
        found = [c for c in CATEGORIES if re.search(rf"\b{c}\b", cleaned.lower())]
        if len(found) == 1:
            category = found[0]
    return sentence.strip(), category


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="HF repo id")
    ap.add_argument("--shots", default="shots", help="screenshot dir")
    ap.add_argument("--out", default=None, help="output jsonl path")
    ap.add_argument("--max-tokens", type=int, default=120)
    ap.add_argument("--limit", type=int, default=0, help="only run N shots (smoke test)")
    ap.add_argument("--no-think", action="store_true",
                    help="pass enable_thinking=False to the chat template (Qwen3.5 hybrid)")
    ap.add_argument("--variant", default="v0", choices=sorted(PROMPT_VARIANTS),
                    help="prompt variant (Round 2 category tuning)")
    args = ap.parse_args()
    prompt = PROMPT_VARIANTS[args.variant]

    bench_dir = Path(__file__).parent
    shots = sorted((bench_dir / args.shots).glob("*.png"))
    if args.limit:
        shots = shots[: args.limit]
    if not shots:
        sys.exit("no shots found")

    safe = args.model.replace("/", "__")
    if args.variant != "v0":
        safe += f"__{args.variant}"
    out_path = Path(args.out) if args.out else bench_dir / "results" / f"{safe}.jsonl"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    import mlx.core as mx
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config

    if "fastvlm" in args.model.lower():
        # InsightKeeper FastVLM MLX quants name the projector
        # `multi_modal_projector.linear_0/linear_2`; mlx-vlm 0.6.3's fastvlm
        # module expects `mm_projector.0/2` (CallableModuleList indices).
        # The checkpoint is tagged format=mlx, so utils.load_model SKIPS
        # Model.sanitize; remap at the earliest point — when safetensors are
        # read — so the quantization class_predicate sees the right key names.
        from mlx_vlm import utils as _vutils

        _orig_lst = _vutils._load_safetensors

        def _patched_lst(path):
            weights = _orig_lst(path)
            return {
                re.sub(r"^(model\.)?multi_modal_projector\.linear_(\d+)\.",
                       r"mm_projector.\2.", k): v
                for k, v in weights.items()
            }

        _vutils._load_safetensors = _patched_lst

    print(f"[bench] loading {args.model} ...", flush=True)
    t0 = time.perf_counter()
    model, processor = load(args.model)
    config = load_config(args.model)
    load_s = time.perf_counter() - t0
    print(f"[bench] loaded in {load_s:.1f}s", flush=True)

    template_kwargs = {}
    if args.no_think:
        template_kwargs["enable_thinking"] = False

    records = []
    with out_path.open("w") as f:
        # warm-up is NOT excluded: record it but flag it (first inference compiles kernels)
        for i, shot in enumerate(shots):
            try:
                formatted = apply_chat_template(
                    processor, config, prompt, num_images=1, **template_kwargs
                )
            except TypeError:
                formatted = apply_chat_template(processor, config, prompt, num_images=1)
            t0 = time.perf_counter()
            try:
                result = generate(
                    model, processor, formatted, image=[str(shot)],
                    verbose=False, max_tokens=args.max_tokens, temperature=0.0,
                )
                wall = time.perf_counter() - t0
                text = result.text if hasattr(result, "text") else str(result)
                err = None
            except Exception as e:  # record failures, keep going
                wall = time.perf_counter() - t0
                text, err = "", f"{type(e).__name__}: {e}"
            sentence, category = parse_output(text)
            rec = {
                "model": args.model,
                "variant": args.variant,
                "file": shot.name,
                "warmup": i == 0,
                "wall_s": round(wall, 3),
                "raw_output": text,
                "sentence": sentence,
                "category": category,
                "error": err,
                "peak_rss_gb": round(peak_rss_gb(), 3),
                "metal_peak_gb": round(mx.get_peak_memory() / 1e9, 3),
            }
            records.append(rec)
            f.write(json.dumps(rec) + "\n")
            f.flush()
            print(f"[bench] {i+1}/{len(shots)} {shot.name}: {wall:.2f}s "
                  f"cat={category or '?'} {'ERR ' + err if err else ''}", flush=True)

        ok = [r for r in records if not r["error"] and not r["warmup"]]
        lats = sorted(r["wall_s"] for r in ok)
        summary = {
            "model": args.model,
            "summary": True,
            "load_s": round(load_s, 2),
            "n": len(records),
            "n_errors": sum(1 for r in records if r["error"]),
            "median_s": lats[len(lats) // 2] if lats else None,
            "p90_s": lats[min(len(lats) - 1, int(len(lats) * 0.9))] if lats else None,
            "peak_rss_gb": round(peak_rss_gb(), 3),
            "metal_peak_gb": round(mx.get_peak_memory() / 1e9, 3),
        }
        f.write(json.dumps(summary) + "\n")
    print(f"[bench] done -> {out_path}")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
