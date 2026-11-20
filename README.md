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

## What does not work yet

- **Offline pages are unreachable.** The device stores ~50 pages written while
  disconnected; pulling them needs a vendor command on `2B11` that has not been
  reverse-engineered. PacketLogger is a dead end on macOS 27.
- **No transcription.** The intended route is PencilKit's `PKStrokeRecognizer`
  (on-device, macOS 27) fed with strokes rebuilt from the archive.
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
