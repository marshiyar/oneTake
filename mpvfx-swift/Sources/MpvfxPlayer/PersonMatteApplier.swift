// Person matte in the painter: a cached matte frame multiplies the layer's alpha, shared by preview and export
// (PreviewPainter.drawContent). The matte is upscaled bilinearly to the picture, then shrunk or grown, softened and
// optionally inverted, all in picture pixels.
import Foundation
import MpvfxCanvas
import MpvfxShared

/// The matte one layer is drawn with: the cached frame at the layer's source frame and the effect's edge controls.
public struct PreviewMatte: Equatable, Sendable {
    /// Which cache frame this is (file and frame index); layers compare by it, not by the pixels.
    public var identity: String
    public var frame: PersonMatteFrame
    public var shrink: Double
    public var soften: Double
    public var invert: Bool
    public init(identity: String, frame: PersonMatteFrame, shrink: Double = 0, soften: Double = 0, invert: Bool = false) {
        self.identity = identity; self.frame = frame; self.shrink = shrink; self.soften = soften; self.invert = invert
    }
    public static func == (a: PreviewMatte, b: PreviewMatte) -> Bool {
        a.identity == b.identity && a.shrink == b.shrink && a.soften == b.soften && a.invert == b.invert
    }
}

public enum PersonMatteApplier {
    /// `image` with its alpha multiplied by the matte's coverage at every pixel.
    public static func apply(_ matte: PreviewMatte, to image: CanvasImage) -> CanvasImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return image }
        var coverage = upscale(matte.frame, width: w, height: h)
        if matte.shrink != 0 { coverage = morph(coverage, width: w, height: h, radius: matte.shrink) }
        if matte.soften > 0 {
            let blurred = MaskCoverageRasterizer.gaussianBlur(coverage.map(Double.init), width: w, height: h, sigma: matte.soften / 2)
            coverage = blurred.map { Float($0) }
        }
        var rgba = image.rgba
        let invert = matte.invert
        rgba.withUnsafeMutableBufferPointer { px in
            for i in 0..<(w * h) {
                var c = coverage[i]
                if invert { c = 1 - c }
                let a = Float(px[i * 4 + 3]) * min(1, max(0, c))
                px[i * 4 + 3] = UInt8(min(255, max(0, a.rounded())))
            }
        }
        return CanvasImage(width: w, height: h, rgba: rgba)
    }

    /// Bilinear upscale of 8-bit coverage to `width` x `height`, 0...1.
    static func upscale(_ frame: PersonMatteFrame, width: Int, height: Int) -> [Float] {
        let mw = frame.width, mh = frame.height
        var out = [Float](repeating: 0, count: width * height)
        guard mw > 0, mh > 0, frame.alpha.count == mw * mh else { return out }
        var x0 = [Int](repeating: 0, count: width), x1 = x0, fx = [Float](repeating: 0, count: width)
        for x in 0..<width {
            let sx = min(Double(mw - 1), max(0, (Double(x) + 0.5) * Double(mw) / Double(width) - 0.5))
            x0[x] = Int(sx); x1[x] = min(mw - 1, x0[x] + 1); fx[x] = Float(sx - Double(x0[x]))
        }
        frame.alpha.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let sy = min(Double(mh - 1), max(0, (Double(y) + 0.5) * Double(mh) / Double(height) - 0.5))
                    let y0 = Int(sy), y1 = min(mh - 1, y0 + 1), fy = Float(sy - Double(y0))
                    let r0 = y0 * mw, r1 = y1 * mw
                    for x in 0..<width {
                        let a = Float(src[r0 + x0[x]]) * (1 - fx[x]) + Float(src[r0 + x1[x]]) * fx[x]
                        let b = Float(src[r1 + x0[x]]) * (1 - fx[x]) + Float(src[r1 + x1[x]]) * fx[x]
                        dst[y * width + x] = (a * (1 - fy) + b * fy) / 255
                    }
                }
            }
        }
        return out
    }

    /// Moves the matte's edge inward (`radius` > 0, a minimum filter) or outward (< 0, a maximum filter) by `|radius|` px; a
    /// fractional radius blends the two whole radii around it. The window is square, so along the axes the edge moves
    /// by exactly the radius.
    static func morph(_ input: [Float], width: Int, height: Int, radius: Double) -> [Float] {
        let erode = radius > 0
        let r = abs(radius)
        let whole = Int(r.rounded(.down)), frac = Float(r - Double(whole))
        let low = whole == 0 ? input : window(input, width: width, height: height, radius: whole, erode: erode)
        guard frac > 0.01 else { return low }
        let high = window(input, width: width, height: height, radius: whole + 1, erode: erode)
        var out = low
        for i in out.indices { out[i] = low[i] + (high[i] - low[i]) * frac }
        return out
    }

    /// Separable min or max over a (2 radius + 1) square. Both passes run along rows so the inner loops are contiguous.
    private static func window(_ input: [Float], width: Int, height: Int, radius: Int, erode: Bool) -> [Float] {
        var horizontal = input
        input.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width {
                        var v = src[row + x]
                        let lo = max(0, x - radius), hi = min(width - 1, x + radius)
                        if erode { for k in lo...hi where src[row + k] < v { v = src[row + k] } }
                        else { for k in lo...hi where src[row + k] > v { v = src[row + k] } }
                        dst[row + x] = v
                    }
                }
            }
        }
        var out = horizontal
        horizontal.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let lo = max(0, y - radius), hi = min(height - 1, y + radius)
                    for k in lo...hi where k != y {
                        let from = k * width, to = y * width
                        if erode { for x in 0..<width where src[from + x] < dst[to + x] { dst[to + x] = src[from + x] } }
                        else { for x in 0..<width where src[from + x] > dst[to + x] { dst[to + x] = src[from + x] } }
                    }
                }
            }
        }
        return out
    }
}
