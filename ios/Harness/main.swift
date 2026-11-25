// Interop tests for the iPhone app's network core, run on a Mac against the real knockdrop.py.
// Real Bonjour, real sockets, scripted knocks. Build and run with ios/test.sh.
import Foundation
import Network

let root = URL(fileURLWithPath: CommandLine.arguments[1])   // repo root
let kd = root.appendingPathComponent("knockdrop").path
let P = [0, 0.4, 0.6, 1.4, 1.8]
let P_SAME = [0, 0.42, 0.63, 1.45, 1.86]
let P_OTHER = [0, 0.8, 1.0, 1.2, 1.8]
let csv: ([Double]) -> String = { $0.map { String($0) }.joined(separator: ",") }
var failures: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print("  \(ok ? "PASS" : "FAIL")  \(name)" + (ok ? "" : "  -- \(detail())"))
    if !ok { failures.append(name) }
}

let tmp = Files.scratchFolder("knockdrop-ios-harness")
defer { try? FileManager.default.removeItem(at: tmp) }

func write(_ name: String, _ text: String) -> URL {
    let u = tmp.appendingPathComponent(name)
    try! text.write(to: u, atomically: true, encoding: .utf8)
    return u
}

func run(_ args: [String], env: [String: String] = [:]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: kd)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    return p
}

