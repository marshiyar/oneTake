//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (c) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
import Foundation
import MpvfxCanvas
import MpvfxShared

/// A layer's resolved canvas fill (clip fill, else the project's): what is drawn behind a picture that does not
/// cover the frame. Image fills are separate layers (`PreviewLayer.fillCutout`), so they decode like any picture.
public struct PreviewFill: Equatable, Sendable {
    public struct Stop: Equatable, Sendable {
        public var offset: Double
        public var color: CanvasColor
    }
    public enum Kind: Equatable, Sendable {
        case color(CanvasColor)
        case gradient(angle: Double, stops: [Stop])
        /// The clip's own picture, scaled to cover the frame, blurred (`blur` is a sigma in canvas px) and darkened.
        case blur(blur: Double, darken: Double)
    }
    public var kind: Kind

    /// The fill a document fill draws: nil for none, inherit, an unsupported one or an image (a layer of its own).
    public init?(_ fill: NativeFill?) {
        guard let fill, fill.isSupported else { return nil }
        switch fill.kind {
        case "color":
            guard let c = fill.color.flatMap(CanvasColor.init(hex:)) else { return nil }
            kind = .color(c)
        case "gradient":
            let stops = fill.stops.compactMap { s in CanvasColor(hex: s.color).map { Stop(offset: s.offset, color: $0) } }
            guard stops.count >= 2 else { return nil }
            kind = .gradient(angle: fill.resolvedAngle, stops: stops)
        case "blur":
            kind = .blur(blur: fill.resolvedBlur / 2, darken: fill.resolvedDarken)
        default: return nil
        }
    }
}

/// Where the picture of the clip an image fill sits behind lands, so the fill layer leaves it uncovered.
public struct PreviewFillCutout: Equatable, Sendable {
    public var box: CanvasRect
    public var crop: CropInsets
    public var fit: NativeMediaFit?
    /// The picture's width over height when known (nil: the picture is taken to fill its box).
    public var aspect: Double?
    public var rotation: Double
    public var scaleX: Double, scaleY: Double
}

