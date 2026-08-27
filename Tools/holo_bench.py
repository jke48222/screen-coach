#!/usr/bin/env python3
"""Phase 0 measurement (c): Holo1.5 grounding cost and accuracy, on this Mac.

Answers three things the architecture depends on and that exist nowhere as a
published figure for this hardware:

  1. How long does one grounding call take on an M5 Pro — split into vision
     encode (time to first token) and decode, because only the first term
     scales with image size and it is the one cropping attacks.
  2. Is Holo1.5 actually right, scored against accessibility-tree ground
     truth rather than eyeballed.
  3. Does cropping to the window instead of feeding the whole display help,
     which is the specific claim the fallback design rests on.

Ground truth comes from `screencoach-bench snap`, which writes a window PNG,
a full-display PNG, and the AX bounds of every labelled actionable element in
both pixel frames. A prediction counts as a hit when the predicted click lands
inside the element's real box — the same criterion ScreenSpot-Pro uses.
"""

import argparse
import json
import math
import statistics
import sys
import time
from pathlib import Path

from PIL import Image


# ---------------------------------------------------------------- resize

def smart_resize(height, width, factor=28, min_pixels=3136, max_pixels=3686400):
    """Qwen2.5-VL's image sizing rule, reimplemented.

    The real one lives in `transformers.models.qwen2_vl` and imports torch,
    which is a gigabyte of dependency for twenty lines of arithmetic. Holo1.5
    reports coordinates in the pixel space of the image *after* this resize,
    so getting it wrong silently shifts every prediction — which would look
    like a bad model rather than a bad harness.
    """
    if max(height, width) / min(height, width) > 200:
        raise ValueError("aspect ratio beyond model support")
    h = max(factor, round(height / factor) * factor)
    w = max(factor, round(width / factor) * factor)
    if h * w > max_pixels:
        beta = math.sqrt((height * width) / max_pixels)
        h = max(factor, math.floor(height / beta / factor) * factor)
        w = max(factor, math.floor(width / beta / factor) * factor)
    elif h * w < min_pixels:
        beta = math.sqrt(min_pixels / (height * width))
        h = math.ceil(height * beta / factor) * factor
        w = math.ceil(width * beta / factor) * factor
    return h, w


# ---------------------------------------------------------------- prompt

# Verbatim from H Company's Holo1.5 cookbook. The JSON schema is part of the
# prompt the model was trained against; paraphrasing it costs accuracy.
CLICK_SCHEMA = {
    "description": "Click at absolute coordinates.",
    "properties": {
        "action": {"const": "click_absolute", "default": "click_absolute",
                   "title": "Action", "type": "string"},
        "x": {"description": "The x coordinate, number of pixels from the left edge.",
              "title": "X", "type": "integer"},
        "y": {"description": "The y coordinate, number of pixels from the top edge.",
              "title": "Y", "type": "integer"},
    },
    "required": ["x", "y"],
    "title": "ClickAbsoluteAction",
    "type": "object",
}


def localization_prompt(target):
    return (
        "Localize an element on the GUI image according to the provided target "
        "and output a click position.\n"
        f"     * You must output a valid JSON following the format: {json.dumps(CLICK_SCHEMA)}\n"
        f"     Your target is:\n{target}"
    )


def parse_click(text):
    """Pull {x, y} out of the model's reply, tolerating stray prose."""
    try:
        start = text.index("{")
        depth, end = 0, None
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        if end:
            obj = json.loads(text[start:end])
            return float(obj["x"]), float(obj["y"])
    except Exception:
        pass
    import re
    nums = re.findall(r"-?\d+(?:\.\d+)?", text)
    if len(nums) >= 2:
        return float(nums[-2]), float(nums[-1])
    return None


# ---------------------------------------------------------------- targets

