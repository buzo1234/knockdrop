#if canImport(UIKit)
import Foundation
import Observation

/// One share from this phone: gather what to send, take a rhythm, keep the offer open.
@Observable @MainActor
final class Sharing {
    enum Phase: Equatable { case none, preparing, needRhythm, live }

    private(set) var phase: Phase = .none
    private(set) var draft: Draft?
    private(set) var pattern: [Double] = []
    private(set) var expires: Date?
    private(set) var sentTo: [String] = []
    private(set) var sendingTo: [String] = []
    private(set) var offerID: String?
    /// The latest thing worth telling the person ("Ana's Mac knocked a different rhythm").
    private(set) var note: String?
    /// Name shown to receivers.
    var from = "iPhone"

    @ObservationIgnored private var server: OfferServer?
    @ObservationIgnored private var job: Task<Void, Never>?

    var isBusy: Bool { phase != .none }

    /// Gather what to share, then wait for a rhythm.
    func prepare(_ make: @escaping () async throws -> Draft) {
        stop()
        phase = .preparing
        note = nil
        job = Task {
            do {
                let d = try await make()
                guard !Task.isCancelled else { return }
                draft = d
                phase = .needRhythm
            } catch {
                guard !Task.isCancelled else { return }
                phase = .none
                note = error.localizedDescription
            }
        }
    }

    /// The rhythm to share behind.
    func use(_ rhythm: [Double]) {
        guard phase == .needRhythm, let d = draft else { return }
        guard Rhythm.validCount(rhythm.count) else {
            note = rhythm.count < KD.minKnocks ? "Tap at least \(KD.minKnocks) times" : "At most \(KD.maxKnocks) taps"
            return
        }
        pattern = rhythm
        phase = .preparing
        note = Rhythm.isTooRegular(rhythm) ? "Tip: an even beat is easy to guess. Mix short and long gaps." : nil
        let name = from
        job = Task {
            do {
                let files = try await Task.detached { try d.files.map(SharedFile.init(url:)) }.value
                guard !Task.isCancelled else { return }
                let s = OfferServer(files: files, pattern: rhythm, clipboard: d.clipboard, from: name)
                s.onEvent = { [weak self] e in self?.handle(e) }
                try s.start()
                server = s
                offerID = s.id
                expires = s.expires
                sentTo = []
                sendingTo = []
                phase = .live
            } catch {
                phase = .none
                note = "Couldn't start sharing: \(error.localizedDescription)"
            }
        }
    }

    /// Stop sharing. `why` is shown when it wasn't the person's own doing.
    func stop(_ why: String? = nil) {
        job?.cancel()
        job = nil
        let wasLive = phase == .live
        server?.stop()
        server = nil
        offerID = nil
        phase = .none
        draft = nil
        if wasLive {
            let sent = sentTo.count
            note = why ?? (sent == 0 ? "Stopped sharing" : "Shared with \(sent == 1 ? sentTo[0] : "\(sent) people")")
        }
    }

    func clearNote() { note = nil }

    private func handle(_ e: OfferServer.Event) {
        switch e {
        case .ready:
            break
        case .sending(let who):
            sendingTo.append(who)
        case .sent(let who):
            if let i = sendingTo.firstIndex(of: who) { sendingTo.remove(at: i) }
            sentTo.append(who)
            note = "Sent to \(who)"
        case .wrong(let who, let left):
            note = "\(who) knocked a different rhythm" + (left <= 3 && left > 0 ? " (\(left) tries left)" : "")
        case .transferFailed(let who, _):
            if let i = sendingTo.firstIndex(of: who) { sendingTo.remove(at: i) }
            note = "Sending to \(who) broke off. They can knock again."
        case .closed(let reason):
            stop(reason == "expired" ? (sentTo.isEmpty ? "Your share expired" : "Share ended; sent to \(sentTo.count)")
                                     : "Stopped: \(reason)")
        }
    }
}
#endif
