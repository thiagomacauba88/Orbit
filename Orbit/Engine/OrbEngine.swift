import Foundation
import os

private let seamLog = Logger(subsystem: "com.thiago.Orbit", category: "seam")

/// What the app still needs before it can listen, as the UI shows it. The orb
/// needs both the microphone (to hear) and speech recognition (to understand), so
/// either one being denied blocks listening and prompts the user to fix it.
enum ListenAccess: Equatable {
    case pending           // not asked yet
    case ready             // mic + speech both granted
    case needsMicrophone
    case needsSpeech
}

/// The brain. Owns the one true `OrbState`, coordinates the services, and is the
/// only place a transition happens. The view reads it; it never reaches back.
///
/// The full cycle lives here:
///   Idle → (voice) → Listening → (silence) → Thinking → Acting → Speaking → Idle
/// Interruption — a phone call, or the user simply talking over the orb — cancels
/// whatever is in flight and lands cleanly, so the orb is never left stuck.
@MainActor
@Observable
final class OrbEngine {
    private(set) var state: OrbState = .idle
    private(set) var access: ListenAccess = .pending
    /// Latest transcript, surfaced for the UI (and handy while developing).
    private(set) var lastHeard: String = ""
    /// Which resolver is live on this device. Logged at launch (category `audio`)
    /// so it's clear on-device which model is actually driving commands.
    let resolverRoute = CommandResolverFactory.activeRouteDescription

    let motion = OrbMotion()

    private let mic: MicrophoneMonitoring
    private let speech: SpeechRecognizing
    private let brain: Brain
    private let speaker: VoiceSpeaking

    private var pump: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var finalizeWatchdog: Task<Void, Never>?
    private var silenceTimer: Task<Void, Never>?
    /// The turn currently open across the seam, so an interrupt can cancel it.
    private var currentTurn: TurnID?
    /// Set when the app backgrounds; the next foreground rebuilds the mic engine.
    private var needsAudioRebuild = false

    // Command-driven state persists across the lifecycle: after "move left" the
    // orb *stays* left until told otherwise. Per-state scale/glow are layered on
    // top of these in `restingTarget`.
    private var commandOffset: CGSize = .zero
    private var commandColor: RGB = .amber
    private var capturedText = ""

    // Voice-activity thresholds.
    private let voiceOnThreshold = 0.16      // wake from idle / keep listening
    private let bargeInThreshold = 0.34      // talk over the orb → interrupt
    private let silenceHangover: TimeInterval = 0.9
    private var lastVoiceAt = Date.distantPast

    // A direction sends the orb to an anchor near that edge (not a small step),
    // so "move left" always lands cleanly on the left and repeating it is
    // idempotent. Each axis is independent, so left-then-up reaches a corner.
    // The anchors are derived from the real view size (see `setViewport`) so the
    // orb reaches close to the edge on any screen, with a margin for the glow.
    private var anchorX: CGFloat = 85
    private var anchorUp: CGFloat = 210
    private var anchorDown: CGFloat = 150
    private let orbRadius: CGFloat = 94   // core radius incl. its largest state scale

    /// Called by the view with its measured size so movement reaches the edges.
    /// Down stops higher than up because the caption lives along the bottom — the
    /// orb should sit above the labels, not cover them.
    /// `fullSize` is the whole screen (the orb centres on it); the insets are the
    /// device's real safe-area insets, so the anchors clear the status bar /
    /// Dynamic Island at the top and the caption + home indicator at the bottom
    /// on any iPhone, not just this one.
    func setViewport(fullSize: CGSize, top: CGFloat, bottom: CGFloat, side: CGFloat) {
        guard fullSize.width > 0, fullSize.height > 0 else { return }
        let sideMargin = side + 16                // keep the core (which grows with
                                                  // energy) off the left/right edges
        let topMargin = top + 8                   // just clear the status bar / island
        let captionSpace = bottom + 112           // clear the caption + home indicator
        anchorX = max(0, fullSize.width / 2 - orbRadius - sideMargin)
        anchorUp = max(0, fullSize.height / 2 - orbRadius - topMargin)
        anchorDown = max(0, fullSize.height / 2 - orbRadius - captionSpace)
    }

