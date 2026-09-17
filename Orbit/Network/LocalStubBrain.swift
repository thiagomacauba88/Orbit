import Foundation
import os

private let seamLog = Logger(subsystem: "com.thiago.Orbit", category: "seam")

/// Stands in for the server across the seam. It runs the on-device resolver and
/// streams the answer back with a little artificial latency, exactly as a real
/// server would over a connection — including stopping cleanly, and confirming,
/// when the phone cancels mid-answer.
///
/// It's an `actor`: the streaming task suspends at each `await` (the simulated
/// network/compute delays), which is precisely when a `cancel` from another task
/// can interleave and take effect.
actor LocalStubBrain: Brain {
    private let resolver: CommandResolver
    private var continuations: [TurnID: AsyncStream<ServerEvent>.Continuation] = [:]
    private var cancelled: Set<TurnID> = []

    init(resolver: CommandResolver) {
        self.resolver = resolver
    }

    nonisolated func start(turn: TurnID, transcript: String) -> AsyncStream<ServerEvent> {
        AsyncStream { continuation in
            Task { await self.run(turn: turn, transcript: transcript, continuation: continuation) }
        }
    }

    nonisolated func cancel(turn: TurnID) {
        Task { await self.acknowledgeCancel(turn) }
    }

    nonisolated func warmUp() {
        Task { await self.prewarm() }
    }

    // MARK: Server side

    private func run(turn: TurnID,
                     transcript: String,
                     continuation: AsyncStream<ServerEvent>.Continuation) async {
        continuations[turn] = continuation
        let tag = turn.raw.prefix(6)
        seamLog.info("→ start \(tag, privacy: .public) \"\(transcript, privacy: .public)\"")

        // Round-trip + the server accepting the turn.
        try? await Task.sleep(for: .milliseconds(120))
        guard alive(turn) else { return cleanup(turn) }
        continuation.yield(.ack(turn))

        // The model resolves the sentence into an instruction.
        let command = (try? await resolver.resolve(transcript))
            ?? OrbCommand(id: UUID().uuidString, action: OrbAction.unknown.rawValue, value: nil)
        guard alive(turn) else { return cleanup(turn) }
        seamLog.info("← command \(tag, privacy: .public) \(command.action, privacy: .public) \(command.value ?? "-", privacy: .public)")
        continuation.yield(.command(turn, command))

        // The reply streams back token by token, the way a server would.
        let (line, outcome) = Self.reply(for: command)
        for chunk in Self.chunks(of: line) {
            try? await Task.sleep(for: .milliseconds(95))
            guard alive(turn) else { return cleanup(turn) }
            continuation.yield(.say(turn, chunk))
        }

        guard alive(turn) else { return cleanup(turn) }
        seamLog.info("← done \(tag, privacy: .public)")
        continuation.yield(.done(turn, outcome))
        cleanup(turn)
    }

    private func acknowledgeCancel(_ turn: TurnID) {
        guard let continuation = continuations[turn] else { return }
        cancelled.insert(turn)
        seamLog.info("← cancelled \(turn.raw.prefix(6), privacy: .public) (server stopped the turn)")
        continuation.yield(.cancelled(turn))   // the server owes the phone this ack
        continuation.finish()
        continuations[turn] = nil
    }

    private func prewarm() async {
        _ = try? await resolver.resolve("hello")
    }

    private func alive(_ turn: TurnID) -> Bool {
        continuations[turn] != nil && !cancelled.contains(turn)
    }

    private func cleanup(_ turn: TurnID) {
        continuations[turn]?.finish()
        continuations[turn] = nil
        cancelled.remove(turn)
    }

    // MARK: Answer generation (the server's job, not the phone's)

    /// The spoken reply and a structured outcome for a resolved command.
    static func reply(for command: OrbCommand) -> (line: String, outcome: CommandOutcome) {
        let id = command.id
        func done(_ detail: String) -> CommandOutcome {
            CommandOutcome(id: id, status: OutcomeStatus.done.rawValue, detail: detail)
        }
        let unsupported = CommandOutcome(id: id, status: OutcomeStatus.unsupported.rawValue, detail: nil)

        switch command.typedAction {
        case .move:
            guard let dir = command.value.flatMap(Direction.init) else {
                return ("I can't do that one.", unsupported)
            }
            return ("Sliding \(dir.rawValue).", done("move \(dir.rawValue)"))
        case .center:
            return ("Back to the middle.", done("centred"))
        case .color:
            guard let color = command.value.flatMap(OrbColor.init) else {
                return ("I can't do that one.", unsupported)
            }
            return ("Turning \(color.rawValue).", done("colour \(color.rawValue)"))
        case .bounce:
            return ("Here's a bounce.", done("bounced"))
        case .unknown:
            return ("I can't do that one.", unsupported)
        }
    }

    /// Split a line into word-sized chunks (keeping the spaces) to stream it.
    static func chunks(of line: String) -> [String] {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        return words.enumerated().map { index, word in
            index == words.count - 1 ? String(word) : "\(word) "
        }
    }
}
