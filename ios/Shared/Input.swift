#if canImport(UIKit)
import UIKit
import Observation

/// Turns taps on the screen and knocks felt by the phone into finished rhythms.
@Observable @MainActor
final class KnockInput {
    /// Knocks of the rhythm in progress (seconds since boot), for drawing it as it's made.
    private(set) var knocks: [TimeInterval] = []
    private(set) var source: RhythmRecorder.Source?
    /// Bumped on every knock the phone feels, so the UI can show it's listening.
    private(set) var feltCount = 0
    var onPattern: (([Double], RhythmRecorder.Source) -> Void)?

    var feelKnocks: Bool {
        didSet { UserDefaults.standard.set(feelKnocks, forKey: "feelKnocks"); updateMotion() }
    }
    /// Knock threshold in noise units; lower hears softer knocks.
    var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold"); motion.threshold = threshold }
    }
    var motionAvailable: Bool { motion.isAvailable }

    @ObservationIgnored private var recorder = RhythmRecorder()
    @ObservationIgnored private let motion = MotionKnocks()
    @ObservationIgnored private var endCheck: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .rigid)

    init() {
        let d = UserDefaults.standard
        feelKnocks = d.object(forKey: "feelKnocks") as? Bool ?? true
        threshold = d.object(forKey: "threshold") as? Double ?? 3.0
        motion.threshold = threshold
        motion.onKnock = { [weak self] t in self?.add(t, .motion) }
    }

    /// The screen is showing: listen. Also used to stop when it isn't.
    func setActive(_ on: Bool) {
        active = on
        if !on { reset() }
        updateMotion()
    }

    func tap(_ t: TimeInterval) {
        add(t, .touch)
    }

    func reset() {
        recorder.reset()
        endCheck?.cancel()
        knocks = []
        source = nil
    }

    private func updateMotion() {
        if active && feelKnocks { motion.start() } else { motion.stop() }
    }

    private func add(_ t: TimeInterval, _ s: RhythmRecorder.Source) {
        guard active else { return }
        if s == .motion { feltCount += 1 }
        guard recorder.add(t, from: s) else { return }
        // No buzz for felt knocks: the phone would feel its own vibration as another knock.
        if s == .touch { haptic.impactOccurred(intensity: 0.7) }
        knocks = recorder.knocks
        source = recorder.source
        endCheck?.cancel()
        endCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((KD.patternEndQuiet + 0.05) * 1e9))
            guard !Task.isCancelled else { return }
            self?.finishIfQuiet()
        }
    }

    private func finishIfQuiet() {
        guard let done = recorder.finish(now: ProcessInfo.processInfo.systemUptime) else { return }
        knocks = []
        source = nil
        onPattern?(done.pattern, done.source)
    }
}
#endif