    init(mic: MicrophoneMonitoring = MicrophoneMonitor(),
         speech: SpeechRecognizing = SpeechRecognizer(),
         brain: Brain = LocalStubBrain(resolver: CommandResolverFactory.make()),
         speaker: VoiceSpeaking = SystemSpeaker()) {
        self.mic = mic
        self.speech = speech
        self.brain = brain
        self.speaker = speaker
    }

    // MARK: Lifecycle

    func begin() async {
        let micOK = await mic.requestPermission()
        let speechOK = await speech.requestAuthorization()
        access = micOK ? (speechOK ? .ready : .needsSpeech) : .needsMicrophone
        audioLog.info("engine begin (mic=\(micOK, privacy: .public), speech=\(speechOK, privacy: .public))")
        audioLog.info("resolver route → \(self.resolverRoute, privacy: .public)")
        guard micOK, speechOK else { return }

        startAudioPipeline()
        speaker.warmUp()      // load the TTS audio unit now, not on the first reply
        brain.warmUp()        // prewarm the model behind the seam, likewise
    }

    func end() {
        pump?.cancel(); pump = nil
        cancelInFlight()
        mic.onBuffer = nil
        mic.stop()
    }

    private func startAudioPipeline() {
        do {
            try mic.start()
            audioLog.info("mic started (running=\(self.mic.isRunning, privacy: .public))")
        } catch {
            // Right after an interruption the session can refuse to reactivate for
            // a moment; give it a beat and try once more before giving up.
            audioLog.error("mic start failed: \(error.localizedDescription, privacy: .public) — retrying")
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !self.mic.isRunning else { return }
                do {
                    try self.mic.start()
                    audioLog.info("mic started on retry")
                    self.startPump()
                } catch {
                    audioLog.error("mic start failed again: \(error.localizedDescription, privacy: .public)")
                    self.enter(.idle)
                }
            }
            return
        }
        startPump()
    }

    /// One long-lived consumer of `mic.events`. An `AsyncStream` allows only a
    /// single iterator, so we create the pump once and keep it across mic
    /// restarts — the mic re-feeds the same stream, and this keeps reading it.
    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            for await event in self.mic.events {
                if Task.isCancelled { break }
                self.handle(event)
            }
        }
    }

    // MARK: Mic events

    private func handle(_ event: MicEvent) {
        switch event {
        case .level(let level):
            // The mic drives the orb only while idle/listening. During
            // thinking/acting/speaking the visuals are state-driven, so the orb
            // doesn't twitch at ambient noise — or at its own voice.
            if state == .idle || state == .listening { motion.setEnergy(level) }
            react(to: level)

        case .interruptionBegan:
            audioLog.info("engine: interruption began → cancel + idle")
            // Stop whatever is in flight and calm to idle, but stay where the orb
            // was put — an interruption shouldn't undo the last "move" command.
            cancelInFlight()
            motion.setEnergy(0)
            enter(.idle)

        case .interruptionEnded:
            audioLog.info("engine: interruption ended → restart pipeline")
            // A listening app always wants the mic back — resume regardless of
            // the system's `shouldResume` hint (which is really about resuming
            // media playback, and often absent for a timer/alarm).
            startAudioPipeline()
            enter(.idle)
        }
    }

    /// Note that the app was backgrounded, so the next foreground must rebuild the
    /// audio pipeline rather than trust `isRunning` (which can read true while the
    /// engine quietly delivers empty buffers after a suspension).
    func markBackgrounded() { needsAudioRebuild = true }

    /// Called when the app returns to the foreground. Rebuilds the pipeline after
    /// a background trip, or just starts it if it somehow isn't running.
    func ensureRunning() {
        guard access == .ready else { return }
        audioLog.info("ensureRunning (rebuild=\(self.needsAudioRebuild, privacy: .public), running=\(self.mic.isRunning, privacy: .public))")
        if needsAudioRebuild {
            needsAudioRebuild = false
            cancelInFlight()
            mic.stop()
            enter(.idle)
            // Give the audio session a beat to settle after foregrounding before
            // reactivating it — reactivating immediately tends to fail.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !self.mic.isRunning else { return }
                self.startAudioPipeline()
            }
        } else if !mic.isRunning {
            startAudioPipeline()
            enter(.idle)
        }
    }

    private func react(to level: Double) {
        let now = Date()
        switch state {
        case .idle:
            if level > voiceOnThreshold { beginListening() }

        case .listening:
            if level > voiceOnThreshold {
                lastVoiceAt = now
            } else if now.timeIntervalSince(lastVoiceAt) > silenceHangover {
                endListening()
            }

        case .thinking, .acting:
            // Barge-in: the user talks over the orb. Stop cleanly, listen fresh.
            if level > bargeInThreshold { bargeIn() }

        case .speaking:
            // Deliberately no mic barge-in here: without acoustic echo
            // cancellation the orb would hear its own voice. Interrupting the
            // spoken reply is the one thing left for the "with a week" list.
            break
        }
    }

    // MARK: Listening → transcript

    private func beginListening() {
        enter(.listening)
        capturedText = ""
        lastVoiceAt = Date()

        // One tap feeds two consumers: amplitude (already flowing) and speech.
        let speech = self.speech
        mic.onBuffer = { buffer in speech.append(buffer) }

        capture = Task { [weak self] in
            guard let self else { return }
            for await t in self.speech.beginUtterance() {
                self.capturedText = t.text
                self.lastHeard = t.text
                // The pause-countdown only runs once there are real words to act
                // on — so a silent, noisy room doesn't keep finalising nothing.
                let hasWords = !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasWords { self.scheduleSilenceFinalize() }
                if t.isFinal { break }
            }
            if !Task.isCancelled { self.finalizeUtterance() }
        }
    }

    /// End the utterance after a short pause with no new transcript. Segmenting on
    /// the words themselves (not on microphone amplitude) is what makes this work
    /// with a noisy input where the level never truly drops to zero.
    private func scheduleSilenceFinalize() {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard let self, !Task.isCancelled else { return }
            self.endListening()
        }
    }

    private func endListening() {
        guard state == .listening else { return }
        silenceTimer?.cancel(); silenceTimer = nil
        mic.onBuffer = nil
        speech.finish()   // ask for the final result

        // Don't hang forever if a final never lands — proceed with what we heard.
        finalizeWatchdog?.cancel()
        finalizeWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.speech.cancel()
            self.finalizeUtterance()
        }
    }

    private func finalizeUtterance() {
        guard state == .listening else { return }
        silenceTimer?.cancel(); silenceTimer = nil
        finalizeWatchdog?.cancel(); finalizeWatchdog = nil
        capture?.cancel(); capture = nil
        mic.onBuffer = nil

        let transcript = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            // Heard nothing intelligible — slip quietly back to rest rather than
            // announcing it and re-triggering on the room's own noise.
            enter(.idle)
            return
        }
        runCommand(from: transcript)
    }

    // MARK: A turn across the seam (Thinking → Acting → Speaking)

    /// Open a turn with the "server" (the stub) and drive the orb from the events
    /// it streams back. The command is applied locally the moment it arrives; the
    /// reply is spoken once it has finished streaming. An interrupt cancels the
    /// turn — see `cancelInFlight`.
    private func runCommand(from transcript: String) {
        enter(.thinking)
        let turn = TurnID()
        currentTurn = turn

        work = Task { [weak self] in
            guard let self else { return }
            var reply = ""
            for await event in self.brain.start(turn: turn, transcript: transcript) {
                if Task.isCancelled { break }
                switch event {
                case .ack:
                    break                                   // still thinking
                case .command(_, let command):
                    self.execute(command)                   // the phone acts locally
                case .say(_, let chunk):
                    reply += chunk                          // assemble the streamed reply
                case .done:
                    await self.deliver(reply)
                case .cancelled:
                    break                                   // teardown already handled
                }
            }
            // If we're still the open turn here, the stream ended without a `done`
            // or a `cancelled` — i.e. the connection dropped mid-answer. Recover
            // cleanly to rest rather than sitting stuck in thinking/acting.
            if self.currentTurn == turn {
                seamLog.info("· turn \(turn.raw.prefix(6), privacy: .public) ended without done (treated as dropped)")
                self.currentTurn = nil
                self.enter(.idle)
            }
        }
    }

    /// Carry a command out locally. Movement is the phone's job — it knows the
    /// screen geometry the server can't — so the server sends *what*, and this
    /// decides *where*. Motion itself is left to the spring layer, so every
    /// command travels and settles rather than snapping.
    private func execute(_ command: OrbCommand) {
        switch command.typedAction {
        case .move:
            guard let dir = command.value.flatMap(Direction.init) else { return }
            commandOffset = anchor(commandOffset, toward: dir)
            enter(.acting)
        case .center:
            commandOffset = .zero
            enter(.acting)
        case .color:
            guard let color = command.value.flatMap(OrbColor.init) else { return }
            commandColor = color.rgb
            enter(.acting)
        case .bounce:
            enter(.acting)
            motion.requestBounce()
        case .unknown:
            break   // nothing to do; the streamed reply says so honestly
        }
    }

    /// Speak the fully-streamed reply, then rest. If an interrupt cancelled the
    /// turn while it was speaking, bail without returning to idle.
    private func deliver(_ reply: String) async {
        enter(.speaking)
        await speaker.speak(reply)
        if Task.isCancelled { return }
        currentTurn = nil
        enter(.idle)
    }

    // MARK: Interruption

    private func bargeIn() {
        cancelInFlight()
        beginListening()
    }

    private func cancelInFlight() {
        // Tell the server to stop this turn (the outbound interrupt), then tear
        // down everything local so nothing keeps running while we listen again.
        if let turn = currentTurn {
            seamLog.info("→ cancel \(turn.raw.prefix(6), privacy: .public) (user interrupted)")
            brain.cancel(turn: turn)
            currentTurn = nil
        }
        silenceTimer?.cancel(); silenceTimer = nil
        finalizeWatchdog?.cancel(); finalizeWatchdog = nil
        capture?.cancel(); capture = nil
        work?.cancel(); work = nil
        speaker.stop()
        speech.cancel()
        mic.onBuffer = nil
    }

    /// Move to the anchor for `dir`, leaving the other axis where it was so
    /// successive commands compose into corners.
    private func anchor(_ base: CGSize, toward dir: Direction) -> CGSize {
        switch dir {
        case .left:  return CGSize(width: -anchorX, height: base.height)
        case .right: return CGSize(width:  anchorX, height: base.height)
        case .up:    return CGSize(width: base.width, height: -anchorUp)
        case .down:  return CGSize(width: base.width, height:  anchorDown)
        }
    }

    // MARK: The single transition point

    private func enter(_ next: OrbState) {
        guard next != state else { return }
        state = next
        motion.setSpeaking(next == .speaking)
        // Drop any leftover mic energy as we leave listening, so the orb travels
        // and thinks calmly instead of staying puffed up by the last loud word.
        if next == .thinking || next == .acting { motion.setEnergy(0) }
        motion.setTarget(restingTarget(for: next))
    }

    /// Per-state look, layered over the persisted command position/colour.
    private func restingTarget(for state: OrbState) -> OrbRenderModel {
        let base = OrbRenderModel(offset: commandOffset, scale: 1, color: commandColor, glow: 0.32, energy: 0)
        // States read apart through glow, not scale. Scale holds at 1.0 through
        // thinking/acting/speaking so those quick transitions don't jiggle the
        // size while the orb is travelling.
        switch state {
        case .idle:      return base
        case .listening: return base.with(scale: 1.03, glow: 0.6)
        case .thinking:  return base.with(glow: 0.42)
        case .acting:    return base.with(glow: 0.72)
        case .speaking:  return base.with(glow: 0.82)
        }
    }
}

private extension OrbRenderModel {
    func with(scale: CGFloat? = nil, glow: Double? = nil, color: RGB? = nil) -> OrbRenderModel {
        OrbRenderModel(offset: offset,
                       scale: scale ?? self.scale,
                       color: color ?? self.color,
                       glow: glow ?? self.glow,
                       energy: energy)
    }
}
