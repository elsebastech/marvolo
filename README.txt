NoteLive — live ink view for the XP-Pen Note Plus
================================================

WHAT IT IS
  Reads pen strokes straight off the notebook over Bluetooth and draws them live
  in your browser: ink in black with pressure-based width, pen-in-air hover in
  blue, plus points/strokes/points-per-second. No vendor app is involved and no
  account or cloud service is used.

HOW TO RUN
  1. Unzip, then drag NoteLive.app to /Applications (or run it from anywhere).
  2. First launch: right-click the app -> Open -> Open. macOS will block a
     double-click because the app is signed ad-hoc, not by an Apple developer.
     (If it still refuses: xattr -dr com.apple.quarantine /Applications/NoteLive.app)
  3. macOS asks for Bluetooth access the first time — approve it. Without this it
     can connect to nothing.
  4. The app opens http://127.0.0.1:8765/ automatically. Open the notebook
     (unfold the cover so it wakes), make sure the green light responds to the
     pen, and write. Strokes appear within a second.

IF IT FINDS NOTHING
  - The notebook sleeps when closed. Open it first.
  - If NotePlusX is connected on that machine, that is fine — NoteLive attaches to
    the existing link — but the notebook must be awake.
  - The notebook was originally paired with your other Mac. On a machine that has
    never seen it, you may need to put the notebook into pairing mode: hold the
    multifunction button ~3 s until the blue light flashes rapidly, then relaunch
    NoteLive. Accept any system pairing prompt.
  - A one-page protocol summary is in source/PROTOCOL-NOTES.md if you want to
    write your own client instead.

CONNECT / DISCONNECT
  The top-left panel shows the link to the notebook:
      [connected]   green  - ink is streaming
      [scanning…]   blue   - looking for the notebook (it may be asleep)
      [connecting…] amber  - found it, setting up the link
      [disconnected] grey  - you pressed disconnect
      [Bluetooth off] red  - Bluetooth is switched off
  The button next to it toggles the link. Press "disconnect" to stop the app
  from touching the notebook; press "connect" to pick it up again. Ink already
  drawn stays on screen when you disconnect.

  If the notebook is asleep it stops advertising, so a reconnect can take a
  moment. Open the notebook (or hold the multifunction button ~3 s) if it does
  not come back.

WHAT IT DOES NOT DO (yet)
  The ~50 pages stored offline inside the notebook still require a device command
  that has not been reverse-engineered. Live capture only covers writing that
  happens while NoteLive is connected.

REBUILDING / MODIFYING
  ASSISTANT-HANDOFF.md is the technical handoff: full protocol, code map, extension
  recipes, failure modes and a test checklist. Read that before editing notelive.swift.

  source/ contains notelive.swift (single file, no dependencies) and build_app.sh.
  Xcode command line tools are required:  xcode-select --install
      cd source && ./build_app.sh      # produces NoteLive.app (universal)

  Command line use (no bundle):
      swiftc -O -o notelive notelive.swift
      ./notelive live              # serve on 8765, no browser auto-launch
      ./notelive live 9000         # different port
      ./notelive replay capture.txt 9000 4   # replay a saved ble-log capture

  Every received event is also appended to live-<timestamp>.ndjson in the working
  directory — that file is the input for transcription work.
