// marvolo — live ink view for the XP-Pen Note Plus.
//
//   ./marvolo live    [port]          capture over BLE and stream to a browser
//   ./marvolo replay FILE [port] [x]  replay a ble-log file at x speed (default 1.0)
//
// Open http://127.0.0.1:8765/ in a browser. Every stroke and hover sample arrives
// over Server-Sent Events and is drawn on a canvas. Events are also appended to
// session-<epoch>.ndjson under ~/Library/Application Support/Marvolo/captures/,
// which is the feed for transcription (NOTELIVE_CAPTURE_DIR overrides the dir).
import Foundation
import CoreBluetooth
import Darwin

signal(SIGPIPE, SIG_IGN)
// Line-buffer stdout: without this, print() is block-buffered when stdout is not a TTY
// (double-click launch, redirect to a log), so every diagnostic below is lost.
setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "live"
var port: UInt16 = 8765
var replayFile: String? = nil
var replaySpeed: Double = 1.0

if mode == "replay" {
    guard args.count > 2 else { print("usage: marvolo replay FILE [port] [speed]"); exit(1) }
    replayFile = args[2]
    if args.count > 3, let p = UInt16(args[3]) { port = p }
    if args.count > 4, let s = Double(args[4]) { replaySpeed = s }
} else if args.count > 2, let p = UInt16(args[2]) {
    port = p
}

let isReplay = (mode == "replay")

// ------------------------------------------------------- capture file (local state)
//
// Strokes are the user's handwriting, so they are LOCAL STATE: they live under
// Application Support and are never committed to the repo.
//
// Do NOT use currentDirectoryPath here. A Finder launch gives the process cwd "/",
// where createFile fails, the handle stays nil, and every single event is dropped
// in silence while the HUD still says "connected". That happened for real: the app
// ran with 7,662 events in RAM and zero bytes on disk.

func jsonEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

let captureEnv = ProcessInfo.processInfo.environment["NOTELIVE_CAPTURE_DIR"] ?? ""
let baseCaptureDir: URL = {
    // Escape hatch for tests and for pointing the archive at a synced folder.
    if !captureEnv.isEmpty { return URL(fileURLWithPath: captureEnv, isDirectory: true) }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Marvolo/captures", isDirectory: true)
}()

// A replay is a test run (or a ble-log -> ndjson conversion), not a writing
// session. Keep it out of the handwriting archive — under captures/replay/ —
// unless the caller named a directory explicitly.
let replayCapture = isReplay && captureEnv.isEmpty
let captureDir = replayCapture
    ? baseCaptureDir.appendingPathComponent("replay", isDirectory: true)
    : baseCaptureDir

var captureStatus = "unknown"
var capturePath = ""
var ndjson: FileHandle? = nil

do {
    try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
    let name = "\(replayCapture ? "replay" : "session")-\(Int(Date().timeIntervalSince1970)).ndjson"
    capturePath = captureDir.appendingPathComponent(name).path
    if !FileManager.default.fileExists(atPath: capturePath) {
        FileManager.default.createFile(atPath: capturePath, contents: nil)
    }
    ndjson = FileHandle(forWritingAtPath: capturePath)
} catch {
    print("CAPTURE ERROR: cannot prepare \(captureDir.path): \(error)")
}

captureStatus = (ndjson != nil) ? "writing" : "error"
if ndjson != nil {
    print("capturing to \(capturePath)")
} else {
    print("CAPTURE DISABLED — \(capturePath.isEmpty ? captureDir.path : capturePath) is not writable.")
    print("  Strokes are kept in memory only and WILL BE LOST on quit.")
}

func record(_ json: String) {
    guard let h = ndjson else { return }
    do {
        try h.write(contentsOf: (json + "\n").data(using: .utf8)!)
    } catch {
        print("CAPTURE ERROR: write failed (\(error)) — events are now memory-only")
        ndjson = nil
        captureStatus = "error"
    }
}

// ---------------------------------------------------------------- page

