import Testing
@testable import Orbit

/// The resolver is the one piece where a careless edit quietly breaks the whole
/// experience: change a keyword or a synonym map and commands silently stop
/// working, with no compile error to catch it. These tests pin the vocabulary
/// and the fallback contract — the things that can "genuinely break".
struct HeuristicResolverTests {
    let resolver = HeuristicResolver()

    @Test("Each direction resolves to a move command")
    func directions() async throws {
        let cases: [(String, String)] = [
            ("move to the left", "left"),
            ("please go right", "right"),
            ("take it to the top", "up"),
            ("send it to the bottom", "down"),
        ]
        for (phrase, expected) in cases {
            let command = try await resolver.resolve(phrase)
            #expect(command.typedAction == .move)
            #expect(command.value == expected)
        }
    }

    @Test("Colour synonyms fold onto the palette")
    func colourSynonyms() async throws {
        let cases: [(String, String)] = [
            ("turn blue", "blue"),
            ("make it purple", "violet"),   // synonym → violet
            ("go gold", "amber"),           // synonym → amber
            ("turn it crimson", "red"),     // synonym → red
        ]
        for (phrase, expected) in cases {
            let command = try await resolver.resolve(phrase)
            #expect(command.typedAction == .color)
            #expect(command.value == expected)
        }
    }

    @Test("Bounce and centre are recognised")
    func bounceAndCentre() async throws {
        #expect(try await resolver.resolve("give me a bounce").typedAction == .bounce)
        #expect(try await resolver.resolve("come back to the middle").typedAction == .center)
    }

    @Test("An unrelated sentence resolves to unknown, not a wrong guess")
    func unknownIsHonest() async throws {
        let command = try await resolver.resolve("tell me a joke about cats")
        #expect(command.typedAction == .unknown)
        #expect(command.value == nil)
    }
}

struct FallbackResolverTests {
    /// Stand-in for a primary resolver (e.g. the on-device model) that returns a
    /// fixed answer, so we can test the fallback wiring without any hardware.
    struct StubResolver: CommandResolver {
        let command: OrbCommand
        func resolve(_ transcript: String) async throws -> OrbCommand { command }
    }

    @Test("Falls back to the parser when the primary can't understand")
    func fallsBackOnUnknown() async throws {
        let primary = StubResolver(command: OrbCommand(id: "x", action: "unknown", value: nil))
        let resolver = FallbackResolver(primary: primary, fallback: HeuristicResolver())

        let command = try await resolver.resolve("turn blue")
        #expect(command.typedAction == .color)
        #expect(command.value == "blue")
    }

    @Test("Keeps the primary's answer when it understood the request")
    func keepsPrimaryWhenKnown() async throws {
        let primary = StubResolver(command: OrbCommand(id: "x", action: "bounce", value: nil))
        let resolver = FallbackResolver(primary: primary, fallback: HeuristicResolver())

        let command = try await resolver.resolve("anything at all")
        #expect(command.typedAction == .bounce)
    }
}
