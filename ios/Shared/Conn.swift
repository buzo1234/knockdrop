import Foundation
@preconcurrency import Dispatch
import Network

/// async/await over an NWConnection: JSON lines, then raw bytes. One task uses a Conn at a time.
final class Conn: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    init(_ connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "knockdrop.conn")) {
        self.connection = connection
        self.queue = queue
    }

    convenience init(to endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        self.init(NWConnection(to: endpoint, using: params))
    }

    /// Wait until connected. `.waiting` isn't fatal: the Local Network prompt may be up.
    func start(timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false   // only touched on `queue`
            let finish: (Error?) -> Void = { err in
                guard !done else { return }
                done = true
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready: finish(nil)
                case .failed(let e): finish(e)
                case .cancelled: finish(KDError.closed)
                default: break
                }
                if case .failed = state { connection.cancel() }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                if !done { connection.cancel(); finish(KDError.timeout) }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    func sendJSON(_ obj: [String: Any]) async throws {
        var d = try JSONSerialization.data(withJSONObject: obj)
        d.append(0x0A)
        try await send(d)
    }

    /// Close our side for writing (TCP FIN); the peer reads end-of-stream.
    func finish() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    /// Next bytes from the network; nil at end of stream. Gives up after `timeout` of silence.
    private func receive(max: Int, timeout: TimeInterval) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            var fired = false   // only touched on `queue`
            let watchdog = DispatchWorkItem { [connection] in fired = true; connection.cancel() }
            queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                watchdog.cancel()
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else if let error {
                    cont.resume(throwing: fired ? KDError.timeout : error)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    func readLine(max: Int = 65536, timeout: TimeInterval = 30) async throws -> Data {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<i])
                buffer = Data(buffer[buffer.index(after: i)...])
                return line
            }
            if buffer.count > max { throw KDError.tooLong }
            guard let d = try await receive(max: KD.chunk, timeout: timeout) else { throw KDError.closed }
            buffer.append(d)
        }
    }

    func readJSON(timeout: TimeInterval = 30) async throws -> [String: Any] {
        let line = try await readLine(timeout: timeout)
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw KDError.badResponse }
        return obj
    }

    /// Up to `max` bytes, buffered ones first; nil at end of stream.
    func read(max: Int, timeout: TimeInterval = 60) async throws -> Data? {
        if !buffer.isEmpty {
            let n = min(max, buffer.count)
            let d = Data(buffer.prefix(n))
            buffer = Data(buffer.dropFirst(n))
            return d
        }
        return try await receive(max: max, timeout: timeout)
    }

    func cancel() {
        connection.cancel()
    }
}
