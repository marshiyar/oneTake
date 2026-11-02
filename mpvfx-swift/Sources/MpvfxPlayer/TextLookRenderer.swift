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

    private struct Key: Hashable { let text: NativeClipText; let width: Int; let height: Int; let scale: Double; let plan: TextRevealPlan? }
    private static let cache = LookCache()
    private static let inkBoundsCache = BoundsCache()

    /// The look drawn for `text` in a box of `box` view units, with `s` view units per canvas px and `deviceScale`
    /// device pixels per view unit. Nil when the text has no (supported) look or this platform cannot rasterize text.
    static func render(_ text: NativeClipText, box: CanvasRect, scale s: Double, deviceScale k: Double,
                       frame: TextRevealFrame? = nil) -> Rendered? {
        guard let look = text.look, look.isSupported, !look.isEmpty else { return nil }
        let k = max(k, 1e-3)
        let pxPerCanvas = s * k
        let width = Int((box.width * k).rounded(.up)), height = Int((box.height * k).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        let bands = bandReaches(look, pxPerCanvas: pxPerCanvas)
        // A frame in which a reveal changes the letters is built from its plan and cached by what it shows; any other
        // frame is the plain letters, cached by the text alone.
        let revealBlock = NativeTextRendering.block(text, scale: pxPerCanvas)
        let planned = frame.flatMap { TextRevealRenderer.plan(text, block: revealBlock, width: Double(width), frame: $0) }
        let shadow = look.shadow.flatMap { sh in CanvasColor(hex: sh.color).map {
            TextLookCompositor.Shadow(dx: Int((sh.resolvedX * pxPerCanvas).rounded()), dy: Int((sh.resolvedY * pxPerCanvas).rounded()),
                                      blur: sh.resolvedBlur * pxPerCanvas, color: $0)
        } }
        let glow = look.glow.flatMap { g -> TextLookCompositor.Glow? in
            guard g.isActive, let color = CanvasColor(hex: g.color) else { return nil }
            return .init(radius: g.resolvedRadius * pxPerCanvas, strength: Float(g.resolvedStrength), color: color)
        }
        let outlineReach = bands.last?.reach ?? 0
        let shadowReach = shadow.map { Double(max(abs($0.dx), abs($0.dy))) + $0.blur * 1.5 } ?? 0
        let glowReach = glow.map { $0.radius * 1.5 + 1 } ?? 0
        let plateReach = look.plate.map { max($0.resolvedPaddingX, $0.resolvedPaddingY) * pxPerCanvas + 1 } ?? 0
        var inset = Int((outlineReach + max(shadowReach, glowReach, plateReach)).rounded(.up)) + 2
        if planned != nil { inset = max(inset, TextRevealRenderer.inset(for: revealBlock)) }
        guard (width + 2 * inset) * (height + 2 * inset) <= maxPixels else {
            FileHandle.standardError.write(Data("[MpVFX] text look skipped: \(width + 2 * inset) x \(height + 2 * inset) px is too large\n".utf8))
            return nil
        }
        let key = Key(text: text, width: width, height: height, scale: pxPerCanvas, plan: planned?.plan)
        let rect = CanvasRect(x: box.x - Double(inset) / k, y: box.y - Double(inset) / k,
                              width: Double(width + 2 * inset) / k, height: Double(height + 2 * inset) / k)
        if let hit = cache.get(key) { return Rendered(image: hit, rect: rect) }
        var letters = text
        letters.color = NativeClipText.newLayerColor; letters.look = nil
        let rgba: [UInt8]?
        if let planned {
            rgba = TextRevealRenderer.pixels(letters, plan: planned.plan, units: planned.units, block: revealBlock, width: width, height: height,
                                             layoutWidth: Double(width), scale: pxPerCanvas, inset: inset)
        } else {
            rgba = NativeTextRendering.rasterize(letters, width: width, height: height, scale: pxPerCanvas, inset: inset)
        }
        guard let rgba else { return nil }
        let imageWidth = width + 2 * inset, imageHeight = height + 2 * inset
        let coverage = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        let fill = CanvasColor.documentColor(text.resolvedColor)
        var gradient: TextLookCompositor.Gradient?
        if let f = look.fill, let from = CanvasColor(hex: f.from), let to = CanvasColor(hex: f.to) {
            // The gradient spans the whole text, so a letter keeps its colour while the rest of the text arrives.
            var bounds: CanvasRect?
            let still = Key(text: text, width: width, height: height, scale: pxPerCanvas, plan: nil)
            if planned == nil {
                bounds = inkBounds(coverage, width: imageWidth, height: imageHeight)
            } else if let hit = inkBoundsCache.get(still) {
                bounds = CanvasRect(x: hit.x + Double(inset), y: hit.y + Double(inset), width: hit.width, height: hit.height)
            } else if let whole = NativeTextRendering.rasterize(letters, width: width, height: height, scale: pxPerCanvas, inset: inset) {
                bounds = inkBounds(stride(from: 3, to: whole.count, by: 4).map { whole[$0] }, width: imageWidth, height: imageHeight)
            }
            // Kept relative to the text box, so a frame with a different inset (a reveal needs room to rise) can use it.
            if let bounds { inkBoundsCache.put(still, CanvasRect(x: bounds.x - Double(inset), y: bounds.y - Double(inset), width: bounds.width, height: bounds.height)) }
            if let bounds { gradient = .init(from: from, to: to, angle: f.resolvedAngle, bounds: bounds) }
        }
        let plate = look.plate.flatMap { plateShape($0, block: revealBlock, width: Double(width), inset: Double(inset), pxPerCanvas: pxPerCanvas) }
        let out = TextLookCompositor.compose(coverage: coverage, width: imageWidth, height: imageHeight,
                                             fill: fill, bands: bands, shadow: shadow, glow: glow, plate: plate, gradient: gradient)
        let image = CanvasImage(width: imageWidth, height: imageHeight, rgba: out)
        cache.put(key, image)
        return Rendered(image: image, rect: rect)
    }

    /// The smallest rectangle (image pixels) that holds every pixel with coverage; nil for an empty picture.
    static func inkBounds(_ coverage: [UInt8], width: Int, height: Int) -> CanvasRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where coverage[y * width + x] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : CanvasRect(x: Double(minX), y: Double(minY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))
    }

    /// The plate behind the lines in image pixels (`inset` px in from the picture's edge). Follows the line boxes of
    /// the layout: a line with no text gets none, and neighbouring lines whose gap is within the vertical padding join.
    static func plateShape(_ plate: NativeTextLook.Plate, block: TextBlock, width: Double, inset: Double, pxPerCanvas px: Double)
        -> TextLookCompositor.Plate? {
        guard let color = CanvasColor(hex: plate.color), color.a > 0, let units = TextRevealRenderer.layout(block, width: width) else { return nil }
        let body = Array(block.text.utf16)
        let lines = units.lines.filter { line in
            let range = line.range.clamped(to: 0..<body.count)
            return !String(decoding: body[range], as: UTF16.self).allSatisfy(\.isWhitespace)
        }.map(\.rect)
        guard !lines.isEmpty else { return nil }
        let padX = plate.resolvedPaddingX * px, padY = plate.resolvedPaddingY * px, radius = plate.resolvedRadius * px
        func grown(_ r: CanvasRect) -> CanvasRect {
            CanvasRect(x: r.x - padX + inset, y: r.y - padY + inset, width: r.width + 2 * padX, height: r.height + 2 * padY)
        }
        if plate.resolvedMode == "block" {
            var all = lines[0]
            for r in lines.dropFirst() {
                let x = min(all.x, r.x), y = min(all.y, r.y)
                all = CanvasRect(x: x, y: y, width: max(all.maxX, r.maxX) - x, height: max(all.maxY, r.maxY) - y)
            }
            return .init(rects: [.init(rect: grown(all), radius: radius)], color: color)
        }
        var shapes = lines.map { TextLookCompositor.PlateRect(rect: grown($0), radius: radius) }
        for (upper, lower) in zip(lines, lines.dropFirst()) where lower.y - upper.maxY <= 2 * padY {
            // The two plates touch or overlap: fill the corners their rounded rectangles leave between them, across the
            // width both lines share, and a pixel past the meeting edge so a fractional edge leaves no seam.
            let left = max(upper.x, lower.x) - padX + inset, right = min(upper.maxX, lower.maxX) + padX + inset
            guard right > left else { continue }
            let join = min(grown(upper).maxY, grown(lower).y), end = max(grown(upper).maxY, grown(lower).y)
            let reach = max(radius, 1)
            let top = max(grown(upper).y, join - reach), bottom = min(grown(lower).maxY, end + reach)
            shapes.append(.init(rect: CanvasRect(x: left, y: top, width: right - left, height: bottom - top), radius: 0))
        }
        return .init(rects: shapes, color: color)
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

/// The ink bounds of recent texts, so a gradient does not rasterize the whole text again for every frame of a reveal.
private final class BoundsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(key: AnyHashable, bounds: CanvasRect)] = []
    static let capacity = 8

    func get<K: Hashable>(_ key: K) -> CanvasRect? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.key == AnyHashable(key) }?.bounds
    }

    func put<K: Hashable>(_ key: K, _ bounds: CanvasRect) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.key == AnyHashable(key) }
        entries.append((AnyHashable(key), bounds))
        if entries.count > Self.capacity { entries.removeFirst() }
    }
}
