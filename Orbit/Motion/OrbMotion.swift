import QuartzCore
import os

/// The physical motion layer. Every frame it eases the *displayed* orb toward the
/// engine's *target*. Because nothing else in the app ever writes on-screen
/// position/scale/colour directly, a command like "move left" can only ever
/// travel — the physics here is the single source of how the orb moves.
///
/// It is deliberately **not** `@MainActor`. The renderer runs on its own thread
/// (so a busy main thread — audio, speech, SwiftUI — can never stall the orb),
/// and it calls `advance` there. The engine, on the main actor, only pushes
/// *inputs* (target, energy, one-shot bounce/settle), which are guarded by a
/// small lock. The physics state and `displayed` are touched only by the render
/// thread, so they need no locking.
final class OrbMotion {
    // MARK: Inputs (written on main, read on the render thread)
    private let lock = OSAllocatedUnfairLock(initialState: Inputs())
    private struct Inputs {
        var target = OrbRenderModel.idle
        var energy = 0.0
        var speaking = false
        var pendingBounce = false
    }

    func setTarget(_ target: OrbRenderModel) { lock.withLock { $0.target = target } }
    func setEnergy(_ energy: Double)         { lock.withLock { $0.energy = energy } }
    func setSpeaking(_ speaking: Bool)       { lock.withLock { $0.speaking = speaking } }
    /// A "bounce": a one-shot impulse consumed on the next frame.
    func requestBounce()                     { lock.withLock { $0.pendingBounce = true } }

    // MARK: Physics state (render thread only)
    private var offsetX = Tween(0)
    private var offsetY = Tween(0)
    private var scale   = Spring(1)
    private var color   = RGB.amber
    private var glow    = 0.32
    private var energyShown  = 0.0
    private var breathPhase  = 0.0

    /// What the renderer draws. Written and read only on the render thread.
    private(set) var displayed = OrbRenderModel.idle

    /// Advance the physics by `dt` seconds and produce a new `displayed` frame.
    /// Called by the renderer on the display clock.
    func advance(dt rawDt: Double) {
        // Clamp dt so a stalled frame (backgrounding) can't explode the spring.
        let dt = min(max(rawDt, 1.0 / 120.0), 1.0 / 30.0)

        let input = lock.withLock { state -> Inputs in
            let snapshot = state
            state.pendingBounce = false
            return snapshot
        }

        if input.pendingBounce {
            scale.velocity += 9   // impulse; the spring settles it on its own
        }

        offsetX.retarget(Double(input.target.offset.width)); offsetX.step(dt: dt)
        offsetY.retarget(Double(input.target.offset.height)); offsetY.step(dt: dt)
        scale.step(to: Double(input.target.scale), dt: dt)

        // Colour and glow ease exponentially (no overshoot — colour shouldn't
        // wobble past its target the way position pleasingly can).
        let k = 1 - exp(-6.0 * dt)
        color = RGB.lerp(color, input.target.color, k)
        glow += (input.target.glow - glow) * k

        // While speaking, drive the pulse internally (a steady talking cadence)
        // instead of from the mic, so the orb never reacts to its own voice.
        breathPhase += dt
        let targetEnergy = input.speaking
            ? 0.36 + 0.30 * (0.5 + 0.5 * sin(breathPhase * 2 * .pi * 2.6))
            : min(max(input.energy, 0), 1)
        // Ease energy rather than switching it — removes the "blink" when the
        // source flips (mic ↔ speaking pulse) between states.
        energyShown += (targetEnergy - energyShown) * (1 - exp(-11.0 * dt))
        let e = energyShown

        // Gentle breathing at rest; fades as real sound takes over.
        let breath = sin(breathPhase * 2 * .pi * 0.16) * 0.015 * (1 - e)

        displayed = OrbRenderModel(
            offset: CGSize(width: offsetX.value, height: offsetY.value),
            scale: (scale.value + breath) * (1 + e * 0.11),
            color: color,
            glow: glow,
            energy: e
        )
    }
}
