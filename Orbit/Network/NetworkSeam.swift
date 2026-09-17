import Foundation

/// Identifies one turn (one request/answer exchange) across the connection, so a
/// cancel can name exactly which turn it means.
struct TurnID: Hashable, Sendable {
    let raw: String
    init() { raw = UUID().uuidString }
}

/// What the server streams back to the phone over the connection, in order.
///
/// This is the wire protocol for the seam. In production these cross a live
/// connection to a server that runs the model; here `LocalStubBrain` produces
/// them locally. The ordering is the contract: `ack` first, then the resolved
/// `command`, then the reply as a run of `say` chunks, then `done` — unless the
/// turn is `cancelled`.
enum ServerEvent: Sendable {
    case ack(TurnID)                        // received; the server is working
    case command(TurnID, OrbCommand)        // the instruction the model resolved
    case say(TurnID, String)                // one chunk of the spoken reply
    case done(TurnID, CommandOutcome)       // turn finished; here's what happened
    case cancelled(TurnID)                  // the server acknowledged a cancel
}

/// The seam itself. The client talks only to this, so replacing the local stub
/// with a real network transport changes nothing above it.
///
/// - `start` opens a turn and returns the inbound event stream.
/// - `cancel` is the outbound interrupt: it tells the server to stop this turn.
///   It returns immediately (fire-and-forget, like a message on the wire); the
///   server confirms by streaming back `.cancelled`.
protocol Brain: Sendable {
    func start(turn: TurnID, transcript: String) -> AsyncStream<ServerEvent>
    func cancel(turn: TurnID)
    /// Pay any one-time model cost now (prewarm), not on the first real turn.
    func warmUp()
}

extension Brain {
    func warmUp() {}
}
