import Foundation

/// Streaming knock detector, the same idea as KnockDetector in knockdrop.py, for the iPhone's
/// 100 Hz motion data. Each channel is high-passed and z-scored against its noise; energy is
/// the mean squared z, smoothed over a few ms, and a knock is the moment its square root
/// crosses `threshold`. Rotation and acceleration are scored separately and either can fire:
/// a knock on the table jolts a phone lying on it, a tap on the phone twists it.
///
/// Unlike the Mac, the noise estimate keeps adapting while things are quiet. A phone goes
/// from a hand to a desk to a sofa, and a threshold fixed at calibration time misses knocks
/// on soft surfaces.
final class KnockDetector {
    var threshold: Double
    let refractory: TimeInterval
    let settle: TimeInterval
    private let alpha: Double      // high-pass baseline
    private let beta: Double       // energy smoothing
    private let adapt: Double      // noise tracking while quiet
    private let floor: [Double]
    private var base: [Double]?
    private var noise: [Double]
    private var energy = [0.0, 0.0]
    private var armed = true
    private var lastKnock = -1e9
    private var quietSince: TimeInterval?
    private var warmup: Int

    /// Channels: rotation x/y/z (rad/s), then user acceleration x/y/z (g).
    init(threshold: Double = 3.0, rate: Double = 100, refractory: TimeInterval = 0.08,
         settle: TimeInterval = 0.03, baseline: TimeInterval = 0.02, window: TimeInterval = 0.015,
         adaptTime: TimeInterval = 4.0) {
        self.threshold = threshold
        self.refractory = refractory
        self.settle = settle
        alpha = min(1, 1 / (baseline * rate))
        beta = min(1, 1 / (window * rate))
        adapt = 1 / (adaptTime * rate)
        floor = [0.002, 0.002, 0.002, 0.0015, 0.0015, 0.0015]   // keeps a dead-still phone from hearing everything
        noise = floor.map { $0 * 3 }
        warmup = Int(0.6 * rate)   // learn the noise before reporting anything
    }

    /// Feed one sample; returns its time if a knock starts here.
    func feed(_ t: TimeInterval, _ v: [Double]) -> TimeInterval? {
        if base == nil { base = v }
        var hp = [Double](repeating: 0, count: 6)
        for i in 0..<6 {
            base![i] += alpha * (v[i] - base![i])
            hp[i] = v[i] - base![i]
        }
        if warmup > 0 {
            warmup -= 1
            for i in 0..<6 { noise[i] += 0.05 * (max(1.25 * abs(hp[i]), floor[i]) - noise[i]) }
            return nil
        }
        var e = [0.0, 0.0]
        for g in 0..<2 {
            var z2 = 0.0
            for i in (g * 3)..<(g * 3 + 3) { z2 += (hp[i] / noise[i]) * (hp[i] / noise[i]) }
            energy[g] += beta * (z2 / 3 - energy[g])
            e[g] = energy[g].squareRoot()
        }
        let level = max(e[0], e[1])
        if level < threshold / 2 {   // quiet: follow the surface's noise (mean |x| * 1.25 ~ sigma)
            for i in 0..<6 { noise[i] += adapt * (max(1.25 * abs(hp[i]), floor[i]) - noise[i]) }
        }
        if armed {
            if level > threshold && t - lastKnock > refractory {
                armed = false
                quietSince = nil
                lastKnock = t
                return t
            }
        } else if level < threshold / 2 {
            if let q = quietSince {
                if t - q >= settle { armed = true }
            } else {
                quietSince = t
            }
        } else {
            quietSince = nil
        }
        return nil
    }
}

#if os(iOS)
import CoreMotion

/// Knocks felt by the phone: on its body, or on the table it's lying on.
final class MotionKnocks {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private var detector: KnockDetector?
    /// Called on the main queue with the knock time (seconds since boot).
    var onKnock: ((TimeInterval) -> Void)?
    var threshold = 3.0 {
        didSet { let t = threshold; queue.addOperation { [weak self] in self?.detector?.threshold = t } }
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isRunning: Bool { manager.isDeviceMotionActive }

    func start() {
        guard isAvailable, !isRunning else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100
        let t = threshold
        queue.addOperation { [weak self] in self?.detector = KnockDetector(threshold: t, rate: 100) }
        manager.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            guard let self, let m, let det = self.detector else { return }
            let r = m.rotationRate, a = m.userAcceleration
            if let k = det.feed(m.timestamp, [r.x, r.y, r.z, a.x, a.y, a.z]) {
                DispatchQueue.main.async { self.onKnock?(k) }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
#endif
