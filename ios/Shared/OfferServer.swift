import Foundation
import Network

struct SharedFile {
    let name: String
    let url: URL
    let size: Int64
    let sha256: String

    init(url: URL) throws {
        self.url = url
        self.name = url.lastPathComponent
        self.size = Files.size(of: url)
        self.sha256 = try Files.sha256(of: url)
    }
}

/// One share: a TCP port advertised over Bonjour that hands the files to anyone who knocks the
/// same rhythm. Same protocol as serve_claim() in knockdrop.py, and like a menu bar share it
/// serves many receivers until stopped, it expires, or too many wrong rhythms arrive.
final class OfferServer: @unchecked Sendable {
    enum Event {
        case ready
        case sending(to: String)
        case sent(to: String)
        case wrong(from: String, attemptsLeft: Int)
        case transferFailed(to: String, message: String)
        case closed(reason: String)
    }

    let id = randomHex(8)
    let pattern: [Double]
    let files: [SharedFile]
    let clipboard: String?
    let from: String
    let expires: Date
    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "knockdrop.offer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var failed = 0
    private var isClosed = false

    init(files: [SharedFile], pattern: [Double], clipboard: String?, from: String, lifetime: TimeInterval = KD.offerLifetime) {
        self.files = files
        self.pattern = pattern
        self.clipboard = clipboard
        self.from = from
        self.expires = Date().addingTimeInterval(lifetime)
    }

    var txtRecord: NWTXTRecord {
        var txt = NWTXTRecord()
        txt["v"] = "1"
        txt["id"] = id
        txt["from"] = from
        txt["knocks"] = String(pattern.count)
        txt["n"] = String(files.count)
        txt["size"] = String(files.reduce(0) { $0 + $1.size })
        if let clipboard { txt["clip"] = clipboard }
        return txt
    }

    /// "Karan's iPhone 3fa2c1", cut to Bonjour's 63-byte limit.
    var serviceName: String {
        var name = from
        while "\(name) \(id.prefix(6))".utf8.count > 63 { name.removeLast() }
        return "\(name) \(id.prefix(6))"
    }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        let l = try NWListener(using: params)
        l.service = NWListener.Service(name: serviceName, type: KD.serviceType, domain: nil, txtRecord: txtRecord)
        l.newConnectionHandler = { [weak self] c in
            guard let self else { c.cancel(); return }
            Task { await self.serve(Conn(c, queue: self.queue)) }
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.emit(.ready)
            case .failed(let e): self?.close("The network stopped working (\(e.localizedDescription))")
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
        queue.asyncAfter(deadline: .now() + max(0, expires.timeIntervalSinceNow)) { [weak self] in
            self?.close("expired")
        }
    }

    /// Stop advertising and accepting. Transfers already running finish.
    func stop() { close(nil) }

    private func close(_ reason: String?) {
        lock.lock()
        let was = isClosed
        isClosed = true
        lock.unlock()
        guard !was else { return }
        listener?.cancel()
        if let reason { emit(.closed(reason: reason)) }
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { self.onEvent?(e) }
    }

    /// nil reply = it matches, go ahead and send.
    private func judge(_ claim: [String: Any], theirs: [Double]?, who: String) -> ([String: Any]?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isClosed { return (["ok": false, "reason": "offer closed"], false) }
        if claim["id"] as? String != id { return (["ok": false, "reason": "unknown offer"], false) }
        if let p = theirs, (claim["pattern"] as? [Any])?.count == p.count, Rhythm.validCount(p.count),
           Rhythm.matches(pattern, p) {
            return (nil, false)
        }
        failed += 1
        let left = KD.maxFailedClaims - failed
        emit(.wrong(from: who, attemptsLeft: left))
        return (["ok": false, "reason": "rhythm doesn't match"], left <= 0)
    }

    private func serve(_ conn: Conn) async {
        defer { conn.cancel() }
        do {
            try await conn.start()
            let claim = try await conn.readJSON()
            let who = (claim["from"] as? String).map { String($0.prefix(64)) } ?? "Someone"
            let theirs = (claim["pattern"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }

            let (reply, closeNow) = judge(claim, theirs: theirs, who: who)
            if let reply {
                try await conn.sendJSON(reply)
                if closeNow { close("too many wrong rhythms") }
                return
            }

            emit(.sending(to: who))
            var manifest: [[String: Any]] = []
            for f in files {
                var item: [String: Any] = ["name": f.name, "size": f.size, "sha256": f.sha256]
                if let clipboard { item["clipboard"] = clipboard }   // receivers put it on their clipboard
                manifest.append(item)
            }
            do {
                try await conn.sendJSON(["ok": true, "from": from, "files": manifest])
                for f in files {
                    let h = try FileHandle(forReadingFrom: f.url)
                    defer { try? h.close() }
                    while let d = try h.read(upToCount: KD.chunk), !d.isEmpty {
                        try await conn.send(d)
                    }
                }
                try await conn.finish()
                while try await conn.read(max: 1, timeout: 60) != nil {}   // until they hang up: then it all arrived
                emit(.sent(to: who))
            } catch {
                emit(.transferFailed(to: who, message: error.localizedDescription))
            }
        } catch {
            // a broken or silent connection before the claim: nothing to report
        }
    }
}
