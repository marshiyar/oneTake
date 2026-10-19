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
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One text renderer for preview and export: a text clip's values (`clip.text`) as the TextBlock the preview
/// draws on its canvas, and the same block drawn into an offscreen bitmap for export (installed as the export
/// text rasterizer at startup), so a text layer looks the same in both.
public enum NativeTextRendering {
    /// The block at `scale` output px per canvas px (font size, letter spacing and line height scale with it).
    public static func block(_ t: NativeClipText, scale s: Double) -> TextBlock {
        let font = CanvasFont(family: t.resolvedFontFamily, size: t.resolvedFontSize * s, numericWeight: t.resolvedFontWeight, italic: t.isItalic)
        return TextBlock(text: t.displayContent, font: font,
                         color: .documentColor(t.resolvedColor),
                         align: TextBlock.Align(rawValue: t.resolvedAlign) ?? .left,
                         letterSpacing: t.resolvedLetterSpacing * s, lineHeight: t.resolvedLineHeight * t.resolvedFontSize * s)
    }

    /// Straight-alpha RGBA8 (`width` × `height`) of the text drawn in a box of that size at `scale` px per canvas px;
    /// nil when this platform has no offscreen text backend or (Windows) the Direct2D target failed, which is logged.
    public static func rasterize(_ t: NativeClipText, width: Int, height: Int, scale: Double) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        let b = block(t, scale: scale)
        let box = CanvasRect(x: 0, y: 0, width: Double(width), height: Double(height))
        #if os(Linux)
        let target = CairoImageTarget(width: width, height: height)
        TextLayout.draw(b, in: box, on: target.canvas)
        return target.straightRGBA()
        #elseif os(Windows)
        // Direct2D's factory is multi-threaded: any thread may draw into its own offscreen target.
        do {
            let target = try Direct2DImageTarget(width: width, height: height)
            TextLayout.draw(b, in: box, on: target.canvas)
            return try target.straightRGBA()
        } catch {
            FileHandle.standardError.write(Data("[MpVFX] text rasterize failed: \(error)\n".utf8))
            return nil
        }
        #elseif canImport(CoreGraphics) && canImport(CoreText)
        // CoreGraphicsCanvas caches fonts in a main-thread dictionary: draw there.
        if !Thread.isMainThread { return DispatchQueue.main.sync { rasterize(t, width: width, height: height, scale: scale) } }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
        TextLayout.draw(b, in: box, on: CoreGraphicsCanvas(context: ctx))
        guard let data = ctx.data else { return nil }
        let src = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let a = src[i + 3]
            out[i + 3] = a
            guard a > 0 else { continue }
            for k in 0..<3 { out[i + k] = UInt8(min(255, (Int(src[i + k]) * 255 + Int(a) / 2) / Int(a))) }
        }
        return out
        #else
        return nil
        #endif
    }
}
