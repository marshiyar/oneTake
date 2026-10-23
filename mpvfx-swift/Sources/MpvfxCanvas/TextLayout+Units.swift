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
extension TextLayout {
    /// Exposes native shaped cluster positions for the runs used by draw. Letter-spaced runs use
    /// their placement advances, including the spacing following every Character.
    public static func units(_ block: TextBlock, width: Double, on canvas: CanvasContext) -> TextUnits {
        let layout: (runs: [Run], ranges: [Range<Int>], lines: [TextUnit], spaces: [TextUnit]) =
            details(block, width: width) { canvas.measureText($0, font: block.font).width }
        var clusters = layout.spaces

        for (index, run) in layout.runs.enumerated() where block.letterSpacing == 0 {
            let start = layout.ranges[index].lowerBound

            for unit in canvas.textUnits(run.text, font: block.font) {
                let rect = unit.rect

                clusters.append(TextUnit(
                    range: (start + unit.range.lowerBound)..<(start + unit.range.upperBound),
                    rect: CanvasRect(x: run.x + rect.x, y: run.y + rect.y, width: rect.width, height: rect.height)
                ))
            }
        }
        clusters.sort { $0.range.lowerBound < $1.range.lowerBound }

        func box(_ range: Range<Int>) -> CanvasRect {
            TextUnits.union(clusters.filter { $0.range.overlaps(range) }.map(\.rect))
        }

        let words = TextUnits.words(canvas.textWordRanges(block.text), in: block.text).map { range in
            TextUnit(range: range, rect: box(range))
        }

        return TextUnits(
            clusters: clusters, words: words, lines: layout.lines,
            block: block, runs: layout.runs, runRanges: layout.ranges
        )
    }

    /// Paint each original shaped run once. Partial reveals clip selected advance boxes, including
    /// shared ligatures. Complete runs bypass clipping, preserving overhang and exact static pixels.
    public static func draw(
        _ units: TextUnits, in box: CanvasRect, on canvas: CanvasContext,
        selecting selected: [TextUnit], opacity: Double = 1
    ) {
        let block = units.block

        guard block.color.a * opacity > 0 else {
            return
        }
        for (index, run) in units.runs.enumerated() where index < units.runRanges.count {
            let range = units.runRanges[index]
            let clusters = units.clusters.filter { $0.range.overlaps(range) }
            let visible = clusters.filter { unit in
                selected.contains { $0.range.overlaps(unit.range) }
            }

            guard !visible.isEmpty else {
                continue
            }
            canvas.withState {
                if visible.count != clusters.count {
                    var path = CanvasPath()

                    for unit in visible {
                        let rect = unit.rect

                        path.addRect(CanvasRect(
                            x: box.x + rect.x, y: box.y + rect.y, width: rect.width, height: rect.height
                        ))
                    }
                    canvas.clip(path)
                }
                canvas.drawText(
                    run.text, at: CanvasPoint(box.x + run.x, box.y + run.y), font: block.font,
                    color: block.color.withAlpha(block.color.a * opacity)
                )
            }
        }
    }
}
