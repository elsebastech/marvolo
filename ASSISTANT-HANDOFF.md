# Marvolo — engineering handoff

> Renamed from NoteLive to **Marvolo** on 2026-11-20. Repo, bundle id
> (`com.elsebastech.marvolo`), capture directory and this note all follow the
> new name; the protocol facts below are unchanged.


  

Written so another assistant (or a human) can pick this up cold and change the app

without re-deriving anything. Read the whole thing before editing; the protocol has

three non-obvious traps that will waste hours if you assume the conventional answer.

  

---

  

## 1. What this is

  

A single-file macOS program that reads pen data directly from an **XP-Pen Note Plus**

Bluetooth smart notebook (`CT860B`, reports as `Note Plus 2214`) and renders the

strokes live in a browser. No vendor app, no cloud service, no licensing.

  

It was built because the official app (NotePlusX / `HWUGEE.NotePlus`) cannot

transcribe, cannot forward notes to an AI, and owns the device exclusively.

  

Two binaries come from one source file:

  

- `Marvolo.app` — double-clickable, universal (x86_64 + arm64), auto-opens the page.

- `marvolo` — the same thing from a terminal, no auto-open, accepts port/replay args.

  

Vendor context: XP-Pen = Ugee = Hanvon Ugee (汉王友基, Shenzhen). The official iOS app

also installs on Apple-silicon Macs as `/Applications/SmartNote.app/Wrapper/...`,

which is how the UUIDs below were first found.

  

---

  

## 2. The device protocol (verified on hardware — trust this)

  

### GATT

  

```

service 180A (Device Information)

service 81D7FDC5-70B7-4475-821D-14E9F2E12FCA (vendor, returns no chars)

service 00010203-0405-0607-0809-0A0B0C0D1912 (vendor, the useful one)

char 2A50 [read] 02 8A 24 66 82 01 00

char 00010203-...-0A0B0C0D2B10 [read,notify] INK STREAM

char 00010203-...-0A0B0C0D2B11 [read,writeNR] COMMAND IN (unused so far)

char 00010203-...-0A0B0C0D2B12 [read,write,writeNR,notify] (silent; not a reply channel)

```

  

PnP ID: vendor `0x248A`, product `0x6682`, version `0x0100`.

  

### Ink payload on 2B10

  

Notification contents are a run of **8-byte records**, little endian:

  

```

byte 0 magic 0x04 or 0x05 (page/session id) 0x02 = control frame (not ink)

byte 1 type 0xA0 pen in range, NOT touching -> HOVER, pressure 0

0xA1 pen touching -> INK, pressure valid

0xC0 marker -> stroke break, NOT a page turn (see §14: 14 markers while writing two lines)

bytes 2-3 X uint16 LE

bytes 4-5 Y uint16 LE

bytes 6-7 pressure uint16 LE, 0..~8191 (non-zero only with 0xA1)

```

  

**Three traps, all confirmed by getting them wrong first:**

  

1. **Y grows DOWNWARD** (origin top-left). Do not flip it. Flipping produces

vertically mirrored glyphs — and the giveaway is that `H` still looks correct.

2. **Notification length varies**: 240 B (30 records), 216 B (27), 64 B (4), 10 B,

1 B. The device batches by size and cadence. Walk 8-byte records to the end of

whatever arrived; never assume a fixed count.

3. **0xA0 is hover, not pen-up.** Earlier notes calling it "pen up" were wrong. A

stroke ends at the `0xA1 → 0xA0` transition. Hover is a full data source at

~226 samples/sec that the vendor app throws away — useful for gestures.

  

Odd-sized packets (len 1 or 10) are control/status frames and must be skipped, not

decoded as geometry. Magic `0x02` frames look like `02 0F 0A 00 01 00 00 00 00 00`;

semantics unknown, safe to ignore.

  

**No handshake is required.** The notebook streams ink to *any* subscribed central,

including on a cold start with the vendor app never launched. If you see silence,

the device is asleep (cover closed, 15-min idle) — not waiting for a command.

  

---

  

## 3. Architecture

  

```

CoreBluetooth ──notify(2B10)──► consume(Data) [main queue]

│

▼

emit(type:x:y:p)

│

┌──────────────┴───────────────┐

▼ ▼

Server.broadcast(JSON) ndjson file append

│

┌────────────┴────────────┐

▼ ▼

SSE clients (browsers) history ring buffer (40k)

│

▼

new client gets backlog on connect

```

  

