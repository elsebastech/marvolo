# XP-Pen Note Plus — BLE protocol notes (realtime ink CRACKED)

Device seen by macOS as `Note Plus 2214`, BLE, `A4:C1:38:22:14:A8`,
CBPeripheral id `4061BF97-297F-EBA3-127C-78BDEBB82B6C`.
App: `/Applications/SmartNote.app/Wrapper/SmartNote.app`, `HWUGEE.NotePlus` v1.0.2.
Vendor: 汉王友基 (Hanvon Ugee; XP-Pen = Ugee). Backend `https://noteplus2.xp-pen.com`.

## GATT (verified)

    service 180A
    service 81D7FDC5-70B7-4475-821D-14E9F2E12FCA
    service 00010203-0405-0607-0809-0A0B0C0D1912
      char 2A50                                  [read]                 02 8A 24 66 82 01 00
      char 00010203-...-2B10  [read,notify]     REALTIME INK STREAM
      char 00010203-...-2B11  [read,writeNR]    COMMAND IN
      char 00010203-...-2B12  [read,write,writeNR,notify]

PnP: vendor 0x248A, product 0x6682, version 0x0100.

## KEY FINDING: ink is broadcast to every subscribed central

macOS multiplexes BLE, and this firmware pushes pen data to *all* subscribed
centrals, not only its bonded one. A second central can attach with
`retrieveConnectedPeripherals(withServices:)` while the vendor app is connected
and receives the same realtime stream. Verified: 243 packets / 2067 points in ~7 s
with the app connected.

COLD START VERIFIED: the notebook streams to our central with the vendor app never
launched and no start command sent — close/reopen the notebook, connect, write, ink
flows (5273 records / 1875 ink points in 52 s). An earlier test that saw silence was
the device asleep, not a missing command. So no handshake is required for realtime.

## Realtime ink payload (characteristic 2B10) — DECODED

Notifications are 240 bytes = 30 records of 8 bytes, little endian:

    byte 0    magic / page id     0x04, 0x05 seen (0x02 = control frame)
    byte 1    type                0xA0 in-range/NO CONTACT (hover), 0xA1 touching (ink), 0xC0 marker
    bytes 2-3 X                   uint16 LE
    bytes 4-5 Y                   uint16 LE   (grows DOWNWARD, origin top-left; do NOT flip)
    bytes 6-7 pressure            uint16 LE, 0..~8191 (nonzero only with 0xA1)

Rules:
- 0xA1 records are ink: accumulate into the current stroke;
- 0xA0 records are HOVER: pen in range, not touching (pressure is 0);
- a stroke ends at the 0xA1 -> 0xA0 transition, and 0xC0 marks a boundary;
- `05 00 00 00 00 00 00 00` terminates a burst (padding to 240 bytes).

Notification LENGTH varies: 240 B (30 points), 216 B (27 points), 64 B (4 points),
1 B, 10 B. The device batches by size and cadence, not a fixed count — always walk
8-byte records to the end of whatever arrived instead of assuming 30 per packet.

Hover is a full second data source, not padding. Measured: 1760 consecutive 0xA0
records over 7.8 s ≈ 226 samples/s, path span 25493 units, while the pen was held
above the page without touching. The vendor app discards it.

Observed on one page: X 0..18877, Y 0..28420, pressure 0..4646.

Other traffic on 2B10:
- 10-byte control frames, magic `0x02`, e.g. `02 0F 0A 00 01 00 00 00 00 00`
  (status/ack; semantics TBD)
- 64-byte bursts, magic `0x04` (separate stream — another page)

Rendering needs NO axis flip. `decode.py` writes decoded.svg / decoded.png /
decoded.json. Verified visually: the page reads "Hello world".

## Static findings in the app binary

Command/log name table: `Get_Ble_Name`, `Get_Bluetooth_Firmware_Info`,
`Get_Mac_Address`, `Get_Offline_Data_Size`, `Get_Device_Basic_Info`,
`Device_Info`, `Sleep_Settings`.

Protocol ivars: `_cPacketType`, `_numberOfBytesInPacket`, `_missingPacketIndexes`,
`_receivedPacketIndexes`, `_offlineDataTotalSize`, `_offlineDataCurrentPage`,
`_bleConnectAuthToken`, `_sendData:frameOfType:tag:`, `_sendDataHepler`
(`UGPenSendDataHelper`).

Frame protocol present: `createDispatchDataWithFrameOfType:frameTag:payload:`
(PeerTalk-derived `Lookin_PTProtocol`, used for the USB tablet line).

Recognition is MyScript/iink (embedded) → ink is vector, not raster.
Not a lead: `BLY*` classes = Tencent Bugly.

## Tools

    ./noteble scan 15                 list nearby BLE devices
    ./noteble probe "Note Plus" 60    attach to the app's live link, subscribe, log
    ./noteble gatt "Note Plus"        connect (app quit), dump tree, read chars
    ./noteble sniff "Note Plus" 45    connect (app quit), subscribe, log
    ./noteble replay <log> 8765 4      replay a capture into the live view (dev aid)
    ./notelive live [port]            LIVE VIEW: BLE -> SSE -> browser canvas
    ./notelive replay FILE [port] [x] replay a capture into the live view (dev aid)
    python3 decode.py <ble-log>.txt   decode to svg/png/json
    python3 decode2.py <log> <out>    decode with hover track (svg/png/json)
    python3 analyze.py <log>          per-magic/type statistics

Live view: run `./notelive live`, open http://127.0.0.1:8765/ . Canvas auto-fits to
what has been written, draws hover in blue and ink in black with pressure width,
prints points/strokes/points-per-second, keeps a 40k-event backlog so a late browser
or a refresh redraws the sheet, and appends every event to live-<ts>.ndjson —
that file is the feed for transcription.


## What is NOT solved

Realtime ink needs no vendor involvement. Still unknown, and each needs a command
on 2B11 that we never captured:

- downloading the 50 pages stored offline on the device;
- device settings (sleep timeout), firmware info, BLE name/MAC.

Note from the owner: the single multifunction button is how the device is told a new
offline page started — press it when turning the page, otherwise offline strokes
belong to the previous page. That is consistent with the `0xC0` boundary markers in
the stream; the button press is likely what emits them (worth confirming by pressing
the button mid-capture and looking for a lone 0xC0).

PacketLogger on this Mac is a dead end: the helper never gets blessed
(`SMPrivilegedExecutables` declared, no LaunchDaemon appears, even after clearing
the DMG quarantine flag), so no HCI trace is produced. Offline-page work would need
another approach — disassembling `UGPenSendDataHelper`, or trying the stored-page
opcodes once notes are backed up.
