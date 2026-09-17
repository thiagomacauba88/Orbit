import Foundation

// The three types below are given by the brief, kept verbatim in shape. We fill
// them in with a small, explicit vocabulary rather than free-form strings so the
// engine and the tests share one source of truth for what the orb can do.

/// An instruction for the orb, produced by a `CommandResolver` from a transcript.
struct OrbCommand: Equatable {
    let id: String
    let action: String      // one of OrbAction.rawValue
    let value: String?      // e.g. a Direction or a colour name; nil when N/A
}

/// The result of trying to carry a command out. Reported honestly — an
/// unsupported request comes back as `.unsupported`, never as a fake success.
struct CommandOutcome: Equatable {
    let id: String
    let status: String      // OutcomeStatus.rawValue
    let detail: String?
}

/// Turns a spoken transcript into an `OrbCommand`. Behind this protocol sit both
/// the hand-written parser and the Foundation Models resolver — the engine
/// doesn't know or care which one answered.
protocol CommandResolver: Sendable {
    func resolve(_ transcript: String) async throws -> OrbCommand
}

// MARK: - The orb's vocabulary

/// What the orb actually knows how to do. `unknown` is a first-class result, not
/// an error: "I couldn't understand that" is a normal, honest outcome.
enum OrbAction: String {
    case move
    case color
    case bounce
    case center
    case unknown
}

enum Direction: String, CaseIterable {
    case left, right, up, down

    /// Canonical direction mentioned in free text, if any. Shared by both
    /// resolvers so the parser and the model speak the same vocabulary.
    static func detect(in text: String) -> Direction? {
        let t = text.lowercased()
        let synonyms: [Direction: [String]] = [
            .left:  ["left"],
            .right: ["right"],
            .up:    ["up", "top", "upward", "higher"],
            .down:  ["down", "bottom", "downward", "lower"]
        ]
        return allCases.first { dir in synonyms[dir, default: [dir.rawValue]].contains { t.contains($0) } }
    }
}

/// Named colours the orb can become. Kept next to `RGB` values so both the
/// resolver (name → command) and the engine (command → colour) agree.
enum OrbColor: String, CaseIterable {
    case amber, blue, green, violet, red, orange, yellow, pink, cyan, white

    var rgb: RGB {
        switch self {
        case .amber:  return .amber
        case .blue:   return .blue
        case .green:  return .green
        case .violet: return .violet
        case .red:    return RGB(r: 0.92, g: 0.32, b: 0.34)
        case .orange: return RGB(r: 0.98, g: 0.55, b: 0.25)
        case .yellow: return RGB(r: 0.98, g: 0.84, b: 0.35)
        case .pink:   return RGB(r: 0.96, g: 0.45, b: 0.72)
        case .cyan:   return RGB(r: 0.35, g: 0.80, b: 0.90)
        case .white:  return RGB(r: 0.92, g: 0.92, b: 0.96)
        }
    }

    /// Canonical colour mentioned in free text, mapping common synonyms onto the
    /// palette (e.g. "purple" → violet, "gold" → amber). Returns nil if no known
    /// colour is present — the caller reports that honestly rather than guessing.
    static func detect(in text: String) -> OrbColor? {
        let t = text.lowercased()
        let synonyms: [OrbColor: [String]] = [
            .amber:  ["amber", "gold", "golden"],
            .blue:   ["blue", "navy", "sky"],
            .green:  ["green", "lime", "emerald"],
            .violet: ["violet", "purple", "indigo", "lilac"],
            .red:    ["red", "crimson", "scarlet", "maroon"],
            .orange: ["orange", "tangerine"],
            .yellow: ["yellow"],
            .pink:   ["pink", "magenta", "rose"],
            .cyan:   ["cyan", "teal", "turquoise", "aqua"],
            .white:  ["white", "silver", "grey", "gray"]
        ]
        // First colour, in enum order, that has any of its synonyms in the text.
        return allCases.first { color in
            synonyms[color, default: [color.rawValue]].contains { t.contains($0) }
        }
    }
}

enum OutcomeStatus: String {
    case done          // carried out
    case unsupported   // understood the words, but not something the orb can do
    case unheard       // nothing intelligible to act on
    case interrupted   // stopped cleanly before finishing
}

extension OrbCommand {
    var typedAction: OrbAction { OrbAction(rawValue: action) ?? .unknown }
}