let html = #"""
<!doctype html>
<html><head><meta charset="utf-8"><title>Marvolo — live ink</title>
<style>
  html,body{margin:0;height:100%;background:#f6f4ef;font:13px -apple-system,system-ui,sans-serif;overflow:hidden}
  canvas{display:block;width:100vw;height:100vh}
  #hud{position:fixed;top:10px;left:12px;background:rgba(255,255,255,.86);border:1px solid #ddd;
       border-radius:8px;padding:8px 12px;line-height:1.5;color:#333;box-shadow:0 1px 4px rgba(0,0,0,.08)}
  #hud b{font-variant-numeric:tabular-nums}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#c33;margin-right:6px}
  .dot.on{background:#2a2}
  button{font:12px inherit;margin-left:8px;padding:2px 8px;border:1px solid #ccc;border-radius:5px;background:#fff;cursor:pointer}
  .pill{display:inline-block;margin-left:10px;padding:2px 9px;border-radius:10px;font-size:11px;
        background:#e8e8e8;color:#555;border:1px solid #d5d5d5;vertical-align:middle}
  .pill.connected{background:#e2f6e2;color:#1c6b1c;border-color:#b6e3b6}
  .pill.connecting{background:#fff4e0;color:#8a5a00;border-color:#f0d9a8}
  .pill.scanning{background:#eaf1fb;color:#1f4f8f;border-color:#c3d8f2}
  .pill.disconnected{background:#f0f0f0;color:#666;border-color:#dcdcdc}
  .pill.bluetoothOff{background:#fdeaea;color:#8f1f1f;border-color:#f3c9c9}
  button[disabled]{opacity:.5;cursor:default}
</style></head>
<body><canvas id="c"></canvas>
<div id="hud">
  <span class="dot" id="dot"></span><span id="state">connecting…</span>
  <span id="link" class="pill">connecting…</span>
  <button id="linkbtn" onclick="toggleLink()">disconnect</button>
  <button onclick="clearAll()">clear</button>
  <div>points <b id="pts">0</b> &nbsp; strokes <b id="strokes">0</b> &nbsp; <b id="rate">0</b>/s
       &nbsp;·&nbsp; <span id="cap">checking save…</span></div>
</div>
<script>
const LW = 28800, LH = 36400;          // nominal active area only; Y grows DOWNWARD (origin top-left)
// LW/LH are the fallback frame used when there is nothing worth fitting. Do not
// treat LH as a clip: real ink has been measured to Y=39043 and view() frames
// whatever was actually written, so a point past LH is drawn, not lost.
const cv = document.getElementById('c'), ctx = cv.getContext('2d');
let sc = 1, ox = 0, oy = 0;
let strokes = [], cur = [], hovers = [], pts = 0, marks = 0;
let rateN = 0, rateT = performance.now(), dirty = true;

// Frame the canvas to what has actually been written, not the whole sheet.
function view(){
  let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9, n = 0;
  const acc = q => { if (q.x < x0) x0 = q.x; if (q.x > x1) x1 = q.x;
                     if (q.y < y0) y0 = q.y; if (q.y > y1) y1 = q.y; n++; };
  for (const s of strokes) for (const q of s) acc(q);
  for (const q of cur) acc(q);
  if (n < 40 || (x1 - x0) < 400) { x0 = 0; y0 = 0; x1 = LW; y1 = LH; }
  const padx = Math.max(500, (x1 - x0) * 0.07), pady = Math.max(500, (y1 - y0) * 0.07);
  x0 -= padx; x1 += padx; y0 -= pady; y1 += pady;
  const dpr = window.devicePixelRatio || 1;
  cv.width = Math.floor(cv.clientWidth * dpr);
  cv.height = Math.floor(cv.clientHeight * dpr);
  const w = x1 - x0, h = y1 - y0;
  sc = Math.min(cv.width / w, cv.height / h);
  ox = (cv.width - w * sc) / 2 - x0 * sc;
  oy = (cv.height - h * sc) / 2 - y0 * sc;
  ctx.lineCap = 'round'; ctx.lineJoin = 'round';
}
function px(x, y){ return [ox + x * sc, oy + y * sc]; }

function stroke(s){
  if (!s || s.length < 2) return;
  const dpr = window.devicePixelRatio || 1;
  for (let i = 1; i < s.length; i++){
    const a = px(s[i-1].x, s[i-1].y), b = px(s[i].x, s[i].y);
    ctx.strokeStyle = '#15120f';
    ctx.lineWidth = Math.max(0.7, Math.min(4.2, 0.7 + s[i].p / 1100)) * dpr;
    ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke();
  }
}
function redraw(){
  view();
  ctx.clearRect(0, 0, cv.width, cv.height);
  const dpr = window.devicePixelRatio || 1;
  for (const q of hovers){
    const [sx, sy] = px(q.x, q.y);
    ctx.fillStyle = 'rgba(70,140,255,.18)';
    ctx.beginPath(); ctx.arc(sx, sy, 1.4 * dpr, 0, 6.283); ctx.fill();
  }
  for (const s of strokes) stroke(s);
  stroke(cur);
}
function ingest(m){
  if (m.t === 'ink') { cur.push({x: m.x, y: m.y, p: m.p}); pts++; }
  else if (m.t === 'hover') {
    if (cur.length > 1) strokes.push(cur);
    cur = [];
    hovers.push({x: m.x, y: m.y});
    if (hovers.length > 1200) hovers.shift();
  } else if (m.t === 'marker' || m.t === 'done') {
    if (cur.length > 1) strokes.push(cur);
    cur = []; marks++;
  } else return;
  dirty = true;
}
function clearAll(){
  strokes = []; cur = []; hovers = []; pts = 0; marks = 0; dirty = true; redraw(); paint();
}
let linkEnabled = true, linkBusy = false;

function applyStatus(m){
  if (m.t !== 'status') return false;
  linkEnabled = m.enabled; linkBusy = m.busy;
  const pill = document.getElementById('link');
  pill.textContent = m.label;
  pill.className = 'pill ' + m.state;
  const btn = document.getElementById('linkbtn');
  btn.textContent = linkEnabled ? 'disconnect' : 'connect';
  btn.disabled = linkBusy;
  const st = document.getElementById('state');
  if (m.state === 'connected') { st.textContent = 'live'; }
  else if (m.state === 'bluetooth off') { st.textContent = 'Bluetooth off'; }
  else { st.textContent = 'no device'; }
  document.getElementById('dot').classList.toggle('on', m.state === 'connected');
  return true;
}

// Capture state is separate from link state: the device can be connected while
// nothing is being written. A silent save failure is worse than a loud one.
function applyCapture(m){
  if (!m || !m.capture) return;
  const el = document.getElementById('cap');
  if (!el) return;
  if (m.capture.state === 'writing') {
    el.textContent = 'saving ' + (m.capture.file || '');
    el.style.color = '#1c6b1c'; el.style.fontWeight = 'normal';
  } else if (m.capture.state === 'error') {
    el.textContent = 'NOT SAVING — strokes are memory-only';
    el.style.color = '#8f1f1f'; el.style.fontWeight = '600';
  } else {
    el.textContent = m.capture.state;
  }
}

function toggleLink(){
  const act = linkEnabled ? 'disconnect' : 'connect';
  document.getElementById('linkbtn').disabled = true;
  fetch('/ctl?action=' + act).catch(()=>{});
}

function paint(){
  document.getElementById('pts').textContent = pts;
  document.getElementById('strokes').textContent = strokes.length + (cur.length > 1 ? 1 : 0);
}

const es = new EventSource('/events');
es.onopen = () => { document.getElementById('dot').classList.add('on');
                    document.getElementById('state').textContent = 'live'; };
es.onerror = () => { document.getElementById('dot').classList.remove('on');
                     document.getElementById('state').textContent = 'disconnected'; };
es.onmessage = ev => {
  const m = JSON.parse(ev.data);
  rateN++;
  if (applyStatus(m)) return;
  if (m.t === 'done') { ingest(m); dirty = true; redraw(); paint();
                        if (!document.getElementById('linkbtn').style.display) {
                          document.getElementById('state').textContent = 'replay finished';
                        }
                        return; }
  ingest(m);
};
setInterval(() => {
  const now = performance.now();
  document.getElementById('rate').textContent = Math.round(rateN * 1000 / (now - rateT));
  rateN = 0; rateT = now;
  if (dirty) { dirty = false; redraw(); }
  paint();
}, 700);

window.addEventListener('resize', () => { dirty = true; });
setInterval(() => { fetch('/status').then(r => r.json()).then(applyCapture).catch(()=>{}); }, 5000);
fetch('/status').then(r => r.json()).then(m => {
  if (m.replay) {
    // Replay mode: no device link to control.
    const pill = document.getElementById('link');
    pill.textContent = 'replay'; pill.className = 'pill disconnected';
    const b = document.getElementById('linkbtn');
    b.textContent = 'replay'; b.disabled = true; b.style.display = 'none';
    return;
  }
  applyCapture(m); applyStatus(m);
}).catch(()=>{});
redraw(); paint();
</script></body></html>
"""#

// ---------------------------------------------------------------- SSE server

final class Server {
    let port: UInt16
    private var clients: [Int32] = []
    private var history: [String] = []
    private let maxHistory = 40000
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    var stats = (clients: 0, events: 0)

    init(port: UInt16) { self.port = port }

    func start() {
        Thread.detachNewThread { self.acceptLoop() }
    }

    private func acceptLoop() {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        if listenFD < 0 { print("socket() failed"); exit(1) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { print("bind failed on port \(port) (errno \(errno)) — try another port"); exit(1) }
        if listen(listenFD, 16) != 0 { print("listen failed"); exit(1) }
        print("serving on http://127.0.0.1:\(port)/")
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            Thread.detachNewThread { self.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { close(fd); return }
        let req = String(decoding: buf[0..<n], as: UTF8.self)
        let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        if path.hasPrefix("/events") {
            let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Cache-Control: no-cache\r
            Connection: keep-alive\r
            Access-Control-Allow-Origin: *\r
            \r
            retry: 1000\n\n
            """
            if sendAll(fd, Array(head.utf8)) {
                lock.lock()
                // catch a late client up on everything drawn so far
                if !history.isEmpty {
                    var catchup = ""
                    catchup.reserveCapacity(history.count * 40)
                    for h in history { catchup += "data: \(h)\n\n" }
                    _ = sendAll(fd, Array(catchup.utf8))
                }
                clients.append(fd)
                stats.clients = clients.count
                lock.unlock()
                print("browser attached (\(stats.clients) client(s), \(history.count) backlog events)")
                return   // keep open
            }
            close(fd); return
        }

        if path == "/" || path.hasPrefix("/index") {
            let body = Array(html.utf8)
            var head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            _ = sendAll(fd, Array(head.utf8))
            _ = sendAll(fd, body)
            close(fd)
            return
        }

        // Current link state, for browsers that loaded after the last status change.
        if path.hasPrefix("/status") {
            // Merge the capture state into whatever the link layer last published,
            // so a browser can always tell whether strokes are reaching disk.
            let base = linkStatusJSON ?? "{\"t\":\"status\",\"state\":\"scanning\",\"label\":\"connecting…\",\"enabled\":true,\"busy\":false,\"replay\":\(isReplay)}"
            let trimmed = base.hasSuffix("}") ? String(base.dropLast()) : base
            let merged = trimmed
                + ",\"capture\":{\"state\":\"\(captureStatus)\""
                + ",\"dir\":\"\(jsonEscape(captureDir.path))\""
                + ",\"file\":\"\(jsonEscape((capturePath as NSString).lastPathComponent))\"}}"
            let body = Array(merged.utf8)
            var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            _ = sendAll(fd, Array(head.utf8))
            _ = sendAll(fd, body)
            close(fd)
            return
        }

        // Control endpoint for connect/disconnect from the browser HUD.
        //   GET /ctl?action=connect
        //   GET /ctl?action=disconnect
        if path.hasPrefix("/ctl") {
            let action = path.contains("action=connect") ? "connect"
                      : path.contains("action=disconnect") ? "disconnect" : ""
            if !action.isEmpty { linkControl?(action) }
            let body = Array("{\"ok\":\(action.isEmpty ? "false" : "true")}".utf8)
            var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            _ = sendAll(fd, Array(head.utf8))
            _ = sendAll(fd, body)
            close(fd)
            return
        }

        if path.hasPrefix("/stats") {
            let s = "{\"clients\":\(stats.clients),\"events\":\(stats.events)"
                  + ",\"capture\":\"\(captureStatus)\""
                  + ",\"captureFile\":\"\(jsonEscape(capturePath))\"}"
            let body = Array(s.utf8)
            var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            _ = sendAll(fd, Array(head.utf8))
            _ = sendAll(fd, body)
            close(fd)
            return
        }

        _ = sendAll(fd, Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        close(fd)
    }

    private func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let sent = bytes[off...].withUnsafeBytes { send(fd, $0.baseAddress, bytes.count - off, 0) }
            if sent <= 0 { return false }
            off += sent
        }
        return true
    }

    // A client that goes away is only noticed when the next event fails to send.
    // In replay mode (or when the pen is idle) no event arrives, so the stale fd and
    // the client count leak forever. Poll with a zero-byte write instead: a dead
    // socket reports EPIPE, a live one reports success.
    func reapDeadClients() {
        lock.lock()
        var dead: [Int32] = []
        let empty: [UInt8] = []
        for fd in clients {
            let n = empty.withUnsafeBytes { send(fd, $0.baseAddress, 0, 0) }
            if n < 0 { dead.append(fd) }
        }
        if !dead.isEmpty {
            clients.removeAll { dead.contains($0) }
            stats.clients = clients.count
            for fd in dead { close(fd) }
            print("reaped \(dead.count) dead client(s)")
        }
        lock.unlock()
    }

    func broadcast(_ json: String) {
        let payload = Array("data: \(json)\n\n".utf8)
        lock.lock()
        stats.events += 1
        history.append(json)
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
        var dead: [Int32] = []
        for fd in clients where !sendAll(fd, payload) { dead.append(fd) }
        if !dead.isEmpty {
            clients.removeAll { dead.contains($0) }
            stats.clients = clients.count
            for fd in dead { close(fd) }
            print("dropped \(dead.count) dead client(s)")
        }
        lock.unlock()
        record(json)
    }
}

// Hook the server's control endpoint to the BLE layer. Declared before the server
// because the server is created first; assigned once `live` exists.
var linkControl: ((String) -> Void)?
var linkStatusJSON: String?

let server = Server(port: port)
// Deliberately NOT started here: each mode starts it only once its input is known
// to be good, so a bad capture (or a taken port) fails before "serving on …" is
// printed. A process that announces a URL and then exits is a confusing lie.

// Periodically drop clients that disconnected without us noticing.
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 5.0)
        server.reapDeadClients()
    }
}

// ---------------------------------------------------------------- ink decoding

func emit(type: UInt8, x: Int, y: Int, p: Int) {
    switch type {
    case 0xA1: server.broadcast("{\"t\":\"ink\",\"x\":\(x),\"y\":\(y),\"p\":\(p)}")
    case 0xA0: server.broadcast("{\"t\":\"hover\",\"x\":\(x),\"y\":\(y)}")
    case 0xC0: server.broadcast("{\"t\":\"marker\"}")
    default: break
    }
}

func consume(_ data: Data) {
    let b = [UInt8](data)
    var i = 0
    while i + 7 < b.count {
        let r = Array(b[i..<(i + 8)])
        emit(type: r[1], x: Int(r[2]) | (Int(r[3]) << 8),
             y: Int(r[4]) | (Int(r[5]) << 8),
             p: Int(r[6]) | (Int(r[7]) << 8))
        i += 8
    }
}

// ---------------------------------------------------------------- replay mode

if mode == "replay", let file = replayFile {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("replay: cannot read \(file)"); exit(1)
    }
    let rx = try! NSRegularExpression(pattern: "^RX ([\\d.]+) \\S+ len=(\\d+) \\| (.+)$")
    var items: [(Double, Data)] = []
    var skipped = 0, addressed = 0
    for line in text.split(separator: "\n") {
        let s = String(line)
        guard s.contains("2B10") else { continue }
        addressed += 1
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            skipped += 1; continue
        }
        let t = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let hex = ns.substring(with: m.range(at: 3))
        var bytes: [UInt8] = []
        for tok in hex.split(separator: " ") {
            if let v = UInt8(tok, radix: 16) { bytes.append(v) }
        }
        if bytes.count >= 8 { items.append((t, Data(bytes))) } else { skipped += 1 }
    }
    // A capture that decodes to nothing must fail here, not open a convincing
    // empty page. Wrong file, wrong address column, or a truncated export all
    // land in this branch.
    if items.isEmpty {
        print("replay: no decodable 2B10 packets in \(file)")
        if addressed == 0 {
            print("replay: no line contains \"2B10\" in the address column — this is")
            print("        probably not a ble-log capture (ndjson sessions are not).")
        } else {
            print("replay: \(addressed) 2B10 line(s) found but none matched the expected shape:")
        }
        print("        RX 1000.000 2B10 len=8 | 04 A0 E8 03 E8 03 00 00")
        print("replay: refusing to serve an empty page"); exit(1)
    }
    if skipped > 0 { print("replay: skipped \(skipped) unparsable 2B10 line(s)") }
    server.start()
    print("replaying \(items.count) packets at \(replaySpeed)x — open http://127.0.0.1:\(port)/")
    let t0 = items.first?.0 ?? 0
    DispatchQueue.global().async {
        var prev = t0
        for (t, d) in items {
            let dt = min(0.25, max(0, (t - prev) / replaySpeed))
            if dt > 0 { Thread.sleep(forTimeInterval: dt) }
            prev = t
            consume(d)
        }
        server.broadcast("{\"t\":\"done\"}")
        print("replay finished")
    }
    RunLoop.main.run()
}

