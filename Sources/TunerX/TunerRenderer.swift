import AppKit
import MetalKit
import QuartzCore
import SwiftUI

struct TXVertex {
    var pos: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
    var params: SIMD4<Float>
}

struct TXUniforms {
    var viewport: SIMD2<Float>
    var time: Float
    var strobePhase: Float
}

/// SwiftUI wrapper around the Metal view.
struct MetalTunerView: NSViewRepresentable {
    let state: DisplayState

    func makeCoordinator() -> TunerRenderer {
        guard let r = TunerRenderer(state: state) else { fatalError("Metal is not available on this Mac") }
        return r
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = TunerRenderer.sampleCount
        view.clearColor = MTLClearColor(red: 0.028, green: 0.031, blue: 0.039, alpha: 1)
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

/// Draws four stacked instruments, all on the GPU:
///  1. STROBE      – three virtual strobe discs; pattern drift speed ∝ deviation, still = in tune
///  2. CHROMATIC   – wide scrolling scale ±6 semitones with note names
///  3. ±50 ¢       – fixed fine scale with 1-cent ticks
///  4. ±5 ¢        – micro scale with 0.1-cent ticks
final class TunerRenderer: NSObject, MTKViewDelegate {
    static let sampleCount = 4

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let atlas: GlyphAtlas
    private let state: DisplayState

    private var verts: [TXVertex] = []
    private var lastTime = CACurrentMediaTime()
    private var dispMC: Double = 6900
    private var dispCents: Double = 0
    private var strobePhase: Double = 0
    private var signalAlpha: Float = 0
    private var px: Float = 2

    init?(state: DisplayState) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        self.state = state
        do {
            let lib = try dev.makeLibrary(source: tunerShaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "tx_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "tx_fragment")
            desc.rasterSampleCount = TunerRenderer.sampleCount
            let ca = desc.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .sourceAlpha
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("TunerX Metal pipeline error: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        guard let s = dev.makeSamplerState(descriptor: sd), let a = GlyphAtlas(device: dev, queue: q) else { return nil }
        sampler = s
        atlas = a
        super.init()
        verts.reserveCapacity(24_000)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: Frame

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTime)
        lastTime = now
        px = Float(view.window?.backingScaleFactor ?? 2)
        let W = Float(view.drawableSize.width), H = Float(view.drawableSize.height)
        guard W > 10, H > 10 else { return }

        let snap = state.get()
        if snap.hasSignal {
            if abs(snap.midiCents - dispMC) > 250 { dispMC = snap.midiCents }
            else { dispMC += (snap.midiCents - dispMC) * (1 - exp(-dt * 20)) }
            dispCents += (snap.cents - dispCents) * (1 - exp(-dt * 20))
            if abs(snap.cents - dispCents) > 20 { dispCents = snap.cents }
            strobePhase += max(-30, min(30, snap.cents)) * 0.5 * dt
            strobePhase -= floor(strobePhase)
        }
        let targetAlpha: Float = snap.hasSignal ? 1 : 0.22
        signalAlpha += (targetAlpha - signalAlpha) * Float(1 - exp(-dt * (snap.hasSignal ? 14 : 3)))

        verts.removeAll(keepingCapacity: true)
        let m = 16 * px, gap = 12 * px
        let avail = H - 2 * m - 3 * gap
        let fractions: [Float] = [0.19, 0.33, 0.26, 0.22]
        var y = m
        var rects: [(Float, Float)] = []
        for f in fractions { rects.append((y, y + avail * f)); y += avail * f + gap }

        drawStrobe(x0: m, y0: rects[0].0, x1: W - m, y1: rects[0].1, snap: snap)
        drawChromatic(x0: m, y0: rects[1].0, x1: W - m, y1: rects[1].1, snap: snap)
        drawLinear(x0: m, y0: rects[2].0, x1: W - m, y1: rects[2].1, range: 50, step: 1,
                   medium: 5, major: 10, title: "FINE   ±50 ¢", zones: [(5, 0.10), (1, 0.20)], snap: snap)
        drawLinear(x0: m, y0: rects[3].0, x1: W - m, y1: rects[3].1, range: 5, step: 0.1,
                   medium: 0.5, major: 1, title: "MICRO   ±5 ¢   ·   0.1 ¢ DIVISIONS", zones: [(1, 0.08), (0.5, 0.14), (0.1, 0.30)],
                   snap: snap)

        guard !verts.isEmpty,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd),
              let vb = device.makeBuffer(bytes: verts, length: MemoryLayout<TXVertex>.stride * verts.count,
                                         options: .storageModeShared) else { return }
        var u = TXUniforms(viewport: SIMD2(W, H), time: Float(now.truncatingRemainder(dividingBy: 1000)),
                           strobePhase: Float(strobePhase))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<TXUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<TXUniforms>.stride, index: 1)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    // MARK: Instruments

    private func panel(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, title: String) {
        quad(x0, y0, x1, y1, SIMD4(0.062, 0.068, 0.082, 1))
        quad(x0, y0, x1, y0 + px, SIMD4(1, 1, 1, 0.05))
        text(title, x: x0 + 12 * px, y: y0 + 6 * px, size: 12 * px, color: SIMD4(0.55, 0.58, 0.64, 1))
    }

    private func drawStrobe(x0: Float, y0: Float, x1: Float, y1: Float, snap: DisplaySnapshot) {
        panel(x0, y0, x1, y1, title: "STROBE")
        let ix0 = x0 + 12 * px, ix1 = x1 - 12 * px
        let iy0 = y0 + 26 * px, iy1 = y1 - 10 * px
        let rowGap = 5 * px
        let rowH = (iy1 - iy0 - 2 * rowGap) / 3
        let col = tuneColor(snap.cents) * SIMD4(1, 1, 1, signalAlpha)
        let periods: [Float] = [96, 48, 24]   // pattern period in points
        let speeds: [Float] = [1, 2, 4]       // like the partials on a strobe disc
        for i in 0..<3 {
            let ry = iy0 + Float(i) * (rowH + rowGap)
            let cycles = (ix1 - ix0) / (periods[i] * px)
            quad(ix0, ry, ix1, ry + rowH, col, mode: 2, p: SIMD2(cycles, speeds[i]))
        }
        let label = SIMD4<Float>(0.6, 0.62, 0.68, 0.8)
        text("♭ FLAT", x: ix0, y: y0 + 6 * px, size: 12 * px, color: label, align: .left, offset: 70 * px)
        text("SHARP ♯", x: ix1, y: y0 + 6 * px, size: 12 * px, color: label, align: .right)
    }

    private func drawChromatic(x0: Float, y0: Float, x1: Float, y1: Float, snap: DisplaySnapshot) {
        panel(x0, y0, x1, y1, title: "CHROMATIC   ±6 SEMITONES")
        let ix0 = x0 + 12 * px, ix1 = x1 - 12 * px
        let iy0 = y0 + 26 * px, iy1 = y1 - 8 * px
        let ih = iy1 - iy0
        let cx = (ix0 + ix1) / 2
        let halfW = (ix1 - ix0) / 2
        let span: Double = 600
        let ppc = Float(Double(halfW) / span)
        let center = dispMC
        let tc = tuneColor(snap.cents)

        // in-tune window around the nearest semitone
        let nearest = (center / 100).rounded() * 100
        let zx0 = cx + Float(nearest - 5 - center) * ppc, zx1 = cx + Float(nearest + 5 - center) * ppc
        quad(zx0, iy0, zx1, iy1, SIMD4(0.25, 1, 0.55, 0.10 * signalAlpha + 0.04))

        let baseY = iy0 + 2 * px
        var c = (floor((center - span) / 10) * 10)
        while c <= center + span + 10 {
            let x = cx + Float(c - center) * ppc
            if x >= ix0 && x <= ix1 {
                let d = abs(x - cx) / halfW
                let fade = max(0, 1 - d * d * d)
                let ci = Int(c.rounded())
                if ci % 100 == 0 {
                    vline(x, baseY, baseY + ih * 0.42, 2.2 * px, SIMD4(0.92, 0.94, 1, 0.9 * fade))
                    let midi = ci / 100
                    if (0...127).contains(midi) {
                        let isTarget = midi == snap.midi && snap.hasSignal
                        let col: SIMD4<Float> = isTarget ? tc : SIMD4(0.85, 0.87, 0.92, 0.85 * fade)
                        let sz = ih * (isTarget ? 0.30 : 0.24)
                        let name = NoteNames.name(midi)
                        let oct = "\(NoteNames.octave(midi))"
                        let wName = atlas.width(name, size: sz), wOct = atlas.width(oct, size: sz * 0.55)
                        let tx = x - (wName + wOct) / 2
                        text(name, x: tx, y: baseY + ih * 0.47, size: sz, color: col, align: .left)
                        text(oct, x: tx + wName, y: baseY + ih * 0.47 + sz * 0.42, size: sz * 0.55,
                             color: col * SIMD4(1, 1, 1, 0.8), align: .left)
                    }
                } else if ci % 50 == 0 {
                    vline(x, baseY, baseY + ih * 0.26, 1.6 * px, SIMD4(0.75, 0.78, 0.85, 0.75 * fade))
                } else {
                    vline(x, baseY, baseY + ih * 0.13, 1.0 * px, SIMD4(0.6, 0.63, 0.7, 0.55 * fade))
                }
            }
            c += 10
        }
        quad(ix0, baseY - px, ix1, baseY, SIMD4(1, 1, 1, 0.15))

        // fixed centre indicator
        let ic = tc * SIMD4(1, 1, 1, signalAlpha)
        quad(cx - 28 * px, iy0, cx + 28 * px, iy1, ic * SIMD4(1, 1, 1, 0.35), mode: 3, u0: SIMD2(-1, 0), u1: SIMD2(1, 1))
        vline(cx, iy0, iy1, 2.5 * px, ic)
        tri(SIMD2(cx - 9 * px, iy0), SIMD2(cx + 9 * px, iy0), SIMD2(cx, iy0 + 12 * px), ic)
        tri(SIMD2(cx - 9 * px, iy1), SIMD2(cx + 9 * px, iy1), SIMD2(cx, iy1 - 12 * px), ic)
    }

    private func drawLinear(x0: Float, y0: Float, x1: Float, y1: Float, range: Double, step: Double,
                            medium: Double, major: Double, title: String, zones: [(Double, Float)],
                            snap: DisplaySnapshot) {
        panel(x0, y0, x1, y1, title: title)
        let ix0 = x0 + 28 * px, ix1 = x1 - 28 * px
        let iy0 = y0 + 26 * px, iy1 = y1 - 8 * px
        let ih = iy1 - iy0
        let cx = (ix0 + ix1) / 2
        let ppc = Float(Double(ix1 - ix0) / (2 * range))
        let base = iy0 + ih * 0.58

        for (w, a) in zones {
            quad(cx - Float(w) * ppc, iy0, cx + Float(w) * ppc, base, SIMD4(0.25, 1, 0.55, a))
        }
        quad(ix0, base, ix1, base + px, SIMD4(1, 1, 1, 0.25))

        let count = Int((2 * range / step).rounded())
        let majorEvery = Int((major / step).rounded()), mediumEvery = Int((medium / step).rounded())
        for i in 0...count {
            let k = i - count / 2
            let x = cx + Float(Double(k) * step) * ppc
            if k % majorEvery == 0 {
                vline(x, base - ih * 0.40, base, 2 * px, SIMD4(0.92, 0.94, 1, 0.95))
                let v = Double(k) * step
                let label = v == 0 ? "0" : (v > 0 ? "+" : "−") + String(format: "%g", abs(v))
                text(label, x: x, y: base + ih * 0.06, size: ih * 0.26, color: SIMD4(0.78, 0.8, 0.86, 1))
            } else if k % mediumEvery == 0 {
                vline(x, base - ih * 0.26, base, 1.5 * px, SIMD4(0.75, 0.78, 0.85, 0.8))
            } else {
                vline(x, base - ih * 0.14, base, 1 * px, SIMD4(0.6, 0.63, 0.7, 0.6))
            }
        }

        // needle
        let cents = dispCents
        let tc = tuneColor(snap.cents) * SIMD4(1, 1, 1, signalAlpha)
        let clamped = max(-range, min(range, cents))
        let nx = cx + Float(clamped) * ppc
        quad(nx - 22 * px, iy0, nx + 22 * px, base, tc * SIMD4(1, 1, 1, 0.35), mode: 3, u0: SIMD2(-1, 0), u1: SIMD2(1, 1))
        vline(nx, iy0 + 4 * px, base, 3 * px, tc)
        tri(SIMD2(nx - 8 * px, iy0), SIMD2(nx + 8 * px, iy0), SIMD2(nx, iy0 + 11 * px), tc)
        if abs(cents) > range && snap.hasSignal {   // off-scale arrow
            let dir: Float = cents > 0 ? 1 : -1
            let ex = cents > 0 ? ix1 + 18 * px : ix0 - 18 * px
            let my = (iy0 + base) / 2
            tri(SIMD2(ex + dir * 10 * px, my), SIMD2(ex - dir * 6 * px, my - 10 * px), SIMD2(ex - dir * 6 * px, my + 10 * px), tc)
        }
    }

    // MARK: Primitives

    private func tuneColor(_ cents: Double) -> SIMD4<Float> {
        let a = Float(min(abs(cents), 25))
        let green = SIMD4<Float>(0.25, 1.0, 0.55, 1)
        let yellow = SIMD4<Float>(1.0, 0.84, 0.25, 1)
        let red = SIMD4<Float>(1.0, 0.32, 0.26, 1)
        if a < 1 { return green }
        if a < 5 { let t = (a - 1) / 4; return green + (yellow - green) * t }
        let t = (a - 5) / 20
        return yellow + (red - yellow) * t
    }

    private func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ c: SIMD4<Float>,
                      mode: Float = 0, u0: SIMD2<Float> = SIMD2(0, 0), u1: SIMD2<Float> = SIMD2(1, 1),
                      p: SIMD2<Float> = SIMD2(0, 0)) {
        let params = SIMD4<Float>(mode, p.x, p.y, 0)
        let a = TXVertex(pos: SIMD2(x0, y0), uv: SIMD2(u0.x, u0.y), color: c, params: params)
        let b = TXVertex(pos: SIMD2(x1, y0), uv: SIMD2(u1.x, u0.y), color: c, params: params)
        let cc = TXVertex(pos: SIMD2(x1, y1), uv: SIMD2(u1.x, u1.y), color: c, params: params)
        let d = TXVertex(pos: SIMD2(x0, y1), uv: SIMD2(u0.x, u1.y), color: c, params: params)
        verts.append(a); verts.append(b); verts.append(cc)
        verts.append(a); verts.append(cc); verts.append(d)
    }

    private func tri(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ c: SIMD4<Float>) {
        let z = SIMD2<Float>(0, 0), params = SIMD4<Float>(0, 0, 0, 0)
        verts.append(TXVertex(pos: p0, uv: z, color: c, params: params))
        verts.append(TXVertex(pos: p1, uv: z, color: c, params: params))
        verts.append(TXVertex(pos: p2, uv: z, color: c, params: params))
    }

    private func vline(_ x: Float, _ y0: Float, _ y1: Float, _ w: Float, _ c: SIMD4<Float>) {
        quad(x - w / 2, y0, x + w / 2, y1, c)
    }

    enum Align { case left, center, right }

    /// Draws text whose cell top is at `y`; `size` is the cell height in pixels.
    private func text(_ s: String, x: Float, y: Float, size: Float, color: SIMD4<Float>,
                      align: Align = .center, offset: Float = 0) {
        let w = atlas.width(s, size: size)
        var pen: Float
        switch align {
        case .left: pen = x + offset
        case .center: pen = x - w / 2
        case .right: pen = x - w
        }
        for ch in s {
            guard let g = atlas.glyph(ch) else { pen += size * 0.5; continue }
            if ch != " " {
                let gx = pen - g.bearing * size
                quad(gx, y, gx + size * atlas.cellAspect, y + size, color, mode: 1,
                     u0: SIMD2(g.u0, g.v0), u1: SIMD2(g.u1, g.v1))
            }
            pen += g.advance * size
        }
    }
}
