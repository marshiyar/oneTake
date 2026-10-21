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

/// A layout-space advance box and a half-open UTF-16 range into the original TextBlock.text.
/// Ranges always end at extended grapheme boundaries. Arrays follow logical reading order,
/// including on RTL lines; x coordinates need not increase. Boxes are typographic, not ink bounds.
public struct TextUnit: Equatable, Sendable {
    public let range: Range<Int>
    public let rect: CanvasRect
    public init(range: Range<Int>, rect: CanvasRect) { self.range = range; self.rect = rect }
}

public struct TextUnits: Sendable {
    public let clusters: [TextUnit]
    public let words: [TextUnit]
    public let lines: [TextUnit]
    let block: TextBlock
    let runs: [TextLayout.Run]
    let runRanges: [Range<Int>]

    static func graphemes(_ text: String) -> [Range<Int>] {
        var offset = 0
        return text.map { character in
            let end = offset + String(character).utf16.count
            defer { offset = end }
            return offset..<end
        }
    }

    /// Expand native word boundaries to whole Swift Characters (e.g. an emoji ZWJ sequence).
    static func words(_ ranges: [Range<Int>], in text: String) -> [Range<Int>] {
        let clusters = graphemes(text)
        var result: [Range<Int>] = []
        for range in ranges {
            let covered = clusters.filter { $0.overlaps(range) }
            guard !covered.isEmpty else { continue }
            let utf16 = Array(text.utf16)
            func isWord(_ cluster: Range<Int>) -> Bool {
                String(decoding: utf16[cluster], as: UTF16.self).unicodeScalars.contains {
                    CharacterSet.alphanumerics.contains($0)
                }
            }
            guard let wordStart = covered.first(where: isWord), let wordEnd = covered.last(where: isWord) else { continue }
            let expanded = wordStart.lowerBound..<wordEnd.upperBound
            // Word APIs disagree about emoji. A word must contain a letter or number; emoji are clusters.
            let value = String(decoding: Array(text.utf16)[expanded], as: UTF16.self)
            guard value.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }
            if result.last != expanded { result.append(expanded) }
        }
        return result
    }

    static func union(_ boxes: [CanvasRect]) -> CanvasRect {
        guard let first = boxes.first else { return CanvasRect(x: 0, y: 0, width: 0, height: 0) }
        let x = boxes.reduce(first.x) { min($0, $1.x) }, y = boxes.reduce(first.y) { min($0, $1.y) }
        let right = boxes.reduce(first.maxX) { max($0, $1.maxX) }, bottom = boxes.reduce(first.maxY) { max($0, $1.maxY) }
        return CanvasRect(x: x, y: y, width: right - x, height: bottom - y)
    }
}

public extension TextLayout {
    /// Exposes the actual runs used by draw, with native shaped cluster positions. No substring is
    /// reshaped to obtain a box: kerning, ligatures, combining marks and bidi context stay intact.
    static func units(_ b: TextBlock, width: Double, on c: CanvasContext) -> TextUnits {
        let details = details(b, width: width, measure: { c.measureText($0, font: b.font).width })
        let runs = details.runs, runRanges = details.ranges
        var clusters: [TextUnit] = details.spaces
        for (index, run) in runs.enumerated() {
            let start = runRanges[index].lowerBound
            for unit in c.textUnits(run.text, font: b.font) {
                let r = unit.rect
                clusters.append(TextUnit(range: (start + unit.range.lowerBound)..<(start + unit.range.upperBound),
                                         rect: CanvasRect(x: run.x + r.x, y: run.y + r.y, width: r.width, height: r.height)))
            }
        }
        clusters.sort { $0.range.lowerBound < $1.range.lowerBound }
        func box(_ range: Range<Int>) -> CanvasRect { TextUnits.union(clusters.filter { $0.range.overlaps(range) }.map(\.rect)) }
        let words = TextUnits.words(c.textWordRanges(b.text), in: b.text).map { TextUnit(range: $0, rect: box($0)) }
        return TextUnits(clusters: clusters, words: words, lines: details.lines, block: b, runs: runs, runRanges: runRanges)
    }

    /// Reveal selected advance boxes while drawing each original shaped run only once. Selection uses
    /// source ranges, so callers can pass clusters, words or lines. A complete run bypasses clipping,
    /// preserving overhanging ink and exact static-render pixels. Partial reveals clip ink at the unit
    /// boundaries (including a shared ligature); they never reshape an isolated Arabic letter.
    static func draw(_ units: TextUnits, in box: CanvasRect, on c: CanvasContext,
                     selecting selected: [TextUnit], opacity: Double = 1) {
        let b = units.block
        guard b.color.a * opacity > 0 else { return }
        for (index, run) in units.runs.enumerated() where index < units.runRanges.count {
            let range = units.runRanges[index]
            let clusters = units.clusters.filter { $0.range.overlaps(range) }
            let visible = clusters.filter { unit in selected.contains { $0.range.overlaps(unit.range) } }
            guard !visible.isEmpty else { continue }
            c.withState {
                if visible.count != clusters.count {
                    var path = CanvasPath()
                    for unit in visible {
                        let r = unit.rect
                        path.addRect(CanvasRect(x: box.x + r.x, y: box.y + r.y, width: r.width, height: r.height))
                    }
                    c.clip(path)
                }
                c.drawText(run.text, at: CanvasPoint(box.x + run.x, box.y + run.y), font: b.font,
                           color: b.color.withAlpha(b.color.a * opacity))
            }
        }
    }
}

public extension CanvasContext {
    /// Fallback for recording/test canvases. Native backends override this with shaped layout geometry.
    func textUnits(_ text: String, font: CanvasFont) -> [TextUnit] {
        TextUnits.graphemes(text).map { range in
            let utf16 = Array(text.utf16)
            let left = measureText(String(decoding: utf16[..<range.lowerBound], as: UTF16.self), font: font).width
            let right = measureText(String(decoding: utf16[..<range.upperBound], as: UTF16.self), font: font).width
            return TextUnit(range: range, rect: CanvasRect(x: left, y: 0, width: max(0, right - left), height: font.size))
        }
    }
    func textWordRanges(_ text: String) -> [Range<Int>] {
        var offset = 0, start: Int?, ranges: [Range<Int>] = []
        for character in text {
            if character.isWhitespace {
                if let s = start { ranges.append(s..<offset) }; start = nil
            } else if start == nil { start = offset }
            offset += String(character).utf16.count
        }
        if let start { ranges.append(start..<offset) }
        return ranges
    }
}
