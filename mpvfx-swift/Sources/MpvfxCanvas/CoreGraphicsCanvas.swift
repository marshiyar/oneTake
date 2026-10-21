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
#if canImport(CoreGraphics) && canImport(CoreText)
// Core Graphics + Core Text backend (macOS shell).
import CoreGraphics
import CoreText
import Foundation

/// Expects a y-down context (AppKit flipped NSView / CGContext pre-flipped by the host).
public final class CoreGraphicsCanvas: CanvasContext {
    public let ctx: CGContext
    public init(context: CGContext) { ctx = context }

    public var deviceScale: Double {
        let t = ctx.userSpaceToDeviceSpaceTransform
        return max(1, Double((t.a * t.a + t.b * t.b).squareRoot()))
    }

    /// A small offscreen y-down bitmap canvas, for text measurement outside of a draw pass.
    public static func offscreen(width: Int = 4, height: Int = 4) -> CoreGraphicsCanvas? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
        return CoreGraphicsCanvas(context: c)
    }

    public func save() { ctx.saveGState() }
    public func restore() { ctx.restoreGState() }
    public func translate(_ dx: Double, _ dy: Double) { ctx.translateBy(x: dx, y: dy) }
    public func scale(_ sx: Double, _ sy: Double) { ctx.scaleBy(x: sx, y: sy) }
    public func rotate(_ radians: Double) { ctx.rotate(by: radians) }

    private func cgPath(_ p: CanvasPath) -> CGPath {
        let m = CGMutablePath()
        for e in p.elements {
            switch e {
            case .move(let a): m.move(to: CGPoint(x: a.x, y: a.y))
            case .line(let a): m.addLine(to: CGPoint(x: a.x, y: a.y))
            case .curve(let c1, let c2, let a):
                m.addCurve(to: CGPoint(x: a.x, y: a.y), control1: CGPoint(x: c1.x, y: c1.y), control2: CGPoint(x: c2.x, y: c2.y))
            case .close: m.closeSubpath()
            }
        }
        return m
    }
    private func cg(_ c: CanvasColor) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    public func clip(_ path: CanvasPath) { ctx.addPath(cgPath(path)); ctx.clip() }
    public func fill(_ path: CanvasPath, _ color: CanvasColor) { ctx.setFillColor(cg(color)); ctx.addPath(cgPath(path)); ctx.fillPath() }
    public func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {
        ctx.setStrokeColor(cg(color)); ctx.setLineWidth(style.width)
        ctx.setLineDash(phase: 0, lengths: style.dash.map { CGFloat($0) })
        ctx.addPath(cgPath(path)); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private struct FontKey: Hashable { let family: String; let size: Double; let weight: Int; let italic: Bool }
    nonisolated(unsafe) private static var fonts: [FontKey: CTFont] = [:]

    /// "Sans" and "Monospace" (the names the views use, as on Linux/Pango) map to the system UI and
    /// monospaced fonts; any other family is looked up by name.
    static func font(_ f: CanvasFont) -> CTFont {
        var w: Int
        switch f.weight { case .regular: w = 0; case .medium: w = 1; case .semibold: w = 2; case .bold: w = 3 }
        var weight: CGFloat = [0.0, 0.23, 0.3, 0.4][w]   // NSFontWeight regular/medium/semibold/bold
        if let nw = f.numericWeight {
            // Weight 100…900 -> NSFontWeight (thin … black).
            let table: [CGFloat] = [-0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62]
            let i = max(0, min(8, Int((Double(nw) / 100).rounded()) - 1))
            weight = table[i]; w = 100 + nw
        }
        let key = FontKey(family: f.family, size: f.size, weight: w, italic: f.italic)
        if let cached = fonts[key] { return cached }
        let base: CTFont
        switch f.family.lowercased() {
        case "sans", "sans-serif", "system-ui":
            base = CTFontCreateUIFontForLanguage(.system, f.size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, f.size, nil)
        case "monospace", "mono":
            base = CTFontCreateWithName("Menlo" as CFString, f.size, nil)
        default:
            base = CTFontCreateWithName(f.family as CFString, f.size, nil)
        }
        var font = base
        if w != 0 {
            let traits: [String: Any] = [kCTFontWeightTrait as String: weight]
            let desc = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base),
                                                                [kCTFontTraitsAttribute as String: traits] as CFDictionary)
            font = CTFontCreateWithFontDescriptor(desc, f.size, nil)
        }
        if f.italic, let slanted = CTFontCreateCopyWithSymbolicTraits(font, f.size, nil, .traitItalic, .traitItalic) { font = slanted }
        fonts[key] = font
        return font
    }

    private func line(_ text: String, _ font: CanvasFont, _ color: CanvasColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): Self.font(font),
                                                    .init(kCTForegroundColorAttributeName as String): cg(color)]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }
    public func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {
        let l = line(text, font, color)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // y-down context
        ctx.textPosition = CGPoint(x: origin.x, y: origin.y + font.size * 0.8)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }
    public func measureText(_ text: String, font: CanvasFont) -> CanvasSize {
        let b = CTLineGetTypographicBounds(line(text, font, CanvasColor(r: 0, g: 0, b: 0)), nil, nil, nil)
        return CanvasSize(b, font.size)
    }
    public func drawImage(_ image: CanvasImage, in rect: CanvasRect) { drawImage(image, in: rect, opacity: 1) }
    public func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double) {
        guard opacity > 0, image.width > 0, image.height > 0,
              let cgImage = image.drawable(CoreGraphicsImage.self, make: { CoreGraphicsImage(image) })?.image else { return }
        ctx.saveGState()
        if opacity < 1 { ctx.setAlpha(opacity) }
        ctx.translateBy(x: rect.x, y: rect.maxY); ctx.scaleBy(x: 1, y: -1)   // CGImage draws y-up
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }
}

/// A `CanvasImage` as a CGImage over one copy of its straight-alpha sRGB pixels, made once per image and drawn by
/// every draw of it (and of its copies).
public final class CoreGraphicsImage: CanvasDrawable {
    public let image: CGImage
    public let byteCount: Int

    /// Nil when Core Graphics cannot make the image.
    init?(_ image: CanvasImage) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(image.rgba) as CFData),
              let cgImage = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        self.image = cgImage
        byteCount = image.rgba.count
    }
}
#endif
