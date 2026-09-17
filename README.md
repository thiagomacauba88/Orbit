# Orbit: Listening Orb

One screen: a microphone, a voice, and an orb you can talk to. It listens through
the real mic, figures out what you asked, does it the way it normally moves, and
says something back out loud. If it can't do what you asked, it says so instead of
pretending.

Everything the app does runs on the device, with no API keys. The one piece a
production build would move to a server, I designed as a clean boundary and built
only the cancellation path against a local stub, which is the part the brief asks
for.

## Build & run

- **Xcode 26**, **iOS 26** target. Open `Orbit.xcodeproj` and run (⌘R).
- The Metal shader is compiled at build time. If Xcode asks, install the Metal
  Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
- On first launch it asks for **Microphone** and **Speech Recognition**. Both are
  needed for commands.
- The simulator uses the Mac's microphone, so commands work there too.

### Which resolver runs where (device matrix)

A real model runs on **every** device. Apple's on-device **Foundation Models**
where the hardware supports it, and a small local model with **MLX** on every other
device (any chip without Apple Intelligence, like the A16). The
deterministic parser is only a fallback.
The app chooses once, at launch, and logs the choice (`os_log`, category `audio`).

| Device | Chip | Resolver |
|---|---|---|
| iPhone 15 Pro / Pro Max, all iPhone 16 | A17 Pro / A18 | Foundation Models (parser fallback) |
| iPhone 15 / 14 Pro and earlier | A16 | Local MLX model, Qwen2.5-0.5B (parser fallback) |

The MLX weights download once (~300 MB) on first launch and then run on-device.
While they load, commands fall back to the parser, so the app is never blocked
waiting. With no internet on the first launch, the parser handles commands until the
model can download. Once it's downloaded, it runs offline.

## The cycle

`Idle → Listening → Thinking → Acting → Speaking → Idle`. Two things break this
straight line. You can interrupt at any time (a phone call, a timer)
and it stops cleanly. And if the request is not supported, it skips Acting and goes
straight to an honest reply.

## Architecture

**MVVM with an explicit state machine.** `OrbEngine` (`@MainActor`, `@Observable`)
owns the one `OrbState`, and `enter(_:)` is the only place where a transition
happens. Cancellation and interruption live in that one place, so the orb can't get
stuck between states. The view only reads the state, never writes back.

**One microphone tap, two consumers.** A single `AVAudioEngine` input tap computes
the amplitude (RMS → dBFS, smoothed) and sends the same buffers to speech
recognition. You can't put two taps on one input node, so the two jobs share the
same capture.

**The orb is drawn with Metal, off the main thread.** A `CAMetalLayer` has its own
render loop (a `CADisplayLink` on a `.userInteractive` thread) at 120 fps. Audio,
speech and SwiftUI all run on the main thread and can't block it, so it can keep the
frame rate while the phone is listening. The motion physics (`OrbMotion`) is
thread-safe and runs inside that same loop, so there is only one clock.

**Services are behind protocols:** `MicrophoneMonitoring`, `SpeechRecognizing`,
`VoiceSpeaking`, `CommandResolver`, and `Brain` (the network seam). The engine
depends on behaviour, not on frameworks, so it is also easy to test without a mic
or a model.

## 01 · The orb, the microphone, and Metal

**Real sound.** The amplitude comes from the real PCM buffers (RMS → dBFS →
normalised, with a fast attack and a slow release), not from a timer or a random
number. It drives the surface motion and the glow while the orb listens.

**The shader** (`OrbShaders.metal`) is one full-screen fragment pass:

- a lit sphere (the normal comes from the disc, plus a directional light, a fresnel
  rim and a small specular) so it looks like a 3-D sphere, not a flat circle.
- an animated surface, value-noise **fbm with 3 octaves**, that moves more as the
  sound gets louder.
- an additive **glow** around the core.
- a near-black background, drawn edge to edge.

**Movement belongs to the orb, not to each command.** The engine only sets targets.
`OrbMotion` moves the on-screen values toward those targets every frame, so "move
left" always travels and settles, and nothing sets a position directly. The
position uses a constant-speed ease-in-out (smootherstep), so it stops cleanly with
no spring bounce at the end. A bounce is a spring impulse, because for a bounce I do
want that overshoot. The anchors come from the real screen size and the safe-area
insets, so the orb reaches the edges on any device.

