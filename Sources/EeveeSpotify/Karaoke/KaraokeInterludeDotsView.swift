import SwiftUI

/// Three dots that fill in one after another across an instrumental gap, breathing while they
/// wait, then swell and vanish just before the next line, after AMLL's interlude dots
/// (packages/core/src/lyric-player/base/interlude-dots.ts).
@available(iOS 15.0, *)
struct KaraokeInterludeDotsView: View {
    let elapsedMs: Int
    let durationMs: Int

    private static let dotSize: CGFloat = 12
    private static let enterMs = 250.0
    private static let exitMs = 750.0
    private static let breathePeriodMs = 4000.0

    var body: some View {
        let elapsed = Double(elapsedMs)
        let remaining = Double(durationMs - elapsedMs)
        // Dots finish filling as the exit starts.
        let fill = min(1, max(0, elapsed / max(1, Double(durationMs) - Self.exitMs)))
        let breathe = 1 + 0.08 * (0.5 - 0.5 * cos(2 * .pi * elapsed / Self.breathePeriodMs))

        var exitScale = 1.0
        var opacity = min(1, max(0, elapsed / Self.enterMs))
        if remaining < Self.exitMs {
            let k = 1 - max(0, remaining) / Self.exitMs
            exitScale = k < 0.6 ? 1 + 0.15 * (k / 0.6) : 1.15 * (1 - (k - 0.6) / 0.4)
            opacity *= min(1, max(0, remaining) / 250)
        }

        return HStack(spacing: Self.dotSize * 0.75) {
            ForEach(0..<3, id: \.self) { index in
                let lit = min(1, max(0, fill * 3 - Double(index)))
                Circle()
                    .fill(Color.white.opacity(0.25 + 0.75 * lit))
                    .frame(width: Self.dotSize, height: Self.dotSize)
            }
        }
        .scaleEffect(breathe * exitScale, anchor: .center)
        .opacity(opacity)
    }
}