- **Transport to the browser is Server-Sent Events**, not WebSocket: one-directional,

no framing code, works with plain `send()` on a BSD socket.

- The HTTP server is ~130 lines of raw BSD sockets in a background thread. There are

no package dependencies anywhere in this project — `swiftc` and the system

frameworks only.

- `SIGPIPE` is ignored at startup; without that, a browser closing its tab kills the

process.

- The listener binds `127.0.0.1` only, so it is not exposed to the network.

  

---

  

## 4. File map (`marvolo.swift`)

Line ranges below are from the original 447-line version and have drifted; §14 adds
the capture/transcribe layer. Search by section banner (`// ---- name`), not by line.

  

| Lines | What |

|---|---|

| 1–33 | arg parsing (`live` / `replay`), ndjson file setup |

| 35–150 | `html` — the whole web page as a Swift raw string (canvas + JS) |

| 152–284 | `Server` — sockets: `start`, `acceptLoop`, `serve`, `sendAll`, `broadcast`, `history` |

| 286–307 | `emit` (record → JSON event) and `consume` (Data → 8-byte records) |

| 309–342 | replay mode: parse a `ble-log-*.txt` capture, feed it through `consume` with timing |

| 344–447 | `Live` — CBCentralManager/Peripheral delegate, scanning, connect, subscribe |

  

Web page side (`html`): `view()` computes the auto-fit transform, `px()` maps device

coords to canvas, `stroke()` draws one stroke with pressure-based width, `redraw()`

redraws everything, `ingest()` folds an event into the stroke model, `clearAll()`,

`paint()` updates the HUD. Every event triggers `dirty = true`; a 700 ms interval

redraws only when dirty, which is what makes auto-fit affordable.

  

---

  

## 5. Event schema (the contract)

  

Every event is one JSON object per SSE `data:` line and one line in `live-*.ndjson`:

  

```json

{"t":"ink","x":12345,"y":22011,"p":1840}

{"t":"hover","x":12345,"y":22011}

{"t":"marker"}

{"t":"done"} // replay only

```

  

That is the entire API surface. Anything downstream (transcription, storage, agents)

should consume the ndjson stream, not the canvas.

  

---

  

## 6. Build, run, test

  

```bash

# terminal binary

swiftc -O -o marvolo marvolo.swift

./marvolo live # serve http://127.0.0.1:8765/

./marvolo live 9000 # custom port

./marvolo replay ble-log.txt 9000 4 # replay a capture at 4x — no hardware needed

  

# app bundle (universal, ad-hoc signed)

./build_app.sh # -> Marvolo.app

```

  

**Always test with `replay` first.** It exercises the exact same `consume` →

`broadcast` → browser path without a device, so a rendering bug is distinguishable

from a Bluetooth bug. Sample capture: `source/../ble-log-*.txt` (ask the owner; they

are gitignored by convention because they contain handwriting).

  

Verification loop used during development: start the server, `curl -s

http://127.0.0.1:8765/stats` to confirm `{"clients":N,"events":M}`, then load the page

and screenshot it.

  

---

  

## 7. Recipes for extending it

  

**Add an HTTP endpoint** — in `Server.serve(fd)`, follow the `/stats` branch: build a

body, write headers with `Content-Length`, `close(fd)`. Keep `broadcast` untouched.

  

**Push events somewhere else** (e.g. POST to an agent, write per-page SVG): add the

side effect inside `Server.broadcast` next to `record(json)` — that is the single

choke point every event passes through. Do not add it in `emit`, which runs on the

Bluetooth callback and should stay fast.

  

**Segment pages** — treat `{"t":"marker"}` as a page break (the notebook's

multifunction button is what produces it) and start a new document. Suggested rule:

close the current page, flush an SVG/JSON snapshot, reset stroke list.

  

**Transcription** — read `live-*.ndjson`, group events into strokes (buffer `ink`

until `hover`/`marker`), and send each stroke group to a handwriting model. Ink is

vector with pressure, so a vision model only needs a rendered PNG if you prefer that

route; the vector path is cheaper and lossless. The vendor app itself uses MyScript

