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
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import MpvfxCanvas
import MpvfxColor
import MpvfxShared
import OneTakeMedia

/// `CanvasContext` on the media engine's software canvas (`RasterSurface`). Export frames are painted on it by the
/// same `PreviewPainter` code that draws the preview, so the two cannot drift apart. Text runs are rendered by the
/// platform's text stack (`TextBitmap`) and drawn as images through the current transform.
public final class RasterCanvas: CanvasContext {
    public let surface: RasterSurface
    /// The first drawing failure since the last `clear` (the protocol's draw calls cannot throw); export checks it
    /// after each frame so a failed draw is reported instead of silently missing from the file.
    public private(set) var drawError: MediaError?
    private var transform = RasterTransform.identity
    private var saved: [RasterTransform] = []

    public init(width: Int, height: Int) throws {
        surface = try RasterSurface(width: width, height: height)
    }

    /// Fills the whole surface (ignores transform and clip) and resets the state stack.
    public func clear(_ color: CanvasColor) {
        surface.clear(RasterColor(r: color.r, g: color.g, b: color.b, a: color.a))
        transform = .identity; saved = []; drawError = nil
    }

    public func save() { saved.append(transform); surface.save() }

    public func restore() {
        if let t = saved.popLast() { transform = t }
        surface.restore()
    }

    public func translate(_ dx: Double, _ dy: Double) {
        apply(RasterTransform.translation(dx, dy))
    }

    public func scale(_ sx: Double, _ sy: Double) {
        var t = RasterTransform(); t.a = sx; t.d = sy
        apply(t)
    }

    public func rotate(_ radians: Double) {
        var t = RasterTransform(); t.a = cos(radians); t.b = sin(radians); t.c = -sin(radians); t.d = cos(radians)
        apply(t)
    }

    public func clip(_ path: CanvasPath) { surface.clip(Self.elements(path)) }

    public func fill(_ path: CanvasPath, _ color: CanvasColor) {
        surface.fill(Self.elements(path), RasterColor(r: color.r, g: color.g, b: color.b, a: color.a))
    }

    public func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {
        surface.stroke(Self.elements(path), RasterStroke(width: style.width, dash: style.dash),
                       RasterColor(r: color.r, g: color.g, b: color.b, a: color.a))
    }

    public func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {
        guard !text.isEmpty else { return }
        let rendered: TextBitmap.Rendered?
        do { rendered = try TextBitmap.render(text, font: font, color: color, scale: deviceScale) } catch {
            if drawError == nil { drawError = MediaError(kind: .internalError, message: "text \"\(text)\": \((error as? MediaError)?.message ?? "it could not be drawn")") }
            return
        }
        guard let bitmap = rendered else { return }
        draw(RasterImage(rgba: bitmap.image.rgba, width: bitmap.image.width, height: bitmap.image.height),
             in: RasterRect(x: origin.x - bitmap.pad, y: origin.y - bitmap.pad,
                            width: Double(bitmap.image.width) / bitmap.scale, height: Double(bitmap.image.height) / bitmap.scale),
             opacity: 1)
    }

    public func measureText(_ text: String, font: CanvasFont) -> CanvasSize {
        do { return try TextBitmap.measure(text, font: font) } catch {
            if drawError == nil { drawError = MediaError(kind: .internalError, message: "text \"\(text)\": \((error as? MediaError)?.message ?? "it could not be drawn")") }
            return CanvasSize(0, font.size)
        }
    }

    public func drawImage(_ image: CanvasImage, in rect: CanvasRect) { drawImage(image, in: rect, opacity: 1) }

    public func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double) {
        guard opacity > 0, image.width > 0, image.height > 0 else { return }
        draw(RasterImage(rgba: image.rgba, width: image.width, height: image.height),
             in: RasterRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), opacity: opacity)
    }

    private func draw(_ image: RasterImage, in rect: RasterRect, opacity: Double) {
        do {
            try surface.drawImage(image, in: rect, opacity: opacity)
        } catch let e as MediaError {
            if drawError == nil { drawError = e }
        } catch {
            if drawError == nil { drawError = MediaError(kind: .internalError, message: (error as? MediaError)?.message ?? "The frame could not be drawn.") }
        }
    }

    /// Device pixels per user unit: the square root of the transform's area scale.
    public var deviceScale: Double { max(1e-6, abs(transform.a * transform.d - transform.b * transform.c).squareRoot()) }

    /// A transparent scratch surface of this canvas's size, kept between blended layers.
    private var blendScratch: RasterCanvas?

    /// Paints one layer with a blend mode: `paint` draws it alone on a transparent scratch surface (identity
    /// transform, no clip), then each pixel is blended over what this canvas holds (`BlendShader`, the CPU reference
    /// of the GPU blend functions) and written back. Call it where no clip is active. False when the scratch surface
    /// or the blend could not be made (the failure is in `drawError`); nothing is drawn then.
    @discardableResult
    public func drawBlended(_ mode: NativeBlendMode, paint: (RasterCanvas) -> Void) -> Bool {
        let w = surface.width, h = surface.height
        do {
            let scratch = try blendScratch ?? RasterCanvas(width: w, height: h)
            blendScratch = scratch
            scratch.clear(.transparent)
            paint(scratch)
            if let e = scratch.drawError { throw e }
            guard let mixed = BlendShader.blend(scratch.image().rgba, over: surface.rgba(), width: w, height: h, mode: mode) else {
                throw MediaError(kind: .internalError, message: "blend: the surface could not be read")
            }
            surface.save()
            surface.setTransform(.identity)
            surface.clear(RasterColor(r: 0, g: 0, b: 0, a: 0))
            try surface.drawImage(RasterImage(rgba: mixed, width: w, height: h), in: RasterRect(x: 0, y: 0, width: Double(w), height: Double(h)))
            surface.restore()
            return true
        } catch {
            if drawError == nil { drawError = (error as? MediaError) ?? MediaError(kind: .internalError, message: (error as? MediaError)?.message ?? "The frame could not be drawn.") }
            return false
        }
    }

    /// The painted frame as straight-alpha RGBA8.
    public func image() -> CanvasImage {
        CanvasImage(width: surface.width, height: surface.height, rgba: surface.rgba())
    }

    private func apply(_ t: RasterTransform) {
        surface.concat(t)
        let m = transform
        var r = RasterTransform()
        r.a = m.a * t.a + m.c * t.b; r.b = m.b * t.a + m.d * t.b
        r.c = m.a * t.c + m.c * t.d; r.d = m.b * t.c + m.d * t.d
        r.tx = m.a * t.tx + m.c * t.ty + m.tx; r.ty = m.b * t.tx + m.d * t.ty + m.ty
        transform = r
    }

    static func elements(_ path: CanvasPath) -> [RasterPathElement] {
        path.elements.map { e in
            switch e {
            case .move(let p): return .move(x: p.x, y: p.y)
            case .line(let p): return .line(x: p.x, y: p.y)
            case let .curve(c1, c2, p): return .curve(c1x: c1.x, c1y: c1.y, c2x: c2.x, c2y: c2.y, x: p.x, y: p.y)
            case .close: return .close
            }
        }
    }
}

