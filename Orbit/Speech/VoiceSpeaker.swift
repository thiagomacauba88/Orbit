import Foundation

/// The orb's voice. Kept behind a protocol so Part 03's flow doesn't depend on
/// how speech is produced — Part 02 drops in the real `AVSpeechSynthesizer`
/// implementation without the engine changing.
protocol VoiceSpeaking: AnyObject {
    /// Speak a line, returning when it has finished (or been stopped).
    func speak(_ line: String) async
    /// Stop mid-sentence, cleanly (used on interrupt).
    func stop()
    /// Pay any one-time initialisation cost now, not during the first command.
    func warmUp()
}

extension VoiceSpeaking {
    func warmUp() {}   // no-op by default
}

/// Placeholder used until Part 02. It "speaks" by waiting a plausible amount of
/// time so the Speaking state, and interrupting out of it, both work end-to-end.
final class SilentSpeaker: VoiceSpeaking {
    private var current: Task<Void, Never>?

    func speak(_ line: String) async {
        let seconds = min(2.4, 0.5 + Double(line.count) * 0.045)
        try? await Task.sleep(for: .seconds(seconds))
    }

    func stop() {
        current?.cancel()
        current = nil
    }
}
