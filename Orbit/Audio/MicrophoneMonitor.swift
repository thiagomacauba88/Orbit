import AVFoundation
import os

let audioLog = Logger(subsystem: "com.thiago.Orbit", category: "audio")

/// Everything the mic can tell the engine, on one channel. Level ticks arrive
/// ~90×/s; interruptions are rare. Keeping them in one stream means the engine
/// has a single place to react and can't miss an interrupt mid-level-burst.
enum MicEvent: Sendable {
    case level(Double)                       // 0…1 smoothed amplitude
    case interruptionBegan                   // e.g. a phone call started
    case interruptionEnded(shouldResume: Bool)
}

/// Abstraction so `OrbEngine` depends on behaviour, not on `AVAudioEngine`.
/// A fake conforming to this drives the engine's tests without any hardware.
protocol MicrophoneMonitoring: AnyObject {
    var events: AsyncStream<MicEvent> { get }
    /// Raw PCM buffers, forwarded on the audio thread. The engine points this at
    /// the speech recognizer while listening so a single tap feeds both the
    /// amplitude (the orb's reaction) and the transcription.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var isRunning: Bool { get }
    func requestPermission() async -> Bool
    func start() throws
    func stop()
}

/// Real microphone input. Amplitude is computed from the actual PCM buffers
/// (RMS → dBFS → normalised), never faked from a timer or RNG.
final class MicrophoneMonitor: MicrophoneMonitoring {
    let events: AsyncStream<MicEvent>
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let continuation: AsyncStream<MicEvent>.Continuation

    // Rebuilt on every start: after an interruption/suspension the old engine can
    // be left "running" yet delivering empty buffers, so we don't reuse it.
    private var engine = AVAudioEngine()
    /// The *real* engine state, not a flag that could go stale when iOS stops the
    /// engine on app suspension without calling us back.
    var isRunning: Bool { engine.isRunning }

    // Envelope follower state (audio thread only).
    private var smoothed: Double = 0
    private let noiseFloorDB: Double = -50   // maps to 0
    private let ceilingDB: Double = -5       // maps to 1

    init() {
        var cont: AsyncStream<MicEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { cont = $0 }
        continuation = cont
        registerInterruptionObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        continuation.finish()
    }

    // MARK: Permission

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied:  return false
        default:
            return await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }

    // MARK: Lifecycle

    func start() throws {
        guard !engine.isRunning else { return }

        // Fresh engine each time — clears any bad post-interruption state.
        engine.stop()
        engine = AVAudioEngine()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
            self?.onBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        smoothed = 0
    }

    // MARK: Amplitude (audio thread)

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sumSquares: Float = 0
        for i in 0..<count {
            let s = channel[i]
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(count))
        let db = 20 * log10(max(Double(rms), 1e-7))
        let normalized = (db - noiseFloorDB) / (ceilingDB - noiseFloorDB)
        let level = min(max(normalized, 0), 1)

        // Fast attack, slow release: rises with the voice, falls back gently so
        // the orb keeps a little life between words instead of strobing.
        let coefficient = level > smoothed ? 0.5 : 0.12
        smoothed += (level - smoothed) * coefficient

        continuation.yield(.level(smoothed))
    }

    // MARK: Interruptions

    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            // The OS has taken the session (phone call, Siri…). Tear down so we
            // don't sit on a dead engine, and let the engine reset to idle.
            audioLog.info("interruption BEGAN")
            stop()
            continuation.yield(.interruptionBegan)
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0)
            } ?? []
            audioLog.info("interruption ENDED (shouldResume=\(options.contains(.shouldResume), privacy: .public))")
            continuation.yield(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
        @unknown default:
            break
        }
    }
}
