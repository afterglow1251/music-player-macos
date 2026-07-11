import SwiftUI
import MetalKit
import simd

/// A real MilkDrop-class visualizer: a GPU frame-feedback engine. Each frame warps
/// the *previous* frame (zoom / rotate / ripple), fades it, and draws the live audio
/// waveform on top — so motion accumulates into the flowing tunnels and trails that
/// define the MilkDrop look. Presets are parameter sets it morphs between, and the
/// beat kicks the zoom. Built on Metal with a ping-pong texture pair.
///
/// This is the genuine technique (feedback + per-pixel warp), not a Canvas mock-up.
/// What it deliberately does NOT do is interpret `.milk` preset files / the ns-eel
/// expression language — that's a separate undertaking; here the presets are ours.
struct MilkdropView: NSViewRepresentable {
    var theme: VisualizerTheme
    var analyzer: SpectrumAnalyzer
    var isPlaying: Bool

    func makeCoordinator() -> MilkdropRenderer { MilkdropRenderer(analyzer: analyzer) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.layer?.isOpaque = true
        if let device = view.device {
            context.coordinator.setup(device: device)
        }
        context.coordinator.setPalette(from: theme)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.setPalette(from: theme)
        // Freeze the loop when paused — the last frame lingers, and no CPU/GPU burns.
        view.isPaused = !isPlaying
    }
}

/// The Metal renderer + MTKView delegate. Not `@MainActor`: MTKView drives it on the
/// main thread, and `SpectrumAnalyzer` is `@unchecked Sendable` (lock-guarded), so
/// reading audio here is safe without actor hops.
final class MilkdropRenderer: NSObject, MTKViewDelegate {
    private let analyzer: SpectrumAnalyzer

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var warpPipeline: MTLRenderPipelineState?
    private var wavePipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var ready = false

    // Ping-pong feedback textures (front = last frame, back = the one we're drawing).
    private var front: MTLTexture?
    private var back: MTLTexture?

    // Wave geometry: interleaved [x, y, r, g, b, a] per point.
    private var waveBuffer: MTLBuffer?
    private static let maxWavePoints = 1024
    private var wavePointCount = 0

    // Palette sampled from the current theme (16 stops), for coloring the waveform.
    private var palette: [SIMD4<Float>] = [SIMD4<Float>(0, 1, 0, 1)]

