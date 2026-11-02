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

/// Where a text layer is in its clip: what a reveal needs to know to draw one frame.
public struct TextRevealFrame: Equatable, Hashable, Sendable {
    /// Frames since the clip's first frame.
    public var frame: Double
    /// The clip's length in frames.
    public var clipFrames: Double
    public var fps: Double
    public init(frame: Double, clipFrames: Double, fps: Double) { self.frame = frame; self.clipFrames = clipFrames; self.fps = fps }
}

/// What one frame of a reveal looks like: the state of each group of letters that arrive together, and the cursor.
/// Equal plans draw equal pictures, so the plan is also what a cached picture is keyed by.
struct TextRevealPlan: Hashable {
    /// Letters that share one reveal unit and one unreveal unit, so they move together.
    struct Atom: Hashable {
        /// Indices into `TextUnits.clusters`.
        var clusters: [Int]
        var opacity: Double
        var moves: [Move]
        var isIdentity: Bool { opacity == 1 && moves.isEmpty }
    }

    /// A rise (`dy` down, px) and a scale about (`cx`, `cy`), in the text box's own space.
    struct Move: Hashable { var cx: Double, cy: Double, dy: Double, scale: Double }

    struct Cursor: Hashable { var x: Double, y: Double, width: Double, height: Double }

    var atoms: [Atom]
    var cursor: Cursor?
}

/// Draws a text layer while it reveals or unreveals: the letters of each unit are drawn on their own, at the opacity,
/// offset and size the style gives them at this frame. Preview and export both come through `PreviewPainter`, so they
/// cannot differ. A frame in which nothing is hidden or moving and no cursor shows has no plan and is drawn as plain
/// text; with a cursor, a layer is drawn unit by unit until its clip ends.
enum TextRevealRenderer {
    /// How far a rising unit travels, as a multiple of the font size.
    static let riseDistance = 0.5
    /// A growing unit starts at this fraction of its size.
    static let growFrom = 0.5

    /// The plan for `text` at `frame` in a box `width` wide, with the units it was built from; nil when the text has no
    /// reveal, it cannot be measured here, or the frame shows the text in full.
    static func plan(_ text: NativeClipText, block: TextBlock, width: Double, frame: TextRevealFrame) -> (plan: TextRevealPlan, units: TextUnits)? {
        let reveal = text.reveal?.isSupported == true ? text.reveal : nil
        let unreveal = text.unreveal?.isSupported == true ? text.unreveal : nil
        guard reveal != nil || unreveal != nil, let units = layout(block, width: width) else { return nil }
        let body = Array(block.text.utf16)
        let letters = units.clusters.indices.filter { !isBlank(units.clusters[$0].range, in: body) }
        guard !letters.isEmpty else { return nil }
        let inUnits = unitList(reveal?.resolvedUnit, units, body), outUnits = unitList(unreveal?.resolvedUnit, units, body)
        let timing = NativeTextRevealTiming(unitCount: inUnits.count, unrevealUnitCount: outUnits.count, clipFrames: frame.clipFrames,
                                            reveal: reveal, unreveal: unreveal)
        let cursorOn = reveal?.hasCursor == true
            || (unreveal?.hasCursor == true && frame.frame > max(0, frame.clipFrames - 1) - timing.unrevealFrames)
        guard timing.isAnimating(atFrame: frame.frame) || cursorOn else { return nil }

        let inOwner = owners(inUnits, length: body.count), outOwner = owners(outUnits, length: body.count)
        var atoms: [TextRevealPlan.Atom] = []
        var slot: [[Int]: Int] = [:]
        for index in letters {
            let at = units.clusters[index].range.lowerBound
            let key = [inOwner[at], outOwner[at]]
            if let i = slot[key] { atoms[i].clusters.append(index); continue }
            slot[key] = atoms.count
            var atom = TextRevealPlan.Atom(clusters: [index], opacity: 1, moves: [])
            for (style, unitIndex, list, amount) in [
                (reveal?.resolvedStyle, inOwner[at], inUnits, timing.arrived(ofUnit: inOwner[at], atFrame: frame.frame)),
                (unreveal?.resolvedStyle, outOwner[at], outUnits, timing.remaining(ofUnit: outOwner[at], atFrame: frame.frame)),
            ] {
                guard let style, unitIndex >= 0, unitIndex < list.count else { continue }
                let look = Self.look(style, amount: amount, fontSize: block.font.size)
                atom.opacity *= look.opacity
                if look.dy != 0 || look.scale != 1 {
                    let r = list[unitIndex].rect
                    atom.moves.append(.init(cx: r.x + r.width / 2, cy: r.y + r.height / 2, dy: look.dy, scale: look.scale))
                }
            }
            atoms.append(atom)
        }
        var plan = TextRevealPlan(atoms: atoms, cursor: nil)
        if cursorOn { plan.cursor = cursor(units, letters: letters, atoms: plan.atoms, body: body, block: block, frame: frame) }
        if plan.cursor == nil, plan.atoms.allSatisfy(\.isIdentity) { return nil }
        return (plan, units)
    }

