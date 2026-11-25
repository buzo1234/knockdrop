import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Observation

/// What arrived, shown on the received sheet.
struct Delivery: Identifiable {
    enum Content {
        case text(String)
        case image(URL)
        case files([ReceivedFile])
    }
    let id = UUID()
    let from: String
    let content: Content
    let felt: Bool   // taken with a rhythm the phone felt on the table
}

@Observable @MainActor
final class AppModel {
    private(set) var nearby: [NearbyOffer] = []
    /// Who we're downloading from right now.
    private(set) var receivingFrom: String?
    var delivery: Delivery?
    private(set) var note: String?
    private(set) var networkTrouble = false
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "name"); sharing.from = displayName }
    }

    let input = KnockInput()
    let sharing = Sharing()

    @ObservationIgnored private let browser = OfferBrowser()
    @ObservationIgnored private var tries: [String: Int] = [:]     // wrong rhythms we sent each offer
    @ObservationIgnored private var got: Set<String> = []
    @ObservationIgnored private var firstSeen: [String: TimeInterval] = [:]
    @ObservationIgnored private var felt: [(at: TimeInterval, pattern: [Double])] = []
    @ObservationIgnored private var noteTask: Task<Void, Never>?

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? UIDevice.current.name : n
    }

    init() {
        name = UserDefaults.standard.string(forKey: "name") ?? ""
        sharing.from = displayName
        input.onPattern = { [weak self] p, s in self?.rhythm(p, from: s) }
        browser.onChange = { [weak self] offers in self?.update(offers) }
        browser.onError = { [weak self] _ in self?.networkTrouble = true }
        Staging.cleanUp()
    }

    // MARK: lifecycle

    func setActive(_ on: Bool) {
        input.setActive(on)
        if on {
            networkTrouble = false
            browser.start()
        } else {
            browser.stop()
            if sharing.phase == .live { sharing.stop("Sharing stopped when you left KnockDrop") }
        }
    }

    func say(_ s: String) {
        note = s
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled { note = nil }
        }
    }

    // MARK: receiving

    private func update(_ offers: [NearbyOffer]) {
        networkTrouble = false
        let now = ProcessInfo.processInfo.systemUptime
        nearby = offers.filter { $0.id != sharing.offerID }
        for o in nearby where firstSeen[o.id] == nil {
            firstSeen[o.id] = now
            // Same table: someone knocked on it, then their share appeared. Take it with what we felt.
            felt.removeAll { now - $0.at > KD.tableWindow }
            if receivingFrom == nil, !sharing.isBusy,
               let f = felt.last(where: { $0.pattern.count == o.knocks }) {
                felt.removeAll { $0.at == f.at }
                Task { await take([o], with: f.pattern, felt: true) }
            }
        }
    }

    private func rhythm(_ pattern: [Double], from source: RhythmRecorder.Source) {
        if sharing.phase == .needRhythm {
            sharing.use(pattern)
            return
        }
        guard receivingFrom == nil, !sharing.isBusy else { return }
        let n = pattern.count
        guard Rhythm.validCount(n) else {
            if source == .touch { say(n < KD.minKnocks ? "Tap at least \(KD.minKnocks) times" : "That's too many taps") }
            return
        }
        let candidates = nearby
            .filter { $0.knocks == n && (tries[$0.id] ?? 0) < KD.maxTriesPerOffer && !got.contains($0.id) }
            .sorted { (firstSeen[$0.id] ?? 0) > (firstSeen[$1.id] ?? 0) }   // newest first: most likely the one just knocked
        guard !candidates.isEmpty else {
            if source == .motion {
                remember(pattern)
            } else {
                let others = Set(nearby.map(\.knocks)).sorted()
                say(others.isEmpty ? "Nobody nearby is sharing right now"
                    : "Nobody's sharing \(n) knocks. Nearby: \(others.map(String.init).joined(separator: ", ")) knocks.")
            }
            return
        }
        Task { await take(candidates, with: pattern, felt: source == .motion) }
    }

    /// A rhythm felt on the table with no share to match yet: the share may be on its way
    /// (the sender finishes knocking, then announces it).
    private func remember(_ pattern: [Double]) {
        felt.append((ProcessInfo.processInfo.systemUptime, pattern))
    }

    private func take(_ offers: [NearbyOffer], with pattern: [Double], felt: Bool) async {
        receivingFrom = offers[0].from
        defer { receivingFrom = nil }
        let incoming = FileManager.default.temporaryDirectory.appendingPathComponent("knockdrop-incoming")
        var lastError: Error?
        for o in offers {
            receivingFrom = o.from
            do {
                switch try await claim(o, pattern: pattern, me: displayName, into: incoming) {
                case .received(let from, let files):
                    got.insert(o.id)
                    deliver(from: from, files: files, felt: felt)
                    return
                case .rejected:
                    tries[o.id, default: 0] += 1
                }
            } catch {
                lastError = error
            }
        }
        if felt { remember(pattern) }   // it may belong to a share that hasn't appeared yet
        if let lastError {
            say("Couldn't reach \(offers[0].from): \(lastError.localizedDescription)")
        } else if felt {
            say("Felt \(pattern.count) knocks, but they didn't match \(offers[0].from)'s rhythm")
        } else {
            say("That rhythm didn't match. Try again.")
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Clipboard shares go on our clipboard, like on a Mac. Files go to Documents, which is
    /// KnockDrop's folder in the Files app.
    private func deliver(from: String, files: [ReceivedFile], felt: Bool) {
        let fm = FileManager.default
        let kinds = Set(files.compactMap(\.clipboard))
        let content: Delivery.Content
        if files.count == 1, kinds == ["text"], let text = try? String(contentsOf: files[0].url, encoding: .utf8) {
            UIPasteboard.general.string = text
            try? fm.removeItem(at: files[0].url)
            content = .text(text)
        } else if files.count == 1, kinds == ["image"], let data = try? Data(contentsOf: files[0].url) {
            UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
            content = .image(files[0].url)
        } else {
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var kept: [ReceivedFile] = []
            for var f in files {
                let dest = Files.uniqueURL(in: docs, name: f.name)
                if (try? fm.moveItem(at: f.url, to: dest)) != nil { f.url = dest }
                kept.append(f)
            }
            content = .files(kept)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        delivery = Delivery(from: from, content: content, felt: felt)
    }
}