(embedded in its binary), so no on-device recognition API is available to you.

  

**Toggle hover rendering / change ink colour** — everything visual lives in the

`html` string: `redraw()` for what is drawn, `view()` for framing, the CSS block for

chrome. Changing Swift is only needed for transport or protocol work.

  

---

  

## 8. Failure modes and what they mean

  

| Symptom | Cause | Fix |

|---|---|---|

| Sits on "scanning" | Notebook asleep/closed, or never paired with this Mac | Open the notebook; if still nothing, hold the multifunction button ~3 s (blue flashes fast) to enter pairing mode |

| `clients: 0, events: 0` in `/stats` | Browser never attached | Open `http://127.0.0.1:<port>/` |

| `clients: 1, events: 0` | Browser fine, device silent | Notebook asleep, or subscribed to the wrong characteristic |

| Double-click refuses to launch | Ad-hoc signed, not notarised | Right-click → Open, or `xattr -dr com.apple.quarantine Marvolo.app` |

| Connects to nothing, no prompt | Bluetooth TCC not granted | System Settings → Privacy & Security → Bluetooth → enable for the app or terminal |

| Text renders mirrored | You flipped Y | Remove the flip (`px()` must add, not subtract, `y * sc`) |

| Process dies when a tab closes | `SIGPIPE` not ignored | Keep `signal(SIGPIPE, SIG_IGN)` |

| `bind failed` on start | Port in use | `./marvolo live 9000` |

  

Port 8765 is fixed in the bundle path; the CLI accepts an argument.

  

---

  

## 9. Known gaps (do not claim these work)

  

- **Offline pages are unreachable.** The device stores ~50 pages written while

disconnected; pulling them needs a command on `2B11` that was never captured.

PacketLogger was attempted and is a dead end on this machine (its SMJobBless helper

never installs, even after clearing quarantine), so HCI capture is unavailable.

The next route would be static analysis of the vendor binary's

`UGPenSendDataHelper`, or careful probing with notes backed up first.

- **Settings/firmware info** (`Get_Ble_Name`, `Get_Offline_Data_Size`, `Sleep_Settings`

are known command names in the vendor binary) are not implemented.

- **No persistence model** — ndjson only; no database, no note library.

- **No transcription yet** — this is the next feature the owner wants.

  

---

  

## 10. Test checklist before declaring a change done

  

1. `swiftc -O -o marvolo marvolo.swift` compiles with no errors.

2. `./marvolo replay <capture> 8765 4` then load the page: handwriting is readable

and correctly oriented (not mirrored), hover appears blue, HUD counts rise.

3. Reload the browser mid-replay: the sheet redraws from the backlog.

4. With hardware: cold-start the notebook, `./marvolo live`, write — ink arrives

within a second.

5. `curl -s http://127.0.0.1:8765/stats` reports plausible `events`.

---

## 11. Post-verification fixes (2026-11-18)

Verified end-to-end on hardware (notebook `Note Plus 2214` paired, RSSI -34):
subscribed to `2B10`, 968 live events captured, browser rendered ink in black
with a blue hover trail, correctly oriented. Two bugs found and fixed.

### Bug A — stdout is block-buffered, so every diagnostic is lost

`print()` in a Swift program is block-buffered when stdout is not a TTY. The
.app is launched by Finder (not a TTY) and the CLI is often piped to a log,
so **none** of the `print()` diagnostics — "scanning for...", "connecting to...",
"subscribed to ink stream", "browser attached" — ever appeared. A double-click
launch that failed to connect was completely silent, which defeats the entire
troubleshooting table in section 8.

Fix, one line next to `signal(SIGPIPE, SIG_IGN)`:

```swift
setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer: logs survive redirects
```

Verified: redirected log went from 0 bytes to the full startup sequence.

### Bug B — dead SSE clients are only reaped when a new event is broadcast

`broadcast()` detects a dead client via a failed `send()`, but nothing calls
`send()` when no event arrives — i.e. when the pen is idle, or in replay mode
after the last packet. The client fd and the `clients` count then leak
permanently. Measured: 4 clients killed -> `/stats` still reported
`clients: 4` indefinitely, and the fds stayed open.