    // Motion / preset state.
    private var lastTime: CFTimeInterval = 0
    private var current = Preset.presets[0]
    private var targetIndex = 0
    private var lastSwitch: CFTimeInterval = 0
    private var zoomKick: Float = 0
    private var prevBass: Float = 0
    private var lastBeat: CFTimeInterval = 0

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        super.init()
    }

    // MARK: Setup

    func setup(device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else {
            print("Milkdrop: shader compilation failed")
            return
        }

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sampDesc)

        // Warp (feedback) — full-screen quad sampling the previous frame, no blend.
        warpPipeline = Self.makePipeline(device, library,
                                         vertex: "quad_vertex", fragment: "warp_fragment",
                                         format: .rgba16Float, blend: false, vertexDescriptor: nil)
        // Composite — the accumulated texture to the drawable.
        compositePipeline = Self.makePipeline(device, library,
                                              vertex: "quad_vertex", fragment: "composite_fragment",
                                              format: .bgra8Unorm, blend: false, vertexDescriptor: nil)
        // Waveform — additive line strip drawn on top of the warped frame.
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float4; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<Float>.stride * 6
        wavePipeline = Self.makePipeline(device, library,
                                         vertex: "wave_vertex", fragment: "wave_fragment",
                                         format: .rgba16Float, blend: true, vertexDescriptor: vd)

        waveBuffer = device.makeBuffer(length: Self.maxWavePoints * 6 * MemoryLayout<Float>.stride,
                                       options: .storageModeShared)

        ready = warpPipeline != nil && wavePipeline != nil && compositePipeline != nil
            && sampler != nil && queue != nil && waveBuffer != nil
    }

    private static func makePipeline(_ device: MTLDevice, _ library: MTLLibrary,
                                     vertex: String, fragment: String,
                                     format: MTLPixelFormat, blend: Bool,
                                     vertexDescriptor: MTLVertexDescriptor?) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.vertexDescriptor = vertexDescriptor
        let attachment = desc.colorAttachments[0]
        attachment?.pixelFormat = format
        if blend {
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .one
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .one
            attachment?.destinationAlphaBlendFactor = .one
        }
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    func setPalette(from theme: VisualizerTheme) {
        let stops = theme.colors.map { color -> SIMD4<Float> in
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
            return SIMD4<Float>(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), 1)
        }
        if !stops.isEmpty { palette = stops }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard let device, size.width > 0, size.height > 0 else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        front = device.makeTexture(descriptor: desc)
        back = device.makeTexture(descriptor: desc)
        // Start from black so the first feedback samples don't read garbage.
        clear(front)
        clear(back)
    }

    private func clear(_ texture: MTLTexture?) {
        guard let texture, let cb = queue?.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rpd.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
        cb.commit()
    }

    func draw(in view: MTKView) {
        guard ready, let queue, let front, let back, let waveBuffer,
              let drawable = view.currentDrawable,
              let screenPass = view.currentRenderPassDescriptor,
              let warpPipeline, let wavePipeline, let compositePipeline
        else { return }

        let uniforms = advance(size: view.drawableSize)
        updateWaveGeometry(into: waveBuffer, level: uniforms.level)

        guard let cb = queue.makeCommandBuffer() else { return }

        // Pass 1 — warp the previous frame into `back`, then add the waveform on top.
        let feedback = MTLRenderPassDescriptor()
        feedback.colorAttachments[0].texture = back
        feedback.colorAttachments[0].loadAction = .dontCare   // the warp quad overwrites all of it
        feedback.colorAttachments[0].storeAction = .store
        if let e1 = cb.makeRenderCommandEncoder(descriptor: feedback) {
            var u = uniforms
            e1.setRenderPipelineState(warpPipeline)
            e1.setFragmentTexture(front, index: 0)
            e1.setFragmentBytes(&u, length: MemoryLayout<MilkUniforms>.stride, index: 0)
            e1.setFragmentSamplerState(sampler, index: 0)
            e1.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            if wavePointCount > 1 {
                e1.setRenderPipelineState(wavePipeline)
                e1.setVertexBuffer(waveBuffer, offset: 0, index: 0)
                e1.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: wavePointCount)
            }
            e1.endEncoding()
        }

        // Pass 2 — show `back` on screen.
        screenPass.colorAttachments[0].loadAction = .clear
        screenPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        if let e2 = cb.makeRenderCommandEncoder(descriptor: screenPass) {
            e2.setRenderPipelineState(compositePipeline)
            e2.setFragmentTexture(back, index: 0)
            e2.setFragmentSamplerState(sampler, index: 0)
            e2.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e2.endEncoding()
        }

        cb.present(drawable)
        cb.commit()

        // Swap: this frame becomes the feedback source for the next.
        self.front = back
        self.back = front
    }

    // MARK: Motion

    /// Step presets, beat kick, and per-frame warp amounts; returns this frame's uniforms.
    private func advance(size: CGSize) -> MilkUniforms {
        let now = CACurrentMediaTime()
        var dt = lastTime == 0 ? 1.0 / 60 : now - lastTime
        dt = min(max(dt, 0), 0.1)
        lastTime = now
        if lastSwitch == 0 { lastSwitch = now }

        // Morph toward the target preset; rotate the lineup every ~14s.
        if now - lastSwitch > 14 {
            targetIndex = (targetIndex + 1) % Preset.presets.count
            lastSwitch = now
        }
        current = current.morphed(toward: Preset.presets[targetIndex], rate: Float(dt) * 0.5)

        // Beat: a rising bass edge kicks the zoom (decays over the next frames).
        let bass = analyzer.bassLevel
        zoomKick *= 0.9
        if bass > 0.5, bass - prevBass > 0.08, now - lastBeat > 0.22 {
            zoomKick = 0.05
            lastBeat = now
        }
        prevBass = bass

        let aspect = size.height > 0 ? Float(size.width / size.height) : 1
        return MilkUniforms(
            resolution: SIMD2<Float>(Float(size.width), Float(size.height)),
            aspect: aspect,
            time: Float(now.truncatingRemainder(dividingBy: 1000)),
            zoom: current.zoom + zoomKick,
            rot: current.rotRate * Float(dt),
            warpAmp: current.warpAmp * (1 + bass * 0.6),
            warpFreq: current.warpFreq,
            decay: current.decay,
            level: bass)
    }

    /// Draw the live waveform straight across the full width, colored across the
    /// palette. A horizontal sweep fills the frame at any aspect (the strip is very
    /// wide and short); the feedback warp then rotates/zooms it into flowing shapes.
    private func updateWaveGeometry(into buffer: MTLBuffer, level: Float) {
        let wave = analyzer.waveform()
        let count = min(wave.count, Self.maxWavePoints)
        guard count > 1 else { wavePointCount = 0; return }

        let intensity: Float = 0.13 * (0.5 + level)
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: count * 6)
        for i in 0..<count {
            let t = Float(i) / Float(count - 1)
            let sample = wave[i]
            let x = t * 2 - 1            // -1…1 across the full width
            let y = sample * 0.72        // vertical swing around the center

            let stop = palette[min(Int(t * Float(palette.count - 1)), palette.count - 1)]
            let glow = intensity * (0.6 + abs(sample))
            let base = i * 6
            pointer[base + 0] = x
            pointer[base + 1] = y
            pointer[base + 2] = stop.x * glow
            pointer[base + 3] = stop.y * glow
            pointer[base + 4] = stop.z * glow
            pointer[base + 5] = 1
        }
        wavePointCount = count
    }
}

