import CoreGraphics

/// An interpolatable RGB colour. We keep colour as raw components (not SwiftUI
/// `Color`) precisely so the motion layer can travel *through* colour space —
/// "turn blue" should glide, never cut.
struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t)
    }

    // Palette. Warm amber at rest; the rest arrive with spoken commands.
    static let amber  = RGB(r: 0.90, g: 0.58, b: 0.36)
    static let ember  = RGB(r: 0.98, g: 0.68, b: 0.42)
    static let blue   = RGB(r: 0.30, g: 0.55, b: 0.95)
    static let violet = RGB(r: 0.58, g: 0.42, b: 0.95)
    static let green  = RGB(r: 0.36, g: 0.80, b: 0.52)
}

/// What the orb should look like. The engine sets these as *targets*; the view
/// never reads them directly — `OrbMotion` eases the on-screen values toward
/// them so movement is always "travel + settle", never a snap.
struct OrbRenderModel: Equatable {
    var offset: CGSize   // points from screen centre
    var scale: CGFloat   // base size multiplier
    var color: RGB       // core colour
    var glow: Double     // 0…1 base luminosity for this state
    var energy: Double   // 0…1 live audio amplitude (passed through, not sprung)

    static let idle = OrbRenderModel(
        offset: .zero, scale: 1.0, color: .amber, glow: 0.32, energy: 0
    )
}
