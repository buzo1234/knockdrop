#if canImport(UIKit)
import SwiftUI
import UIKit

/// The surface you tap a rhythm on. UIKit, for exact touch timestamps.
struct TapPad: UIViewRepresentable {
    let onTap: (TimeInterval) -> Void

    func makeUIView(context: Context) -> PadView {
        let v = PadView()
        v.onTap = onTap
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        v.isAccessibilityElement = true
        v.accessibilityLabel = "Tap pad"
        v.accessibilityHint = "Tap a rhythm here"
        v.accessibilityTraits = .allowsDirectInteraction
        return v
    }

    func updateUIView(_ v: PadView, context: Context) {
        v.onTap = onTap
    }

    final class PadView: UIView {
        var onTap: ((TimeInterval) -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let t = touches.map(\.timestamp).min() { onTap?(t) }
        }
    }
}

/// A rhythm drawn as dots on a line: ●──●─●────●
struct RhythmStrip: View {
    let times: [Double]
    var minSpan: Double = 0
    var dot: CGFloat = 14

    var body: some View {
        Canvas { ctx, size in
            let inset = dot / 2 + 2
            let w = size.width - 2 * inset, y = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: inset, y: y))
            line.addLine(to: CGPoint(x: inset + w, y: y))
            ctx.stroke(line, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let span = max(times.last ?? 0, minSpan, 1e-9)
            for t in times {
                let x = inset + (times.count == 1 && minSpan == 0 ? 0 : CGFloat(t / span) * w)
                ctx.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                         with: .color(.accentColor))
            }
        }
        .frame(height: dot + 8)
        .accessibilityLabel("\(times.count) knocks")
    }
}

/// "●●●●●": how many knocks an offer's rhythm has.
struct KnockDots: View {
    let count: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in Circle().frame(width: 6, height: 6) }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(count) knocks")
    }
}

/// The rhythm being tapped right now, growing as it's made.
struct LiveRhythm: View {
    let input: KnockInput
    var body: some View {
        let first = input.knocks.first ?? 0
        RhythmStrip(times: input.knocks.map { $0 - first }, minSpan: 1.6)
            .opacity(input.knocks.isEmpty ? 0.25 : 1)
            .animation(.easeOut(duration: 0.12), value: input.knocks.count)
    }
}

/// The sharing side of the pad: preparing, taking the rhythm, then live.
struct SharingPanel: View {
    let sharing: Sharing
    let input: KnockInput
    var onDone: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            switch sharing.phase {
            case .none:
                EmptyView()
            case .preparing:
                ProgressView()
                Text(sharing.pattern.isEmpty ? "Getting it ready…" : "Opening your share…")
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            case .needRhythm:
                VStack(spacing: 6) {
                    Text("Tap a secret rhythm").font(.title2.bold())
                    Text("Sharing \(sharing.draft?.label ?? "")")
                        .foregroundStyle(.secondary)
                    Text(input.feelKnocks ? "Anywhere here, or knock on the table. 3 to 16 knocks."
                                          : "Anywhere here. 3 to 16 taps.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)   // taps fall through to the pad
                LiveRhythm(input: input).padding(.horizontal, 24).allowsHitTesting(false)
                Button("Cancel", role: .cancel) { sharing.stop(); onDone?() }
                    .buttonStyle(.bordered)
            case .live:
                VStack(spacing: 6) {
                    Text("Sharing \(sharing.draft?.label ?? "")").font(.headline)
                    Text("Anyone on this Wi-Fi who knocks this rhythm gets it")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)
                RhythmStrip(times: sharing.pattern, dot: 18).padding(.horizontal, 24).allowsHitTesting(false)
                HStack(spacing: 6) {
                    if let expires = sharing.expires {
                        Text(timerInterval: Date()...max(expires, Date()), countsDown: true)
                            .monospacedDigit()
                        Text("left")
                    }
                    if !sharing.sendingTo.isEmpty {
                        Text("· sending to \(sharing.sendingTo.last!)…")
                    } else if !sharing.sentTo.isEmpty {
                        Text("· sent to \(sharing.sentTo.count)")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
                .allowsHitTesting(false)
                Button(role: .destructive) { sharing.stop(); onDone?() } label: {
                    Text("Stop Sharing").frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(24)
    }
}
#endif
