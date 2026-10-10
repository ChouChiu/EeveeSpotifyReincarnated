import Foundation
import CoreGraphics

/// Per-frame layout and motion for the custom lyrics view, modelled on AMLL's lyric player
/// (amll-dev/applemusic-like-lyrics, packages/core/src/lyric-player/base). Every line rides its
/// own springs; a focus change ripples down the list with a staggered delay; lines away from the
/// focus shrink and blur with distance; long instrumental gaps open a slot for breathing dots.
final class KaraokeLyricsEngine: ObservableObject {
    struct LineTiming {
        let startMs: Int
        let endMs: Int
    }

    struct LineFrame {
        let index: Int
        let y: CGFloat
        let scale: CGFloat
        let blur: CGFloat
        /// 0 for a resting line, 1 for one being sung; eased between the two.
        let activeAmount: Double
    }

    struct InterludeFrame {
        let y: CGFloat
        let elapsedMs: Int
        let durationMs: Int
    }

    struct Frame {
        /// Playback position to draw this frame at, smoothed (see `smoothedMs`).
        var currentMs = 0
        var lines: [LineFrame] = []
        var interlude: InterludeFrame?
        var footerY: CGFloat?
        var footerBlur: CGFloat = 0
    }

    struct Interlude: Equatable {
        /// Line the dots sit below; -1 puts them above the first line.
        let anchor: Int
        let startMs: Int
        let endMs: Int
    }

    struct Focus: Equatable {
        /// Lines being sung right now (several when they overlap).
        var highlighted: ClosedRange<Int>?
        /// First line of the focus, what AMLL calls scrollToIndex.
        var index: Int
        /// Last highlighted line, or `index` when none is.
        var latestIndex: Int
        var interlude: Interlude?
    }

    static let lineSpacing: CGFloat = 24
    static let interludeHeight: CGFloat = 44
    /// Where the focused line sits, as a fraction of the view height (AMLL's default).
    static let alignPosition: CGFloat = 0.35
    static let footerIndex = -1
    /// The line being sung grows to 1.14x and resting lines sit at 0.97x, qplayer's take on
    /// Apple Music's depth scaling; lines wrap at the narrower width so the grown line still fits.
    static let activeScale: CGFloat = 1.14
    static let restingScale: CGFloat = 0.97

    private static let minInterludeGapMs = 7000
    private static let staggerStep = 0.05
    private static let userScrollHoldSeconds = 3.0
    private static let defaultLineHeight: CGFloat = 40
    private static let maxFrameDelta = 0.1
    private static let maxBlur: CGFloat = 12

    private static let slowPosY = KaraokeSpring.Params(mass: 0.9, stiffness: 90, damping: 15)
    private static let scaleParams = KaraokeSpring.Params(mass: 2, stiffness: 100, damping: 25)
    private static let fadeParams = KaraokeSpring.Params(mass: 1, stiffness: 170, damping: 26)
    private static let momentumParams = KaraokeSpring.Params(mass: 1, stiffness: 60, damping: 16)

    private let timings: [LineTiming]
    private var heights: [Int: CGFloat] = [:]
    private var heightsVersion = 0

    private var posY: [KaraokeSpring] = []
    private var scale: [KaraokeSpring]
    private var active: [KaraokeSpring]
    private var blur: [KaraokeSpring]
    private var footerY = KaraokeSpring(0, params: slowPosY)
    private var footerBlur = KaraokeSpring(0, params: fadeParams)
    private var interludeY = KaraokeSpring(0, params: slowPosY)
    private var shownInterlude: Interlude?

    private var lastFrameTime: TimeInterval?
    private var displayMs: Double?
    private var lastLayoutKey: LayoutKey?
    private var wasScrolling = false
    private var lastBounds: ClosedRange<CGFloat> = 0...0

    private var userOffset: CGFloat = 0
    private var dragBase: CGFloat?
    private var momentum: KaraokeSpring?
    private var lastUserScroll: TimeInterval = -.infinity
    private var frozenFocal: Focal?

    private struct Focal: Equatable {
        var top: CGFloat
        var height: CGFloat
    }

