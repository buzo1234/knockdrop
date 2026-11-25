import Foundation
import CryptoKit

/// Constants shared with knockdrop.py. Change them there and here together.
enum KD {
    static let serviceType = "_knockdrop._tcp"
    static let minKnocks = 3
    static let maxKnocks = 16
    static let patternEndQuiet: TimeInterval = 1.5   // a rhythm ends after this long without a knock
    static let tolerance = 0.12
    static let offerLifetime: TimeInterval = 300
    static let maxFailedClaims = 8                   // wrong rhythms an offer takes before it closes
    static let maxTriesPerOffer = 3                  // wrong rhythms we send one offer before giving up on it
    static let tableWindow: TimeInterval = 20        // a rhythm felt this long before an offer appears can claim it
    static let chunk = 1 << 16
    static let clipboardKinds: Set<String> = ["text", "image", "files"]
}

enum KDError: LocalizedError {
    case closed, timeout, badResponse, checksum(String), tooLong

    var errorDescription: String? {
        switch self {
        case .closed: return "The connection closed"
        case .timeout: return "Timed out"
        case .badResponse: return "Unexpected reply"
        case .checksum(let name): return "\(name) arrived damaged"
        case .tooLong: return "Reply too long"
        }
    }
}

// MARK: - rhythm math (same as knockdrop.py)

enum Rhythm {
    static func intervals(_ t: [Double]) -> [Double] {
        zip(t, t.dropFirst()).map { $1 - $0 }
    }

    /// Each gap as a fraction of the whole pattern, so tempo doesn't matter.
    static func normalized(_ t: [Double]) -> [Double] {
        let iv = intervals(t)
        let total = iv.reduce(0, +)
        return iv.map { $0 / (total > 0 ? total : 1e-9) }
    }

    /// 0 = identical; nil when the knock counts differ.
    static func distance(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        return zip(normalized(a), normalized(b)).map { abs($0 - $1) }.max()
    }

    static func matches(_ a: [Double], _ b: [Double], tolerance: Double = KD.tolerance) -> Bool {
        guard let d = distance(a, b), let la = a.last, let lb = b.last else { return false }
        let tempo = max(la, 1e-9) / max(lb, 1e-9)
        return d <= tolerance && tempo >= 0.5 && tempo <= 2.0
    }

    static func isTooRegular(_ t: [Double]) -> Bool {
        let iv = intervals(t)
        guard let hi = iv.max(), let lo = iv.min() else { return false }
        return hi / max(lo, 1e-9) < 1.6
    }

    static func validCount(_ n: Int) -> Bool { (KD.minKnocks...KD.maxKnocks).contains(n) }
}

/// Collects knocks from the screen and the motion sensor into one rhythm. Times are seconds
/// since boot: UITouch.timestamp and CMDeviceMotion.timestamp both use that clock.
struct RhythmRecorder {
    enum Source { case touch, motion }

    private(set) var knocks: [TimeInterval] = []
    private(set) var source: Source?

    /// Returns true if the knock was counted.
    mutating func add(_ t: TimeInterval, from s: Source) -> Bool {
        guard let owner = source, let last = knocks.last else {
            source = s
            knocks = [t]
            return true
        }
        if s == owner {
            guard t - last >= 0.08 else { return false }   // one knock rings for a while; two fingers land together
            knocks.append(t)
            return true
        }
        // Tapping the screen shakes the phone, so the sensor may report the first tap before the
        // touch arrives. Taps are exact, so they win; the sensor's echoes of them are ignored.
        if s == .touch, owner == .motion, knocks.count == 1, t - knocks[0] < 0.25 {
            source = .touch
            knocks = [t]
            return true
        }
        return false
    }

    /// The finished rhythm (relative times) once nobody knocked for `patternEndQuiet`.
    mutating func finish(now: TimeInterval) -> (pattern: [Double], source: Source)? {
        guard let last = knocks.last, let s = source, now - last > KD.patternEndQuiet else { return nil }
        let p = knocks.map { $0 - knocks[0] }
        reset()
        return (p, s)
    }

    mutating func reset() {
        knocks = []
        source = nil
    }
}

// MARK: - files

enum Files {
    /// A safe file name from whatever the other side sent: no folders, no hidden files.
    static func safeName(_ name: String) -> String {
        var n = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? "file" : n
    }

    /// `folder/name`, or `name (1)`, `name (2)`... if that's taken.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        let safe = safeName(name)
        let ext = (safe as NSString).pathExtension
        let base = (safe as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(safe)
        var i = 1
        while fm.fileExists(atPath: url.path) || fm.fileExists(atPath: url.path + ".part") {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        return url
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: KD.chunk), !d.isEmpty {
            hasher.update(data: d)
        }
        return hasher.finalize().hex
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// A fresh empty folder in the temporary directory.
    static func scratchFolder(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func human(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

func randomHex(_ bytes: Int) -> String {
    (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
}

/// "clipboard text", "an image", "3 files" -- what an offer holds, for people.
func offerLabel(clipboard: String?, fileCount: Int) -> String {
    switch clipboard {
    case "text": return "clipboard text"
    case "image": return "a clipboard image"
    default: return fileCount == 1 ? "1 file" : "\(fileCount) files"
    }
}
