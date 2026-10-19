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
        let space = b.letterSpacing
        func w(_ s: String) -> Double { s.isEmpty ? 0 : measure(s) + space * Double(s.count) }
        var lines: [(words: [String], last: Bool)] = []
        for para in b.text.components(separatedBy: "\n") {
            let words = para.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var line: [String] = []
            for word in words {
                if line.isEmpty { line = [word]; continue }
                let candidate = (line + [word]).joined(separator: " ")
                if w(candidate) <= width + 1e-6 { line.append(word) } else { lines.append((line, false)); line = [word] }
            }
            lines.append((line, true))
        }
        var runs: [Run] = []
        let glyphTop = (b.lineHeight - b.font.size) / 2
        for (i, line) in lines.enumerated() {
            let y = Double(i) * b.lineHeight + glyphTop
            let text = line.words.joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let lineWidth = w(text)
            if b.align == .justify && !line.last && line.words.count > 1 {
                // Extra width goes between the words; each word is placed on its own.
                let wordsWidth = line.words.reduce(0) { $0 + w($1) }
                let gap = (width - wordsWidth) / Double(line.words.count - 1)
                var x = 0.0
                for word in line.words {
                    runs += place(word, x: x, y: y, spacing: space, measure: measure)
                    x += w(word) + gap
                }
                continue
            }
            let x: Double
            switch b.align {
            case .left, .justify: x = 0
            case .center: x = (width - lineWidth) / 2
            case .right: x = width - lineWidth
            }
            runs += place(text, x: x, y: y, spacing: space, measure: measure)
        }
        return runs
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
