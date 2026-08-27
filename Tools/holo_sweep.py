#!/usr/bin/env python3
"""Phase 0 (c), part two: what actually drives Holo1.5's latency, and what it costs.

The first run said 6.0 s time-to-first-token for one grounding call against a
budget of 400–900 ms. Quantising 16.6 GB of weights down to 5.3 GB moved that
by 15%, which rules the weights out as the bottleneck and points at the vision
encoder: a 2322×1900 window is 3.65 megapixels, and Qwen2.5-VL turns that into
roughly 4,700 image tokens before a single output token exists.

If that is the real term, then the fix is the one the architecture already
called for — feed the model less image — and this sweep measures the exchange
rate between pixels, latency, and accuracy:

  display     the whole screen, which is what a pure-vision coach does
  window      window-scoped capture, the current design
  window@N    the window downscaled to an N-megapixel budget
  cropK       the KxK grid cell containing the target, at native resolution,
              which is what the pipeline can actually do when it has a rough
              idea where to look

Scored against accessibility-tree ground truth: a hit is a predicted click
inside the element's real bounds, the ScreenSpot-Pro criterion.
"""

import argparse
import json
import math
import statistics
import time
from pathlib import Path

from PIL import Image

from holo_bench import (CLICK_SCHEMA, describe, localization_prompt,
                        parse_click, pick_targets, smart_resize)


def p(vals, q):
    s = sorted(vals)
    return s[min(len(s) - 1, max(0, math.ceil(q / 100 * len(s)) - 1))]


