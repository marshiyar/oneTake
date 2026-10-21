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
extension CanvasContext {
    /// Fallback for recording canvases. Native backends override this with shaped layout geometry.
    public func textUnits(_ text: String, font: CanvasFont) -> [TextUnit] {
        let utf16 = Array(text.utf16)

        return TextUnits.graphemes(text).map { range in
            let prefix = String(decoding: utf16[..<range.lowerBound], as: UTF16.self)
            let throughCluster = String(decoding: utf16[..<range.upperBound], as: UTF16.self)
            let left = measureText(prefix, font: font).width
            let right = measureText(throughCluster, font: font).width

            return TextUnit(
                range: range, rect: CanvasRect(x: left, y: 0, width: max(0, right - left), height: font.size)
            )
        }
    }

    public func textWordRanges(_ text: String) -> [Range<Int>] {
        var offset = 0
        var start: Int?
        var ranges: [Range<Int>] = []

        for character in text {
            if character.isWhitespace {
                if let start: Int {
                    ranges.append(start..<offset)
                }
                start = nil
            }
            else if start == nil {
                start = offset
            }
            offset += String(character).utf16.count
        }
        if let start: Int {
            ranges.append(start..<offset)
        }
        return ranges
    }
}
