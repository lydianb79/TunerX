import AppKit
import Metal

/// Rasterises a small character set with CoreText into a mip-mapped texture so the Metal
/// scale can draw note names and numbers without leaving the GPU path.
final class GlyphAtlas {
    struct Glyph {
        var u0: Float, v0: Float, u1: Float, v1: Float
        var advance: Float     // in units of cell height
        var bearing: Float     // left padding inside the cell, in units of cell height
    }

    static let charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789♯♭+-−.,:·¢±/()% "
    let texture: MTLTexture
    let cellAspect: Float = 1
    private var glyphs: [Character: Glyph] = [:]

    init?(device: MTLDevice, queue: MTLCommandQueue) {
        let cell = 96, cols = 16
        let chars = Array(GlyphAtlas.charset)
        let rows = (chars.count + cols - 1) / cols
        let texW = cell * cols, texH = cell * rows
        guard let ctx = CGContext(data: nil, width: texW, height: texH, bitsPerComponent: 8, bytesPerRow: texW * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let font = NSFont.systemFont(ofSize: 64, weight: .semibold)
        let pad: CGFloat = 8
        var map: [Character: Glyph] = [:]

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, ch) in chars.enumerated() {
            let col = i % cols, row = i / cols
            let str = NSAttributedString(string: String(ch),
                                         attributes: [.font: font, .foregroundColor: NSColor.white])
            let sz = str.size()
            // CG origin is bottom-left; bitmap row 0 is the top of the texture.
            let x = CGFloat(col * cell) + pad
            let y = CGFloat(texH - (row + 1) * cell) + (CGFloat(cell) - sz.height) / 2
            str.draw(at: CGPoint(x: x, y: y))
            map[ch] = Glyph(u0: Float(col * cell) / Float(texW), v0: Float(row * cell) / Float(texH),
                               u1: Float((col + 1) * cell) / Float(texW), v1: Float((row + 1) * cell) / Float(texH),
                               advance: Float(sz.width) / Float(cell), bearing: Float(pad) / Float(cell))
        }
        NSGraphicsContext.restoreGraphicsState()

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: texW, height: texH,
                                                            mipmapped: true)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc), let data = ctx.data else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, texW, texH), mipmapLevel: 0, withBytes: data, bytesPerRow: texW * 4)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        texture = tex
        glyphs = map
    }

    func glyph(_ c: Character) -> Glyph? { glyphs[c] }

    func width(_ s: String, size: Float) -> Float {
        s.reduce(0) { $0 + (glyphs[$1]?.advance ?? 0.5) * size }
    }
}