// ---------------------------------------------------------------- live BLE mode

enum LinkState: String {
    case scanning = "scanning"     // looking for the notebook
    case connecting = "connecting" // found it, GATT in progress
    case connected = "connected"   // subscribed to the ink stream
    case disconnected = "disconnected" // user asked to disconnect, or link lost
    case bluetoothOff = "bluetooth off"

    var label: String {
        switch self {
        case .scanning: return "scanning…"
        case .connecting: return "connecting…"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .bluetoothOff: return "Bluetooth off"
        }
    }
}

final class Live: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: String
    var chosen: CBPeripheral?

    /// When false the app does not touch the notebook at all — the user turned it off.
    var enabled = true
    /// True while a connect/disconnect is in flight, so the UI can grey out the button.
    var busy = false
    var state: LinkState = .scanning {
        didSet { if oldValue != state { publishStatus() } }
    }

    init(target: String) {
        self.target = target
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // ---- control actions (driven by the browser HUD) ----

    func connect() {
        guard !enabled else { return }
        enabled = true
        busy = false
        print("connect requested")
        startScanning()
    }

    func disconnect() {
        enabled = false
        busy = false
        print("disconnect requested")
        central?.stopScan()
        if let p = chosen {
            central?.cancelPeripheralConnection(p)
        }
        chosen = nil
        // lastKnown is deliberately kept: it is how "connect" finds the device again
        // once it has stopped advertising.
        state = .disconnected
    }

    // ---- scanning ----

    /// The last peripheral we saw. Kept across a manual disconnect so that
    /// "connect" can re-establish the link directly, even when the notebook has
    /// stopped advertising (which is what happens right after we cancel the link).
    private var lastKnown: CBPeripheral?
    /// Set while we are trying to reach `lastKnown` directly, so that a failure or a
    /// timeout can fall back to active scanning.
    private var directAttempt = false
    private var directTimer: Timer?

    private func startScanning() {
        guard enabled else { return }
        guard central.state == .poweredOn else {
            state = .bluetoothOff
            return
        }
        // 1. If we already know the device, try to reconnect to it directly.
        if chosen == nil, let known = lastKnown {
            chosen = known
            known.delegate = self
            state = .connecting
            directAttempt = true
            print("reconnecting to \(known.name ?? "device")...")
            central.connect(known, options: nil)
            // If the device is not advertising, connect() can hang for ever.
            // Give it a few seconds, then fall back to scanning for it.
            directTimer?.invalidate()
            directTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) {
                [weak self] _ in
                guard let self, self.directAttempt, self.enabled else { return }
                self.directAttempt = false
                print("direct reconnect timed out — falling back to scan")
                self.chosen = nil
                self.state = .scanning
                self.central.stopScan()
                self.central.scanForPeripherals(withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
            return
        }
        // 2. If something else (e.g. the vendor app) already holds the notebook, join it
        // instead of waiting for an advertisement that will never come.
        if chosen == nil {
            let cands = [CBUUID(string: "00010203-0405-0607-0809-0A0B0C0D2B10"),
                         CBUUID(string: "00010203-0405-0607-0809-0A0B0C0D1912")]
            if let p = central.retrieveConnectedPeripherals(withServices: cands).first {
                chosen = p
                lastKnown = p
                p.delegate = self
                state = .connecting
                print("attaching to already-connected \(p.name ?? "device")")
                central.connect(p, options: nil)
                return
            }
        }
        if state != .connecting { state = .scanning }
        print("scanning for '\(target)'...")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    // ---- status reporting to the browser ----

    private func publishStatus() {
        let j = "{\"t\":\"status\",\"state\":\"\(state.rawValue)\",\"label\":\"\(state.label)\",\"enabled\":\(enabled),\"busy\":\(busy)}"
        linkStatusJSON = j
        server.broadcast(j)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            state = .bluetoothOff
            print("bluetooth state \(c.state.rawValue) — is Bluetooth on, and is this app allowed to use it?")
            return
        }
        guard enabled else { return }
        startScanning()
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled, chosen == nil else { return }
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.lowercased().contains(target.lowercased()) else { return }
        chosen = p
        lastKnown = p
        c.stopScan()
        state = .connecting
        print("connecting to \(name)...")
        p.delegate = self
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        directAttempt = false
        directTimer?.invalidate()
        print("connected — discovering services")
        p.delegate = self
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("disconnected (\(error.map { "\($0)" } ?? "no error"))")
        directAttempt = false
        directTimer?.invalidate()
        chosen = nil
        if !enabled { state = .disconnected; return }
        guard enabled else { state = .disconnected; return }
        // The notebook sleeps on its own; when it wakes we pick it up again.
        state = .scanning
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startScanning() }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("connect failed (\(error.map { "\($0)" } ?? "?"))")
        directAttempt = false
        directTimer?.invalidate()
        chosen = nil
        guard enabled else { state = .disconnected; return }
        state = .scanning
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startScanning() }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        var subscribed = false
        for ch in service.characteristics ?? [] {
            if ch.uuid.uuidString.hasSuffix("2B10") && ch.properties.contains(.notify) {
                p.setNotifyValue(true, for: ch)
                subscribed = true
                print("subscribed to ink stream \(ch.uuid.uuidString)")
            }
        }
        if subscribed {
            busy = false
            state = .connected
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let d = ch.value, !d.isEmpty { consume(d) }
    }
}

let live = Live(target: "Note Plus")
server.start()
linkControl = { action in
    if action == "connect" { live.connect() } else { live.disconnect() }
}
// When launched as a double-clickable .app, open the live view automatically.
if Bundle.main.bundleIdentifier != nil {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["http://127.0.0.1:\(port)/"]
        try? p.run()
    }
}
print("live mode — ink will stream to http://127.0.0.1:\(port)/")
RunLoop.main.run()
