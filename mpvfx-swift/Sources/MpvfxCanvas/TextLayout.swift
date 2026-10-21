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

/// A block of text laid out in a box: lines break at `\n` and wrap at the box width between words, each line box is `lineHeight`
/// tall with the glyphs centred in it (half-leading), lines align left / center / right / justify, and
/// `letterSpacing` px follows every character. The preview draws it straight onto its canvas; export draws the
/// same layout into a bitmap, so both place every glyph identically.
public struct TextBlock: Equatable, Sendable {
    public enum Align: String, Sendable { case left, center, right, justify }
    public var text: String
    public var font: CanvasFont
    public var color: CanvasColor
    public var align: Align
    public var letterSpacing: Double
    /// Line box height in px.
    public var lineHeight: Double
    public init(text: String, font: CanvasFont, color: CanvasColor, align: Align = .left, letterSpacing: Double = 0, lineHeight: Double? = nil) {
        self.text = text; self.font = font; self.color = color; self.align = align; self.letterSpacing = letterSpacing
        self.lineHeight = lineHeight ?? font.size * 1.2
    }
}

public enum TextLayout {
    /// One piece of text drawn at (x, y): y is the top of its em box, both relative to the box origin.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var x: Double, y: Double
    }

    /// The runs a block draws in a box `width` wide. `measure` gives a string's advance width without letter spacing.
    public static func layout(_ b: TextBlock, width: Double, measure: (String) -> Double) -> [Run] {
        details(b, width: width, measure: measure).runs
    }

    /// Retain source offsets during wrapping; searching the final runs loses empty lines and spaces.
    static func details(_ b: TextBlock, width: Double, measure: (String) -> Double)
        -> (runs: [Run], ranges: [Range<Int>], lines: [TextUnit], spaces: [TextUnit]) {
        let space = b.letterSpacing
        func w(_ s: String) -> Double { s.isEmpty ? 0 : measure(s) + space * Double(s.count) }
        var lines: [(words: [String], last: Bool, start: Int)] = []
        var paragraphOffset = 0
        for para in b.text.components(separatedBy: "\n") {
            let words = para.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var line: [String] = [], lineStart = paragraphOffset, offset = paragraphOffset
            for word in words {
                if line.isEmpty { line = [word]; lineStart = offset }
                else {
                    let candidate = (line + [word]).joined(separator: " ")
                    if w(candidate) <= width + 1e-6 { line.append(word) }
                    else { lines.append((line, false, lineStart)); line = [word]; lineStart = offset }
                }
                offset += word.utf16.count + 1
            }
            lines.append((line, true, lineStart))
            paragraphOffset += para.utf16.count + 1
        }
        var runs: [Run] = [], ranges: [Range<Int>] = [], lineUnits: [TextUnit] = [], spaces: [TextUnit] = []
        let glyphTop = (b.lineHeight - b.font.size) / 2
        func append(_ text: String, x: Double, y: Double, offset: Int) {
            let placed = place(text, x: x, y: y, spacing: space, measure: measure)
            if space != 0 {
                var prefix = ""
                var characterOffset = offset
                for (index, character) in text.enumerated() {
                    let value = String(character)
                    let length = value.utf16.count
                    let prefixWidth = prefix.isEmpty ? 0 : measure(prefix)
                    let advance = measure(prefix + value) - prefixWidth + space
                    spaces.append(TextUnit(
                        range: characterOffset..<(characterOffset + length),
                        rect: CanvasRect(
                            x: x + prefixWidth + space * Double(index), y: y,
                            width: max(0, advance), height: b.font.size
                        )
                    ))
                    prefix += value
                    characterOffset += length
                }
            }
            var cursor = 0
            for run in placed {
                // place either returns the complete string or one Character at a time.
                if space == 0 || text.count <= 1 { ranges.append(offset..<(offset + text.utf16.count)) }
                else {
                    let suffix = String(decoding: Array(text.utf16)[cursor...], as: UTF16.self)
                    if let found = suffix.range(of: run.text) {
                        cursor += found.lowerBound.utf16Offset(in: suffix)
                        ranges.append((offset + cursor)..<(offset + cursor + run.text.utf16.count))
                        cursor += run.text.utf16.count
                    }
                }
            }
            runs += placed
        }
        for (i, line) in lines.enumerated() {
            let y = Double(i) * b.lineHeight + glyphTop
            let text = line.words.joined(separator: " ")
            let lineWidth = w(text)
            let x: Double
            switch b.align {
            case .left, .justify: x = 0
            case .center: x = (width - lineWidth) / 2
            case .right: x = width - lineWidth
            }
            let justified = b.align == .justify && !line.last && line.words.count > 1
            lineUnits.append(TextUnit(range: line.start..<(line.start + text.utf16.count),
                                      rect: CanvasRect(x: x, y: Double(i) * b.lineHeight,
                                                       width: justified ? width : lineWidth, height: b.lineHeight)))
            guard !text.isEmpty else { continue }
            if justified {
                let wordsWidth = line.words.reduce(0) { $0 + w($1) }
                let gap = (width - wordsWidth) / Double(line.words.count - 1)
                var wordX = 0.0, offset = line.start
                for (index, word) in line.words.enumerated() {
                    append(word, x: wordX, y: y, offset: offset)
                    let wordEnd = offset + word.utf16.count
                    if index < line.words.count - 1 {
                        spaces.append(TextUnit(
                            range: wordEnd..<(wordEnd + 1),
                            rect: CanvasRect(x: wordX + w(word), y: y, width: gap, height: b.font.size)
                        ))
                    }
                    wordX += w(word) + gap
                    offset = wordEnd + 1
                }
            } else { append(text, x: x, y: y, offset: line.start) }
        }
        return (runs, ranges, lineUnits, spaces)
    }

    /// A string as one run, or one run per character when letter spacing separates them (each character after the
    /// advance of the ones before it, so kerning inside the prefix is kept).
    static func place(_ s: String, x: Double, y: Double, spacing: Double, measure: (String) -> Double) -> [Run] {
        guard spacing != 0, s.count > 1 else { return [Run(text: s, x: x, y: y)] }
        var out: [Run] = []
        var prefix = ""
        for (i, ch) in s.enumerated() {
            if !ch.isWhitespace { out.append(Run(text: String(ch), x: x + (prefix.isEmpty ? 0 : measure(prefix)) + spacing * Double(i), y: y)) }
            prefix.append(ch)
        }
        return out
    }

    /// Draws the block inside `box` (no clip: text overflowing the box shows).
    public static func draw(_ b: TextBlock, in box: CanvasRect, on c: CanvasContext, opacity: Double = 1) {
        guard b.color.a * opacity > 0 else { return }
        let color = b.color.withAlpha(b.color.a * opacity)
        for r in layout(b, width: box.width, measure: { c.measureText($0, font: b.font).width }) {
            c.drawText(r.text, at: CanvasPoint(box.x + r.x, box.y + r.y), font: b.font, color: color)
        }
    }
}