## 02 · A voice

`AVSpeechSynthesizer`, on-device. The voice is chosen once. Since the orb listens
and replies in English, it prefers the best English voice that is installed (premium > enhanced > default, and en-US to break
ties), and falls back to the system default. It is warmed up at launch with a
silent line, so the first real reply doesn't cause a glitch when the audio switches
to playback while the orb is still moving.

**What the orb does while speaking:** it stays where it was put, keeps its colour,
and pulses in a steady "talking" rhythm. This pulse is made in code, not from
the mic, so it looks the same on every device and the orb never reacts to its own
voice. Interrupting the orb by talking while it speaks back is deliberately left out:
without echo cancellation, the mic would hear the orb's own voice.

## 03 · Spoken commands, with a model

Speech to text with `SFSpeechRecognizer`, on-device. I end the sentence on a pause
in the transcript, not on the raw mic amplitude, because in a real room the
amplitude never really drops to zero. Then a `CommandResolver` turns the text into
an `OrbCommand`. Two resolvers sit behind that protocol, chosen at runtime:

- **`FoundationModelsResolver`**: Apple's on-device model, available on iOS 26 with
  Apple Intelligence (iPhone 15 Pro and the 16 line). Guided generation (`@Generable`)
  keeps its answer inside the orb's vocabulary.
- **`MLXResolver`**: a small local model (Qwen2.5-0.5B-Instruct, 4-bit) run with
  MLX, for every other device, the older iPhones without Apple Intelligence. It asks the model
  for a compact JSON command and reads it back. The weights download once and then
  run on-device.
- **`HeuristicResolver`**: a hand-written keyword parser. It is deterministic,
  always available, the thing the tests check, and the fallback while a model loads
  or if it fails.

All of them send their answer through the same synonym maps, so there is one
definition of what the orb understands.

**Which I picked and why.** A real model has to run on every device, not just the
ones with Apple Intelligence. So the app uses two models, chosen at launch:
Foundation Models where it's available
(platform-native, no download), and a small local model with MLX on every other
device, older iPhones included. MLX is Apple's own Metal-backed ML
framework, and a 0.5B 4-bit
model is small and fast enough for a tiny "sentence → command" task on the A16.
Each device runs exactly one model, with the parser as the last resort.

**What it is good at here:** natural phrasing and association, which the keyword
parser can't do. It can take a colour described by something else, or a direction
worded loosely, and map it onto the orb's vocabulary. Foundation Models handles
subtler intent better than the small MLX model does.

**Where it breaks:** the small MLX model (0.5B) is not a strong reasoner. It gets
clear associations, but misses subtler intent ("come back" with "left" in the
sentence often becomes a move left, not a centre), and it misses less common
associations and metaphors. I tried a 1B model. It was a little better but not
enough to justify a 700 MB download and slower first inference on the A16, so I kept
the 0.5B and reported the limit here rather than hiding it. The real fix is a bigger
model on a server. On Foundation Models devices these cases mostly already work.

**Latency:** the model is warmed up at launch, and the resolve has a timeout that
falls back to the parser (3 s for Foundation Models, 8 s for MLX, whose first
inference is slower because it compiles Metal kernels), so the Thinking state can't
hang. A short prompt keeps the normal case fast, and the MLX first-run cost is paid
once.

## 04 · The seam it would cross in production

Everything above runs on the phone. A real build would not: the model would run on
a server and the answer would stream back over a connection. The client only talks
to the `Brain` protocol, so replacing the local stub with a real transport changes
nothing above it.

**Messages, in order.**

```
Client → server:   start(turnId, transcript)
                   cancel(turnId)

Server → client:   ack(turnId)                 // received, working
                   command(turnId, OrbCommand) // what the model resolved
                   say(turnId, chunk)          // reply, streamed in pieces
                   ...
                   done(turnId, CommandOutcome) // finished
             or    cancelled(turnId)            // acknowledged a cancel
```

