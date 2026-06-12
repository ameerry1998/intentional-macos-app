#!/usr/bin/env python3
"""Score bake-off results: category accuracy vs labels.json + manual description
grades from grades.json (graded by a human/agent reading each output vs truth).

grades.json format: {"<model_repo>": {"<file>": {"grade": 0|1|2, "hallucination": bool}}}

Usage: .venv/bin/python score_results.py
Prints a markdown summary table.
"""

import json
from pathlib import Path

BENCH = Path(__file__).parent


def main():
    labels = {l["file"]: l for l in json.loads((BENCH / "labels.json").read_text())}
    grades_path = BENCH / "grades.json"
    grades = json.loads(grades_path.read_text()) if grades_path.exists() else {}

    rows = []
    for jl in sorted((BENCH / "results").glob("*.jsonl")):
        if jl.name.startswith("smoke"):
            continue
        recs = [json.loads(l) for l in jl.read_text().splitlines() if l.strip()]
        summary = next((r for r in recs if r.get("summary")), {})
        recs = [r for r in recs if not r.get("summary")]
        if not recs:
            continue
        model = recs[0]["model"]
        variant = recs[0].get("variant")
        if variant and variant != "v0":
            model = f"{model}__{variant}"  # Round-2 prompt variants
        mg = grades.get(model, {})

        n = cat_ok = cat_ok_alt = errors = 0
        graded = []
        halluc = 0
        for r in recs:
            lab = labels.get(r["file"])
            if not lab:
                continue
            n += 1
            if r.get("error"):
                errors += 1
                continue
            if r["category"] == lab["category"]:
                cat_ok += 1
                cat_ok_alt += 1
            elif lab.get("alt_category") and r["category"] == lab["alt_category"]:
                cat_ok_alt += 1
            g = mg.get(r["file"])
            if g is not None:
                grade = 0 if g.get("hallucination") else g["grade"]
                graded.append(grade)
                halluc += 1 if g.get("hallucination") else 0

        lats = sorted(r["wall_s"] for r in recs if not r.get("error") and not r.get("warmup"))
        med = lats[len(lats) // 2] if lats else None
        p90 = lats[min(len(lats) - 1, int(len(lats) * 0.9))] if lats else None
        rows.append({
            "model": model,
            "n": n,
            "cat_acc": cat_ok / n if n else 0,
            "cat_acc_alt": cat_ok_alt / n if n else 0,
            "desc_grade": sum(graded) / len(graded) if graded else None,
            "halluc": halluc,
            "errors": errors,
            "load_s": summary.get("load_s"),
            "median_s": med,
            "p90_s": p90,
            "cadence_s": round(p90 * 1.5, 1) if p90 else None,
            "metal_peak_gb": summary.get("metal_peak_gb"),
            "peak_rss_gb": summary.get("peak_rss_gb"),
        })

    hdr = ("| Model | Cat acc | Cat acc (+alt) | Desc grade /2 | Halluc | Errors | "
           "Load s | Median s | p90 s | Max cadence | Metal peak GB |")
    sep = "|" + "---|" * 11
    print(hdr)
    print(sep)
    for r in rows:
        dg = f"{r['desc_grade']:.2f}" if r["desc_grade"] is not None else "—"
        print(f"| {r['model']} | {r['cat_acc']:.0%} | {r['cat_acc_alt']:.0%} | {dg} | "
              f"{r['halluc']} | {r['errors']} | {r['load_s']} | {r['median_s']} | "
              f"{r['p90_s']} | every {r['cadence_s']}s | {r['metal_peak_gb']} |")


if __name__ == "__main__":
    main()
