import Foundation

/// A fixed-duration ease-out tween for a single scalar.
///
/// Unlike a spring, this arrives in a known, finite time and stops cleanly —
/// no asymptotic "crawl" at the end. That decisive finish is what reads as fluid
/// for travel (position). Springs are still the right tool for a *bounce*, where
/// the overshoot is the point; this is the right tool for "move and arrive".
struct Tween {
    private(set) var value: Double
    private var start: Double
    private var target: Double
    private var elapsed: Double
    private var duration: Double

    /// Duration is derived from distance so the orb moves at a roughly constant
    /// speed — a short hop and a long sweep feel like the same gesture, instead
    /// of the long one looking twice as fast under a fixed duration.
    var pointsPerSecond: Double = 480
    var minDuration: Double = 0.34
    var maxDuration: Double = 0.75

    init(_ value: Double) {
        self.value = value
        self.start = value
        self.target = value
        self.duration = 0.001
        self.elapsed = 0.001   // begin already settled
    }

    /// Aim at a new target, easing from wherever we are now. A repeat of the
    /// current target is a no-op, so calling this every frame is free.
    mutating func retarget(_ newTarget: Double) {
        guard newTarget != target else { return }
        start = value
        target = newTarget
        elapsed = 0
        let distance = abs(newTarget - start)
        duration = min(max(distance / pointsPerSecond, minDuration), maxDuration)
    }

    mutating func step(dt: Double) {
        guard elapsed < duration else { value = target; return }
        elapsed += dt
        let t = min(elapsed / duration, 1)
        // Smootherstep — an ease-in-out with zero velocity *and* acceleration at
        // both ends. It leaves rest gently (no fast jerk at the start) and lands
        // just as gently (no abrupt stop that reads as a bounce).
        let eased = t * t * t * (t * (t * 6 - 15) + 10)
        value = start + (target - start) * eased
    }
}
