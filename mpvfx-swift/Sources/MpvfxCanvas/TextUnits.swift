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

public struct TextUnits: Sendable {
    public let clusters: [TextUnit]
    public let words: [TextUnit]
    public let lines: [TextUnit]
    internal let block: TextBlock
    internal let runs: [TextLayout.Run]
    internal let runRanges: [Range<Int>]

    internal static func graphemes(_ text: String) -> [Range<Int>] {
        var offset = 0

        return text.map { character in
            let end = offset + String(character).utf16.count

            defer {
                offset = end
            }
            return offset..<end
        }
    }

    /// Expand native words to whole Characters, trimming punctuation and whitespace at their edges.
    /// Emoji remain available as clusters; words must contain a letter or number.
    internal static func words(_ ranges: [Range<Int>], in text: String) -> [Range<Int>] {
        let clusters = graphemes(text)
        let utf16 = Array(text.utf16)
        var result: [Range<Int>] = []

        func isWord(_ cluster: Range<Int>) -> Bool {
            String(decoding: utf16[cluster], as: UTF16.self).unicodeScalars.contains { scalar in
                CharacterSet.alphanumerics.contains(scalar)
            }
        }

        for range in ranges {
            let covered = clusters.filter { $0.overlaps(range) }

            guard let wordStart = covered.first(where: isWord),
                  let wordEnd = covered.last(where: isWord)
            else {
                continue
            }
            let expanded = wordStart.lowerBound..<wordEnd.upperBound

            if result.last != expanded {
                result.append(expanded)
            }
        }
        return result
    }

    internal static func union(_ boxes: [CanvasRect]) -> CanvasRect {
        guard let first = boxes.first else {
            return CanvasRect(x: 0, y: 0, width: 0, height: 0)
        }
        let left = boxes.reduce(first.x) { min($0, $1.x) }
        let top = boxes.reduce(first.y) { min($0, $1.y) }
        let right = boxes.reduce(first.maxX) { max($0, $1.maxX) }
        let bottom = boxes.reduce(first.maxY) { max($0, $1.maxY) }

        return CanvasRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
