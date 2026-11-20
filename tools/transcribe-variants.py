#!/usr/bin/env python3
"""Compare OCR request shapes for a Marvolo note.

Reads the key from the environment or ~/.config/marvolo/env and never prints it.

    python3 tools/transcribe-variants.py <note dir>

Variants:
  full   the whole page.png, exactly as the app sends it (multipart, purpose only)
  bands  the page cut into ink bands, each band sent as its own page

Why bands: the OCR endpoint takes no prompt, no language and no model — only `file`
and `purpose`. It resizes the whole image down to fit its budget, so on a sheet that is
mostly white space each line of handwriting arrives tiny. Cutting the sheet into the
regions that actually have ink gives every line more pixels.
"""
import json
import os
import sys
import time
import urllib.request
import uuid

from PIL import Image

ENV = os.path.expanduser("~/.config/marvolo/env")
DEFAULT_ENDPOINT = "https://api.deepseek.com/v1/tools/ocr"


def api_key():
    key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if key:
        return key, "environment"
    if os.path.exists(ENV):
        for line in open(ENV):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            if name.strip() == "DEEPSEEK_API_KEY":
                value = value.strip().strip('"').strip("'")
                if value:
                    return value, ENV
    sys.exit("no DEEPSEEK_API_KEY in the environment or in " + ENV)


def ocr(png_bytes, endpoint):
    boundary = "marvolo-" + str(uuid.uuid4())
    body = b"".join([
        f"--{boundary}\r\n".encode(),
        b'Content-Disposition: form-data; name="purpose"\r\n\r\n',
        b"text_recognition\r\n",
        f"--{boundary}\r\n".encode(),
        b'Content-Disposition: form-data; name="file"; filename="page.png"\r\n',
        b"Content-Type: image/png\r\n\r\n",
        png_bytes,
        b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ])
    request = urllib.request.Request(
        endpoint,
        data=body,
        method="POST",
        headers={
            "Authorization": "Bearer " + api_key()[0],
            "Content-Type": "multipart/form-data; boundary=" + boundary,
        },
    )
    started = time.time()
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = json.loads(response.read().decode())
    ms = int((time.time() - started) * 1000)
    if "error" in payload:
        return {"text": "", "ms": ms, "error": payload["error"].get("message")}
    pages = payload.get("pages") or []
    return {
        "text": "\n".join(p.get("text", "") for p in pages).strip(),
        "ms": ms,
        "pages": len(pages),
        "finish": [p.get("finish_reason") for p in pages],
        "usage": payload.get("usage"),
    }


def ink_bands(image, gap=140, pad=28, max_bands=6):
    """Rows with ink, grouped into bands separated by at least `gap` blank rows."""
    grey = image.convert("L")
    width, height = grey.size
    pixels = grey.load()
    rows = []
    for y in range(height):
        dark = sum(1 for x in range(0, width, 4) if pixels[x, y] < 200)
        if dark:
            rows.append(y)
    if not rows:
        return []
    groups, start, previous = [], rows[0], rows[0]
    for y in rows[1:]:
        if y - previous > gap:
            groups.append((start, previous))
            start = y
        previous = y
    groups.append((start, previous))
    # Merge the tail if there are more bands than we want to pay for.
    if len(groups) > max_bands:
        step = len(groups) / max_bands
        groups = [groups[int(i * step)] for i in range(max_bands)]
    return [(0, max(0, a - pad), width, min(height, b + pad)) for a, b in groups]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    note = os.path.abspath(sys.argv[1])
    page = os.path.join(note, "page.png")
    endpoint = os.environ.get("MARVOLO_OCR_ENDPOINT", DEFAULT_ENDPOINT)
    image = Image.open(page)
    print(f"note: {os.path.basename(note)}")
    print(f"page: {image.size[0]}x{image.size[1]} px, {os.path.getsize(page)} bytes")
    print(f"key:  read from {api_key()[1]}")
    print(f"endpoint: {endpoint}\n")

    with open(page, "rb") as handle:
        raw = handle.read()

    print("--- full page ---")
    full = ocr(raw, endpoint)
    print(json.dumps(full, ensure_ascii=False, indent=2))

    cuts = ink_bands(image)
    print(f"\n--- bands ({len(cuts)}) ---")
    pieces, total = [], 0
    for index, box in enumerate(cuts):
        buffer = __import__("io").BytesIO()
        image.crop(box).save(buffer, format="PNG")
        result = ocr(buffer.getvalue(), endpoint)
        total += result["ms"]
        pieces.append(result)
        print(f"band {index} {box}: {result['ms']} ms, {len(result['text'])} chars "
              f"{'(error: ' + result['error'] + ')' if result.get('error') else ''}")
    joined = "\n".join(piece["text"] for piece in pieces if piece["text"]).strip()
    print(f"\ntotal {total} ms\njoined:\n{joined}")


if __name__ == "__main__":
    main()