def pick_targets(gt, count, seed=0):
    """A spread of targets, deduplicated by label and by position.

    Logic Pro exposes a hundred near-identical channel-strip controls; letting
    the sampler load up on those would measure one thing repeatedly and call
    it coverage.
    """
    import random
    rng = random.Random(seed)
    seen_labels, seen_cells, pool = set(), set(), []
    for t in gt["targets"]:
        title = (t.get("title") or "").strip()
        if not title or len(title) < 2:
            continue
        cx, cy = t["center"]
        cell = (int(cx // 150), int(cy // 150))
        if title.lower() in seen_labels or cell in seen_cells:
            continue
        seen_labels.add(title.lower())
        seen_cells.add(cell)
        pool.append(t)
    rng.shuffle(pool)
    return pool[:count]


def describe(t):
    """What a reasoning model would say, not what AX stores.

    The pipeline's contract is that the LLM names targets the way a person
    would — "the Play button" — so the benchmark has to ask in those terms or
    it is measuring an easier problem than the real one.
    """
    title = (t.get("title") or "").strip()
    role = t["role"].replace("AX", "")
    noun = {"CheckBox": "button", "Button": "button", "MenuItem": "menu item",
            "PopUpButton": "pop-up button", "TextField": "text field",
            "Image": "image", "StaticText": "label", "Row": "row",
            "Cell": "cell", "Tab": "tab", "Link": "link"}.get(role, role.lower())
    return f"the {title} {noun}"


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/holo1.5-7b-mlx")
    ap.add_argument("--data", default="bench-data/logic-pro.json")
    ap.add_argument("--targets", type=int, default=12)
    ap.add_argument("--scope", default="window", choices=["window", "display", "both"])
    ap.add_argument("--max-tokens", type=int, default=48)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    data_path = Path(args.data)
    gt = json.loads(data_path.read_text())
    root = data_path.parent

    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config
    import mlx.core as mx

    print(f"Loading {args.model} …", flush=True)
    t0 = time.perf_counter()
    model, processor = load(args.model)
    config = load_config(args.model)
    load_s = time.perf_counter() - t0
    peak_after_load = mx.get_peak_memory() / 1e9
    print(f"  loaded in {load_s:.1f}s   weights resident ~{peak_after_load:.2f} GB\n")

    scopes = ["window", "display"] if args.scope == "both" else [args.scope]
    targets = pick_targets(gt, args.targets)
    if not targets:
        sys.exit("No usable targets in ground truth.")

    all_results = {}

    for scope in scopes:
        if scope == "window":
            img_path = root / gt["image"]
            ox, oy = 0.0, 0.0
        else:
            if not gt.get("display"):
                print(f"[{scope}] no display capture in ground truth, skipping")
                continue
            img_path = root / gt["display"]["image"]
            ox, oy = gt["display"]["window_origin_px"]

        original = Image.open(img_path).convert("RGB")
        ow, oh = original.size
        rh, rw = smart_resize(oh, ow)
        resized = original.resize((rw, rh), Image.Resampling.LANCZOS)
        # Model answers in resized pixels; ground truth is in original pixels.
        sx, sy = ow / rw, oh / rh

        print(f"── {scope}: {img_path.name}  {ow}×{oh} → {rw}×{rh} "
              f"({rw*rh/1e6:.2f} MP fed to the encoder)")

        rows = []
        for i, t in enumerate(targets, 1):
            instruction = describe(t)
            prompt = apply_chat_template(
                processor, config, localization_prompt(instruction), num_images=1
            )

            tmp = root / ".holo_input.png"
            resized.save(tmp)

            t_start = time.perf_counter()
            ttft = None
            text = ""
            ntok = 0
            for chunk in stream_generate(model, processor, prompt, image=str(tmp),
                                         max_tokens=args.max_tokens, temperature=0.0):
                if ttft is None:
                    ttft = time.perf_counter() - t_start
                text += chunk.text
                ntok += 1
            total = time.perf_counter() - t_start
            tmp.unlink(missing_ok=True)

            click = parse_click(text)
            gx, gy, gw, gh = t["px"]
            gx, gy = gx + ox, gy + oy
            hit, dist = False, None
            if click:
                px, py = click[0] * sx, click[1] * sy
                hit = (gx <= px <= gx + gw) and (gy <= py <= gy + gh)
                cx, cy = gx + gw / 2, gy + gh / 2
                dist = math.hypot(px - cx, py - cy)

            rows.append({"target": instruction, "hit": hit, "dist_px": dist,
                         "ttft_ms": ttft * 1000 if ttft else None,
                         "total_ms": total * 1000, "tokens": ntok,
                         "raw": text.strip()[:120]})
            mark = "HIT " if hit else "miss"
            dtxt = f"{dist:6.0f}px" if dist is not None else "   n/a"
            print(f"  {i:2d}. {mark} {dtxt}  ttft {ttft*1000:6.0f}ms "
                  f"total {total*1000:6.0f}ms  {instruction[:44]}")

        hits = sum(1 for r in rows if r["hit"])
        ttfts = [r["ttft_ms"] for r in rows if r["ttft_ms"]]
        totals = [r["total_ms"] for r in rows]
        acc = hits / len(rows) * 100

        def p(vals, q):
            s = sorted(vals)
            return s[min(len(s) - 1, max(0, math.ceil(q / 100 * len(s)) - 1))]

        print(f"\n  accuracy   {hits}/{len(rows)}  = {acc:.1f}%")
        print(f"  ttft       p50 {statistics.median(ttfts):7.0f} ms   p90 {p(ttfts,90):7.0f} ms")
        print(f"  total      p50 {statistics.median(totals):7.0f} ms   p90 {p(totals,90):7.0f} ms")
        print(f"  peak mem   {mx.get_peak_memory()/1e9:.2f} GB\n")

        all_results[scope] = {
            "image": img_path.name, "input_px": [ow, oh], "encoder_px": [rw, rh],
            "accuracy_pct": acc, "hits": hits, "n": len(rows),
            "ttft_p50_ms": statistics.median(ttfts), "ttft_p90_ms": p(ttfts, 90),
            "total_p50_ms": statistics.median(totals), "total_p90_ms": p(totals, 90),
            "peak_gb": mx.get_peak_memory() / 1e9,
            "rows": rows,
        }

    if len(all_results) == 2:
        w, d = all_results["window"], all_results["display"]
        print("── window-crop vs full-display")
        print(f"  accuracy   {d['accuracy_pct']:.1f}% → {w['accuracy_pct']:.1f}% "
              f"({w['accuracy_pct'] - d['accuracy_pct']:+.1f} pts)")
        print(f"  ttft p50   {d['ttft_p50_ms']:.0f} ms → {w['ttft_p50_ms']:.0f} ms "
              f"({d['ttft_p50_ms'] / max(w['ttft_p50_ms'],1e-9):.2f}x)")

    if args.out:
        Path(args.out).write_text(json.dumps({
            "model": args.model, "load_s": load_s,
            "weights_gb": peak_after_load, "scopes": all_results,
        }, indent=2))
        print(f"\nWrote {args.out}")


if __name__ == "__main__":
    main()