**The user interrupts a streamed answer.** The phone sends `cancel(turnId)` and
stops everything locally right away (stops the TTS, stops the stream, starts
listening again). The server owes a `cancelled(turnId)` ack and must stop sending
`say` chunks. The thing the phone knows and the server does not is the exact screen
size and render state. That is why the command runs on the client: the server says
what ("move left"), and the phone decides where (the anchor for this screen).

**The connection drops in the middle.** The stream ends without `done` or
`cancelled`. The phone treats the turn as dropped and goes back to Idle, instead of
getting stuck or applying half of an answer. A real build would show a short
"connection lost" and let the user try again. The turn is dropped, not finished
silently.

**Implemented vs on paper.** The cancellation path is built and it runs.
`LocalStubBrain` is an `actor` that stands in for the server: it resolves, streams
the reply with some artificial latency, and answers a cancel in the middle with an
ack. Both barge-in and the phone-call / timer interruption use it. You can see it in
the console (`os_log`, category `seam`): `→ start`, `← command`, `← done`, and on an
interrupt `→ cancel` / `← cancelled`. The real network transport stays on paper, as
the brief allows.

## Performance note

**How I measured:** Xcode's Debug gauges (CPU / Memory / Energy / FPS) and the
`perf` log (FPS and `ProcessInfo.thermalState`, logged every two seconds), on an
iPhone 14 Pro and an iPhone 16 Pro over a sustained session. Rough numbers, reported
honestly. Instruments would give a deeper per-pass breakdown. The gauges were enough
here.

> **The numbers, on two devices:**
>
> **iPhone 14 Pro (A16), running the local MLX model:**
> - FPS: **120** while rendering, dipping to ~88 during a model inference, because the
>   GPU is shared between the shader and the on-device model.
> - Memory: **~450 MB** (about 340 MB of that is the resident 0.5B model).
> - Thermal: fair after a sustained session. Energy: low.
>
> **iPhone 16 Pro (A18 Pro), using Foundation Models:**
> - FPS: **120**, steady.
> - Memory: **~103 MB** (no model weights in the app, since Foundation Models is
>   system-provided).
> - Energy: higher while a command is in flight, low at rest.

**Where the shader cost is.** It is one full-screen fragment pass. The background and
glow are cheap, and the expensive part, the 3-octave fbm, only runs inside the
sphere's disc. The cost is just shading every pixel at 120 fps.

**Holding 120 fps for two hours while listening.** The shader holds 120 fps on both
devices, the iPhone 16 Pro (A18 Pro) and the 14 Pro (A16). On the 16 Pro it stays
rock-solid, since Foundation Models runs as a system service and doesn't share the
app's GPU pass. The only dip is on the 14 Pro during a local model inference, where
the GPU is shared with MLX. (Easy to miss: iPhone caps apps at 60 fps unless the Info.plist sets
`CADisableMinimumFrameDurationOnPhone`, which is why the first run read 60.) What
keeps the rate up: the render loop runs off the main thread, so audio/STT/SwiftUI
can't drop its frames, the uniforms are triple-buffered with a semaphore, and the
loop pauses in the background. To close the inference dip I would move the noise into
a tiled texture, render at a lower internal resolution, and drop the
`preferredFrameRateRange` at rest and as `thermalState` climbs, checking each in
Metal System Trace rather than guessing.

## Tests

`OrbitTests/CommandResolverTests.swift` covers the part that can break without a
warning: the command vocabulary and the fallback. It checks each direction, colours
(including synonyms like *purple → violet*), bounce and centre. It also checks that an
unrelated sentence becomes `unknown` instead of a wrong guess, and that
`FallbackResolver` goes to the parser when the primary can't understand, but keeps the
primary's answer when it can. It needs no mic and no model, because the resolver is pure.

## The five questions

**1. What I kept from the movement examples, and what I left out.**

Kept, because each one has a job on a one-screen orb you talk to:

- The Settling, for how it arrives: it travels and eases to rest instead of jumping.
- The Surfacing, for the idle life: a slow breathing at rest, and a swell from the
  mic while it listens, so it is clearly alive with no input.
- A different look for each state, made with the glow and the energy pulse instead
  of resizing the orb.

