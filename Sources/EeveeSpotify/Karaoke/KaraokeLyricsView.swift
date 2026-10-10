import SwiftUI

@available(iOS 15.0, *)
struct KaraokeLyricsView: View {
    var onDismiss: () -> Void
    @StateObject private var model: KaraokeLyricsViewModel
    private let options = UserDefaults.karaokeOptions

    init(trackId: String?, lyrics: KaraokeLyricsDto, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _model = StateObject(wrappedValue: KaraokeLyricsViewModel(trackId: trackId, lyrics: lyrics, onNoLyrics: onDismiss))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if KaraokeGlass.isEnabled {
                    KaraokeGlassBackground().ignoresSafeArea()
                } else {
                    KaraokeBackgroundView()
                }
                if let lyrics = model.lyrics {
                    KaraokeLyricsStage(lyrics: lyrics, layouts: model.layouts, options: options, size: geo.size)
                        // New lyrics (a new song, or the same song re-fetched) start from their own layout and springs.
                        .id(model.generation)
                }
                closeButton
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var closeButtonBackground: some View {
        if KaraokeGlass.isEnabled {
            KaraokeGlassCapsule()
        } else {
            Circle().fill(Color.white.opacity(0.12))
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .padding(14)
                .background(closeButtonBackground)
        }
        .padding(.top, 50)
        .padding(.trailing, 20)
    }
}

private struct KaraokeLineHeightsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Lines laid out by hand rather than in a ScrollView: each one is placed every frame from its own
/// springs (see KaraokeLyricsEngine), which is what lets them move independently.
@available(iOS 15.0, *)
private struct KaraokeLyricsStage: View {
    let lyrics: KaraokeLyricsDto
    let layouts: [KaraokeLineLayout]
    let options: KaraokeOptions
    let size: CGSize

    @StateObject private var engine: KaraokeLyricsEngine
    @State private var measuredHeights: [Int: CGFloat] = [:]

    private let horizontalPadding: CGFloat = 24

    init(lyrics: KaraokeLyricsDto, layouts: [KaraokeLineLayout], options: KaraokeOptions, size: CGSize) {
        self.lyrics = lyrics
        self.layouts = layouts
        self.options = options
        self.size = size
        _engine = StateObject(wrappedValue: KaraokeLyricsEngine(
            timings: lyrics.lines.map { KaraokeLyricsEngine.LineTiming(startMs: $0.startMs, endMs: $0.endMs) }
        ))
    }

    private var lineWidth: CGFloat { max(0, size.width - horizontalPadding * 2) }
    /// Lines wrap narrower than the column so the sung line still fits once it grows.
    private var wrapWidth: CGFloat { lineWidth / KaraokeLyricsEngine.activeScale }
    private var alignment: HorizontalAlignment { options.textAlignment.horizontalAlignment }
    private var frameAlignment: Alignment { Alignment(horizontal: alignment, vertical: .top) }
    /// Reversed direction mirrors the list vertically: the focus sits low and lines rise from above.
    private var isReversed: Bool { options.reversedDirection }
    /// The settings slider's default of 1.5 maps to AMLL's narrow-screen blur.
    private var blurScale: CGFloat { CGFloat(options.blurIntensity / 1.5 * 0.8) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            measuringPass
            // Uncapped, so ProMotion screens get even 120Hz frames rather than an uneven 60.
            TimelineView(.animation) { context in
                let tracker = KaraokePlaybackTracker.shared
                let frame = engine.frame(
                    frameTime: context.date.timeIntervalSinceReferenceDate,
                    reportedMs: tracker.currentPositionMs(),
                    isPlaying: tracker.isPlaying(),
                    containerHeight: size.height,
                    blurScale: blurScale
                )
                lines(frame: frame)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    engine.dragChanged(translation: direction * value.translation.height)
                }
                .onEnded { value in
                    engine.dragEnded(
                        translation: direction * value.translation.height,
                        predictedTranslation: direction * value.predictedEndTranslation.height
                    )
                }
        )
    }

    private var direction: CGFloat { isReversed ? -1 : 1 }

    private func placedY(_ y: CGFloat, height: CGFloat) -> CGFloat {
        isReversed ? size.height - y - height : y
    }

    private func lines(frame: KaraokeLyricsEngine.Frame) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(frame.lines.filter { layouts.indices.contains($0.index) }, id: \.index) { line in
                KaraokeLineView(
                    layout: layouts[line.index],
                    // A line at rest looks the same at any time, so give it a fixed state and let
                    // SwiftUI skip it until it wakes up.
                    state: line.activeAmount > 0.001
                        ? KaraokeLineState(currentMs: frame.currentMs, activeAmount: line.activeAmount)
                        : .resting,
                    availableWidth: wrapWidth,
                    alignment: alignment
                )
                .equatable()
                .scaleEffect(line.scale, anchor: options.textAlignment.unitPoint)
                .frame(width: lineWidth, alignment: Alignment(horizontal: alignment, vertical: .top))
                .blur(radius: line.blur)
                .offset(x: horizontalPadding, y: placedY(line.y, height: lineHeight(line.index)))
            }

            if let interlude = frame.interlude {
                KaraokeInterludeDotsView(elapsedMs: interlude.elapsedMs, durationMs: interlude.durationMs)
                    .frame(width: lineWidth, height: KaraokeLyricsEngine.interludeHeight, alignment: Alignment(horizontal: alignment, vertical: .center))
                    .offset(x: horizontalPadding, y: placedY(interlude.y, height: KaraokeLyricsEngine.interludeHeight))
            }

            if let footerY = frame.footerY {
                KaraokeCreditsFooterView(lyrics: lyrics)
                    .frame(width: size.width)
                    .blur(radius: frame.footerBlur)
                    .offset(y: placedY(footerY, height: lineHeight(KaraokeLyricsEngine.footerIndex)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func lineHeight(_ index: Int) -> CGFloat {
        measuredHeights[index] ?? 0
    }

    /// Lays every line out once, invisibly and at rest, to learn its height. Kept outside the
    /// timeline so it only reruns when the lyrics or the width change.
    private var measuringPass: some View {
        VStack(spacing: 0) {
            ForEach(Array(layouts.enumerated()), id: \.offset) { index, layout in
                KaraokeLineView(layout: layout, state: nil, availableWidth: wrapWidth, alignment: alignment)
                    .background(heightReader(index))
            }
            KaraokeCreditsFooterView(lyrics: lyrics)
                .frame(width: size.width)
                .background(heightReader(KaraokeLyricsEngine.footerIndex))
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: size.width, height: 0, alignment: .top)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onPreferenceChange(KaraokeLineHeightsKey.self) { heights in
            measuredHeights = heights
            engine.setHeights(heights)
        }
    }

    private func heightReader(_ index: Int) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: KaraokeLineHeightsKey.self, value: [index: geometry.size.height])
        }
    }
}
