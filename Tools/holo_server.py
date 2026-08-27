#!/usr/bin/env python3
"""Long-running Holo1.5 grounding server, spoken to over stdio in JSON lines.

The app is Swift and the model is MLX/Python, so something has to bridge them.
A sidecar beats a per-query subprocess for one measured reason: loading the
4-bit weights costs ~0.5 s and holding them costs ~5.6 GB, and paying that on
every query would dominate a budget where the whole vision path is ~2.4 s.

The coordinate maths lives *here*, deliberately, next to the resize that
creates the problem. The server is handed a full frame and an optional crop; it
crops, applies Qwen2.5-VL's `smart_resize`, asks the model, then undoes both
transforms so the caller gets a point in the ORIGINAL frame's pixel space. Every
place that inverse has been re-derived elsewhere in this project, it has been a
bug.

Protocol — one JSON object per line each way:

    <- {"id":1,"image":"/tmp/f.png","query":"the Play button","crop":[x,y,w,h]}
    -> {"id":1,"x":1131.0,"y":287.0,"ttft_ms":1610,"total_ms":1901,"tokens":980}

    -> {"ready":true,"model":"...","load_s":0.5}      once, at startup
    -> {"id":1,"error":"..."}                          on failure
"""

import json
import math
import sys
import time
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from holo_bench import localization_prompt, parse_click, smart_resize  # noqa: E402


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    model_path = sys.argv[1] if len(sys.argv) > 1 else str(
        Path.home() / "models/holo1.5-7b-4bit")
    max_tokens = 48

    t0 = time.perf_counter()
    try:
        from mlx_vlm import load, stream_generate
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.utils import load_config
        model, processor = load(model_path)
        config = load_config(model_path)
    except Exception as e:  # noqa: BLE001
        emit({"ready": False, "error": f"{type(e).__name__}: {e}"})
        return 1
    emit({"ready": True, "model": model_path,
          "load_s": round(time.perf_counter() - t0, 2)})

    scratch = Path(model_path).parent / ".holo_server_input.png"

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        if req.get("op") == "quit":
            break

        rid = req.get("id")
        try:
            image = Image.open(req["image"]).convert("RGB")

            # Crop first, resize second. Doing it the other way round throws
            # away the resolution that makes small targets findable — Phase 0
            # measured native-res cropping at 3x the accuracy of downscaling
            # for the same token budget.
            ox, oy = 0.0, 0.0
            crop = req.get("crop")
            if crop:
                cx, cy, cw, ch = crop
                x0 = max(0, int(cx))
                y0 = max(0, int(cy))
                x1 = min(image.width, int(cx + cw))
                y1 = min(image.height, int(cy + ch))
                if x1 - x0 >= 8 and y1 - y0 >= 8:
                    image = image.crop((x0, y0, x1, y1))
                    ox, oy = float(x0), float(y0)

            w, h = image.size
            budget = req.get("max_pixels") or 3686400
            rh, rw = smart_resize(h, w, max_pixels=budget)
            resized = image.resize((rw, rh), Image.Resampling.LANCZOS)
            resized.save(scratch)

            prompt = apply_chat_template(
                processor, config, localization_prompt(req["query"]), num_images=1
            )
            start = time.perf_counter()
            ttft, text = None, ""
            for chunk in stream_generate(model, processor, prompt, image=str(scratch),
                                         max_tokens=req.get("max_tokens", max_tokens),
                                         temperature=0.0):
                if ttft is None:
                    ttft = time.perf_counter() - start
                text += chunk.text
            total = time.perf_counter() - start

            click = parse_click(text)
            if click is None:
                emit({"id": rid, "error": "model returned no coordinates",
                      "raw": text[:160]})
                continue

            # Undo resize, then undo crop — back into the original frame.
            x = click[0] * (w / rw) + ox
            y = click[1] * (h / rh) + oy
            emit({"id": rid, "x": x, "y": y,
                  "ttft_ms": round((ttft or 0) * 1000, 1),
                  "total_ms": round(total * 1000, 1),
                  "tokens": (rw * rh) // 784,
                  "encoder_px": [rw, rh]})
        except Exception as e:  # noqa: BLE001
            emit({"id": rid, "error": f"{type(e).__name__}: {e}"})

    scratch.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