    /// Opacity, downward offset (px) and scale of a unit that is `amount` (0…1) of the way shown, in `style`.
    static func look(_ style: String, amount: Double, fontSize: Double) -> (opacity: Double, dy: Double, scale: Double) {
        let a = min(1, max(0, amount))
        let eased = 1 - (1 - a) * (1 - a) * (1 - a)
        switch style {
        case "rise": return (a, (1 - eased) * riseDistance * fontSize, 1)
        case "grow": return (a, 0, growFrom + (1 - growFrom) * eased)
        case "typeOn": return (a > 0 ? 1 : 0, 0, 1)
        default: return (a, 0, 1)
        }
    }

    /// Extra pixels around the box in a frame picture: room for a rising unit and for glyph overhang.
    static func inset(for block: TextBlock) -> Int { Int((block.font.size * riseDistance).rounded(.up)) + 2 }

    /// One frame of the reveal as a picture, and where it goes, for a text box of `box` view units on a canvas with
    /// `deviceScale` device pixels per view unit. Nil when the frame shows the text in full (draw it as plain text).
    static func image(_ text: NativeClipText, box: CanvasRect, scale s: Double, deviceScale k: Double,
                      frame: TextRevealFrame) -> (image: CanvasImage, rect: CanvasRect)? {
        let k = max(k, 1e-3), px = s * k
        let width = Int((box.width * k).rounded(.up)), height = Int((box.height * k).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        let block = NativeTextRendering.block(text, scale: px)
        let layoutWidth = box.width * k
        guard let (plan, units) = plan(text, block: block, width: layoutWidth, frame: frame) else { return nil }
        let inset = inset(for: block)
        guard let rgba = pixels(text, plan: plan, units: units, block: block, width: width, height: height, layoutWidth: layoutWidth,
                                scale: px, inset: inset) else { return nil }
        let rect = CanvasRect(x: box.x - Double(inset) / k, y: box.y - Double(inset) / k,
                              width: Double(width + 2 * inset) / k, height: Double(height + 2 * inset) / k)
        return (CanvasImage(width: width + 2 * inset, height: height + 2 * inset, rgba: rgba), rect)
    }

    /// The frame's pixels, `inset` px wider than the box on every side: the whole text drawn once, then each atom's
    /// share of it placed as the plan says. Nil when this platform cannot rasterize text.
    static func pixels(_ text: NativeClipText, plan: TextRevealPlan, units: TextUnits, block: TextBlock, width: Int, height: Int,
                       layoutWidth: Double, scale px: Double, inset: Int) -> [UInt8]? {
        var still = text
        still.reveal = nil; still.unreveal = nil; still.look = nil
        guard let base = baseCache.get(still, width, height, px, inset) ?? NativeTextRendering.rasterize(
            still, width: width, height: height, scale: px, inset: inset, layoutWidth: layoutWidth) else { return nil }
        baseCache.put(still, width, height, px, inset, base)
        let glyphTop = (block.lineHeight - block.font.size) / 2
        let offset = Double(inset)
        let atoms = plan.atoms.map { atom in
            TextRevealCompositor.Atom(
                regions: atom.clusters.map {
                    let r = units.clusters[$0].rect
                    return CanvasRect(x: r.x + offset, y: r.y - glyphTop + offset, width: r.width, height: block.lineHeight)
                },
                opacity: atom.opacity,
                moves: atom.moves.map { TextRevealPlan.Move(cx: $0.cx + offset, cy: $0.cy + offset, dy: $0.dy, scale: $0.scale) })
        }
        let color = CanvasColor.documentColor(text.resolvedColor)
        let bytes = [color.r, color.g, color.b, color.a].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        return TextRevealCompositor.compose(
            source: base, width: width + 2 * inset, height: height + 2 * inset, atoms: atoms, showsAll: atoms.allSatisfy(\.isIdentity),
            cursor: plan.cursor.map { CanvasRect(x: $0.x + offset, y: $0.y + offset, width: $0.width, height: $0.height) }, cursorColor: bytes)
    }

    private final class BaseCache: @unchecked Sendable {
        struct Key: Hashable { let text: NativeClipText; let width: Int; let height: Int; let scale: Double; let inset: Int }
        private let lock = NSLock()
        private var entries: [(key: Key, pixels: [UInt8])] = []
        static let capacity = 3
        func get(_ text: NativeClipText, _ w: Int, _ h: Int, _ scale: Double, _ inset: Int) -> [UInt8]? {
            let key = Key(text: text, width: w, height: h, scale: scale, inset: inset)
            lock.lock(); defer { lock.unlock() }
            return entries.first { $0.key == key }?.pixels
        }
        func put(_ text: NativeClipText, _ w: Int, _ h: Int, _ scale: Double, _ inset: Int, _ pixels: [UInt8]) {
            let key = Key(text: text, width: w, height: h, scale: scale, inset: inset)
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.key == key }
            entries.append((key, pixels))
            if entries.count > Self.capacity { entries.removeFirst() }
        }
    }