    private struct LayoutKey: Equatable {
        var focus: Focus
        var heightsVersion: Int
        var containerHeight: CGFloat
        var userOffset: CGFloat
    }

    init(timings: [LineTiming]) {
        self.timings = timings
        scale = timings.map { _ in KaraokeSpring(Double(Self.restingScale * 100), params: Self.scaleParams) }
        active = timings.map { _ in KaraokeSpring(0, params: Self.fadeParams) }
        blur = timings.map { _ in KaraokeSpring(0, params: Self.fadeParams) }
    }

    // MARK: Input

    /// Measured line heights keyed by line index, plus the credits footer under `footerIndex`.
    func setHeights(_ measured: [Int: CGFloat]) {
        guard measured != heights else { return }
        heights = measured
        heightsVersion += 1
    }

    func dragChanged(translation: CGFloat) {
        if dragBase == nil {
            if frozenFocal == nil { frozenFocal = lastFocal }
            dragBase = userOffset
            momentum = nil
        }
        userOffset = clampOffset((dragBase ?? 0) + translation)
        lastUserScroll = Self.clock()
    }

    func dragEnded(translation: CGFloat, predictedTranslation: CGFloat) {
        dragBase = nil
        var spring = KaraokeSpring(Double(userOffset), params: Self.momentumParams)
        spring.setTarget(Double(clampOffset(userOffset + (predictedTranslation - translation))))
        momentum = spring
        lastUserScroll = Self.clock()
    }

    var isUserScrolling: Bool {
        dragBase != nil || momentum != nil || Self.clock() - lastUserScroll < Self.userScrollHoldSeconds
    }

    // MARK: Frame

    /// - Parameters:
    ///   - frameTime: The frame's presentation time, so motion steps evenly whenever the frame is built.
    ///   - reportedMs: The tracker's playback position estimate.
    func frame(frameTime: TimeInterval, reportedMs: Int, isPlaying: Bool, containerHeight: CGFloat, blurScale: CGFloat) -> Frame {
        guard !timings.isEmpty, !heights.isEmpty, containerHeight > 0 else { return Frame() }

        let now = Self.clock()
        let dt = min(Self.maxFrameDelta, max(0, frameTime - (lastFrameTime ?? frameTime)))
        lastFrameTime = frameTime

        let (currentMs, isSeek) = smoothedMs(reportedMs: reportedMs, isPlaying: isPlaying, dt: dt)

        stepUserScroll(dt: dt, now: now)
        let scrolling = isUserScrolling

        let focus = Self.resolveFocus(timings, at: currentMs)
        let layout = computeLayout(focus: focus, containerHeight: containerHeight)
        lastBounds = layout.bounds

        let isFirstLayout = posY.isEmpty
        if isFirstLayout {
            // Lines float up into place on open, like AMLL's rebuild.
            posY = layout.lineY.map { KaraokeSpring(Double($0 + containerHeight * 0.3), params: Self.slowPosY) }
            footerY.snap(to: Double(layout.footerY + containerHeight * 0.3))
        }

        let key = LayoutKey(focus: focus, heightsVersion: heightsVersion, containerHeight: containerHeight, userOffset: userOffset)
        if scrolling && !isFirstLayout {
            for i in timings.indices { posY[i].snap(to: Double(layout.lineY[i])) }
            footerY.snap(to: Double(layout.footerY))
        } else if key != lastLayoutKey {
            let focusMoved = lastLayoutKey.map { $0.focus != focus } ?? false
            // Returning from a user scroll ripples back the same way a new line does.
            let stagger = (focusMoved || wasScrolling) && !isSeek
            let params = Self.posYParams(focus: focus, timings: timings, isSeek: isSeek || isFirstLayout)
            applyTargets(layout: layout, focus: focus, params: params, stagger: stagger)
        }
        lastLayoutKey = key
        wasScrolling = scrolling

        updateInterlude(focus.interlude, y: layout.interludeY)

        for i in timings.indices {
            let isHighlighted = focus.highlighted?.contains(i) ?? false
            scale[i].setTarget(Double((isHighlighted ? Self.activeScale : Self.restingScale) * 100))
            active[i].setTarget(isHighlighted ? 1 : 0)
            blur[i].setTarget(scrolling ? 0 : Double(Self.blurLevel(index: i, focus: focus, isFocused: isHighlighted) * blurScale))

            posY[i].step(dt)
            scale[i].step(dt)
            active[i].step(dt)
            blur[i].step(dt)
        }
        footerBlur.setTarget(scrolling ? 0 : Double(Self.blurLevel(index: timings.count, focus: focus, isFocused: false) * blurScale))
        footerY.step(dt)
        footerBlur.step(dt)
        interludeY.step(dt)

        var frame = Frame()
        frame.currentMs = currentMs
        let overscan = containerHeight * 0.4
        for i in timings.indices {
            let y = CGFloat(posY[i].position)
            guard y + height(i) >= -overscan, y <= containerHeight + overscan else { continue }
            frame.lines.append(LineFrame(
                index: i,
                y: y,
                scale: CGFloat(scale[i].position / 100),
                blur: min(Self.maxBlur, max(0, CGFloat(blur[i].position))),
                activeAmount: min(1, max(0, active[i].position))
            ))
        }

        let footer = CGFloat(footerY.position)
        if footer <= containerHeight + overscan {
            frame.footerY = footer
            frame.footerBlur = min(Self.maxBlur, max(0, CGFloat(footerBlur.position)))
        }

        if let interlude = shownInterlude {
            frame.interlude = InterludeFrame(
                y: CGFloat(interludeY.position),
                elapsedMs: currentMs - interlude.startMs,
                durationMs: interlude.endMs - interlude.startMs
            )
        }
        return frame
    }

