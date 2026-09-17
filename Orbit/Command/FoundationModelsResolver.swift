import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Resolves a transcript with Apple's on-device model (iOS 26 Apple Intelligence)
/// using guided generation, so the model can only ever answer in the orb's own
/// vocabulary.
///
/// This is the "modern route" the brief mentions — but it runs only on eligible
/// hardware (iPhone 15 Pro and later). On everything else, including the target
/// iPhone 14 Pro, `isAvailable` is false and the app falls back to the heuristic
/// parser. Same protocol, different engine underneath.
@available(iOS 26.0, *)
struct FoundationModelsResolver: CommandResolver {

    #if canImport(FoundationModels)
    @Generable
    struct Draft {
        @Guide(description: "The single closest action: move, color, bounce, center, or unknown.")
        var action: String
        @Guide(description: "For move: left, right, up, or down. For color: the closest of amber, blue, green, violet, red, orange, yellow, pink, cyan, white. Otherwise empty.")
        var value: String
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why the model is (un)available — surfaced so we can tell at a glance on
    /// device whether Foundation Models is actually driving the resolver.
    static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(.deviceNotEligible):
            return "device not eligible"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence not enabled"
        case .unavailable(.modelNotReady):
            return "model not ready (downloading)"
        case .unavailable:
            return "unavailable"
        }
    }

    func resolve(_ transcript: String) async throws -> OrbCommand {
        let session = LanguageModelSession(instructions: Self.instructions)
        let draft = try await session.respond(to: transcript, generating: Draft.self).content
        return Self.normalize(action: draft.action, value: draft.value)
    }

    private static let instructions = """
    You turn a short spoken request into one command for a glowing orb on screen.
    Actions the orb can do:
    - move — value is left, right, up, or down
    - color — value is the closest of: amber, blue, green, violet, red, orange, yellow, pink, cyan, white
    - bounce
    - center — return to the middle
    Map a described colour to the closest one on the list, for example:
    grass → green, a banana → yellow, fire → red, the ocean → blue, a flamingo → pink.
    If the request is none of these actions, use action "unknown". Never invent an \
    action, and never pick a colour outside the list.
    """
    #else
    static var isAvailable: Bool { false }
    static var availabilityDescription: String { "FoundationModels framework not in SDK" }

    func resolve(_ transcript: String) async throws -> OrbCommand {
        OrbCommand(id: UUID().uuidString, action: OrbAction.unknown.rawValue, value: nil)
    }
    #endif

    /// Fold the model's answer back onto the orb's real vocabulary, reusing the
    /// exact synonym maps the heuristic uses — one definition of what the orb
    /// understands, shared by both routes.
    static func normalize(action: String, value: String) -> OrbCommand {
        let id = UUID().uuidString
        switch OrbAction(rawValue: action.lowercased()) ?? .unknown {
        case .move:
            guard let dir = Direction.detect(in: value) else { return unknown(id) }
            return OrbCommand(id: id, action: OrbAction.move.rawValue, value: dir.rawValue)
        case .color:
            guard let color = OrbColor.detect(in: value) else { return unknown(id) }
            return OrbCommand(id: id, action: OrbAction.color.rawValue, value: color.rawValue)
        case .bounce:
            return OrbCommand(id: id, action: OrbAction.bounce.rawValue, value: nil)
        case .center:
            return OrbCommand(id: id, action: OrbAction.center.rawValue, value: nil)
        case .unknown:
            return unknown(id)
        }
    }

    private static func unknown(_ id: String) -> OrbCommand {
        OrbCommand(id: id, action: OrbAction.unknown.rawValue, value: nil)
    }
}
