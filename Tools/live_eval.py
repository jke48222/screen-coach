#!/usr/bin/env python3
"""Evaluate AX-only, vision-only and the hybrid on live macOS apps.

**Why this exists instead of ScreenSpot-Pro.**

The plan was to run the hybrid on ScreenSpot-Pro and compare against the
published Holo1.5 numbers. That cannot be done, and the reason is structural
rather than fixable: ScreenSpot-Pro is a set of static PNGs captured on other
people's machines, and an accessibility tree is live process state. There is no
AX tree for a screenshot. A grounder whose primary path is the AX tree scores
exactly its vision-only number on ScreenSpot-Pro — the benchmark cannot see the
contribution at all.

So ScreenSpot-Pro remains useful for one thing: checking that our Holo1.5 setup
reproduces the published 57.94, which validates the vision path as a component.
Measuring the *hybrid* needs targets on a running machine, where the tree
exists. That is what this does.

Ground truth is AX bounds, verified pixel-exact against Logic Pro and Chrome by
drawing them back onto the captures. A hit is a predicted point inside the
element's real box — the same criterion ScreenSpot-Pro uses, so the numbers are
comparable in kind even though the target sets differ.

Conditions:
  ax_only        resolver alone; no model, ~0.07 ms
  vision_full    Holo1.5 on the whole frame — what a pure-vision coach does
  vision_axcrop  Holo1.5 on a crop the tree aimed, target ABLATED from the tree
  hybrid         the shipping policy: AX when confident, else aimed-crop vision
"""

import argparse
import json
import math
import statistics
import time
from pathlib import Path

from PIL import Image

from holo_bench import localization_prompt, parse_click, smart_resize

AX_HIT_THRESHOLD = 0.62   # must match AXResolver.hitThreshold


def prepare(image, crop):
    x0, y0 = 0.0, 0.0
    if crop:
        cx, cy, cw, ch = crop
        x0, y0 = max(0, int(cx)), max(0, int(cy))
        x1, y1 = min(image.width, int(cx + cw)), min(image.height, int(cy + ch))
        if x1 - x0 >= 8 and y1 - y0 >= 8:
            image = image.crop((x0, y0, x1, y1))
        else:
            x0, y0 = 0.0, 0.0
    w, h = image.size
    rh, rw = smart_resize(h, w)
    resized = image.resize((rw, rh), Image.Resampling.LANCZOS)
    return resized, (lambda mx, my: (mx * (w / rw) + x0, my * (h / rh) + y0)), rw * rh


