import Metal
import QuartzCore
import simd
import os

private let perfLog = Logger(subsystem: "com.thiago.Orbit", category: "perf")

/// CPU-side mirror of the shader's `OrbUniforms`. Field order and packing match
/// the Metal struct exactly (`color` first for 16-byte alignment).
struct OrbUniforms {
    var color: SIMD3<Float>
    var resolution: SIMD2<Float>
    var center: SIMD2<Float>
    var radius: Float
    var time: Float
    var energy: Float
    var glow: Float
}

/// Renders the orb with a single full-screen fragment-shader pass and advances
/// the motion physics on the display clock. It draws straight into a
/// `CAMetalLayer`, so it can run on its own thread — a busy main thread never
/// stalls the orb. All per-frame work is on the GPU; the CPU only steps the
/// springs and copies a handful of floats.
final class OrbRenderer {
    let device: MTLDevice

    private let motion: OrbMotion
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    // Triple-buffered uniforms so the CPU can write frame N+1 while the GPU still
    // reads frame N — no stalls, no data race.
    private static let maxInFlight = 3
    private let uniformBuffers: [MTLBuffer]
    private let inFlight = DispatchSemaphore(value: maxInFlight)
    private var slot = 0

    private let baseRadius: Float = 92
    private let startTime = CACurrentMediaTime()

    // Lightweight instrumentation: average FPS + thermal state every ~2s, logged
    // (category "perf") so a sustained run can be read straight from the console.
    private var perfFrames = 0
    private var perfWindowStart = CACurrentMediaTime()

    init(motion: OrbMotion) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable on this device — it is required for Orbit.")
        }
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "orb_vertex"),
              let fragmentFn = library.makeFunction(name: "orb_fragment")
        else { fatalError("Failed to build the Metal pipeline for Orbit.") }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        else { fatalError("Failed to create the Metal render pipeline state.") }

        self.device = device
        self.motion = motion
        self.queue = queue
        self.pipeline = pipeline
        self.uniformBuffers = (0..<Self.maxInFlight).map { _ in
            device.makeBuffer(length: MemoryLayout<OrbUniforms>.stride, options: .storageModeShared)!
        }
    }

    /// Advance physics by `dt` and draw one frame into `layer`. Runs on the
    /// render thread.
    func renderFrame(to layer: CAMetalLayer, dt: Double) {
        trackPerf()
        motion.advance(dt: dt)
        let model = motion.displayed

        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return }

        inFlight.wait()
        guard let drawable = layer.nextDrawable() else { inFlight.signal(); return }

        slot = (slot + 1) % Self.maxInFlight
        let buffer = uniformBuffers[slot]

        let scale = Float(layer.contentsScale)
        let resolution = SIMD2<Float>(Float(size.width), Float(size.height))
        var uniforms = OrbUniforms(
            color: SIMD3<Float>(Float(model.color.r), Float(model.color.g), Float(model.color.b)),
            resolution: resolution,
            center: SIMD2<Float>(resolution.x / 2 + Float(model.offset.width) * scale,
                                 resolution.y / 2 + Float(model.offset.height) * scale),
            radius: baseRadius * Float(model.scale) * scale,
            time: Float(CACurrentMediaTime() - startTime),
            energy: Float(model.energy),
            glow: Float(model.glow)
        )
        memcpy(buffer.contents(), &uniforms, MemoryLayout<OrbUniforms>.stride)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { inFlight.signal(); return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func trackPerf() {
        perfFrames += 1
        let now = CACurrentMediaTime()
        let elapsed = now - perfWindowStart
        guard elapsed >= 2.0 else { return }
        let fps = Double(perfFrames) / elapsed
        perfLog.info("fps \(Int(fps.rounded()), privacy: .public) · thermal \(Self.thermalName, privacy: .public)")
        perfFrames = 0
        perfWindowStart = now
    }

    private static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