    // MARK: Clock

    /// The tracker extrapolates between player callbacks and jumps a little whenever a new one
    /// lands, which shows up as the fill and lift twitching. Run our own clock forward at frame
    /// rate and ease it toward the reported position instead, never backward while playing;
    /// only a jump of over a second (a seek) is taken at once.
    private func smoothedMs(reportedMs: Int, isPlaying: Bool, dt: Double) -> (ms: Int, isSeek: Bool) {
        let reported = Double(reportedMs)
        guard var display = displayMs else {
            displayMs = reported
            return (reportedMs, false)
        }
        if isPlaying { display += dt * 1000 }
        let error = reported - display
        if abs(error) > 1000 {
            displayMs = reported
            return (reportedMs, true)
        }
        let corrected = display + error * min(1, dt * 4)
        display = isPlaying ? max(display - dt * 1000 * 0.5, corrected) : corrected
        displayMs = display
        return (Int(display.rounded()), false)
    }

    // MARK: Focus

    static func resolveFocus(_ timings: [LineTiming], at ms: Int) -> Focus {
        var first: Int?
        var last: Int?
        var lastStarted: Int?
        var latestEnd = 0
        for (i, line) in timings.enumerated() where line.startMs <= ms {
            lastStarted = i
            latestEnd = max(latestEnd, line.endMs)
            if ms < line.endMs {
                if first == nil { first = i }
                last = i
            }
        }

        if let first, let last {
            return Focus(highlighted: first...last, index: first, latestIndex: last, interlude: nil)
        }

        let next = (lastStarted ?? -1) + 1
        if next < timings.count {
            let nextStart = timings[next].startMs
            if nextStart - latestEnd >= minInterludeGapMs && ms >= latestEnd {
                let interlude = Interlude(anchor: lastStarted ?? -1, startMs: latestEnd, endMs: nextStart)
                return Focus(highlighted: nil, index: next, latestIndex: next, interlude: interlude)
            }
        }

        let index = lastStarted ?? 0
        return Focus(highlighted: nil, index: index, latestIndex: index, interlude: nil)
    }

    /// AMLL's distance-based depth of field: one step per line away from the focus, with lines
    /// already sung one step further back than those still to come.
    static func blurLevel(index: Int, focus: Focus, isFocused: Bool) -> CGFloat {
        guard !isFocused else { return 0 }
        let distance = index < focus.index ? focus.index - index + 1 : abs(index - focus.latestIndex)
        return CGFloat(1 + distance)
    }