Fix, a `reapDeadClients()` method that probes each client with a zero-byte
`send()` (a dead socket returns EPIPE, a live one returns success), called every
5 s from a detached thread.

Verified: 3 clients killed -> count went to 0 within one tick; a live client
in the same set was kept and still received data.

### What was verified working (no change needed)

- Bundle: universal (x86_64 + arm64), ad-hoc signature valid, `codesign --verify` passes.
- Source compiles clean with `swiftc -O`, zero warnings after the patch.
- Replay path: capture -> `consume` -> SSE -> canvas, correct event schema
  (`ink` / `hover` / `marker` / `done`).
- Orientation: text renders right-side up (no Y flip).
- Backlog catch-up: reload mid-session redraws the sheet from the 40k-event history.
- Marker: `0xC0` ends a stroke and is emitted as `{"t":"marker"}`.
- Odd-sized and `0x02` control frames are skipped without corrupting geometry.
- `clear` button empties the canvas and resets the counters.
- SIGPIPE ignored: the server survives an abrupt browser-tab disconnect.
- Binding is loopback-only (`127.0.0.1` confirmed via `lsof`); unreachable over the LAN IP.
- `LH = 36400` is only a fallback; real ink reached Y=39043 and was not clipped,
  because `view()` auto-fits to the points actually written.

### Note on the replay capture format

`marvolo replay` only accepts lines that contain the substring `2B10` **and**
match `^RX ([\d.]+) \S+ len=(\d+) \| (.+)$`. The `2B10` is the characteristic
id in the address column, e.g.:

```
RX 1000.000 2B10 len=8 | 04 A0 E8 03 E8 03 00 00
```

A capture without `2B10` in the address column silently yields zero events and
only a `{"t":"done"}` line — it does not error. Worth a guard in the replay
parser so a malformed capture fails loudly instead of looking like an empty page.

---

## 12. Connect / disconnect on demand (2026-11-18)

The browser HUD now shows the link state and lets you connect or disconnect the
notebook without restarting the app.

### The HUD

    [● live] [connected] [disconnect] [clear]
     points 528  strokes 8  217/s

The pill is colour-coded: green `connected`, blue `scanning…`, amber
`connecting…`, grey `disconnected`, red `Bluetooth off`. The button label flips
between `connect` and `disconnect`. In replay mode the pill reads `replay` and
the button is hidden — there is no device link to control.

### New HTTP endpoints

| Endpoint | Purpose |
|---|---|
| `GET /ctl?action=connect` | connect (or resume scanning) |
| `GET /ctl?action=disconnect` | disconnect and stop touching the device |
| `GET /status` | current link state as JSON |

`/status` exists because a browser that loads *after* the last state change
would otherwise never learn the current state — the status event is only
broadcast on change. The browser fetches `/status` once on load.

The status event also rides the normal SSE stream:

```json
{"t":"status","state":"connected","label":"connected","enabled":true,"busy":false}
```

Note `status` is a new event type on the stream. Anything consuming the
ndjson feed should ignore `t != "ink"`.

### The state machine

`scanning -> connecting -> connected`, plus `disconnected` and `bluetooth off`.
The BLE layer was rewritten around an `enabled` flag:

- `disconnect` stops the scan, cancels the peripheral connection, and sets
  `enabled = false`. The app then does not touch the notebook at all.
- `connect` sets `enabled = true` and starts scanning again.
- On an unexpected drop (the notebook sleeps after ~15 min idle) the app goes
  back to `scanning` and retries on its own — the notebook is picked up again
  when it wakes.

### Trap: reconnecting after a manual disconnect

Cancelling the BLE connection makes the notebook **stop advertising**. A plain
"connect" that only scans would therefore never find it again — the device is
silent until it is woken. The fix keeps a reference to the last known
peripheral and tries to reconnect to it directly:

```swift
if chosen == nil, let known = lastKnown {
    chosen = known; known.delegate = self
    state = .connecting
    directAttempt = true
    central.connect(known, options: nil)
    // connect() can hang for ever when the device is not advertising
    directTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { ... }
}
```

The 6 s timer is the escape hatch: if the direct reconnect has not completed,
fall back to active scanning. Verified on hardware — manual disconnect then
manual connect restored the link in ~2 s.

Without the `lastKnown` shortcut the button would appear broken: the app would
sit in `scanning…` forever, because the device no longer advertises itself.

