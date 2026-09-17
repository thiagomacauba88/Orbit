import Foundation

/// A plain, hand-written resolver: keyword matching over the transcript. No
/// model, no network — always available, fully deterministic, and the thing our
/// tests pin down. It's also the fallback when the on-device model isn't present.
///
/// It intentionally understands a small vocabulary well rather than a large one
/// vaguely. Anything outside it resolves to `.unknown`, which the engine reports
/// honestly instead of guessing.
struct HeuristicResolver: CommandResolver {

    func resolve(_ transcript: String) async throws -> OrbCommand {
        let text = transcript.lowercased()
        let id = UUID().uuidString

        // Order reflects salience: an explicit "bounce" wins over an incidental
        // direction word, a colour wins over a bare "make it", etc.
        if matches(text, ["bounce", "jump", "hop", "pulse"]) {
            return OrbCommand(id: id, action: OrbAction.bounce.rawValue, value: nil)
        }

        if let color = OrbColor.detect(in: text) {
            return OrbCommand(id: id, action: OrbAction.color.rawValue, value: color.rawValue)
        }

        if matches(text, ["center", "centre", "middle"]) {
            return OrbCommand(id: id, action: OrbAction.center.rawValue, value: nil)
        }

        if let direction = Direction.detect(in: text) {
            return OrbCommand(id: id, action: OrbAction.move.rawValue, value: direction.rawValue)
        }

        return OrbCommand(id: id, action: OrbAction.unknown.rawValue, value: nil)
    }

    // MARK: Matching

    private func matches(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