    /// AMLL's getPosYSpringPolicy: slow and soft for seeks and interludes, otherwise stiffer the
    /// faster the lines come.
    static func posYParams(focus: Focus, timings: [LineTiming], isSeek: Bool) -> KaraokeSpring.Params {
        guard !isSeek, focus.interlude == nil, focus.index > 0, focus.index < timings.count else {
            return slowPosY
        }
        let interval = Double(timings[focus.index].startMs - timings[focus.index - 1].startMs)
        let clamped = min(max(interval, 100), 800)
        let ratio = pow(1 - (clamped - 100) / 700, 0.2)
        let stiffness = 170 + ratio * 50
        return KaraokeSpring.Params(mass: 0.9, stiffness: stiffness, damping: stiffness.squareRoot() * 2.2)
    }

    // MARK: Layout

    private struct Layout {
        var lineY: [CGFloat]
        var interludeY: CGFloat?
        var footerY: CGFloat
        var bounds: ClosedRange<CGFloat>
    }

    private var lastFocal: Focal?

    private func height(_ index: Int) -> CGFloat {
        heights[index] ?? Self.defaultLineHeight
    }

    private func computeLayout(focus: Focus, containerHeight: CGFloat) -> Layout {
        var tops: [CGFloat] = []
        tops.reserveCapacity(timings.count)
        var interludeTop: CGFloat?
        var y: CGFloat = 0
        for i in timings.indices {
            if let interlude = focus.interlude, interlude.anchor + 1 == i {
                interludeTop = y
                y += Self.interludeHeight
            }
            tops.append(y)
            y += height(i) + Self.lineSpacing
        }
        let footerTop = y

        let focal: Focal
        if let interludeTop {
            focal = Focal(top: interludeTop, height: Self.interludeHeight)
        } else {
            let index = min(max(focus.index, 0), timings.count - 1)
            focal = Focal(top: tops[index], height: height(index))
        }
        lastFocal = focal

        // While the user scrolls, the list stays pinned to where the focus was when they started,
        // so a new line starting doesn't yank the content out from under their finger.
        let anchor = frozenFocal ?? focal
        let base = containerHeight * Self.alignPosition - anchor.height / 2 - anchor.top + userOffset

        let lowest = -(footerTop - anchor.top)
        let highest = anchor.top
        return Layout(
            lineY: tops.map { $0 + base },
            interludeY: interludeTop.map { $0 + base },
            footerY: footerTop + base,
            bounds: min(lowest, highest)...max(lowest, highest)
        )
    }

    private func applyTargets(layout: Layout, focus: Focus, params: KaraokeSpring.Params, stagger: Bool) {
        var delay = 0.0
        var step = stagger ? Self.staggerStep : 0
        for i in timings.indices {
            let y = layout.lineY[i]
            posY[i].setTarget(Double(y), params: params, delay: delay)
            // Lines above the screen move at once; from the top edge down each waits a little
            // longer than the one before, the wave tightening below the focus.
            if y + height(i) >= 0 {
                delay += step
                if i >= focus.index { step /= 1.05 }
            }
        }
        footerY.setTarget(Double(layout.footerY), params: params, delay: delay)
    }

    private func updateInterlude(_ interlude: Interlude?, y: CGFloat?) {
        if interlude != shownInterlude, let y {
            interludeY.snap(to: Double(y))
        } else if let y {
            interludeY.setTarget(Double(y))
        }
        shownInterlude = interlude
    }

    // MARK: User scroll

    private func clampOffset(_ offset: CGFloat) -> CGFloat {
        min(max(offset, lastBounds.lowerBound), lastBounds.upperBound)
    }

    private func stepUserScroll(dt: Double, now: TimeInterval) {
        if var spring = momentum {
            spring.step(dt)
            userOffset = clampOffset(CGFloat(spring.position))
            if spring.isSettled {
                momentum = nil
            } else {
                momentum = spring
            }
            lastUserScroll = now
        }
        // Hand control back to playback: drop the offset and let the springs carry the lines home.
        if dragBase == nil, momentum == nil, now - lastUserScroll >= Self.userScrollHoldSeconds,
           userOffset != 0 || frozenFocal != nil {
            userOffset = 0
            frozenFocal = nil
        }
    }

    private static func clock() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
