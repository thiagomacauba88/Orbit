import Foundation

/// The single lifecycle the orb moves through. Every transition in the app
/// funnels through `OrbEngine.enter(_:)` so interruption/cancellation lives in
/// exactly one place — the orb can never be left stuck between states.
enum OrbState: String, Equatable, CaseIterable {
    case idle       // Waiting. Still alive, but at rest.
    case listening  // Someone is speaking; the orb reacts to real sound.
    case thinking   // Working out what was asked for.
    case acting     // Carrying the instruction out.
    case speaking   // Saying something back, out loud.
}
