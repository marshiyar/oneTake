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

/// Draws a text layer that has a look (outlines, drop shadow): the letters are rasterized once by the platform's
/// text stack, `TextLookCompositor` builds shadow, outlines and fill from their coverage, and the result is drawn
/// as one image. Preview and export both come through `PreviewPainter`, so they cannot differ.
enum TextLookRenderer {
    /// The composited bitmap and where it goes, relative to the text box's top-left, in view units.
    struct Rendered { let image: CanvasImage; let rect: CanvasRect }

    /// Bitmaps beyond this many pixels are not built (an outline plus a shadow at a huge size): the layer then
    /// draws without its look and the reason is logged.
    static let maxPixels = 24_000_000

    private struct Key: Hashable { let text: NativeClipText; let width: Int; let height: Int; let scale: Double }
    private static let cache = LookCache()

    /// The look drawn for `text` in a box of `box` view units, with `s` view units per canvas px and `deviceScale`
    /// device pixels per view unit. Nil when the text has no (supported) look or this platform cannot rasterize text.
    static func render(_ text: NativeClipText, box: CanvasRect, scale s: Double, deviceScale k: Double) -> Rendered? {
        guard let look = text.look, look.isSupported, !look.isEmpty else { return nil }
        let k = max(k, 1e-3)
        let pxPerCanvas = s * k
        let width = Int((box.width * k).rounded(.up)), height = Int((box.height * k).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        let bands = bandReaches(look, pxPerCanvas: pxPerCanvas)
        let shadow = look.shadow.flatMap { sh in CanvasColor(hex: sh.color).map {
            TextLookCompositor.Shadow(dx: Int((sh.resolvedX * pxPerCanvas).rounded()), dy: Int((sh.resolvedY * pxPerCanvas).rounded()),
                                      blur: sh.resolvedBlur * pxPerCanvas, color: $0)
        } }
        let outlineReach = bands.last?.reach ?? 0
        let shadowReach = shadow.map { Double(max(abs($0.dx), abs($0.dy))) + $0.blur * 1.5 } ?? 0
        let inset = Int((outlineReach + shadowReach).rounded(.up)) + 2
        guard (width + 2 * inset) * (height + 2 * inset) <= maxPixels else {
            FileHandle.standardError.write(Data("[MpVFX] text look skipped: \(width + 2 * inset) x \(height + 2 * inset) px is too large\n".utf8))
            return nil
        }
        let key = Key(text: text, width: width, height: height, scale: pxPerCanvas)
        let rect = CanvasRect(x: box.x - Double(inset) / k, y: box.y - Double(inset) / k,
                              width: Double(width + 2 * inset) / k, height: Double(height + 2 * inset) / k)
        if let hit = cache.get(key) { return Rendered(image: hit, rect: rect) }
        var letters = text
        letters.color = NativeClipText.newLayerColor; letters.look = nil
        guard let rgba = NativeTextRendering.rasterize(letters, width: width, height: height, scale: pxPerCanvas, inset: inset) else { return nil }
        let coverage = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        let fill = CanvasColor.documentColor(text.resolvedColor)
        let out = TextLookCompositor.compose(coverage: coverage, width: width + 2 * inset, height: height + 2 * inset,
                                             fill: fill, bands: bands, shadow: shadow)
        let image = CanvasImage(width: width + 2 * inset, height: height + 2 * inset, rgba: out)
        cache.put(key, image)
        return Rendered(image: image, rect: rect)
    }

    /// The outline bands in device px. The second outline starts where the first ends; a `center` outline straddles
    /// the letter edge, so only its outer half shows (the fill covers the rest).
    static func bandReaches(_ look: NativeTextLook, pxPerCanvas: Double) -> [TextLookCompositor.Band] {
        var reach = 0.0
        var out: [TextLookCompositor.Band] = []
        for o in look.outlines ?? [] where o.width > 0 {
            reach += o.width * pxPerCanvas * (o.resolvedPosition == "center" ? 0.5 : 1)
            if let color = CanvasColor(hex: o.color), color.a > 0 { out.append(.init(reach: reach, color: color)) }
        }
        return out
    }
}

/// A few recent looks, so a still title is not rebuilt on every draw.
private final class LookCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(key: AnyHashable, image: CanvasImage)] = []
    static let capacity = 6

    func get<K: Hashable>(_ key: K) -> CanvasImage? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.key == AnyHashable(key) }?.image
    }

    func put<K: Hashable>(_ key: K, _ image: CanvasImage) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.key == AnyHashable(key) }
        entries.append((AnyHashable(key), image))
        if entries.count > Self.capacity { entries.removeFirst() }
    }
}
