import Foundation
import os
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

private let mlxLog = Logger(subsystem: "com.thiago.Orbit", category: "mlx")

/// Resolves commands with a small local LLM (MLX). This is what lets a real model
/// run on *any* recent iPhone, including the A16 (14 Pro), where Apple's Foundation
/// Models is not available. It sits behind `CommandResolver`, so the rest of the
/// app doesn't know which model answered.
///
/// The model (Qwen2.5-0.5B-Instruct, 4-bit, ~300 MB) downloads once on first use
/// and then runs fully on-device. Loading is kept in a stored task so a resolve
/// timeout cancels only the wait, not the download, and the next command finds the
/// model ready.
actor MLXResolver: CommandResolver {
    static let modelId = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    #if canImport(MLXLLM)
    static let isAvailable = true

    private var readyContainer: ModelContainer?
    private var isLoading = false

    /// Kick off the one-time load in the background. `resolve` never waits on it,
    /// so while the model is still loading the parser answers right away instead
    /// of the command hanging for the whole timeout.
    private func startLoadingIfNeeded() {
        guard readyContainer == nil, !isLoading else { return }
        isLoading = true
        Task {
            await ModelLoadIndicator.shared.begin()
            do {
                let configuration = ModelConfiguration(id: Self.modelId)
                mlxLog.info("loading \(Self.modelId, privacy: .public) …")
                let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { progress in
                    let fraction = progress.fractionCompleted
                    mlxLog.info("model download \(Int(fraction * 100), privacy: .public)%")
                    Task { @MainActor in ModelLoadIndicator.shared.update(fraction) }
                }
                mlxLog.info("model ready")
                self.readyContainer = container
            } catch {
                mlxLog.error("model load failed: \(error.localizedDescription, privacy: .public)")
            }
            self.isLoading = false
            await ModelLoadIndicator.shared.finish()
        }
    }

    func resolve(_ transcript: String) async throws -> OrbCommand {
        startLoadingIfNeeded()
        guard let container = readyContainer else {
            throw MLXResolverError.notReady   // still loading → the parser answers now
        }

        var parameters = GenerateParameters()
        parameters.maxTokens = 48
        let session = ChatSession(
            container, instructions: Self.instructions, generateParameters: parameters)
        let raw = try await session.respond(to: transcript)
        return try Self.parse(raw)
    }

    private static let instructions = """
    You turn a short spoken request into one command for a glowing orb.
    Reply with ONLY a compact JSON object, like {"action":"color","value":"blue"}.
    action is one of: move, color, bounce, center, unknown.
    For move, value is left, right, up or down. For color, value is the closest
    common colour to what they describe. Otherwise value is "".
    Use center when they want the orb back in the middle. Use unknown when the
    request is none of these.
    """
    #else
    static let isAvailable = false

    func resolve(_ transcript: String) async throws -> OrbCommand {
        OrbCommand(id: UUID().uuidString, action: OrbAction.unknown.rawValue, value: nil)
    }
    #endif

    // MARK: Parsing

    private struct Draft: Decodable {
        let action: String?
        let value: String?
    }

    /// Read the model's JSON answer and fold it onto the orb's vocabulary (reusing
    /// the same normalisation the other resolvers use). Throws if it can't be read,
    /// which lets the fallback parser answer instead.
    static func parse(_ raw: String) throws -> OrbCommand {
        guard let object = firstJSONObject(in: raw),
              let data = object.data(using: .utf8),
              let draft = try? JSONDecoder().decode(Draft.self, from: data)
        else { throw MLXResolverError.unreadable }

        return normalize(action: (draft.action ?? "unknown"), value: draft.value ?? "")
    }

    /// Fold a free-text action/value onto the orb's real vocabulary.
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

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text[start...].firstIndex(of: "}")
        else { return nil }
        return String(text[start...end])
    }
}

enum MLXResolverError: Error { case unreadable, notReady }
