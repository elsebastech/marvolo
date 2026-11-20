# Marvolo

Reads pen data straight off an **XP-Pen Note Plus** Bluetooth smart notebook
(`CT860B`, advertises as `Note Plus 2214`) and draws the strokes live in a
browser. No vendor app, no account, no cloud service, no licensing.

It exists because the official app (NotePlusX / `HWUGEE.NotePlus`) cannot
transcribe, cannot forward notes anywhere, and owns the device exclusively.

One Swift file, no package dependencies: `swiftc` and the system frameworks.

## What works today

- Live ink, read from BLE characteristic `2B10` and pushed to the browser over SSE.
- Pressure-based stroke width, hover trail, auto-fit framing, backlog catch-up on reload.
- Connect / disconnect the notebook on demand from the HUD.
- Every event is appended to an ndjson session file on disk (see below).
- **Capture**: one click renders the current page to PNG + SVG, writes a note folder,
  and POSTs it to an n8n webhook if one is configured.
- **Transcribe**: one click sends that PNG to on-demand OCR and shows the text in the
  HUD, ready to copy.

## What does not work yet

- **Offline pages are unreachable.** The device stores ~50 pages written while
  disconnected; pulling them needs a vendor command on `2B11` that has not been
  reverse-engineered. PacketLogger is a dead end on macOS 27.
- **No on-device transcription.** `PKStrokeRecognizer` exists on macOS 27 and is
  wired up to work, but it treats programmatically built strokes as invisible
  ("stroke provider visible strokes 0") and returns nil, so transcription goes
  through an OCR API instead. See ASSISTANT-HANDOFF.md §14.
- Settings / firmware info (sleep timeout, BLE name, MAC) are not implemented.

## Layout

    source/marvolo.swift       the whole program (BLE + HTTP/SSE + HTML/JS page)
    source/build_app.sh         builds Marvolo.app (universal, ad-hoc signed)
    source/PROTOCOL-NOTES.md    device protocol notes
    ASSISTANT-HANDOFF.md        full engineering spec — read this first
    README.txt                  end-user quickstart shipped in the distribution
    Marvolo.app/               built bundle (gitignored)

## Build

    cd source && bash build_app.sh && mv Marvolo.app ../

`build_app.sh` builds **into `source/`**; the distribution expects the bundle one
level up. Forgetting the `mv` silently ships the previous build. Verify:

    strings -a Marvolo.app/Contents/MacOS/Marvolo | grep -c "/status"   # must be >= 1

## Run

    ./Marvolo.app/Contents/MacOS/Marvolo        # serves http://127.0.0.1:8765/
    ./marvolo live [port]
    ./marvolo replay capture.txt [port] [speed]  # no hardware needed

First launch needs Bluetooth permission, and the app is ad-hoc signed, so use
right-click → Open or `xattr -dr com.apple.quarantine Marvolo.app`.

## Capture and transcription

Two buttons in the HUD, two endpoints, all secrets from the environment.

    GET /capture      snapshot the current page -> note folder, optional webhook POST
    GET /transcribe   OCR the current page      -> text, saved next to the note
    GET /ctl?action=clear   also clears the server's copy of the page

A note is a folder, not a database:

    ~/Library/Application Support/Marvolo/captures/notes/2026-11-20T13-14-28-p1/
        page.png     the page, rendered from the vectors at 2400 px wide
        page.svg     same page, vector
        meta.json    page, captured, strokes, points, session file, text (if any)
        page.txt     transcript, present once you transcribe that page

Capturing does **not** close the page: it is a camera, not a scalpel. Capturing
twice keeps both snapshots. Transcribing before capturing is fine — the text
travels with the note.

A sheet is bounded by `clear` only. The notebook's `0xC0` marker is a stroke
break, not a page turn — it fires mid-writing, so treating it as a page change
left capture staring at an empty page. If the app has just restarted, capture
rebuilds the strokes from the newest session file that has ink and says so in
`meta.json` (`"source": "session-file"`).

Configuration (environment first, then `~/.config/marvolo/env`; see `.env.example`):

    DEEPSEEK_API_KEY        OCR key. Without it the transcribe button says so.
    MARVOLO_WEBHOOK_URL     where notes go; empty means local only
    MARVOLO_WEBHOOK_TOKEN   optional, sent as "Authorization: Bearer …"
    MARVOLO_OCR_ENDPOINT    default https://api.deepseek.com/v1/tools/ocr
    MARVOLO_NOTES_DIR       default <captures>/notes

The webhook receives `multipart/form-data`: a `meta` field (JSON) and, when they
exist, `text`, `page` (page.png) and `svg`. That is the whole contract, so storage
policy (Drive, a vault, a database) lives in n8n, not in this process.

The app prints what is configured at startup, never the values:

    config: ocr key set -> api.deepseek.com
    config: webhook 127.0.0.1

## Where strokes are stored

Captures are **local state, never repository content** — they are the user's
handwriting. They go to:

    ~/Library/Application Support/Marvolo/captures/session-<epoch>.ndjson

One file per run, one JSON event per line:

    {"t":"ink","x":12345,"y":22011,"p":1840}
    {"t":"hover","x":12345,"y":22011}
    {"t":"marker"}
    {"t":"status","state":"connected",...}

Override the directory with `NOTELIVE_CAPTURE_DIR=/some/path`. If the directory
cannot be created or the file cannot be opened, the app prints `CAPTURE ERROR`
once at startup, reports `"capture":"error"` on `/status` and `/stats`, and the
HUD shows *NOT SAVING — strokes are memory-only*. It does not fail silently:
that bug cost a full session of handwriting.

## Tests

`source/../` has no test suite; verification is behavioural:

1. `swiftc -O -o /tmp/nl marvolo.swift` — zero warnings.
2. Replay a synthetic capture and check the ndjson file fills with the right event types.
3. Load the page and confirm orientation (letters, not scribbles), backlog on reload, HUD counters.
4. Against hardware: write, disconnect from the HUD, reconnect, write again.
5. `/stats` reports plausible counts; `/status` reports `"capture":"writing"`.

## License

Not chosen yet.