### Build layout gotcha

`build_app.sh` builds `Marvolo.app` **into its own directory** (`source/`).
The shipped layout wants it at the top level of the distribution. So after
running the script, promote it:

```bash
cd source && bash build_app.sh && mv Marvolo.app ../
```

Skipping that step silently ships the *previous* build — the bundle still runs
and still works, it just does not have the new endpoints. Verify with:

```bash
strings -a Marvolo.app/Contents/MacOS/Marvolo | grep -c "/status"   # must be 1
```

Also note the extracted `build_app.sh` may lose its executable bit when unzipped;
`bash build_app.sh` works regardless. The built binary keeps `+x`.

---

## 13. Capture persistence (2026-11-20)

### Bug C — the capture file path depended on the working directory

`ndjsonPath` was built from `FileManager.default.currentDirectoryPath`, so the
session file was written next to wherever the process happened to start. A
Finder launch sets the cwd to `/`, where `createFile` fails; the
`FileHandle(forWritingAtPath:)` then returns nil and `record()` drops every event
on the floor. The HUD still showed `connected` and `/stats` counted thousands of
events, so a session looked healthy while **nothing reached disk**.

Measured on the real machine: 7,662 events in memory, zero bytes on disk, no
`live-*.ndjson` anywhere under the home directory.

Fix: capture under Application Support, with the failure surfaced.

```swift
let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
let captureDir = base.appendingPathComponent("Marvolo/captures", isDirectory: true)
// NOTELIVE_CAPTURE_DIR overrides it (tests, or a synced archive)
```

    ~/Library/Application Support/Marvolo/captures/session-<epoch>.ndjson

Renamed from `live-<ts>.ndjson` to `session-<ts>.ndjson`.

### Failing loudly

Three surfaces, all required — a silent save failure is worse than no save:

1. stdout at startup: `capturing to <path>`, or `CAPTURE ERROR: ...` plus
   `CAPTURE DISABLED — ... WILL BE LOST on quit`.
2. `GET /status` and `GET /stats` carry `"capture":"writing"` or `"error"`.
3. The HUD shows `saving session-<ts>.ndjson` in green or
   `NOT SAVING — strokes are memory-only` in bold red. It polls `/status` every
   5 s, so a write that starts failing mid-session is visible.

`record()` catches write errors, flips `captureStatus` to `error` and drops the
handle, instead of trapping or silently continuing.

### Captures are local state, not repository content

They are the user's handwriting. `.gitignore` excludes `captures/` and
`*.ndjson`; the repo holds source and build script only. The built `Marvolo.app`
is excluded too (307 KB, rebuilt every time).

### Recovering a session that was never written

The server keeps a 40k-event history for browser backlog, and `/events` replays
it to any new subscriber, so a lost session is recoverable while the process is
still alive:

```bash
curl -sN --max-time 6 http://127.0.0.1:8765/events | sed -n 's/^data: //p' > rescue.ndjson
```

That recovered 7,665 events (3,665 ink, 3,981 hover, 14 marker) from the session
that was running with a broken capture path. It is a rescue path, not a backup:
once the process quits, the history is gone.

### Verified

- Writable dir: `NOTELIVE_CAPTURE_DIR=/tmp/x` → file created, 15 events written with
  the correct schema (`hover`/`ink`/`marker`/`done`), `/status` and `/stats`
  report `writing`.
- Unwritable dir (`/System/...`): startup prints `CAPTURE ERROR ... Operation not
  permitted` + `CAPTURE DISABLED`, both endpoints report `"capture":"error"`.
- Default path: creates `~/Library/Application Support/Marvolo/captures/` and the
  session file on first run.

---

## 14. Capture, transcription and storage offload (2026-11-20)

Two HUD buttons. `capture` snapshots the current page; `transcribe` turns that page
into text. Both need a model of the page, which the process did not have before.

### The page document

`Document` keeps `pages -> strokes -> points`, fed from `emit()` (the single point
every decoded record passes through). `0xA1` appends, `0xA0` ends a stroke, `0xC0`
ends a stroke and opens a new page. Appending three integers under an `NSLock` is
cheap enough for the Bluetooth callback thread; rendering and network I/O happen on
the per-connection HTTP thread instead.