class Condition:
    """Builds the image for one target and the mapping back to window pixels."""

    def __init__(self, name, base_image, offset, max_pixels=None, grid=None):
        self.name = name
        self.base = base_image
        self.offset = offset          # base image origin in window-pixel space
        self.max_pixels = max_pixels
        self.grid = grid

    def build(self, target):
        img = self.base
        # Crop origin, in the base image's own pixel space.
        cx0, cy0 = 0.0, 0.0

        if self.grid:
            # The grid cell containing the target, plus a margin. This
            # simulates knowing the rough region — from a partial AX hit, or
            # from the reasoning model naming a panel — without handing over
            # the answer, since the cell is a fixed tiling of the window
            # rather than a box centred on the element.
            W, H = self.base.size
            tcx = target["center"][0] + self.offset[0]
            tcy = target["center"][1] + self.offset[1]
            cw, ch = W / self.grid, H / self.grid
            col = min(self.grid - 1, max(0, int(tcx // cw)))
            row = min(self.grid - 1, max(0, int(tcy // ch)))
            mx, my = cw * 0.25, ch * 0.25
            x0 = max(0, col * cw - mx)
            y0 = max(0, row * ch - my)
            x1 = min(W, (col + 1) * cw + mx)
            y1 = min(H, (row + 1) * ch + my)
            img = self.base.crop((int(x0), int(y0), int(x1), int(y1)))
            cx0, cy0 = int(x0), int(y0)

        w, h = img.size
        mp = self.max_pixels or 3686400
        rh, rw = smart_resize(h, w, max_pixels=mp)
        resized = img.resize((rw, rh), Image.Resampling.LANCZOS)

        # Model answers in resized pixels. Undo resize, undo crop, undo the
        # base image's own offset, and we are back in window-pixel space
        # where the ground truth lives.
        sx, sy = w / rw, h / rh

        def to_window(mx_, my_):
            return (mx_ * sx + cx0 - self.offset[0],
                    my_ * sy + cy0 - self.offset[1])

        return resized, to_window, (rw, rh)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(Path.home() / "models/holo1.5-7b-4bit"))
    ap.add_argument("--data", default="bench-data/logic-pro.json")
    ap.add_argument("--targets", type=int, default=10)
    ap.add_argument("--max-tokens", type=int, default=48)
    ap.add_argument("--out", default="bench-data/holo-sweep.json")
    args = ap.parse_args()

    data_path = Path(args.data)
    gt = json.loads(data_path.read_text())
    root = data_path.parent
    targets = pick_targets(gt, args.targets)

    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config
    import mlx.core as mx

    print(f"Loading {args.model} …", flush=True)
    t0 = time.perf_counter()
    model, processor = load(args.model)
    config = load_config(args.model)
    print(f"  loaded in {time.perf_counter()-t0:.1f}s  "
          f"weights ~{mx.get_peak_memory()/1e9:.2f} GB\n")

    window_img = Image.open(root / gt["image"]).convert("RGB")
    conditions = [
        Condition("window", window_img, (0, 0)),
        Condition("window@1.0MP", window_img, (0, 0), max_pixels=1_000_000),
        Condition("window@0.5MP", window_img, (0, 0), max_pixels=500_000),
        Condition("crop2 (native)", window_img, (0, 0), grid=2),
        Condition("crop3 (native)", window_img, (0, 0), grid=3),
        Condition("crop4 (native)", window_img, (0, 0), grid=4),
    ]
    if gt.get("display"):
        disp = Image.open(root / gt["display"]["image"]).convert("RGB")
        ox, oy = gt["display"]["window_origin_px"]
        conditions.insert(0, Condition("display", disp, (ox, oy)))

    results = {}
    tmp = root / ".holo_sweep.png"

    for cond in conditions:
        rows = []
        for t in targets:
            image, to_window, (rw, rh) = cond.build(t)
            image.save(tmp)
            prompt = apply_chat_template(
                processor, config, localization_prompt(describe(t)), num_images=1
            )
            t_start = time.perf_counter()
            ttft, text = None, ""
            for chunk in stream_generate(model, processor, prompt, image=str(tmp),
                                         max_tokens=args.max_tokens, temperature=0.0):
                if ttft is None:
                    ttft = time.perf_counter() - t_start
                text += chunk.text
            total = time.perf_counter() - t_start

            click = parse_click(text)
            gx, gy, gw, gh = t["px"]
            hit, dist = False, None
            if click:
                px, py = to_window(*click)
                hit = (gx <= px <= gx + gw) and (gy <= py <= gy + gh)
                dist = math.hypot(px - (gx + gw / 2), py - (gy + gh / 2))
            rows.append({"target": describe(t), "hit": hit, "dist_px": dist,
                         "ttft_ms": ttft * 1000, "total_ms": total * 1000,
                         "px": rw * rh, "tokens_est": rw * rh // 784})

        hits = sum(r["hit"] for r in rows)
        ttfts = [r["ttft_ms"] for r in rows]
        mp = rows[0]["px"] / 1e6
        tok = rows[0]["tokens_est"]
        results[cond.name] = {
            "accuracy_pct": hits / len(rows) * 100, "hits": hits, "n": len(rows),
            "megapixels": mp, "image_tokens_est": tok,
            "ttft_p50_ms": statistics.median(ttfts), "ttft_p90_ms": p(ttfts, 90),
            "total_p50_ms": statistics.median([r["total_ms"] for r in rows]),
            "rows": rows,
        }
        print(f"  {cond.name:16s} {mp:5.2f} MP  ~{tok:5d} tok   "
              f"acc {hits}/{len(rows)} = {hits/len(rows)*100:5.1f}%   "
              f"ttft p50 {statistics.median(ttfts):7.0f} ms", flush=True)

    tmp.unlink(missing_ok=True)

    print("\n── exchange rate: pixels → latency → accuracy")
    base = results.get("window")
    for name, r in results.items():
        speed = base["ttft_p50_ms"] / r["ttft_p50_ms"] if base else 1
        print(f"  {name:16s} {r['ttft_p50_ms']:7.0f} ms  ({speed:4.2f}x)   "
              f"{r['accuracy_pct']:5.1f}%")

    Path(args.out).write_text(json.dumps({"model": args.model, "conditions": results},
                                         indent=2))
    print(f"\nWrote {args.out}")


if __name__ == "__main__":
    main()
