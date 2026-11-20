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
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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

// ---------------------------------------------------------------- configuration
//
// Every secret comes from the environment, or from ~/.config/marvolo/env — a file
// that is never in the repo. Nothing here is printed: only whether a value exists.
// That is what lets this file be published open-source without a scrub pass.
//
//   DEEPSEEK_API_KEY        OCR (transcribe button)
//   MARVOLO_WEBHOOK_URL     n8n webhook that stores the note (capture button)
//   MARVOLO_WEBHOOK_TOKEN   optional, sent as "Authorization: Bearer …"
//   MARVOLO_OCR_ENDPOINT    override the OCR endpoint
//   MARVOLO_NOTES_DIR       override where note folders are written

func readEnvFile(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        if !key.isEmpty { out[key] = value }
    }
    return out
}

let configPath = NSHomeDirectory() + "/.config/marvolo/env"
let fileEnv = readEnvFile(configPath)

func cfg(_ name: String) -> String? {
    if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
    if let v = fileEnv[name], !v.isEmpty { return v }
    return nil
}

let ocrEndpoint = cfg("MARVOLO_OCR_ENDPOINT") ?? "https://api.deepseek.com/v1/tools/ocr"
let ocrKey = cfg("DEEPSEEK_API_KEY")
let webhookURL = cfg("MARVOLO_WEBHOOK_URL")
let webhookToken = cfg("MARVOLO_WEBHOOK_TOKEN")
let notesDirEnv = cfg("MARVOLO_NOTES_DIR")

// Say what is configured, never what it is. A missing key should be visible at
// startup, not discovered by pressing a button that quietly fails.
print("config: ocr \(ocrKey == nil ? "NO KEY (transcribe will refuse)" : "key set")"
      + " -> \(URL(string: ocrEndpoint)?.host ?? ocrEndpoint)")
print("config: webhook \(webhookURL == nil ? "not set (notes stay local)" : (URL(string: webhookURL!)?.host ?? "set"))")

// ---------------------------------------------------------------- page document
//
// Until now the process was a pipe: bytes in, bytes out, no model of what had been
// written. Capture and transcribe both need the page, so keep one.
//
// This is updated from `emit`, which runs on the Bluetooth callback thread. Appending
// three integers under a lock is nanoseconds; rendering and I/O happen elsewhere, so
// the rule from the handoff (nothing slow on that thread) still holds.

struct DocPoint { let x: Int; let y: Int; let p: Int }

final class Document {
    private let lock = NSLock()
    private var strokes: [[DocPoint]] = []
    private var cur: [DocPoint] = []
    private var sheet = 0            // only `clear` starts a new sheet

    func ingest(_ type: UInt8, x: Int, y: Int, p: Int) {
        lock.lock(); defer { lock.unlock() }
        switch type {
        case 0xA1:
            cur.append(DocPoint(x: x, y: y, p: p))
        case 0xA0, 0xC0:
            // 0xA0 is hover and 0xC0 is the notebook's marker: BOTH only end the
            // current stroke. A marker is NOT a page turn — the device emits one at
            // stroke boundaries (14 of them for two handwritten lines), so treating
            // it as a page break left the "current page" empty right after writing
            // and capture answered "nothing written". Sheet changes are explicit:
            // the user presses clear.
            flushLocked()
        default:
            break
        }
    }

    private func flushLocked() {
        if cur.count > 1 { strokes.append(cur) }
        cur = []
    }

    /// Current sheet and its strokes, including the one still being written.
    func snapshot() -> (page: Int, strokes: [[DocPoint]]) {
        lock.lock(); defer { lock.unlock() }
        var out = strokes
        if cur.count > 1 { out.append(cur) }
        return (sheet, out)
    }

    var sheetNumber: Int {
        lock.lock(); defer { lock.unlock() }
        return sheet
    }

    /// The browser's `clear` button clears here too, and starts the next sheet, so the
    /// next capture does not resurrect strokes the user just wiped off the screen.
    /// `clears` also disables the session-file fallback: once the user emptied the
    /// sheet, reading old ink back off disk would be a bug, not a rescue.
    func clearCurrentPage() {
        lock.lock(); defer { lock.unlock() }
        strokes = []
        cur = []
        sheet += 1
        clears += 1
    }