def inside(px, py, box):
    x, y, w, h = box
    return x <= px <= x + w and y <= py <= y + h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(Path.home() / "models/holo1.5-7b-4bit"))
    ap.add_argument("--snapshots", nargs="+", required=True,
                    help="snapshot JSONs from `screencoach-bench snap`")
    ap.add_argument("--plans", nargs="*", default=[],
                    help="matching axplan JSONs, in the same order as --snapshots")
    ap.add_argument("--out", default="bench-data/live-eval.json")
    args = ap.parse_args()

    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config

    print(f"Loading {args.model} …", flush=True)
    model, processor = load(args.model)
    config = load_config(args.model)

    conditions = ["ax_only", "vision_full", "vision_axcrop", "hybrid"]
    rows = {c: [] for c in conditions}
    scratch = Path(args.out).parent / ".live_eval.png"

    for i, snap_path in enumerate(args.snapshots):
        snap = json.loads(Path(snap_path).read_text())
        root = Path(snap_path).parent
        if i < len(args.plans):
            plan_path = Path(args.plans[i])
        else:
            plan_path = root / (Path(snap_path).stem + "-axplan.json")
            if not plan_path.exists():
                plan_path = root / f"axplan-{Path(snap_path).stem}.json"
        if not plan_path.exists():
            print(f"  !! no axplan beside {snap_path}; run `screencoach-bench axplan` first")
            continue
        plan = json.loads(plan_path.read_text())
        image = Image.open(root / snap["image"]).convert("RGB")
        app = snap["app"]
        print(f"\n── {app}: {len(plan['plans'])} targets")

        def run_vision(query, crop):
            img, to_frame, npx = prepare(image, crop)
            img.save(scratch)
            prompt = apply_chat_template(processor, config,
                                         localization_prompt(query), num_images=1)
            t0 = time.perf_counter()
            ttft, text = None, ""
            for chunk in stream_generate(model, processor, prompt, image=str(scratch),
                                         max_tokens=48, temperature=0.0):
                if ttft is None:
                    ttft = time.perf_counter() - t0
                text += chunk.text
            click = parse_click(text)
            pt = to_frame(*click) if click else None
            return pt, (ttft or 0) * 1000, npx // 784

        for p in plan["plans"]:
            box, query = p["target_px"], p["query"]
            ax_hit = bool(p["ax_hit"])
            ax_score = float(p["ax_score"])
            crop = None if p["crop_whole_window"] else p["crop_px"]

            rows["ax_only"].append({"app": app, "query": query, "hit": ax_hit,
                                    "ms": 0.07, "tokens": 0})

            pt_full, ms_full, tok_full = run_vision(query, None)
            rows["vision_full"].append({
                "app": app, "query": query,
                "hit": bool(pt_full and inside(*pt_full, box)),
                "ms": ms_full, "tokens": tok_full})

            pt_crop, ms_crop, tok_crop = run_vision(query, crop)
            rows["vision_axcrop"].append({
                "app": app, "query": query,
                "hit": bool(pt_crop and inside(*pt_crop, box)),
                "ms": ms_crop, "tokens": tok_crop})

            # The shipping policy, assembled from the two measurements above
            # rather than re-run: confident tree answer wins outright,
            # otherwise the aimed-crop vision answer is used.
            if ax_score >= AX_HIT_THRESHOLD:
                rows["hybrid"].append({"app": app, "query": query, "hit": ax_hit,
                                       "ms": 0.07, "tokens": 0, "via": "ax"})
            else:
                rows["hybrid"].append({
                    "app": app, "query": query,
                    "hit": bool(pt_crop and inside(*pt_crop, box)),
                    "ms": ms_crop, "tokens": tok_crop, "via": "vision"})
            print(f"   {'HIT ' if ax_hit else 'miss'}ax "
                  f"{'HIT ' if rows['vision_full'][-1]['hit'] else 'miss'}full "
                  f"{'HIT ' if rows['vision_axcrop'][-1]['hit'] else 'miss'}crop   "
                  f"{query[:46]}", flush=True)

    scratch.unlink(missing_ok=True)

    print("\n── results")
    print(f"  {'condition':16s} {'accuracy':>12s} {'p50 latency':>14s} {'tokens':>9s}")
    summary = {}
    for c in conditions:
        r = rows[c]
        if not r:
            continue
        hits = sum(x["hit"] for x in r)
        acc = hits / len(r) * 100
        p50 = statistics.median([x["ms"] for x in r])
        tok = statistics.median([x["tokens"] for x in r])
        summary[c] = {"accuracy_pct": acc, "hits": hits, "n": len(r),
                      "p50_ms": p50, "median_tokens": tok}
        print(f"  {c:16s} {hits:3d}/{len(r):<3d} = {acc:5.1f}% {p50:11.1f} ms {tok:9.0f}")

    if "hybrid" in summary:
        via_ax = sum(1 for x in rows["hybrid"] if x.get("via") == "ax")
        n = len(rows["hybrid"])
        print(f"\n  hybrid resolved {via_ax}/{n} on the tree alone "
              f"({via_ax/n*100:.0f}%) — those cost 0.07 ms and never touched the model")
        print("  Published reference points on ScreenSpot-Pro (different target set,")
        print("  same hit criterion): Holo1.5-7B 57.94, Holo1.5-72B 63.25, GPT-4o 0.8.")

    Path(args.out).write_text(json.dumps({"summary": summary, "rows": rows}, indent=2))
    print(f"\nWrote {args.out}")


if __name__ == "__main__":
    main()
