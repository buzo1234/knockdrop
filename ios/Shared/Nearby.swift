import Foundation
import Network

/// Someone nearby sharing something, found over Bonjour (`_knockdrop._tcp`, see knockdrop.py).
struct NearbyOffer: Identifiable, Equatable {
    let id: String
    let from: String
    let knocks: Int
    let fileCount: Int
    let size: Int64
    let clipboard: String?
    let endpoint: NWEndpoint

    init?(txt: NWTXTRecord, endpoint: NWEndpoint) {
        guard txt["v"] == "1", let id = txt["id"], !id.isEmpty,
              let k = txt["knocks"].flatMap(Int.init), Rhythm.validCount(k) else { return nil }
        self.id = id
        self.from = txt["from"].flatMap { $0.isEmpty ? nil : String($0.prefix(64)) } ?? "Someone"
        self.knocks = k
        self.fileCount = txt["n"].flatMap(Int.init) ?? 1
        self.size = txt["size"].flatMap(Int64.init) ?? 0
        self.clipboard = txt["clip"].flatMap { KD.clipboardKinds.contains($0) ? $0 : nil }
        self.endpoint = endpoint
    }

    var label: String { offerLabel(clipboard: clipboard, fileCount: fileCount) }
}

/// Watches the network for offers. Calls `onChange` on the main queue with the current list.
final class OfferBrowser {
    var onChange: (([NearbyOffer]) -> Void)?
    var onError: ((NWError) -> Void)?
    private var browser: NWBrowser?
    private var stopped = true

    func start() {
        stopped = false
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: KD.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.publish(results) }
        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let e):
                self.onError?(e)
                self.browser?.cancel()
                self.browser = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !self.stopped { self.start() } }
            case .waiting(let e):
                self.onError?(e)   // usually Local Network access turned off
            default:
                break
            }
        }
        browser = b
        b.start(queue: .main)
    }

    func stop() {
        stopped = true
        browser?.cancel()
        browser = nil
        onChange?([])
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        var byID: [String: NearbyOffer] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, let o = NearbyOffer(txt: txt, endpoint: r.endpoint) else { continue }
            byID[o.id] = o   // the same offer can show up once per network interface
        }
        onChange?(byID.values.sorted { ($0.from, $0.id) < ($1.from, $1.id) })
    }
}
