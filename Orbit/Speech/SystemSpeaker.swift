import AVFoundation

/// The orb's real voice: on-device text-to-speech via `AVSpeechSynthesizer`.
/// Nothing goes over the network. The voice is chosen once, preferring the
/// highest-quality English voice actually installed and falling back gracefully
/// when a better one isn't present.
final class SystemSpeaker: NSObject, VoiceSpeaking, AVSpeechSynthesizerDelegate {
    // Touched only from the main actor (the engine drives every call), so the
    // synthesizer's non-Sendable types are safe to hold here.
    private nonisolated(unsafe) let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private nonisolated(unsafe) var continuation: CheckedContinuation<Void, Never>?

    override init() {
        voice = SystemSpeaker.bestAvailableVoice()
        super.init()
        synth.delegate = self
    }

    /// The chosen voice's name — surfaced for the README/debugging.
    var voiceDescription: String { voice.map { "\($0.name) (\($0.language))" } ?? "system default" }

    func speak(_ line: String) async {
        guard !line.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.05

        await withCheckedContinuation { cont in
            // Defensive: never strand a previous awaiter.
            continuation?.resume()
            continuation = cont
            synth.speak(utterance)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)   // resolves via didCancel
    }

    /// Speak a silent (volume 0) utterance at launch so the synthesizer loads its
    /// audio unit *and* the session switches on the playback route now, while the
    /// orb is idle — rather than hitching the first real reply, which lands right
    /// as the first movement is still settling. A space is too short to fully
    /// spin that up, so warm with a real phrase.
    func warmUp() {
        let warm = AVSpeechUtterance(string: "warming up")
        warm.voice = voice
        warm.volume = 0
        synth.speak(warm)
    }

    // MARK: Delegate

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume()
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume()
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }

    // MARK: Voice selection

    /// Best English voice on the phone: premium > enhanced > default quality,
    /// nudging toward en-US on ties. Premium/enhanced voices only exist once the
    /// user has downloaded them, so this quietly lands on the best that's there.
    static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }

        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            let quality: Int
            switch v.quality {
            case .premium:  quality = 3
            case .enhanced: quality = 2
            default:        quality = 1
            }
            return quality * 2 + (v.language == "en-US" ? 1 : 0)
        }

        return english.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