`/ctl?action=clear` now also clears this model. Before, `clear` was browser-only, so
the next capture would have resurrected strokes the user had just wiped.

**Trap:** the `/ctl` closure is `if action == "connect" { … } else { live.disconnect() }`.
Passing `"clear"` to it would drop the BLE link. The branch matches actions
explicitly now; never add an action there without matching it.

### Rendering

`renderPNG` draws the vectors into a Core Graphics bitmap (2400 px wide, white
background, pressure-mapped width) and encodes it with ImageIO; `renderSVG` emits the
same geometry as lines. No window, no PencilKit, works mid-stroke.

**Trap:** Core Graphics has its origin bottom-left and the notebook's Y grows
downward, so the context is flipped once (`translateBy` + `scaleBy(1, -1)`). Without
that flip the PNG is mirrored vertically — the same class of bug as the canvas.

### Endpoints

    GET /capture     -> {ok, page, dir, strokes, points, text, uploaded, webhook, writeErrors?}
    GET /transcribe  -> {ok, page, text, ms, saved} | {ok:false, error}

Both are GET so the button and a `curl` do the same thing. `respondJSON` exists so
every reply has its `Content-Length`; the SSE and `/` paths keep their own writers.

`/transcribe` blocks for the length of the OCR round trip (~1 s observed for a page).
That is intentional: the connection thread serves one request and the browser button
shows a busy state.

### Notes, and where storage policy lives

A note is a folder: `page.png`, `page.svg`, `meta.json`, and `page.txt` once
transcribed. Default path is `<captures>/notes/<stamp>-p<N>`, overridable with
`MARVOLO_NOTES_DIR`. Capturing twice keeps both snapshots.

If `MARVOLO_WEBHOOK_URL` is set, the same files go out as `multipart/form-data`
(`meta` JSON field, plus `text`, `page`, `svg`) with an optional Bearer token. n8n
receives one POST and decides whether the note lands in Drive, a vault, or a
database. Storage credentials never enter this process — that is why the app does
not know what Drive is.

### Configuration

Environment first, then `~/.config/marvolo/env` (KEY=VALUE, `#` comments, quotes
stripped). Startup prints presence only — `config: ocr key set -> api.deepseek.com` —
so a log can be shared without leaking a key. `.env` and `.env.*` are gitignored
except `.env.example`, which documents the names and nothing else.

### Why transcription is not on-device: PKStrokeRecognizer is gated

`PKStrokeRecognizer` is real on macOS 27 (33 languages, recognition version 9) and it
runs headless once two build facts are handled:

