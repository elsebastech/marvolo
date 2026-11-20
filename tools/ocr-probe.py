#!/usr/bin/env python3
"""Probe: does cropping to lines recover the word the OCR keeps missing?

Tries the same note with different crops and scales, prints what each variant reads.
Cheap: each call is one page.
"""
import io
import json
import os
import sys
import time
import urllib.request
import uuid

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib.machinery import SourceFileLoader  # noqa: E402

ocr_mod = SourceFileLoader("variants", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                    "transcribe-variants.py")).load_module()

ENDPOINT = os.environ.get("MARVOLO_OCR_ENDPOINT", "https://api.deepseek.com/v1/tools/ocr")


def line_boxes(image, gap=60, pad=40):
    grey = image.convert("L")
    w, h = grey.size
    px = grey.load()
    rows = [y for y in range(h) if any(px[x, y] < 200 for x in range(0, w, 4))]
    if not rows:
        return []
    groups, start, prev = [], rows[0], rows[0]
    for y in rows[1:]:
        if y - prev > gap:
            groups.append((start, prev))
            start = y
        prev = y
    groups.append((start, prev))
    return [(0, max(0, a - pad), w, min(h, b + pad)) for a, b in groups]


def run(label, image, endpoint=ENDPOINT):
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    data = buffer.getvalue()
    started = time.time()
    result = ocr_mod.ocr(data, endpoint)
    result["wall_ms"] = int((time.time() - started) * 1000)
    print(f"\n[{label}] {image.size[0]}x{image.size[1]} px, {len(data)} bytes, "
          f"{result.get('usage', {}).get('input_tokens', '?')} input tokens, {result['wall_ms']} ms")
    if result.get("error"):
        print("  error:", result["error"])
    else:
        print("  text:", json.dumps(result["text"], ensure_ascii=False))
    return result


def main():
    note = os.path.abspath(sys.argv[1])
    page = os.path.join(note, "page.png")
    image = Image.open(page).convert("RGB")
    print(f"note {os.path.basename(note)} — {image.size[0]}x{image.size[1]}")

    run("full page", image)

    boxes = line_boxes(image)
    print(f"\nlines found: {len(boxes)} -> {boxes}")
    pieces = []
    for i, box in enumerate(boxes):
        crop = image.crop(box)
        result = run(f"line {i} raw {box}", crop)
        pieces.append(result["text"])
    print("\njoined lines:", json.dumps("\n".join(pieces).strip(), ensure_ascii=False))

    if boxes:
        crop = image.crop(boxes[0])
        run("line 0 at 1.5x", crop.resize((int(crop.width * 1.5), int(crop.height * 1.5)),
                                          Image.LANCZOS))
        grey = crop.convert("L").point(lambda v: 0 if v < 150 else 255).convert("RGB")
        run("line 0 threshold 150", grey)


if __name__ == "__main__":
    main()