    private var clears = 0
    var hasCleared: Bool {
        lock.lock(); defer { lock.unlock() }
        return clears > 0
    }
}

let document = Document()

// ---------------------------------------------------------------- rendering
//
// The capture is vector, so the PNG is rendered from the points, not screenshotted
// from a browser: no window needed, no scaling artefacts, and it works while the
// page is mid-stroke.

struct InkFrame { let x0, y0, x1, y1: Double }

func inkFrame(_ strokes: [[DocPoint]]) -> InkFrame? {
    var x0 = Double.greatestFiniteMagnitude, y0 = Double.greatestFiniteMagnitude
    var x1 = -Double.greatestFiniteMagnitude, y1 = -Double.greatestFiniteMagnitude
    var n = 0
    for s in strokes { for q in s {
        x0 = min(x0, Double(q.x)); y0 = min(y0, Double(q.y))
        x1 = max(x1, Double(q.x)); y1 = max(y1, Double(q.y)); n += 1
    } }
    guard n > 0 else { return nil }
    let padX = max(120.0, (x1 - x0) * 0.06), padY = max(120.0, (y1 - y0) * 0.08)
    return InkFrame(x0: x0 - padX, y0: y0 - padY, x1: x1 + padX, y1: y1 + padY)
}

/// Pressure to stroke width in output pixels. The device's own pressure units are
/// 0…8191; the same curve the on-screen renderer uses, scaled to the output so thin
/// hairlines stay readable instead of vanishing.
func penWidth(_ p: Int, scale: Double) -> Double {
    let base = 0.7 + Double(p) / 1100.0
    return max(1.4, min(10.0, base * scale * 14.0))
}