/// A warp/feedback parameter set. `zoom`/`rotRate`/`warpAmp` are per-frame amounts
/// applied to the sampling of the previous frame; `decay` is the trail persistence.
private struct Preset {
    var zoom: Float
    var rotRate: Float
    var warpAmp: Float
    var warpFreq: Float
    var decay: Float

    func morphed(toward target: Preset, rate: Float) -> Preset {
        let k = min(max(rate, 0), 1)
        func lerp(_ a: Float, _ b: Float) -> Float { a + (b - a) * k }
        return Preset(zoom: lerp(zoom, target.zoom),
                      rotRate: lerp(rotRate, target.rotRate),
                      warpAmp: lerp(warpAmp, target.warpAmp),
                      warpFreq: lerp(warpFreq, target.warpFreq),
                      decay: lerp(decay, target.decay))
    }

    static let presets: [Preset] = [
        Preset(zoom: 1.015, rotRate:  0.15, warpAmp: 0.010, warpFreq:  6, decay: 0.965), // tunnel
        Preset(zoom: 1.002, rotRate:  0.60, warpAmp: 0.020, warpFreq:  4, decay: 0.955), // swirl
        Preset(zoom: 0.992, rotRate: -0.20, warpAmp: 0.035, warpFreq: 11, decay: 0.972), // ripple
        Preset(zoom: 0.985, rotRate:  0.10, warpAmp: 0.020, warpFreq:  8, decay: 0.960), // bloom-out
    ]
}

/// Mirrors the `Uniforms` struct in the shader — field order & layout must match.
private struct MilkUniforms {
    var resolution: SIMD2<Float>
    var aspect: Float
    var time: Float
    var zoom: Float
    var rot: Float
    var warpAmp: Float
    var warpFreq: Float
    var decay: Float
    var level: Float
}

extension MilkdropRenderer {
    /// Metal Shading Language, compiled at launch so there's no `.metal` build step.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float aspect;
        float time;
        float zoom;
        float rot;
        float warpAmp;
        float warpFreq;
        float decay;
        float level;
    };

    struct QuadOut { float4 pos [[position]]; float2 uv; };

    vertex QuadOut quad_vertex(uint vid [[vertex_id]]) {
        float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        QuadOut o;
        o.pos = float4(p[vid], 0, 1);
        o.uv = p[vid] * float2(0.5, -0.5) + 0.5;
        return o;
    }

    // Warp the previous frame: rotate + zoom + a sinusoidal ripple around the center,
    // then fade — feedback turns this into flowing tunnels and trails.
    fragment float4 warp_fragment(QuadOut in [[stage_in]],
                                  texture2d<float> prevTex [[texture(0)]],
                                  constant Uniforms& u [[buffer(0)]],
                                  sampler samp [[sampler(0)]]) {
        float2 c = float2(0.5, 0.5);
        float2 p = in.uv - c;
        p.x *= u.aspect;
        float s = sin(u.rot), co = cos(u.rot);
        p = float2(p.x * co - p.y * s, p.x * s + p.y * co);
        p /= u.zoom;
        p += u.warpAmp * float2(sin(p.y * u.warpFreq + u.time),
                                cos(p.x * u.warpFreq + u.time));
        p.x /= u.aspect;
        float4 prev = prevTex.sample(samp, p + c);
        return prev * u.decay;
    }

    struct WaveIn { float2 pos [[attribute(0)]]; float4 color [[attribute(1)]]; };
    struct WaveOut { float4 pos [[position]]; float4 color; };

    vertex WaveOut wave_vertex(WaveIn in [[stage_in]]) {
        WaveOut o;
        o.pos = float4(in.pos, 0, 1);
        o.color = in.color;
        return o;
    }
    fragment float4 wave_fragment(WaveOut in [[stage_in]]) { return in.color; }

    fragment float4 composite_fragment(QuadOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler samp [[sampler(0)]]) {
        float4 c = tex.sample(samp, in.uv);
        return float4(c.rgb * 1.25, 1.0);
    }
    """
}