/// Browse until an offer matching `where` shows up.
func findOffer(timeout: TimeInterval = 10, where match: @escaping (NearbyOffer) -> Bool) async -> NearbyOffer? {
    await withCheckedContinuation { cont in
        DispatchQueue.main.async {
            let b = OfferBrowser()
            var done = false
            let finish: (NearbyOffer?) -> Void = { o in
                guard !done else { return }
                done = true
                b.stop()
                cont.resume(returning: o)
            }
            b.onChange = { offers in if let o = offers.first(where: match) { finish(o) } }
            b.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return cond()
}

Task {
    // ---------------------------------------------------------------- Mac shares, iPhone receives
    print("Mac shares a file -> iPhone core receives it (Bonjour only, like a real iPhone)")
    let payload = "héllo from the Mac 👊\n" + String(repeating: "x", count: 300_000)
    let src = write("from mac.txt", payload)
    let sender = run(["--pattern", csv(P), "send", "-y", "--multi", src.path], env: ["KNOCKDROP_BEACONS": "bonjour"])
    let offer = await findOffer { $0.knocks == 5 && $0.fileCount == 1 }
    check("offer found over Bonjour", offer != nil, "nothing on _knockdrop._tcp")
    if let offer {
        let host = String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "")
        check("TXT says who and what", offer.from.lowercased() == host.lowercased() && offer.size == Int64(payload.utf8.count) && offer.clipboard == nil,
              "\(offer.from) \(offer.size)")
        do {
            let r = try await claim(offer, pattern: P_OTHER, me: "harness", into: tmp.appendingPathComponent("in1"))
            if case .rejected(let why) = r { check("wrong rhythm rejected", why.contains("match"), why) }
            else { check("wrong rhythm rejected", false, "it was accepted") }

            let r2 = try await claim(offer, pattern: P_SAME, me: "harness", into: tmp.appendingPathComponent("in2"))
            if case .received(_, let files) = r2, let f = files.first {
                let got = try String(contentsOf: f.url, encoding: .utf8)
                check("received with the right content", got == payload && f.name == "from mac.txt", "\(f.name) \(got.count)")
            } else {
                check("matching rhythm received", false, "\(r2)")
            }
        } catch {
            check("claim", false, "\(error)")
        }
    }
    sender.terminate()
    sender.waitUntilExit()
    let gone = await findOffer(timeout: 3) { $0.id == offer?.id }
    check("offer disappears when the Mac stops", gone == nil)

    // ---------------------------------------------------------------- iPhone shares, Mac receives
    print("iPhone core shares -> knockdrop receive on the Mac gets it")
    let phoneFile = write("from phone.txt", "sent from the iPhone ✨")
    let server = OfferServer(files: [try! SharedFile(url: phoneFile)], pattern: P, clipboard: nil, from: "Test iPhone")
    var events: [OfferServer.Event] = []
    server.onEvent = { events.append($0) }
    try! server.start()
    _ = await waitFor(5) { events.contains { if case .ready = $0 { return true }; return false } }
    let out = tmp.appendingPathComponent("mac-out")
    try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let wrong = run(["--pattern", csv(P_OTHER), "receive", "--out", out.path], env: ["KNOCKDROP_BEACONS": "bonjour"])
    wrong.waitUntilExit()
    check("Mac with a wrong rhythm gets nothing", wrong.terminationStatus != 0 &&
          (try? FileManager.default.contentsOfDirectory(atPath: out.path))?.isEmpty == true)
    check("iPhone saw the wrong rhythm", events.contains { if case .wrong(_, 7) = $0 { return true }; return false }, "\(events)")

    let right = run(["--pattern", csv(P_SAME), "receive", "--out", out.path], env: ["KNOCKDROP_BEACONS": "bonjour"])
    right.waitUntilExit()
    let got = try? String(contentsOf: out.appendingPathComponent("from phone.txt"), encoding: .utf8)
    check("Mac received the iPhone's file", right.terminationStatus == 0 && got == "sent from the iPhone ✨", "\(String(describing: got))")
    check("iPhone reported it sent", await waitFor(5) { events.contains { if case .sent = $0 { return true }; return false } }, "\(events)")

    // ---------------------------------------------------------------- iPhone to iPhone, clipboard text
    print("iPhone core shares clipboard text -> another iPhone core receives it")
    let text = write("Clipboard text.txt", "copied on one phone")
    let s2 = OfferServer(files: [try! SharedFile(url: text)], pattern: P, clipboard: "text", from: "Phone A")
    try! s2.start()
    if let o = await findOffer(where: { $0.id == s2.id }) {
        check("clipboard kind in TXT", o.clipboard == "text" && o.label == "clipboard text", "\(String(describing: o.clipboard))")
        let r = try? await claim(o, pattern: P_SAME, me: "Phone B", into: tmp.appendingPathComponent("in3"))
        if case .received(let from, let files)? = r {
            check("received from Phone A", from == "Phone A" && files.first?.clipboard == "text", "\(from) \(files)")
        } else {
            check("phone to phone", false, "\(String(describing: r))")
        }
    } else {
        check("phone offer found", false)
    }
    s2.stop()

    // too many wrong rhythms close the offer
    let s3 = OfferServer(files: [try! SharedFile(url: text)], pattern: P, clipboard: nil, from: "Phone C")
    var closed = false
    s3.onEvent = { if case .closed = $0 { closed = true } }
    try! s3.start()
    if let o = await findOffer(where: { $0.id == s3.id }) {
        for _ in 0..<KD.maxFailedClaims { _ = try? await claim(o, pattern: P_OTHER, me: "x", into: tmp) }
        check("closes after \(KD.maxFailedClaims) wrong rhythms", await waitFor(3) { closed })
        let after = try? await claim(o, pattern: P, me: "x", into: tmp.appendingPathComponent("in4"))
        if case .received? = after { check("closed offer refuses the right rhythm", false) }
        else { check("closed offer refuses the right rhythm", true) }
    }

    // ---------------------------------------------------------------- rhythm math parity
    print("rhythm math")
    check("same rhythm matches", Rhythm.matches(P, P_SAME))
    check("other rhythm doesn't", !Rhythm.matches(P, P_OTHER))
    check("half tempo still matches", Rhythm.matches(P, P.map { $0 * 1.9 }))
    check("way slower doesn't", !Rhythm.matches(P, P.map { $0 * 2.5 }))
    var rec = RhythmRecorder()
    _ = rec.add(10.00, from: .motion)
    check("tap replaces the sensor's echo of it", rec.add(10.05, from: .touch) && rec.knocks == [10.05])
    check("sensor ignored once taps own the rhythm", !rec.add(10.4, from: .motion))
    _ = rec.add(10.5, from: .touch); _ = rec.add(11.0, from: .touch)
    check("not finished while knocking", rec.finish(now: 11.2) == nil)
    let done = rec.finish(now: 12.6)
    check("finished after the quiet", done?.source == .touch &&
          zip(done?.pattern ?? [], [0, 0.45, 0.95]).allSatisfy { abs($0 - $1) < 1e-9 } && done?.pattern.count == 3, "\(String(describing: done))")

    // detector: quiet noise, then a sharp spike
    let det = KnockDetector(threshold: 3, rate: 100)
    var hits: [TimeInterval] = []
    for i in 0..<400 {
        let t = Double(i) / 100
        var v = (0..<6).map { _ in Double.random(in: -0.003...0.003) }
        if i == 200 || i == 230 { v[5] += 0.2; v[1] += 0.3 }
        if let k = det.feed(t, v) { hits.append(k) }
    }
    check("detector finds two knocks in noise", hits.count == 2 && abs(hits[0] - 2.0) < 0.02, "\(hits)")

    print(failures.isEmpty ? "\nall passed" : "\nFAILED: \(failures.joined(separator: ", "))")
    exit(failures.isEmpty ? 0 : 1)
}

RunLoop.main.run()