    private static let baseCache = BaseCache()

    // MARK: units

    private static func isBlank(_ range: Range<Int>, in body: [UInt16]) -> Bool {
        String(decoding: body[range.clamped(to: 0..<body.count)], as: UTF16.self).allSatisfy(\.isWhitespace)
    }

    private static func unitList(_ unit: String?, _ units: TextUnits, _ body: [UInt16]) -> [TextUnit] {
        switch unit {
        case "characters": return units.clusters.filter { !isBlank($0.range, in: body) }
        case "lines": return units.lines.filter { !isBlank($0.range, in: body) }
        default: return units.words
        }
    }

    /// For each UTF-16 offset, the unit it belongs to. Offsets between units (punctuation a word leaves out, a blank)
    /// join the unit before them, or the first unit when they come first.
    private static func owners(_ list: [TextUnit], length: Int) -> [Int] {
        var out = [Int](repeating: -1, count: length)
        for (i, u) in list.enumerated() { for at in u.range.clamped(to: 0..<length) { out[at] = i } }
        var last = list.isEmpty ? -1 : 0
        var firstSeen = false
        for at in 0..<length {
            if out[at] >= 0 { last = out[at]; firstSeen = true } else if firstSeen { out[at] = last }
        }
        for at in 0..<length where out[at] < 0 { out[at] = list.isEmpty ? -1 : 0 }
        return out
    }

    // MARK: cursor

    /// A bar the height of the last shown letter, after it (before it, in right-to-left text), blinking once a second;
    /// before anything shows it waits where the first letter will appear. Nil in the off half of the blink.
    private static func cursor(_ units: TextUnits, letters: [Int], atoms: [TextRevealPlan.Atom], body: [UInt16], block: TextBlock,
                               frame: TextRevealFrame) -> TextRevealPlan.Cursor? {
        let half = max(1, (frame.fps / 2).rounded())
        guard Int((max(0, frame.frame) / half).rounded(.down)) % 2 == 0 else { return nil }
        var shown = Set<Int>()
        for atom in atoms where atom.opacity > 0 { shown.formUnion(atom.clusters) }
        let anchor = letters.last(where: shown.contains) ?? letters[0]
        let r = units.clusters[anchor].rect
        let rtl = isRightToLeft(units.clusters[anchor].range, in: body)
        let width = max(1, block.font.size * 0.06)
        let after = shown.contains(anchor)
        // The bar's near edge sits on the letter's far edge (after it) or on its near edge (before the first letter).
        let x: Double
        switch (rtl, after) {
        case (false, true): x = r.x + r.width
        case (false, false): x = r.x
        case (true, true): x = r.x - width
        case (true, false): x = r.x + r.width - width
        }
        return .init(x: x, y: r.y, width: width, height: r.height)
    }

    private static func isRightToLeft(_ range: Range<Int>, in body: [UInt16]) -> Bool {
        let s = String(decoding: body[range.clamped(to: 0..<body.count)], as: UTF16.self)
        return s.unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFDFF).contains($0.value) || (0xFE70...0xFEFF).contains($0.value) }
    }

    // MARK: layout

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(block: TextBlock, width: Double, units: TextUnits)] = []
        static let capacity = 8
        func get(_ block: TextBlock, _ width: Double) -> TextUnits? {
            lock.lock(); defer { lock.unlock() }
            return entries.first { $0.width == width && $0.block == block }?.units
        }
        func put(_ block: TextBlock, _ width: Double, _ units: TextUnits) {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.width == width && $0.block == block }
            entries.append((block, width, units))
            if entries.count > Self.capacity { entries.removeFirst() }
        }
    }

    private static let cache = Cache()

    /// The unit boxes of `block` laid out `width` wide. Measured on the platform's own offscreen canvas, never on
    /// the canvas being drawn on, so preview and export (which draw on different canvases) get the same boxes.
    static func layout(_ block: TextBlock, width: Double) -> TextUnits? {
        if let hit = cache.get(block, width) { return hit }
        guard let units = measure(block, width: width) else { return nil }
        cache.put(block, width, units)
        return units
    }

    private static func measure(_ block: TextBlock, width: Double) -> TextUnits? {
        #if os(Linux)
        let target = CairoImageTarget(width: 1, height: 1)
        return withExtendedLifetime(target) { TextLayout.units(block, width: width, on: target.canvas) }
        #elseif os(Windows)
        guard let target = try? Direct2DImageTarget(width: 1, height: 1) else { return nil }
        return withExtendedLifetime(target) { TextLayout.units(block, width: width, on: target.canvas) }
        #elseif canImport(CoreGraphics) && canImport(CoreText)
        // CoreGraphicsCanvas keeps its fonts in a static dictionary that is not thread-safe: measure on the main thread.
        if !Thread.isMainThread { return DispatchQueue.main.sync { measure(block, width: width) } }
        guard let canvas = CoreGraphicsCanvas.offscreen() else { return nil }
        return TextLayout.units(block, width: width, on: canvas)
        #else
        return nil
        #endif
    }
}