Left out (the interesting half): the show-first qualities (layered particle/fluid
surfaces, trails, multi-axis wobble, anything that needs heavy GPU work all the
time). Two reasons. Performance: an early SwiftUI `.blur()` was already dropping
frames on the 14 Pro, and the frame rate has to hold for two hours, so a full screen
of live effects would cost the deliberate motion I wanted to keep. Meaning: here the
motion is a status display (rest, attention, travel, speech), and qualities that
don't map to one of those add little.

**2. What I'd do with a week instead of a day.**

- Barge-in while speaking, with acoustic echo cancellation (`.voiceChat`), so the
  orb can tell your voice from its own. It is the one interruption case I left out.
- Richer motion inside a real perf budget: a noise texture or a Metal compute pass
  to bring back some lab qualities without dropping frames, and momentum so commands
  can chain (change direction mid-travel).
- Foundation Models with streaming and a short reason, plus a couple of tools, so
  bigger requests answer with an explanation.
- A real network transport behind the `Brain` seam, and the reconnect/retry UX that
  the drop case only describes.
- Accessibility: VoiceOver state announcements, Dynamic Type on the caption, Reduce
  Motion.
- More tests: an engine-level test with fakes for the full
  transcript → state → outcome path, including interruption.

**3. What I deliberately didn't build, and why it is right at this size.**

- No barge-in during Speaking. Without echo cancellation the orb would hear itself.
  Interruption works everywhere else, and I wrote the gap down instead of shipping
  something flaky.
- No real server. The seam is fully designed and only the cancellation path is built
  against a stub, which is what the brief asks for.
- No settings, onboarding, history or persistence. A talk-to-it orb does not need
  memory of past commands, and more screens work against "one screen".
- A small, exact vocabulary instead of a wide, vague one. The model widens the
  phrasing it accepts, not what the orb can do.
- No heavy visuals, for frame-rate and readability.

**4. How I worked: where AI helped, where it led me wrong, what I checked by hand.**

I owned the shape of
the project: the base setup, the architecture (MVVM with a single-transition state
machine, one audio tap feeding both the amplitude and the STT, the render off the
main thread, and the model and the seam each behind a protocol), the scope, and the
trade-offs. I used an assistant to move fast inside those decisions.

- Where it helped: the framework boilerplate, written to my design
  (`AVAudioEngine`, `SFSpeechRecognizer`, `AVSpeechSynthesizer`, the Metal
  pipeline), and a fast second read on the logs. The pump bug, a second
  `AsyncStream` iterator that got nothing after an audio rebuild, came from reading
  the lifecycle logs together.
- Where it led me wrong: when the motion felt off, it kept suggesting motion fixes
  (spring constants, easing curves) for what were really a frame drop (a live
  `.blur`), an audio-route glitch on the first TTS, and that stream bug. That was the
  wrong layer three times. It can't run the app, so it guesses what is likely, not
  what is really on the screen.
- What I checked by hand: the architecture and every design choice, and everything
  that only a device shows (motion smoothness, the first-command glitch, interruption
  and background recovery, and the model on eligible hardware). Running it on the
  device and not stopping at the first answer is what fixed each of these.

**5. One thing in this brief I think is wrong.**

The brief says the orb "moves through the same cycle every time". In practice it
describes more than that. It also says the user can interrupt at any point (which
jumps back to Listening from any state), and that an impossible request is answered
honestly (which skips Acting: Listening → Thinking → Speaking). So it is really a
small state graph with interruptions and skips, not a fixed cycle, and building it as
a literal cycle would work against "interrupt at any point". I built it as a graph
with one transition point for that reason.

A smaller one, same idea: "drive movement from real sound, not a timer" is right for
the audio reactivity, but the deliberate movement (the settle and the travel) has to
be based on time. The rule should not be read as "no time-based motion at all", or
"The Settling" is not possible.

## Instrumentation

The app logs with `os_log` in four categories: `seam` (the client/server messages,
including the cancellation path), `audio` (permission, interruption and recovery),
`perf` (FPS and thermal state), and `mlx` (the local model loading and download
progress). None of it shows in the UI. Filter Console by category to read it.
