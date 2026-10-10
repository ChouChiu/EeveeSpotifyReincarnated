import SwiftUI

struct KaraokeWordLayout {
    let syllables: [KaraokeSyllableDto]
    let startMs: Int
    let endMs: Int
    /// Set for long held words, which get AMLL's per-character swell instead of the plain float.
    let emphasis: KaraokeEmphasis?
}

struct KaraokeLineLayout {
    let words: [KaraokeWordLayout]
    let isRTL: Bool
    /// False for line-synced lyrics, whose words all light up together without per-word motion.
    let isDynamic: Bool

    init(line: KaraokeLineDto, isRTL: Bool) {
        self.isRTL = isRTL
        let isDynamic = line.syllables.contains { $0.endMs > $0.startMs }
        self.isDynamic = isDynamic

        let groups = line.words
        words = groups.enumerated().map { index, syllables in
            let startMs = syllables.first?.startMs ?? line.startMs
            let endMs = syllables.last?.endMs ?? startMs
            let emphasis = isDynamic
                ? KaraokeEmphasis.make(
                    text: syllables.map(\.text).joined(),
                    durationMs: endMs - startMs,
                    isLastWord: index == groups.count - 1
                )
                : nil
            return KaraokeWordLayout(syllables: syllables, startMs: startMs, endMs: endMs, emphasis: emphasis)
        }
    }
}

extension KaraokeTextAlignment {
    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var unitPoint: UnitPoint {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// Live playback state for one line.
struct KaraokeLineState: Equatable {
    let currentMs: Int
    /// 0 at rest, 1 while sung; eased by the engine.
    let activeAmount: Double

    /// A line at rest looks the same at any time, so every resting line shares this state.
    static let resting = KaraokeLineState(currentMs: 0, activeAmount: 0)
}

enum KaraokeLineStyle {
    /// The size of the line being sung; resting lines are scaled down from it (see KaraokeLyricsEngine).
    static let fontSize: CGFloat = 32
    static let font = Font.system(size: fontSize, weight: .bold)

    /// Text alpha for a line at rest, and for the sung / unsung parts of the line being sung
    /// (AMLL's bright and dark mask alphas).
    static let restingAlpha = 0.25
    static let sungAlpha = 1.0
    static let unsungAlpha = 0.4

    /// Width of the soft edge on the fill, in em.
    static let fadeWidthEm = 0.5
    /// How far a syllable rises once sung, in em.
    static let liftEm = 0.1
}

@available(iOS 15.0, *)
struct KaraokeLineView: View, Equatable {
    let layout: KaraokeLineLayout
    let state: KaraokeLineState
    let availableWidth: CGFloat
    let alignment: HorizontalAlignment

    // Layouts are fixed for the life of a lyrics stage (it rebuilds when the lyrics change),
    // so only the inputs that vary frame to frame are compared.
    static func == (lhs: KaraokeLineView, rhs: KaraokeLineView) -> Bool {
        lhs.state == rhs.state && lhs.availableWidth == rhs.availableWidth && lhs.alignment == rhs.alignment
    }

    var body: some View {
        KaraokeFlowLayout(spacing: 8, alignment: alignment) {
            ForEach(Array(layout.words.enumerated()), id: \.offset) { _, word in
                if let emphasis = word.emphasis {
                    KaraokeEmphasizedWordView(word: word, emphasis: emphasis, state: state, isRTL: layout.isRTL)
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(word.syllables.enumerated()), id: \.offset) { _, syllable in
                            KaraokeSyllableTextView(syllable: syllable, state: state, isDynamic: layout.isDynamic, isRTL: layout.isRTL)
                        }
                    }
                }
            }
        }
        .frame(width: availableWidth)
        // Mirrors word/row order for RTL lines; the fill gradient is flipped separately below.
        .environment(\.layoutDirection, layout.isRTL ? .rightToLeft : .leftToRight)
    }
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

private func clamp01(_ value: Double) -> Double {
    min(1, max(0, value))
}

/// Fill progress of a span, 0 before it starts and 1 once it ends.
private func fillProgress(startMs: Int, endMs: Int, currentMs: Int) -> Double {
    guard endMs > startMs else { return currentMs >= startMs ? 1 : 0 }
    return clamp01(Double(currentMs - startMs) / Double(endMs - startMs))
}

/// Gradient stops for a fill sweeping across a span: sung alpha behind the edge, unsung ahead of
/// it, with a soft edge `fade` wide (a fraction of the span). The edge enters fully off the
/// leading side at 0 and leaves fully off the trailing side at 1, as AMLL's mask does.
private func fillStops(progress: Double, fade: Double, active: Double) -> [Gradient.Stop] {
    let bright = lerp(KaraokeLineStyle.restingAlpha, KaraokeLineStyle.sungAlpha, active)
    let dark = lerp(KaraokeLineStyle.restingAlpha, KaraokeLineStyle.unsungAlpha, active)
    let edge = progress * (1 + fade)
    let start = clamp01(edge - fade)
    let end = max(start, clamp01(edge))
    return [
        .init(color: .white.opacity(bright), location: 0),
        .init(color: .white.opacity(bright), location: start),
        .init(color: .white.opacity(dark), location: end),
        .init(color: .white.opacity(dark), location: 1),
    ]
}

@available(iOS 15.0, *)
private struct KaraokeSyllableTextView: View {
    let syllable: KaraokeSyllableDto
    let state: KaraokeLineState
    let isDynamic: Bool
    let isRTL: Bool

