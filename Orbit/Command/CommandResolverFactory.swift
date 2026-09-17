import Foundation

/// Tries the primary resolver, and falls back on the secondary when the primary
/// throws or can't make sense of the request. This is what lets the on-device
/// model lead while the deterministic parser quietly backs it up.
struct FallbackResolver: CommandResolver {
    let primary: CommandResolver
    let fallback: CommandResolver
    /// How long the primary (model) may take before we give up and let the parser
    /// answer. This is the latency guard: the Thinking state can never hang on a
    /// slow model — worst case it costs this long, then a deterministic answer.
    var primaryTimeout: Duration = .seconds(3)

    func resolve(_ transcript: String) async throws -> OrbCommand {
        do {
            let command = try await withTimeout(primaryTimeout) {
                try await primary.resolve(transcript)
            }
            if command.typedAction == .unknown {
                return try await fallback.resolve(transcript)
            }
            return command
        } catch {
            // Timed out, threw, or was unavailable — the parser answers instead.
            return try await fallback.resolve(transcript)
        }
    }
}

private struct ResolveTimedOut: Error {}

/// Run `operation`, but give up after `timeout`. Used to cap model latency.
private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ResolveTimedOut()
        }
        guard let result = try await group.next() else { throw ResolveTimedOut() }
        group.cancelAll()
        return result
    }
}

/// Chooses the resolver at runtime: the on-device model when the hardware
/// supports it, the heuristic parser otherwise. The choice is made once, here,
/// so the rest of the app never branches on it.
enum CommandResolverFactory {
    static func make() -> CommandResolver {
        // Apple-Intelligence hardware: use Foundation Models, parser as last resort.
        if #available(iOS 26.0, *), FoundationModelsResolver.isAvailable {
            return FallbackResolver(primary: FoundationModelsResolver(),
                                    fallback: HeuristicResolver())
        }
        // No Apple model on this chip (e.g. the A16 in the 14 Pro): run a small
        // local model with MLX so a real model still drives commands. The parser
        // covers cold-start and any failure.
        if MLXResolver.isAvailable {
            // A small local model on the A16 can be slow on its first inference
            // (Metal kernels compile), so give it more room before the parser
            // takes over. Once warm it answers well under this.
            return FallbackResolver(primary: MLXResolver(),
                                    fallback: HeuristicResolver(),
                                    primaryTimeout: .seconds(8))
        }
        return HeuristicResolver()
    }

    /// Human-readable note on which route is live — surfaced in the launch log and
    /// handy to confirm at a glance which resolver a given device is using.
    static var activeRouteDescription: String {
        if #available(iOS 26.0, *), FoundationModelsResolver.isAvailable {
            return "model: Foundation Models"
        }
        if MLXResolver.isAvailable {
            return "model: MLX local (\(MLXResolver.modelId))"
        }
        return "model: parser only"
    }
}
