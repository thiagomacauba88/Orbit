import SwiftUI

/// The one screen. Owns the engine, hands the orb the motion layer, and starts
/// the audio pipeline when it appears / tears it down when it leaves.
struct ContentView: View {
    @State private var engine = OrbEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The orb is a Metal fragment shader that renders its own dark
            // backdrop edge to edge (behind the status bar and home indicator).
            OrbMetalView(motion: engine.motion)
                .ignoresSafeArea()

            caption

            modelLoadingLabel

            permissionOverlay
        }
        // Measured on the safe-area-respecting ZStack, so we get both the visible
        // size and the real insets. The orb centres on the full screen, and the
        // movement anchors clear the actual chrome on whatever device this is.
        .onGeometryChange(for: ViewportInfo.self) { proxy in
            ViewportInfo(size: proxy.size,
                         top: proxy.safeAreaInsets.top,
                         bottom: proxy.safeAreaInsets.bottom,
                         side: max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing))
        } action: { info in
            engine.setViewport(
                fullSize: CGSize(width: info.size.width + info.side * 2,
                                 height: info.size.height + info.top + info.bottom),
                top: info.top, bottom: info.bottom, side: info.side
            )
        }
        .task { await engine.begin() }
        .onChange(of: scenePhase) { _, phase in
            audioLog.info("scenePhase → \(String(describing: phase), privacy: .public)")
            if phase == .background { engine.markBackgrounded() }
            if phase == .active { engine.ensureRunning() }
        }
        .onDisappear { engine.end() }
    }

    /// Quiet status line: the current state, and the last thing the orb heard.
    /// Deliberately understated so the orb stays the subject of the screen.
    private var caption: some View {
        VStack {
            Spacer()
            VStack(spacing: 6) {
                Text(engine.state.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.45))
                if !engine.lastHeard.isEmpty {
                    Text("“\(engine.lastHeard)”")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 48)
            .padding(.horizontal, 32)
            .animation(.easeInOut(duration: 0.25), value: engine.state)
        }
        .allowsHitTesting(false)
    }

    /// Shown only while the local model is being prepared (downloaded on first
    /// launch, then loaded). Commands still work off the parser meanwhile.
    @ViewBuilder
    private var modelLoadingLabel: some View {
        let indicator = ModelLoadIndicator.shared
        if indicator.isPreparing {
            VStack {
                Spacer()
                VStack(spacing: 2) {
                    Text(indicator.progress > 0 && indicator.progress < 1
                         ? "Preparing the model… \(Int(indicator.progress * 100))%"
                         : "Preparing the model…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                    Text("You can still talk to it")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.bottom, 96)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// Shown when the orb can't listen because a permission is off. The message
    /// names the one that's missing — the mic (to hear) or speech recognition (to
    /// understand) — so the fix in Settings is obvious.
    @ViewBuilder
    private var permissionOverlay: some View {
        switch engine.access {
        case .needsMicrophone:
            accessPrompt(
                title: "Orbit needs the microphone",
                detail: "It listens to your voice on-device to react and follow commands. Nothing leaves the phone."
            )
        case .needsSpeech:
            accessPrompt(
                title: "Orbit needs Speech Recognition",
                detail: "It turns your voice into text on-device to follow commands. Nothing leaves the phone."
            )
        case .pending, .ready:
            EmptyView()
        }
    }

    private func accessPrompt(title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(28)
        .padding(.bottom, 40)
    }
}

/// Screen geometry the engine needs to place movement anchors: the visible size
/// plus the real safe-area insets, so it adapts to any device's chrome.
private struct ViewportInfo: Equatable {
    var size: CGSize
    var top: CGFloat
    var bottom: CGFloat
    var side: CGFloat
}

#Preview {
    ContentView()
}