func renderPNG(_ strokes: [[DocPoint]], maxWidth: Int = 2400) -> Data? {
    guard let f = inkFrame(strokes) else { return nil }
    let w = f.x1 - f.x0, h = f.y1 - f.y0
    let scale = min(4.0, Double(maxWidth) / max(1.0, w))
    let pxW = max(1, Int((w * scale).rounded())), pxH = max(1, Int((h * scale).rounded()))

    guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pxW), height: CGFloat(pxH)))
    ctx.setStrokeColor(CGColor(red: 0.07, green: 0.06, blue: 0.05, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // Core Graphics puts the origin bottom-left; the notebook's Y grows downward.
    // Flip once here so the render matches the sheet (and never mirror the text).
    ctx.translateBy(x: 0, y: CGFloat(pxH))
    ctx.scaleBy(x: 1, y: -1)

    func tx(_ q: DocPoint) -> CGPoint {
        CGPoint(x: (Double(q.x) - f.x0) * scale, y: (Double(q.y) - f.y0) * scale)
    }
    for s in strokes where s.count > 1 {
        for i in 1..<s.count {
            ctx.setLineWidth(CGFloat(penWidth((s[i - 1].p + s[i].p) / 2, scale: scale)))
            ctx.beginPath()
            ctx.move(to: tx(s[i - 1]))
            ctx.addLine(to: tx(s[i]))
            ctx.strokePath()
        }
    }
    guard let image = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

func renderSVG(_ strokes: [[DocPoint]]) -> String? {
    guard let f = inkFrame(strokes) else { return nil }
    let w = Int((f.x1 - f.x0).rounded()), h = Int((f.y1 - f.y0).rounded())
    var out = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(w) \(h)" width="\(w)" height="\(h)">
    <rect width="\(w)" height="\(h)" fill="#ffffff"/>
    <g fill="none" stroke="#15120f" stroke-linecap="round" stroke-linejoin="round">

    """
    func sx(_ v: Int, _ origin: Double) -> Int { Int((Double(v) - origin).rounded()) }
    for s in strokes where s.count > 1 {
        for i in 1..<s.count {
            let a = s[i - 1], b = s[i]
            let wpx = String(format: "%.2f", penWidth((a.p + b.p) / 2, scale: 1.0) / 14.0 * 3.0)
            out += "<line x1=\"\(sx(a.x, f.x0))\" y1=\"\(sx(a.y, f.y0))\" x2=\"\(sx(b.x, f.x0))\" "
                 + "y2=\"\(sx(b.y, f.y0))\" stroke-width=\"\(wpx)\"/>\n"
        }
    }
    out += "</g>\n</svg>\n"
    return out
}

// ---------------------------------------------------------------- http client
//
// No dependencies, so URLSession with a semaphore: the calling thread is already a
// per-connection worker, and every call here is allowed to block for a few seconds.

func httpPost(_ urlString: String, body: Data, contentType: String,
              headers: [String: String] = [:], timeout: TimeInterval = 90) -> (Int, Data) {
    guard let url = URL(string: urlString) else { return (-1, Data("malformed url".utf8)) }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(contentType, forHTTPHeaderField: "Content-Type")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body
    req.timeoutInterval = timeout

    let sem = DispatchSemaphore(value: 0)
    var status = -1
    var payload = Data()
    let task = URLSession.shared.dataTask(with: req) { data, response, error in
        if let http = response as? HTTPURLResponse { status = http.statusCode }
        if let e = error { payload = Data("transport error: \(e.localizedDescription)".utf8) }
        else { payload = data ?? Data() }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
        task.cancel()
        return (-1, Data("timeout after \(Int(timeout))s".utf8))
    }
    return (status, payload)
}

func multipart(boundary: String, fields: [(String, String)],
               files: [(name: String, filename: String, mime: String, data: Data)]) -> Data {
    var body = Data()
    for (name, value) in fields {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append(value.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
    }
    for f in files {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(f.name)\"; filename=\"\(f.filename)\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: \(f.mime)\r\n\r\n".data(using: .utf8)!)
        body.append(f.data)
        body.append("\r\n".data(using: .utf8)!)
    }
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    return body
}

func randomBoundary() -> String { "marvolo-\(UUID().uuidString)" }

/// DeepSeek's OCR tool: image in, text out, one page per response. Not a chat model,
/// so nothing is invented around the transcription.
func ocrText(png: Data) -> (text: String?, error: String?) {
    guard let key = ocrKey else {
        return (nil, "DEEPSEEK_API_KEY is not set (environment or ~/.config/marvolo/env)")
    }
    let boundary = randomBoundary()
    let body = multipart(boundary: boundary,
                         fields: [("purpose", "text_recognition")],
                         files: [(name: "file", filename: "page.png", mime: "image/png", data: png)])
    let (status, reply) = httpPost(ocrEndpoint, body: body,
                                   contentType: "multipart/form-data; boundary=\(boundary)",
                                   headers: ["Authorization": "Bearer \(key)"])
    guard (200..<300).contains(status) else {
        let snippet = String(decoding: reply.prefix(400), as: UTF8.self)
        return (nil, "OCR failed: HTTP \(status) — \(snippet)")
    }
    guard let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
          let pages = obj["pages"] as? [[String: Any]] else {
        return (nil, "OCR replied with an unexpected body: \(String(decoding: reply.prefix(300), as: UTF8.self))")
    }
    let text = pages.compactMap { $0["text"] as? String }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (text.isEmpty ? nil : text, text.isEmpty ? "OCR returned no text for this page" : nil)
}

// ---------------------------------------------------------------- notes
//
// A note is a folder, not a database: page.png, page.svg, meta.json and page.txt.
// n8n receives the same things and decides where they live long-term, so the Drive or
// vault credentials never enter this process. Swapping storage later means editing a
// workflow, not rebuilding the app.

var lastTranscript: String? = nil
var lastTranscriptPage = -1
var lastNote: (dir: URL, page: Int)? = nil

func noteStamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    return f.string(from: Date())
}

func notesBaseDir() -> URL {
    if let dir = notesDirEnv { return URL(fileURLWithPath: dir, isDirectory: true) }
    return captureDir.appendingPathComponent("notes", isDirectory: true)
}

/// One folder per capture. Capturing twice keeps both snapshots rather than
/// overwriting: the page may have grown between them, and that is data.
func uniqueNoteDir(page: Int) -> URL {
    let base = notesBaseDir()
    let stem = "\(noteStamp())-p\(page + 1)"
    var dir = base.appendingPathComponent(stem, isDirectory: true)
    var n = 2
    while FileManager.default.fileExists(atPath: dir.path) {
        dir = base.appendingPathComponent("\(stem)-\(n)", isDirectory: true)
        n += 1
    }
    return dir
}

func writeNoteFile(_ url: URL, _ data: Data) -> String? {
    do { try data.write(to: url); return nil }
    catch { return "\(url.lastPathComponent): \(error.localizedDescription)" }
}

/// Rebuild strokes from a session file. The in-memory model is empty after a restart,
/// and the ndjson is the only thing that outlives the process, so capture checks disk
/// before telling the user there is nothing to save.
func strokesFromSession(_ path: String) -> [[DocPoint]] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var out: [[DocPoint]] = []
    var cur: [DocPoint] = []
    for line in text.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = ev["t"] as? String else { continue }
        if t == "ink" {
            cur.append(DocPoint(x: (ev["x"] as? NSNumber)?.intValue ?? 0,
                                y: (ev["y"] as? NSNumber)?.intValue ?? 0,
                                p: (ev["p"] as? NSNumber)?.intValue ?? 0))
        } else if t == "hover" || t == "marker" {
            if cur.count > 1 { out.append(cur) }
            cur = []
        }
    }
    if cur.count > 1 { out.append(cur) }
    return out
}

/// Current session first, then the most recently written session that has ink. Returns
/// the file it used so the note records where the strokes actually came from.
func strokesFromDisk() -> (strokes: [[DocPoint]], file: String) {
    if !capturePath.isEmpty {
        let s = strokesFromSession(capturePath)
        if !s.isEmpty { return (s, (capturePath as NSString).lastPathComponent) }
    }
    let files = (try? FileManager.default.contentsOfDirectory(
        at: captureDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let sessions = files
        .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "ndjson" }
        .sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    for url in sessions.prefix(5) {
        let s = strokesFromSession(url.path)
        if !s.isEmpty { return (s, url.lastPathComponent) }
    }
    return ([], "")
}

/// Snapshot the current sheet. The sheet stays open — this is a camera, not a scalpel.
func capturePage() -> [String: Any] {
    let snap = document.snapshot()
    var strokes = snap.strokes
    var source = (capturePath as NSString).lastPathComponent
    var fromMemory = true
    if strokes.isEmpty && !document.hasCleared {
        let disk = strokesFromDisk()
        strokes = disk.strokes
        if !disk.file.isEmpty { source = disk.file }
        fromMemory = false
    }
    let points = strokes.reduce(0) { $0 + $1.count }
    guard points > 0, let png = renderPNG(strokes) else {
        return ["ok": false, "error": document.hasCleared
                    ? "this sheet is empty — you cleared it, so there is nothing to capture"
                    : "no ink yet — nothing has been written"]
    }

    let dir = uniqueNoteDir(page: snap.page)
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    catch { return ["ok": false, "error": "cannot create \(dir.path): \(error.localizedDescription)"] }

    var failures: [String] = []
    if let e = writeNoteFile(dir.appendingPathComponent("page.png"), png) { failures.append(e) }
    let svg = renderSVG(strokes)
    if let svg = svg, let e = writeNoteFile(dir.appendingPathComponent("page.svg"), Data(svg.utf8)) {
        failures.append(e)
    }

    // A transcription made before the capture belongs to the same note, so the note
    // travels complete instead of the text arriving later and orphaned.
    let textHere = (lastTranscriptPage == snap.page) ? lastTranscript : nil
    if let text = textHere,
       let e = writeNoteFile(dir.appendingPathComponent("page.txt"), Data(text.utf8)) {
        failures.append(e)
    }

    var meta: [String: Any] = [
        "app": "marvolo",
        "page": snap.page + 1,
        "captured": ISO8601DateFormatter().string(from: Date()),
        "strokes": strokes.count,
        "points": points,
        "session": source,
        "source": fromMemory ? "memory" : "session-file",
        "png": "page.png",
        "svg": svg == nil ? "" : "page.svg",
    ]
    if let text = textHere { meta["text"] = text }
    if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]),
       let e = writeNoteFile(dir.appendingPathComponent("meta.json"), data) {
        failures.append(e)
    }
    lastNote = (dir, snap.page)

    var result: [String: Any] = [
        "ok": true,
        "page": snap.page + 1,
        "dir": dir.path,
        "strokes": strokes.count,
        "points": points,
        "source": fromMemory ? "memory" : "session-file",
        "text": textHere ?? "",
    ]
    if !failures.isEmpty { result["writeErrors"] = failures }

    if let hook = webhookURL {
        var headers: [String: String] = [:]
        if let token = webhookToken { headers["Authorization"] = "Bearer \(token)" }
        let boundary = randomBoundary()
        var fields: [(String, String)] = []
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            fields.append(("meta", json))
        }
        if let text = textHere { fields.append(("text", text)) }
        var files: [(name: String, filename: String, mime: String, data: Data)] = [
            (name: "page", filename: "page.png", mime: "image/png", data: png)
        ]
        if let svg = svg { files.append((name: "svg", filename: "page.svg", mime: "image/svg+xml", data: Data(svg.utf8))) }
        let (status, reply) = httpPost(hook,
                                       body: multipart(boundary: boundary, fields: fields, files: files),
                                       contentType: "multipart/form-data; boundary=\(boundary)",
                                       headers: headers, timeout: 60)
        result["uploaded"] = (200..<300).contains(status)
        result["webhook"] = ["status": status,
                             "reply": String(decoding: reply.prefix(300), as: UTF8.self)]
        print("capture: webhook HTTP \(status)")
    } else {
        result["uploaded"] = false
        result["webhook"] = "MARVOLO_WEBHOOK_URL not set — note kept local"
    }
    print("capture: page \(snap.page + 1), \(strokes.count) strokes, \(points) points (\(fromMemory ? "memory" : source)) -> \(dir.path)")
    return result
}

func transcribePage() -> [String: Any] {
    let snap = document.snapshot()
    var strokes = snap.strokes
    if strokes.isEmpty && !document.hasCleared { strokes = strokesFromDisk().strokes }
    guard let png = renderPNG(strokes) else {
        return ["ok": false, "error": document.hasCleared
                    ? "this sheet is empty — you cleared it, so there is nothing to capture"
                    : "no ink yet — nothing has been written"]
    }
    let started = Date()
    let (text, error) = ocrText(png: png)
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    guard let text = text else {
        print("transcribe: \(error ?? "failed")")
        return ["ok": false, "error": error ?? "OCR failed", "ms": ms]
    }
    lastTranscript = text
    lastTranscriptPage = snap.page

    // If this page was already captured, the transcript lands in that note too.
    var saved = ""
    if let note = lastNote, note.page == snap.page {
        let url = note.dir.appendingPathComponent("page.txt")
        if let e = writeNoteFile(url, Data(text.utf8)) { saved = "error: \(e)" } else { saved = url.path }
    }
    print("transcribe: page \(snap.page + 1), \(text.count) chars in \(ms) ms")
    return ["ok": true, "page": snap.page + 1, "text": text, "ms": ms, "saved": saved]
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
  #msg{font-size:11px;color:#1c6b1c;min-height:1em}
  #msg.err{color:#8f1f1f;font-weight:600}
  #panel{display:none;margin-top:6px;max-width:460px;max-height:38vh;overflow:auto;
         background:#fff;border:1px solid #dcdcdc;border-radius:6px;padding:6px 8px}
  #panelhead{display:flex;align-items:center;gap:6px;margin-bottom:4px;color:#666}
  #panelhead button{margin-left:auto}
  #out{margin:0;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;color:#15120f}
</style></head>
<body><canvas id="c"></canvas>
<div id="hud">
  <span class="dot" id="dot"></span><span id="state">connecting…</span>
  <span id="link" class="pill">connecting…</span>
  <button id="linkbtn" onclick="toggleLink()">disconnect</button>
  <button id="capbtn" onclick="doCapture()">capture</button>
  <button id="trbtn" onclick="doTranscribe()">transcribe</button>
  <button onclick="clearAll()">clear</button>
  <div>points <b id="pts">0</b> &nbsp; strokes <b id="strokes">0</b> &nbsp; <b id="rate">0</b>/s
       &nbsp;·&nbsp; <span id="cap">checking save…</span></div>
  <div id="msg"></div>
  <div id="panel">
    <div id="panelhead"><b id="eng"></b><button onclick="copyText()">copy</button>
      <button onclick="hidePanel()">×</button></div>
    <pre id="out"></pre>
  </div>
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
  // Clear the server-side page too, otherwise the next capture would resurrect what
  // the user just wiped off the screen.
  fetch('/ctl?action=clear').catch(()=>{});
}

// Snapshot and transcription. Both block on the server, so the buttons say what they
// are doing and refuse a second click while one is in flight.
let lastText = '';
function say(text, bad){
  const el = document.getElementById('msg');
  el.textContent = text;
  el.className = bad ? 'err' : '';
  if (!bad) { const mine = text; setTimeout(() => { if (el.textContent === mine) el.textContent = ''; }, 6000); }
}
async function doCapture(){
  const b = document.getElementById('capbtn');
  b.disabled = true; say('capturing…');
  try {
    const r = await (await fetch('/capture')).json();
    if (!r.ok) { say(r.error || 'capture failed', true); }
    else {
      const name = (r.dir || '').split('/').pop();
      say('saved ' + name + (r.uploaded ? ' · sent' : ' · local only'));
    }
  } catch (e) { say('capture failed: ' + e, true); }
  b.disabled = false;
}
async function doTranscribe(){
  const b = document.getElementById('trbtn');
  b.disabled = true; say('transcribing…');
  try {
    const r = await (await fetch('/transcribe')).json();
    if (!r.ok) { say(r.error || 'transcription failed', true); }
    else {
      lastText = r.text || '';
      document.getElementById('out').textContent = lastText;
      document.getElementById('eng').textContent = 'ocr ' + (r.ms / 1000).toFixed(1) + 's'
        + (r.saved ? ' · saved' : '');
      document.getElementById('panel').style.display = 'block';
      say('transcribed');
    }
  } catch (e) { say('transcription failed: ' + e, true); }
  b.disabled = false;
}
function copyText(){
  navigator.clipboard.writeText(lastText).then(() => say('copied')).catch(() => say('copy failed', true));
}
function hidePanel(){ document.getElementById('panel').style.display = 'none'; }
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

        // Control endpoint for the browser HUD.
        //   GET /ctl?action=connect | disconnect | clear
        // `clear` is deliberately NOT forwarded to the BLE layer: that closure treats
        // anything that is not "connect" as disconnect, which would drop the link.
        if path.hasPrefix("/ctl") {
            let action = path.contains("action=connect") ? "connect"
                      : path.contains("action=disconnect") ? "disconnect"
                      : path.contains("action=clear") ? "clear" : ""
            var ok = false
            switch action {
            case "connect", "disconnect":
                linkControl?(action); ok = true
            case "clear":
                document.clearCurrentPage(); ok = true
            default:
                break
            }
            _ = respondJSON(fd, ["ok": ok, "action": action])
            return
        }

        // Snapshot the current page: renders it, writes the note folder, and hands the
        // same files to the n8n webhook if one is configured. GET so that both the HUD
        // button and a plain curl call do the same thing.
        if path.hasPrefix("/capture") {
            _ = respondJSON(fd, capturePage())
            return
        }

        // Transcribe the current page through the OCR endpoint. Blocking by design: the
        // browser button waits and shows the result, and this thread serves one request.
        if path.hasPrefix("/transcribe") {
            _ = respondJSON(fd, transcribePage())
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

    /// One JSON reply, headers and all. Every endpoint that is not the SSE stream or
    /// the page itself goes through here, so Content-Length is never forgotten.
    @discardableResult
    private func respondJSON(_ fd: Int32, _ object: [String: Any]) -> Bool {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"ok\":false,\"error\":\"could not encode response\"}".utf8)
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = sendAll(fd, Array(head.utf8))
        _ = sendAll(fd, [UInt8](body))
        close(fd)
        return true
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
    document.ingest(type, x: x, y: y, p: p)
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
