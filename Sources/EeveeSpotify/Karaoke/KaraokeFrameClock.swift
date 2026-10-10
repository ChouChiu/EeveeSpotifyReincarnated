import QuartzCore
import SwiftUI

/// Ticks once per display refresh at the screen's full rate. TimelineView(.animation) leaves the
/// rate to the system, which on ProMotion screens drops and varies it, so slow motion like the
/// syllable lift visibly stutters. A display link can ask for 120Hz outright, and its target
/// timestamp is when the frame will actually be shown.
final class KaraokeFrameClock: ObservableObject {
    @Published private(set) var frameTime: CFTimeInterval = CACurrentMediaTime()

    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
        // Common modes keep it ticking while the user drags the lyrics.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    deinit {
        link?.invalidate()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        frameTime = link.targetTimestamp
    }

    /// The display link retains its target; this keeps it from retaining the clock.
    private final class WeakTarget: NSObject {
        weak var clock: KaraokeFrameClock?

        init(_ clock: KaraokeFrameClock) {
            self.clock = clock
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let clock else {
                link.invalidate()
                return
            }
            clock.tick(link)
        }
    }
}

/// Rebuilds `content` on every tick of `clock`, keeping the per-frame work out of its parent.
struct KaraokeFrameDriven<Content: View>: View {
    @ObservedObject var clock: KaraokeFrameClock
    @ViewBuilder let content: (CFTimeInterval) -> Content

    var body: some View {
        content(clock.frameTime)
    }
}
