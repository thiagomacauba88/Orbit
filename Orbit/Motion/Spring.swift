import Foundation

/// A tiny critically-ish damped spring integrator for a single scalar.
///
/// Damping ratio here (~0.8) is deliberately just under 1: the value overshoots
/// a hair and settles back. That small overshoot is what reads as *alive* — it
/// gives us "The Settling" (arrive, overshoot, ease home) and "The Surfacing"
/// (rise into place) from the motion lab without any keyframed animation.
struct Spring {
    var value: Double
    var velocity: Double = 0

    var stiffness: Double = 130
    var damping: Double = 18

    /// When within this distance of the target (and nearly stopped), snap home.
    /// Kills the slow asymptotic "crawl" at the end of the travel. 0 = never snap
    /// (right for tiny-range springs like scale, wrong for position).
    var restThreshold: Double = 0

    init(_ value: Double, stiffness: Double = 130, damping: Double = 18, restThreshold: Double = 0) {
        self.value = value
        self.stiffness = stiffness
        self.damping = damping
        self.restThreshold = restThreshold
    }

    mutating func step(to target: Double, dt: Double) {
        // Semi-implicit Euler — stable at the frame rates we care about.
        let force = -stiffness * (value - target) - damping * velocity
        velocity += force * dt
        value += velocity * dt

        if restThreshold > 0,
           abs(value - target) < restThreshold,
           abs(velocity) < restThreshold * 12 {
            value = target
            velocity = 0
        }
    }
}
