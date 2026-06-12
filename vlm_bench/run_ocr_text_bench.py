#!/usr/bin/env python3
"""Round 2 (2026-06-12): OCR+text baseline — replicates the pipeline the app
shipped (Apple Vision OCR -> first ~600 chars -> Qwen3-4B text model) on the
same 30 screenshots, so the bake-off has the missing comparison row.

OCR: VNRecognizeTextRequest, accurate mode, via pyobjc-framework-Vision.
Text model: mlx-community/Qwen3-4B-Instruct-2507-4bit via mlx_lm (loaded from
the app's flat cache at ~/Library/Caches/models/mlx-community/ if present).
Prompt: the ORIGINAL v0 one-sentence+category prompt, adapted for text input —
this row represents what shipped, not the tuned Round-2 prompts.

Usage:
    HF_HOME=$PWD/models .venv/bin/python run_ocr_text_bench.py
"""

import json
import resource
import time
from pathlib import Path

from run_vlm_bench import parse_output

TEXT_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
APP_CACHE = Path.home() / "Library/Caches/models" / TEXT_MODEL
OCR_CHAR_LIMIT = 600

PROMPT_TEMPLATE = (
    "Based on this text OCR'd from the user's screen, describe in one "
    "sentence what the user is doing on this screen, then on a new line "
    "output exactly one category: "
    "work | communication | entertainment | shopping | neutral.\n\n"
    "OCR text:\n{ocr}"
)


def ocr_image(path: str) -> tuple[str, float]:
    """Apple Vision accurate-mode OCR. Returns (text, wall_seconds)."""
    import Quartz
    import Vision
    from Foundation import NSURL

    t0 = time.perf_counter()
    url = NSURL.fileURLWithPath_(path)
    src = Quartz.CGImageSourceCreateWithURL(url, None)
    cgimage = Quartz.CGImageSourceCreateImageAtIndex(src, 0, None)
    handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(
        cgimage, None
    )
    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    ok, err = handler.performRequests_error_([request], None)
    if not ok:
        raise RuntimeError(f"Vision OCR failed: {err}")
    lines = []
    for obs in request.results() or []:
        cand = obs.topCandidates_(1)
        if cand and len(cand):
            lines.append(str(cand[0].string()))
    return "\n".join(lines), time.perf_counter() - t0


def main():
    bench_dir = Path(__file__).parent
    shots = sorted((bench_dir / "shots").glob("*.png"))
    out_path = bench_dir / "results" / "ocr-text__Qwen3-4B-Instruct-2507-4bit.jsonl"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    import mlx.core as mx
    from mlx_lm import load, generate
    from mlx_lm.sample_utils import make_sampler

    model_path = str(APP_CACHE) if APP_CACHE.exists() else TEXT_MODEL
    print(f"[ocr-bench] loading {model_path} ...", flush=True)
    t0 = time.perf_counter()
    model, tokenizer = load(model_path)
    load_s = time.perf_counter() - t0
    print(f"[ocr-bench] loaded in {load_s:.1f}s", flush=True)

    sampler = make_sampler(temp=0.0)
    records = []
    with out_path.open("w") as f:
        for i, shot in enumerate(shots):
            try:
                ocr_text, ocr_s = ocr_image(str(shot))
            except Exception as e:
                ocr_text, ocr_s = "", 0.0
                print(f"[ocr-bench] OCR ERROR {shot.name}: {e}", flush=True)
            snippet = ocr_text[:OCR_CHAR_LIMIT]
            prompt = PROMPT_TEMPLATE.format(ocr=snippet)
            messages = [{"role": "user", "content": prompt}]
            formatted = tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False
            )
            t0 = time.perf_counter()
            try:
                text = generate(
                    model, tokenizer, formatted,
                    max_tokens=120, sampler=sampler, verbose=False,
                )
                llm_s = time.perf_counter() - t0
                err = None
            except Exception as e:
                llm_s = time.perf_counter() - t0
                text, err = "", f"{type(e).__name__}: {e}"
            sentence, category = parse_output(text)
            rec = {
                "model": f"ocr-text/{TEXT_MODEL}",
                "file": shot.name,
                "warmup": i == 0,
                "ocr_s": round(ocr_s, 3),
                "ocr_chars": len(ocr_text),
                "ocr_snippet": snippet,
                "wall_s": round(ocr_s + llm_s, 3),
                "llm_s": round(llm_s, 3),
                "raw_output": text,
                "sentence": sentence,
                "category": category,
                "error": err,
                "metal_peak_gb": round(mx.get_peak_memory() / 1e9, 3),
                "peak_rss_gb": round(
                    resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9, 3
                ),
            }
            records.append(rec)
            f.write(json.dumps(rec) + "\n")
            f.flush()
            print(f"[ocr-bench] {i+1}/{len(shots)} {shot.name}: ocr {ocr_s:.2f}s "
                  f"({len(ocr_text)} ch) + llm {llm_s:.2f}s cat={category or '?'}",
                  flush=True)

        ok = [r for r in records if not r["error"] and not r["warmup"]]
        lats = sorted(r["wall_s"] for r in ok)
        summary = {
            "model": f"ocr-text/{TEXT_MODEL}",
            "summary": True,
            "load_s": round(load_s, 2),
            "n": len(records),
            "n_errors": sum(1 for r in records if r["error"]),
            "median_s": lats[len(lats) // 2] if lats else None,
            "p90_s": lats[min(len(lats) - 1, int(len(lats) * 0.9))] if lats else None,
            "metal_peak_gb": round(mx.get_peak_memory() / 1e9, 3),
            "peak_rss_gb": round(
                resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9, 3
            ),
        }
        f.write(json.dumps(summary) + "\n")
    print(f"[ocr-bench] done -> {out_path}")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
