#!/usr/bin/env python3
"""Same note, two engines: the OCR endpoint vs a vision model with an instruction.

The OCR endpoint takes no prompt (docs: any field other than `file` and `purpose` is a
400), so it can only report what its recognizer sees. `deepseek-flash` accepts the image
plus an instruction, which is the difference the library transcripts were showing.

    python3 tools/transcribe-vlm.py <note dir>
"""
import base64
import json
import os
import sys
import time
import urllib.request

ENV = os.path.expanduser("~/.config/marvolo/env")
CHAT = "https://api.deepseek.com/chat/completions"

PROMPT = (
    "Transcribe literalmente el texto manuscrito de esta imagen, línea por línea, "
    "en el orden en que aparece. Respeta acentos, mayúsculas y puntuación. "
    "No corrijas ni interpretes: si una palabra es dudosa, escríbela como la ves. "
    "Devuelve solo la transcripción, sin comentarios."
)


def api_key():
    key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if key:
        return key
    for line in open(ENV):
        line = line.strip()
        if line.startswith("DEEPSEEK_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("no key")


def transcribe(png_path, model="deepseek-flash", detail="original"):
    with open(png_path, "rb") as handle:
        b64 = base64.b64encode(handle.read()).decode()
    body = json.dumps({
        "model": model,
        "temperature": 0,
        "max_tokens": 1024,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": PROMPT},
                {"type": "image_url",
                 "image_url": {"url": "data:image/png;base64," + b64, "detail": detail}},
            ],
        }],
    }).encode()
    request = urllib.request.Request(CHAT, data=body, method="POST", headers={
        "Authorization": "Bearer " + api_key(),
        "Content-Type": "application/json",
    })
    started = time.time()
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = json.loads(response.read().decode())
    ms = int((time.time() - started) * 1000)
    if "error" in payload:
        return {"error": payload["error"], "ms": ms}
    return {
        "text": payload["choices"][0]["message"]["content"].strip(),
        "finish": payload["choices"][0].get("finish_reason"),
        "reasoning_chars": len((payload["choices"][0]["message"].get("reasoning_content") or "")),
        "ms": ms,
        "usage": payload.get("usage"),
        "model": payload.get("model"),
    }


def main():
    note = os.path.abspath(sys.argv[1])
    page = os.path.join(note, "page.png")
    print(f"note: {os.path.basename(note)}")
    for detail in ("original", "low"):
        result = transcribe(page, detail=detail)
        print(f"\n[deepseek-flash, detail={detail}] {result.get('ms')} ms "
              f"finish={result.get('finish')} reasoning_chars={result.get('reasoning_chars')} "
              f"usage={result.get('usage')}")
        if result.get("error"):
            print("  error:", json.dumps(result["error"], ensure_ascii=False))
        else:
            print("  text:", json.dumps(result["text"], ensure_ascii=False))


if __name__ == "__main__":
    main()