/// One text run rendered offscreen by the platform's text stack (Cairo/Pango on Linux, Core Text on macOS,
/// DirectWrite on Windows). Throws when that stack fails (Windows: a Direct2D/DirectWrite/WIC call).
enum TextBitmap {
    struct Rendered { let image: CanvasImage; let scale: Double; let pad: Double }

    /// Margin in user units around the measured run, for glyph overhang (italics, descenders).
    static let margin = 2.0

    static func measure(_ text: String, font: CanvasFont) throws -> CanvasSize {
        #if os(Linux)
        return CairoImageTarget(width: 1, height: 1).canvas.measureText(text, font: font)
        #elseif os(Windows)
        return try Direct2DCanvas.measure(text, font: font)
        #elseif canImport(CoreGraphics) && canImport(CoreText)
        return CoreGraphicsCanvas.offscreen()?.measureText(text, font: font) ?? CanvasSize(0, 0)
        #else
        return CanvasSize(Double(text.count) * font.size * 0.6, font.size)
        #endif
    }

    /// The run drawn at `scale` device pixels per unit, `margin` units of padding on every side; nil when empty.
    static func render(_ text: String, font: CanvasFont, color: CanvasColor, scale: Double) throws -> Rendered? {
        let size = try measure(text, font: font)
        let k = max(scale, 1e-3)
        let w = Int(((size.width + 2 * margin) * k).rounded(.up)), h = Int(((max(size.height, font.size * 1.3) + 2 * margin) * k).rounded(.up))
        guard w > 0, h > 0, w <= 16_384, h <= 16_384 else { return nil }
        #if os(Linux)
        let target = CairoImageTarget(width: w, height: h)
        target.canvas.scale(k, k)
        target.canvas.drawText(text, at: CanvasPoint(margin, margin), font: font, color: color)
        return Rendered(image: CanvasImage(width: w, height: h, rgba: target.straightRGBA()), scale: k, pad: margin)
        #elseif os(Windows)
        let target = try Direct2DImageTarget(width: w, height: h)
        target.canvas.scale(k, k)
        target.canvas.drawText(text, at: CanvasPoint(margin, margin), font: font, color: color)
        return Rendered(image: CanvasImage(width: w, height: h, rgba: try target.straightRGBA()), scale: k, pad: margin)
        #elseif canImport(CoreGraphics) && canImport(CoreText)
        guard let c = CoreGraphicsCanvas.offscreen(width: w, height: h) else { return nil }
        c.scale(k, k)
        c.drawText(text, at: CanvasPoint(margin, margin), font: font, color: color)
        guard let rgba = straightRGBA(c.ctx, width: w, height: h) else { return nil }
        return Rendered(image: CanvasImage(width: w, height: h, rgba: rgba), scale: k, pad: margin)
        #else
        return nil
        #endif
    }

    #if canImport(CoreGraphics) && canImport(CoreText) && !os(Linux)
    /// Straight-alpha RGBA8 from a premultiplied-last 8-bit bitmap context (rows as stored: the context is y-down).
    static func straightRGBA(_ ctx: CGContext, width: Int, height: Int) -> [UInt8]? {
        guard let data = ctx.data else { return nil }
        let stride = ctx.bytesPerRow
        let src = data.bindMemory(to: UInt8.self, capacity: stride * height)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4, o = (y * width + x) * 4
                let a = Int(src[i + 3])
                guard a > 0 else { continue }
                for k in 0..<3 { out[o + k] = UInt8(min(255, (Int(src[i + k]) * 255 + a / 2) / a)) }
                out[o + 3] = UInt8(a)
            }
        }
        return out
    }
    #endif
}
