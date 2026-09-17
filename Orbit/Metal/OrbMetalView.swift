import SwiftUI
import QuartzCore

/// A vsync-driven render loop running on its own thread, so nothing the main
/// thread does (audio, speech, SwiftUI) can stall the orb. This is what lets the
/// orb hold its frame rate while the phone is listening the whole time.
final class RenderLoop: NSObject {
    private let onFrame: (Double) -> Void
    private var thread: Thread?
    private var displayLink: CADisplayLink?
    private var runLoop: CFRunLoop?
    private var lastTimestamp: CFTimeInterval = 0

    init(onFrame: @escaping (Double) -> Void) { self.onFrame = onFrame }

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .current, forMode: .common)
            self.displayLink = link
            self.lastTimestamp = 0
            CFRunLoopRun()
        }
        thread.name = "OrbRenderLoop"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
        thread = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 1.0 / 120.0 : now - lastTimestamp
        lastTimestamp = now
        onFrame(dt)
    }
}

/// UIView whose backing layer is a `CAMetalLayer`, driven by the off-main render
/// loop. Layout stays on the main thread; drawing does not.
final class MetalOrbUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let renderer: OrbRenderer
    private var loop: RenderLoop?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(motion: OrbMotion) {
        renderer = OrbRenderer(motion: motion)
        super.init(frame: .zero)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        isOpaque = true
        backgroundColor = .black
        observeLifecycle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            updateDrawableSize()
            startRendering()
        } else {
            loop?.stop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    // The GPU may not be used while the app is backgrounded — submitting there
    // aborts every command buffer with a permission error. So pause the render
    // loop on background and resume it on foreground.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                audioLog.info("app → background (render paused)")
                self?.loop?.stop()
            }
        )
        lifecycleObservers.append(
            center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                audioLog.info("app → foreground (render resumed)")
                guard let self, self.window != nil else { return }
                self.startRendering()
            }
        )
    }

    private func startRendering() {
        if loop == nil {
            // Capture the CAMetalLayer here, on the main thread. The render loop
            // then uses that reference directly and never touches the
            // main-thread-only `UIView.layer` accessor off-thread.
            let layer = metalLayer
            let renderer = self.renderer
            loop = RenderLoop { dt in renderer.renderFrame(to: layer, dt: dt) }
        }
        loop?.start()
    }

    private func updateDrawableSize() {
        let scale = window?.screen.scale ?? 3
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0 { metalLayer.drawableSize = size }
    }
}

/// SwiftUI wrapper.
struct OrbMetalView: UIViewRepresentable {
    var motion: OrbMotion

    func makeUIView(context: Context) -> MetalOrbUIView { MetalOrbUIView(motion: motion) }
    func updateUIView(_ uiView: MetalOrbUIView, context: Context) {}
}