    /// Each syllable eases up from its start and stays raised while the line is active, so the
    /// sung part of the line sits visibly above what's still to come.
    private var lift: CGFloat {
        guard isDynamic else { return 0 }
        let rise = KaraokeLift.value(
            elapsedMs: Double(state.currentMs - syllable.startMs),
            durationMs: Double(syllable.endMs - syllable.startMs)
        )
        return -CGFloat(rise * KaraokeLineStyle.liftEm * state.activeAmount) * KaraokeLineStyle.fontSize
    }

    // LinearGradient never mirrors .leading/.trailing for RTL, so pick the physical edges here.
    private var gradientStart: UnitPoint { isRTL ? .trailing : .leading }
    private var gradientEnd: UnitPoint { isRTL ? .leading : .trailing }

    var body: some View {
        let progress = fillProgress(startMs: syllable.startMs, endMs: syllable.endMs, currentMs: state.currentMs)
        let fade = min(1, max(0.08, KaraokeLineStyle.fadeWidthEm / max(0.5, syllable.text.estimatedWidthEm)))

        Text(syllable.text)
            .font(KaraokeLineStyle.font)
            .foregroundStyle(
                LinearGradient(
                    stops: fillStops(progress: progress, fade: fade, active: state.activeAmount),
                    startPoint: gradientStart,
                    endPoint: gradientEnd
                )
            )
            .offset(y: lift)
    }
}

/// A long held word: characters swell and glow one after another while a soft fill sweeps the
/// whole word. The fill is a mask over the word so it stays continuous across the characters.
@available(iOS 15.0, *)
private struct KaraokeEmphasizedWordView: View {
    let word: KaraokeWordLayout
    let emphasis: KaraokeEmphasis
    let state: KaraokeLineState
    let isRTL: Bool

    /// Room around the word so the mask doesn't clip swollen characters or their glow.
    private let maskBleed: CGFloat = 20

    /// Word fill progress, weighting each syllable by its share of the characters.
    private var progress: Double {
        let total = word.syllables.reduce(0) { $0 + $1.text.count }
        guard total > 0 else { return fillProgress(startMs: word.startMs, endMs: word.endMs, currentMs: state.currentMs) }
        return word.syllables.reduce(0) { sum, syllable in
            sum + Double(syllable.text.count) / Double(total)
                * fillProgress(startMs: syllable.startMs, endMs: syllable.endMs, currentMs: state.currentMs)
        }
    }

    var body: some View {
        let elapsed = Double(state.currentMs - word.startMs)
        let active = state.activeAmount
        let em = Double(KaraokeLineStyle.fontSize)
        // The same lift as plain syllables, with the swell riding on top of it.
        let lift = KaraokeLift.value(elapsedMs: elapsed, durationMs: Double(word.endMs - word.startMs))
            * KaraokeLineStyle.liftEm

        HStack(spacing: 0) {
            ForEach(Array(emphasis.characters.enumerated()), id: \.offset) { index, character in
                let motion = emphasis.state(forCharacter: index, elapsedMs: elapsed)
                Text(character)
                    .font(KaraokeLineStyle.font)
                    .foregroundColor(.white)
                    .scaleEffect(1 + (motion.scale - 1) * active)
                    .offset(
                        x: CGFloat(motion.offsetX * em * active) * (isRTL ? -1 : 1),
                        y: CGFloat((motion.offsetY - lift) * em * active)
                    )
                    .shadow(
                        color: .white.opacity(motion.glowAlpha * active),
                        radius: CGFloat(motion.glowRadius * em)
                    )
            }
        }
        .mask(fillMask)
    }

    private var fillMask: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let total = width + maskBleed * 2
            // Express the sweep across the word in the coordinates of the wider mask.
            let fade = Double(KaraokeLineStyle.fadeWidthEm * KaraokeLineStyle.fontSize / width)
            // Colours past the first and last stop extend to the mask's edges by themselves.
            let stops = fillStops(progress: progress, fade: fade, active: state.activeAmount).map { stop in
                Gradient.Stop(color: stop.color, location: (maskBleed + stop.location * width) / total)
            }
            LinearGradient(
                stops: stops,
                startPoint: isRTL ? .trailing : .leading,
                endPoint: isRTL ? .leading : .trailing
            )
            .frame(width: total, height: geometry.size.height + maskBleed * 2)
            .offset(x: -maskBleed, y: -maskBleed)
        }
    }
}
