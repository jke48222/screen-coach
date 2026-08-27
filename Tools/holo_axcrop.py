#!/usr/bin/env python3
"""Does the accessibility tree aim the vision fallback better than a blind grid?

Phase 0 established that native-resolution cropping beats downscaling by 3× at
equal token cost, and that even a blind 3×3 grid cell beat feeding the whole
window on both speed and accuracy. This asks the follow-up the architecture
actually depends on: when AX cannot name the element, can it still say *where
to look* — and is that better than tiling?

Three conditions, one model, identical targets and prompts:

  full     the whole captured frame, downscaled to fit the encoder
  crop3    the 3×3 grid cell containing the target, native resolution.
           Blind: it knows the target's position because the harness does,
           which makes it a generous baseline, not a realistic one.
  axcrop   the crop `screencoach-bench axplan` derived from the accessibility
           tree with the target ABLATED — the tree never saw the element.
           Some of these fall back to the whole frame, and that counts.

Ground truth is AX bounds in display pixels; a hit is a predicted click inside
the element's real box, the ScreenSpot-Pro criterion.
"""

import argparse
import json
import math
import statistics
import time
from pathlib import Path

from PIL import Image

from holo_bench import (describe, localization_prompt, parse_click, smart_resize)


def p(vals, q):
    s = sorted(vals)
    return s[min(len(s) - 1, max(0, math.ceil(q / 100 * len(s)) - 1))]


def prepare(image, crop, max_pixels=None):
    """Crop, resize to the encoder's budget, and return the inverse mapping."""
    x0, y0 = 0.0, 0.0
    if crop is not None:
        x0, y0, cw, ch = crop
        x0, y0 = max(0, int(x0)), max(0, int(y0))
        x1 = min(image.width, int(x0 + cw))
        y1 = min(image.height, int(y0 + ch))
        if x1 - x0 < 8 or y1 - y0 < 8:
            x0, y0, x1, y1 = 0, 0, image.width, image.height
        image = image.crop((x0, y0, x1, y1))
    w, h = image.size
    rh, rw = smart_resize(h, w, max_pixels=max_pixels or 3686400)
    resized = image.resize((rw, rh), Image.Resampling.LANCZOS)
    sx, sy = w / rw, h / rh
    return resized, (lambda mx, my: (mx * sx + x0, my * sy + y0)), rw * rh


def grid_cell(image, target_px, k=3):
    W, H = image.size
    cx = target_px[0] + target_px[2] / 2
    cy = target_px[1] + target_px[3] / 2
    cw, ch = W / k, H / k
    col = min(k - 1, max(0, int(cx // cw)))
    row = min(k - 1, max(0, int(cy // ch)))
    mx, my = cw * 0.25, ch * 0.25
    x0, y0 = max(0, col * cw - mx), max(0, row * ch - my)
    return [x0, y0, min(W, (col + 1) * cw + mx) - x0, min(H, (row + 1) * ch + my) - y0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(Path.home() / "models/holo1.5-7b-4bit"))
    ap.add_argument("--data", default="bench-data/google-chrome.json")
    ap.add_argument("--plan", default="bench-data/axplan-chrome.json")
    ap.add_argument("--max-tokens", type=int, default=48)
    ap.add_argument("--out", default="bench-data/holo-axcrop.json")
    args = ap.parse_args()

    gt = json.loads(Path(args.data).read_text())
    plan = json.loads(Path(args.plan).read_text())
    root = Path(args.data).parent
    image = Image.open(root / gt["image"]).convert("RGB")

    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config

    print(f"Loading {args.model} …", flush=True)
    model, processor = load(args.model)
    config = load_config(args.model)
    print(f"  {image.width}×{image.height} canonical frame, "
          f"{len(plan['plans'])} targets\n")

    conditions = ["full", "crop3", "axcrop"]
    results = {c: [] for c in conditions}
    tmp = root / ".holo_axcrop.png"

    for cond in conditions:
        for row in plan["plans"]:
            tpx = row["target_px"]
            if cond == "full":
                crop = None
            elif cond == "crop3":
                crop = grid_cell(image, tpx, 3)
            else:
                crop = row["crop_px"]

            img, to_frame, npx = prepare(image, crop)
            img.save(tmp)
            prompt = apply_chat_template(
                processor, config, localization_prompt(row["query"]), num_images=1
            )
            t0 = time.perf_counter()
            ttft, text = None, ""
            for chunk in stream_generate(model, processor, prompt, image=str(tmp),
                                         max_tokens=args.max_tokens, temperature=0.0):
                if ttft is None:
                    ttft = time.perf_counter() - t0
                text += chunk.text

            click = parse_click(text)
            hit, dist = False, None
            if click:
                px, py = to_frame(*click)
                hit = (tpx[0] <= px <= tpx[0] + tpx[2]) and (tpx[1] <= py <= tpx[1] + tpx[3])
                dist = math.hypot(px - (tpx[0] + tpx[2] / 2), py - (tpx[1] + tpx[3] / 2))
            results[cond].append({
                "query": row["query"], "hit": hit, "dist_px": dist,
                "ttft_ms": ttft * 1000, "tokens": npx // 784,
                "crop_covered_target": row.get("crop_contains_target"),
            })
        rows = results[cond]
        hits = sum(r["hit"] for r in rows)
        print(f"  {cond:8s} acc {hits}/{len(rows)} = {hits/len(rows)*100:5.1f}%   "
              f"ttft p50 {statistics.median([r['ttft_ms'] for r in rows]):7.0f} ms   "
              f"~{statistics.median([r['tokens'] for r in rows]):5.0f} tok", flush=True)

    tmp.unlink(missing_ok=True)

    print("\n── per-target (hit / distance in px)")
    print(f"  {'target':44s} " + "".join(f"{c:>12s}" for c in conditions))
    for i, row in enumerate(plan["plans"]):
        cells = []
        for c in conditions:
            r = results[c][i]
            cells.append("HIT" if r["hit"] else (f"{r['dist_px']:.0f}px" if r["dist_px"] else "n/a"))
        covered = "" if results["axcrop"][i]["crop_covered_target"] else "  [crop missed target]"
        print(f"  {row['query'][:44]:44s} " + "".join(f"{c:>12s}" for c in cells) + covered)

    Path(args.out).write_text(json.dumps({"model": args.model, "results": results}, indent=2))
    print(f"\nWrote {args.out}")


if __name__ == "__main__":
    main()
