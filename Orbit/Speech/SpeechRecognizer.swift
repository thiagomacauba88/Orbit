import Speech

/// One incremental transcription result.
struct Transcript: Sendable {
    let text: String
    let isFinal: Bool
}

/// Abstraction over speech-to-text so the engine can be exercised without the
/// Speech framework or a microphone.
protocol SpeechRecognizing: AnyObject {
    var isAvailable: Bool { get }
    func requestAuthorization() async -> Bool
    /// Start one utterance. Yields partials, then a final, then finishes.
    func beginUtterance() -> AsyncStream<Transcript>
    /// Feed captured audio (called from the audio thread).
    func append(_ buffer: AVAudioPCMBuffer)
    /// Signal end-of-speech; the final result follows.
    func finish()
    /// Abandon the current utterance immediately (used on interrupt).
    func cancel()
}

/// On-device speech recognition. `requiresOnDeviceRecognition` is forced on so
/// nothing is ever sent over the network — a hard requirement of the brief, not
/// a nice-to-have.
final class SpeechRecognizer: SpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(locale: Locale = Locale(identifier: "en-US")) {
        // Commands are English (per the brief's examples); pin the recognizer to
        // en-US so recognition quality doesn't drift with the device language.
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    var isAvailable: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    func beginUtterance() -> AsyncStream<Transcript> {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        return AsyncStream { continuation in
            guard let recognizer, recognizer.isAvailable else {
                continuation.finish()
                return
            }
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(
                        Transcript(text: result.bestTranscription.formattedString,
                                   isFinal: result.isFinal)
                    )
                    if result.isFinal { continuation.finish() }
                }
                if error != nil { continuation.finish() }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func finish() {
        request?.endAudio()
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
    }
}