/// Draws canvas fills and builds their pixels.
enum CanvasFillPainter {
    /// The convex quad (view px, clockwise) a picture covers once the layer's scale and rotation about the box centre
    /// are applied; `image` is the picture's size when known.
    static func coveredQuad(box: CanvasRect, crop: CropInsets, fit: NativeMediaFit?, picture: (width: Int, height: Int)?,
                            rotation: Double, scaleX: Double, scaleY: Double, frame: CanvasRect, scale s: Double) -> [CanvasPoint] {
        var placed = box
        if let p = picture { placed = PreviewPainter.mediaRect(imageWidth: p.width, imageHeight: p.height, in: box, fit: fit) }
        let visible = CanvasRect(x: box.x + crop.left, y: box.y + crop.top, width: max(0, box.width - crop.left - crop.right),
                                 height: max(0, box.height - crop.top - crop.bottom))
        let x0 = max(placed.x, visible.x), y0 = max(placed.y, visible.y)
        let x1 = min(placed.maxX, visible.maxX), y1 = min(placed.maxY, visible.maxY)
        let r = PreviewPainter.toView(CanvasRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0)), frame: frame, scale: s)
        let b = PreviewPainter.toView(box, frame: frame, scale: s)
        let cx = b.x + b.width / 2, cy = b.y + b.height / 2
        let a = rotation * .pi / 180, cs = cos(a), sn = sin(a)
        return [CanvasPoint(r.x, r.y), CanvasPoint(r.maxX, r.y), CanvasPoint(r.maxX, r.maxY), CanvasPoint(r.x, r.maxY)].map { p in
            let dx = (p.x - cx) * scaleX, dy = (p.y - cy) * scaleY
            return CanvasPoint(cx + dx * cs - dy * sn, cy + dx * sn + dy * cs)
        }
    }

    static func area(_ q: [CanvasPoint]) -> Double {
        var a = 0.0
        for i in q.indices { let p = q[i], n = q[(i + 1) % q.count]; a += p.x * n.y - n.x * p.y }
        return a / 2
    }

    /// True when `quad` covers `rect` (to half a pixel): nothing of the fill would show.
    static func covers(_ quad: [CanvasPoint], _ rect: CanvasRect) -> Bool {
        let sign: Double = area(quad) >= 0 ? 1 : -1
        guard abs(area(quad)) > 0 else { return false }
        let corners = [CanvasPoint(rect.x, rect.y), CanvasPoint(rect.maxX, rect.y), CanvasPoint(rect.maxX, rect.maxY), CanvasPoint(rect.x, rect.maxY)]
        for p in corners {
            for i in quad.indices {
                let a = quad[i], b = quad[(i + 1) % quad.count]
                let len = max(1e-9, ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot())
                if sign * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) / len < -0.5 { return false }
            }
        }
        return true
    }

    /// The canvas rect with the picture's quad cut out (opposite winding), for a clip.
    static func holePath(canvas: CanvasRect, quad: [CanvasPoint]) -> CanvasPath {
        var p = CanvasPath(); p.addRect(canvas)
        let q = area(quad) > 0 ? Array(quad.reversed()) : quad
        guard let first = q.first else { return p }
        p.move(to: first); for pt in q.dropFirst() { p.line(to: pt) }; p.close()
        return p
    }

    /// Draws `fill` over the canvas except where the picture (`quad`) lands, behind it. `picture` is the clip's decoded
    /// frame (the blurred copy's source).
    static func draw(_ fill: PreviewFill, quad: [CanvasPoint], picture: CanvasImage?, opacity: Double, canvas: CanvasRect,
                     scale: Double, on c: CanvasContext) {
        guard canvas.width > 0, canvas.height > 0, !covers(quad, canvas) else { return }
        c.withState {
            c.clip(holePath(canvas: canvas, quad: quad))
            switch fill.kind {
            case .color(let col):
                c.fillRect(canvas, col.withAlpha(col.a * opacity))
            case .gradient(let angle, let stops):
                let w = max(1, Int((canvas.width * c.deviceScale).rounded())), h = max(1, Int((canvas.height * c.deviceScale).rounded()))
                if let img = gradientImage(angle: angle, stops: stops, width: w, height: h) { c.drawImage(img, in: canvas, opacity: opacity) }
            case .blur(let sigma, let darken):
                guard let picture else { return }
                let k = c.deviceScale / 4
                let w = max(1, Int((canvas.width * k).rounded())), h = max(1, Int((canvas.height * k).rounded()))
                if let img = blurredCopy(picture, width: w, height: h, sigma: sigma * scale * c.deviceScale / 4, darken: darken) {
                    c.drawImage(img, in: canvas, opacity: opacity)
                }
            }
        }
    }

    // MARK: Pixels

    private static let cache = FillImageCache()

    /// A linear gradient over `width` x `height` px: the CSS gradient line at `angle` degrees (0 points up, 90 right,
    /// 180 down), stops interpolated in straight sRGB. Nil beyond the size a frame can have.
    static func gradientImage(angle: Double, stops: [PreviewFill.Stop], width: Int, height: Int) -> CanvasImage? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 36_000_000, stops.count >= 2 else { return nil }
        let key = "g|\(angle)|\(stops.map { "\($0.offset),\($0.color.r),\($0.color.g),\($0.color.b),\($0.color.a)" }.joined(separator: ";"))|\(width)x\(height)"
        if let hit = cache.get(key) { return hit }
        let a = angle * .pi / 180
        let dx = sin(a), dy = -cos(a)
        let length = abs(Double(width) * dx) + abs(Double(height) * dy)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let sorted = stops.sorted { $0.offset < $1.offset }
        // Lookup table along the line keeps the per-pixel work to one index.
        let steps = 2048
        var lut = [(UInt8, UInt8, UInt8, UInt8)](repeating: (0, 0, 0, 0), count: steps + 1)
        for i in 0...steps { lut[i] = color(at: Double(i) / Double(steps), in: sorted) }
        let cx = Double(width) / 2, cy = Double(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                let t = length > 0 ? ((Double(x) + 0.5 - cx) * dx + (Double(y) + 0.5 - cy) * dy) / length + 0.5 : 0
                let c = lut[max(0, min(steps, Int((t * Double(steps)).rounded())))]
                let i = (y * width + x) * 4
                out[i] = c.0; out[i + 1] = c.1; out[i + 2] = c.2; out[i + 3] = c.3
            }
        }
        let image = CanvasImage(width: width, height: height, rgba: out)
        cache.put(key, image)
        return image
    }

    private static func color(at t: Double, in stops: [PreviewFill.Stop]) -> (UInt8, UInt8, UInt8, UInt8) {
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        var lo = stops[0], hi = stops[stops.count - 1]
        if t <= lo.offset { hi = lo } else if t >= hi.offset { lo = hi } else {
            for i in 1..<stops.count where t <= stops[i].offset { lo = stops[i - 1]; hi = stops[i]; break }
        }
        let f = hi.offset > lo.offset ? (t - lo.offset) / (hi.offset - lo.offset) : 0
        let a = lo.color, b = hi.color
        return (byte(a.r + (b.r - a.r) * f), byte(a.g + (b.g - a.g) * f), byte(a.b + (b.b - a.b) * f), byte(a.a + (b.a - a.a) * f))
    }

    /// `picture` scaled to cover `width` x `height` (area-averaged, centred), blurred with a Gaussian of `sigma` px
    /// (three box passes, edges repeated so the mean colour holds) and multiplied by `1 - darken`. Opaque.
    static func blurredCopy(_ picture: CanvasImage, width: Int, height: Int, sigma: Double, darken: Double) -> CanvasImage? {
        guard width > 0, height > 0, picture.width > 0, picture.height > 0, width * height <= 36_000_000 else { return nil }
        let scale = max(Double(width) / Double(picture.width), Double(height) / Double(picture.height))
        let srcW = Double(width) / scale, srcH = Double(height) / scale
        let x0 = (Double(picture.width) - srcW) / 2, y0 = (Double(picture.height) - srcH) / 2
        let n = max(1, min(8, Int((1 / scale).rounded(.up))))
        var chans = [[Float]](repeating: [Float](repeating: 0, count: width * height), count: 3)
        let src = picture.rgba
        for y in 0..<height {
            for x in 0..<width {
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0..<n {
                    let sy = min(picture.height - 1, max(0, Int(y0 + (Double(y) + (Double(j) + 0.5) / Double(n)) / scale)))
                    for i in 0..<n {
                        let sx = min(picture.width - 1, max(0, Int(x0 + (Double(x) + (Double(i) + 0.5) / Double(n)) / scale)))
                        let o = (sy * picture.width + sx) * 4
                        r += Double(src[o]); g += Double(src[o + 1]); b += Double(src[o + 2])
                    }
                }
                let k = 1 / Double(n * n)
                let idx = y * width + x
                chans[0][idx] = Float(r * k); chans[1][idx] = Float(g * k); chans[2][idx] = Float(b * k)
            }
        }
        let keep = Float(max(0, min(1, 1 - darken)))
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for c in 0..<3 {
            var plane = chans[c]
            if sigma >= 0.25 {
                for size in TextLookCompositor.boxSizes(sigma: sigma) {
                    plane = boxBlurClamped(plane, width: width, height: height, radius: (size - 1) / 2, horizontal: true)
                    plane = boxBlurClamped(plane, width: width, height: height, radius: (size - 1) / 2, horizontal: false)
                }
            }
            for i in 0..<width * height { out[i * 4 + c] = UInt8(max(0, min(255, (plane[i] * keep).rounded()))) }
        }
        return CanvasImage(width: width, height: height, rgba: out)
    }

    private static func boxBlurClamped(_ a: [Float], width: Int, height: Int, radius r: Int, horizontal: Bool) -> [Float] {
        guard r > 0 else { return a }
        var out = [Float](repeating: 0, count: a.count)
        let lines = horizontal ? height : width, length = horizontal ? width : height
        let norm = 1 / Float(2 * r + 1)
        for l in 0..<lines {
            func at(_ i: Int) -> Float {
                let j = max(0, min(length - 1, i))
                return horizontal ? a[l * width + j] : a[j * width + l]
            }
            var sum: Float = 0
            for i in -r...r { sum += at(i) }
            for i in 0..<length {
                if horizontal { out[l * width + i] = sum * norm } else { out[i * width + l] = sum * norm }
                sum += at(i + r + 1) - at(i - r)
            }
        }
        return out
    }
}

/// The last gradient pictures, so a still frame is not rebuilt on every draw.
private final class FillImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(key: String, image: CanvasImage)] = []

    func get(_ key: String) -> CanvasImage? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.key == key }?.image
    }

    func put(_ key: String, _ image: CanvasImage) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.append((key, image))
        if entries.count > 3 { entries.removeFirst() }
    }
}
