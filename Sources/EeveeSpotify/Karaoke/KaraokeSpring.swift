import Foundation

/// Closed-form damped spring, ported from AMLL's `Spring` (amll-dev/applemusic-like-lyrics,
/// packages/core/src/utils/spring.ts, itself based on pushkine's solver). Retargeting starts a new
/// solve from the current position and velocity, so a line that is still moving bends toward its
/// new target instead of restarting from rest.
struct KaraokeSpring {
    struct Params: Equatable {
        var mass: Double = 1
        var stiffness: Double = 100
        var damping: Double = 10
    }

    private struct Pending {
        var target: Double
        var params: Params
        var remaining: Double
    }

    private(set) var target: Double
    private(set) var position: Double
    private(set) var velocity: Double = 0
    private var params: Params
    private var origin: Double
    private var originVelocity: Double = 0
    private var elapsed: Double = 0
    private var pending: Pending?

    init(_ value: Double, params: Params = Params()) {
        target = value
        position = value
        origin = value
        self.params = params
    }

    /// The value the spring will come to rest at, counting a target still waiting on its delay.
    var finalTarget: Double { pending?.target ?? target }

    var isSettled: Bool {
        pending == nil && abs(target - position) < 0.01 && abs(velocity) < 0.01
    }

    mutating func snap(to value: Double) {
        target = value
        position = value
        velocity = 0
        origin = value
        originVelocity = 0
        elapsed = 0
        pending = nil
    }

    /// Moves toward `value`, optionally after `delay` seconds. Asking for the target the spring is
    /// already heading to is a no-op, so callers can repeat it every frame without resetting a delay.
    mutating func setTarget(_ value: Double, params newParams: Params? = nil, delay: Double = 0) {
        let resolvedParams = newParams ?? pending?.params ?? params
        if value == finalTarget && resolvedParams == (pending?.params ?? params) {
            return
        }
        if delay > 0 {
            pending = Pending(target: value, params: resolvedParams, remaining: delay)
            return
        }
        pending = nil
        restart(target: value, params: resolvedParams)
    }

    mutating func step(_ dt: Double) {
        if var queued = pending {
            queued.remaining -= dt
            if queued.remaining <= 0 {
                pending = nil
                restart(target: queued.target, params: queued.params)
            } else {
                pending = queued
            }
        }
        guard !(position == target && velocity == 0) else { return }
        elapsed += dt
        evaluate()
        if abs(target - position) < 0.001 && abs(velocity) < 0.001 {
            position = target
            velocity = 0
        }
    }

    private mutating func restart(target newTarget: Double, params newParams: Params) {
        origin = position
        originVelocity = velocity
        elapsed = 0
        target = newTarget
        params = newParams
    }

    /// Solves m·x'' + c·x' + k·(x - target) = 0 from (origin, originVelocity). Overdamped springs
    /// fall back to the critically damped solution, the same simplification AMLL makes.
    private mutating func evaluate() {
        let m = max(params.mass, 0.0001)
        let k = max(params.stiffness, 0.0001)
        let c = max(params.damping, 0)
        let delta = target - origin
        let t = elapsed

        let displacement: Double
        let displacementVelocity: Double
        if c / (2 * (k * m).squareRoot()) >= 1 {
            let w = (k / m).squareRoot()
            let b = w * delta - originVelocity
            let decay = exp(-w * t)
            displacement = (delta + b * t) * decay
            displacementVelocity = decay * (b - w * (delta + b * t))
        } else {
            let a = c / (2 * m)
            let wd = (4 * m * k - c * c).squareRoot() / (2 * m)
            let b = (a * delta - originVelocity) / wd
            let decay = exp(-a * t)
            let cosine = cos(wd * t)
            let sine = sin(wd * t)
            displacement = decay * (delta * cosine + b * sine)
            displacementVelocity = decay * ((wd * b - a * delta) * cosine - (a * b + wd * delta) * sine)
        }
        position = target - displacement
        velocity = -displacementVelocity
    }
}