1. It only exists in the **Xcode** SDK. The CommandLineTools SDK has no
   `PKStrokeRecognizer`, and the two toolchains are not interchangeable
   (CLT ships Swift 6.3, Xcode 27's SDK is built with 6.4). Calling Xcode's `swiftc`
   directly works; `xcrun` refuses until the Xcode licence is accepted with `sudo`.
2. `PKDrawing(strokes:)` traps with `CFHash() called with NULL` in
   `PKReplicaManager _saveStateImmediately` when the process has **no bundle
   identifier**. Embedding `__info_plist` with a `CFBundleIdentifier` (or running
   inside the `.app`) fixes it.

With both handled, `recognizedText()` and `indexableContent` still return nil for
strokes we build ourselves. The system log says why:

    stroke provider visible strokes 0
    RecognitionTask running for 0 strokes: 0 added strokes
    Raw session result … Text: 0 (0)

The provider discards every stroke that did not come from a PencilKit session. Tried
and ruled out: scale 0.02–0.1 with pen 1–4 pt, translation to origin and to an A4
margin, Y normal and flipped, `preferredLanguages` nil/en+es/es, polling for 6 s,
`dataRepresentation()` round-trip, a real `.app` bundle launched through
LaunchServices, `PKStrokePath(controlPoints:creationDate:id:)` with stable UUIDs,
and the new Bézier route `PKStrokePath(bezierPath:creationDate:pointProvider:)`.
A two-line synthetic drawing is discarded the same way, so it is not about our data.
The remote-side error itself is redacted (`Remote Recognition error: <private>`);
unredacting needs `log config --mode private_data:on` as admin.

Conclusion: on-device recognition needs either an Apple answer or a signed-app test on
a machine where the Xcode licence is accepted. Until then transcription goes through
OCR, which is a different engine and does not share this limitation.

### Verified (replay, no hardware, no key)

- `capture` on the rescue capture: 65 strokes / 3,665 points -> note folder with
  `page.png` (154 KB), `page.svg`, `meta.json`; PNG renders upright and legible.
- Webhook: fake receiver got `multipart/form-data`, `meta` field intact, and
  `Authorization: Bearer testtoken`; reply status surfaced in the HTTP response.
- Webhook unset: `uploaded:false`, note kept local, message says so.
- `transcribe` without a key: `{"ok":false,"error":"DEEPSEEK_API_KEY is not set …"}`.
- `clear` then `capture`: `nothing written on this page yet` (the model, not the canvas).
- `/ctl?action=nonsense`: `ok:false`, link state untouched (still `scanning`).
- HUD in a real browser: buttons render, capture reports `saved … · local only`,
  transcribe shows the error in red, buttons re-enable in both cases.

### Correction: 0xC0 is a stroke break, not a page turn

The first version of `Document` treated `0xC0` as "new page". Measured against a real
session it is not: the notebook emitted **14 markers while Sebastian wrote two lines**
("Punto de partida"), and the last event of the session was a marker — so the "current
page" was empty and `capture` answered *nothing written on this page yet* while 1,279
ink points sat one page back.

What the record actually means: `0xC0` closes the stroke being written, exactly like a
hover does, and the device fires it at boundaries of its own choosing. There is no
reliable page delimiter in the stream that has been decoded so far.

So a sheet is bounded by **explicit** user action only: `clear` (or `/ctl?action=clear`)
ends the sheet and increments its number. Everything written since the last clear
belongs to the current sheet, which is what someone pressing `capture` expects.

### Capture reads the session file when memory is empty

Restarting the app empties the in-memory document while the ndjson keeps everything.
`capture` and `transcribe` therefore fall back to disk: current session file first, then
the newest `session-*.ndjson` in the archive that contains ink. The reply and
`meta.json` say which one was used (`"source": "memory" | "session-file"`), because a
note that silently comes from an older file would be a lie about its provenance.

`replay/` sessions are excluded from that search — they are test output, not handwriting.

Verified with the real session: `capture` returned `source: session-file`, 20 strokes,
1,279 points, and the rendered page reads "Punto de partida", upright and legible.

Known quirk of the fallback: it only applies while memory is empty. Once ink arrives
in a restarted process, the sheet is that new ink alone — earlier strokes are still in
the previous session file, never rewritten, but they are not part of the new sheet. If
that matters for a workflow, seed the document at startup instead of lazily; the
reason it is not done today is that seeding would resurrect yesterday's note for
someone starting a clean sheet.

---

## 15. The capture library (UI, 2026-11-20)

Full-screen browser over the notes folder: list on the left, selected note on the
right. No database and no index — the archive is a directory of folders, so the
library is a listing, and notes captured before this code existed appear in it.

### Endpoints

    GET /notes            { ok, root, notes: [{id, page, strokes, points, captured,
                                                session, source, hasPng, hasSvg, hasText}] }
    GET /note/thumb?d=    cached 360 px PNG, generated on first request
    GET /note/file?d=&f=  page.png | page.svg | page.txt | meta.json
    GET /note/reveal?d=   /usr/bin/open -R on the note folder

`/notes` sorts by the `captured` field (ISO 8601 UTC, so string order is time order)
and falls back to the folder mtime when a `meta.json` is missing or lacks it.

### Traps hit while building it

1. **The library must read the archive root, not the session directory.** In replay
   mode `captureDir` is `captures/replay/`, so deriving the notes path from it made the
   library show an empty list (it was listing `captures/replay/notes`). `notesBaseDir()`
   now hangs off `baseCaptureDir`, which is why a replay instance can browse the real
   archive — useful for UI work without hardware.
2. **Serve files by name, never by path.** `noteFile()` accepts only the four known
   file names and a directory name matching `^[A-Za-z0-9._-]+$`, then re-checks the
   resolved path is inside the notes root. Verified: `d=../../../../etc&f=passwd` and
   `f=../../Marvolo.app/Contents/Info.plist` both return `no such note file`.
3. **The list must not download full pages.** Five notes × 170 KB is ~850 KB just to
   show 54×38 px; fifty notes would be 8 MB per open. `thumb.png` (360 px, ~15 KB) is
   generated with `CGImageSourceCreateThumbnailAtIndex`, cached in the note folder, and
   regenerated only when `page.png` is newer than it. First request 38 ms, cached 0.5 ms.
4. **Zoom must not lose the sheet.** Zoom anchors on the pointer, so a fast wheel on
   blank paper sends the note off screen with nothing left to grab. `clampView()` keeps
   at least 90 px of the sheet inside the viewport on every transform.
5. **SVG stroke width has to match the PNG.** The first version wrote a fixed
   `stroke-width` and the notation looked like hairlines compared with the render. Width
   is now `penWidth(pressure, scale: uScale) / uScale` with `uScale = 2400 / frameWidth`,
   i.e. the same curve the raster uses, expressed in viewBox units.

### What the note view deliberately is not

The note is displayed as the SVG that was written at capture time, so it cannot drift
from what the note contains. Re-rendering from the ndjson would show a sheet that is
still growing, which is the live canvas's job. If a note ever needs editing, that is a
different feature with different rules about which file becomes the truth.

### Verified

- `/notes` on the real archive: 5 notes with metadata, newest first.
- `/note/file` serves `page.svg` (200, `image/svg+xml`, 134 KB) and `page.png`.
- Path traversal and unknown file names rejected with `no such note file`.
- Browser: list renders with thumbnails, selecting a note injects its SVG
  (`15020×12203`, 1,966 line elements), wheel zoom changes the transform
  (0.0244 → 0.1646 → 2.27), `fit` restores the framed view, `Esc` closes.
- Thumbnails: 360×292 / 360×157 / 360×49 depending on the note's aspect, ~9–15 KB each.

---

## 16. Transcribing notes that already exist (2026-11-20)

The library got a `transcribe` action, and both transcription paths now leave a note in
the same shape.

### One writer for transcripts

`attachTranscript(noteDir:text:)` writes `page.txt` **and** merges `text` plus a
`transcribed` ISO 8601 timestamp into `meta.json`. It is used by:

- `transcribePage()` — the HUD button, when the sheet was already captured
  (`lastNote`), and
- `transcribeNote(_:)` — `GET /note/transcribe?d=<note id>`, which OCRs the note's own
  `page.png` off disk and writes back into that folder.

Before this, the HUD path wrote only `page.txt`, so `meta.json` and the library badge
disagreed with the folder. Anything that consumes notes (n8n included) should trust
`meta.json`, so it has to be true.

The library button is disabled when `hasText` is already true; `/notes` reports
`hasText` and, when present, `text`.

### Verified without a real key

A local stand-in for `/v1/tools/ocr` (answers the same JSON shape, records what it
receives) plus `DEEPSEEK_API_KEY` + `MARVOLO_OCR_ENDPOINT` in the process environment
was enough to exercise the whole chain:

- request was `multipart/form-data` with the PNG present (`has_png_magic: true`), a
  `purpose` field, and `Authorization: Bearer …`;
- response parsed, `{"ok":true,"id":…,"ms":53,"text":"probando probando 1,2,3\n— firma"}`;
- `page.txt` written, `meta.json` gained `text` and `transcribed`;
- `/notes` flipped that note to `hasText: true` and later returned its `text`.

Missing key still answers `DEEPSEEK_API_KEY is not set (environment or
~/.config/marvolo/env)` — the message names the file so the fix is obvious.

### Two traps about testing the config file

1. **`NSHomeDirectory()` ignores `HOME`.** Launching the binary with
   `HOME=/tmp/fakehome` does *not* redirect `~/.config/marvolo/env` or
   Application Support: both still resolve to the real home, so a sandboxed config test
   is impossible that way. Testing the file reader requires either the real file or a
   `MARVOLO_*` override.
2. **Never write test keys into the user's config file.** An attempt to drop a fake key
   into `~/.config/marvolo/env` was blocked by the approval guard, which is the correct
   outcome: that file is the user's credentials, not a scratch pad. Use environment
   variables plus a `MARVOLO_OCR_ENDPOINT` stand-in instead, and assert the request shape
   rather than the key.
