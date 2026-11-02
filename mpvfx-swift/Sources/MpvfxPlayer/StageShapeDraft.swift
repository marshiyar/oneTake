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
// The Shape tool's geometry (issue #324), in composition pixels and free of any drawing: what a press and a drag
// (or a click) make, with Shift and Option applied, and where the picker's chips sit.
//
//   click (no drag)        a 200 x 120 box centred on the click; a line or arrow runs corner to corner of it.
//   rectangle / ellipse    corner to corner of the drag. Shift makes the box square (a circle for the ellipse) along the
//                          longer side, keeping the drag's direction. Option draws from the centre: the press is the
//                          centre and the pointer a corner.
//   line / arrow           from the press to the pointer. Shift snaps the angle to the nearest 45 degrees, keeping the
//                          length. Option draws from the centre: the press is the middle and the pointer an end.
// The box is whole pixels. A line's box is the bounds of its two ends, at least `minimumBox` thick on a flat axis, and
// its ends are stored as fractions of the box. A new line or arrow is white and 6 px thick, a new rectangle or ellipse
// white and filled.
import Foundation
import MpvfxCanvas
import MpvfxShared

public struct StageShapeDraft: Equatable, Sendable {
    public static let defaultSize = CanvasSize(200, 120)
    public static let minimumBox = 20.0
    /// The kinds the tool draws, in the picker's order.
    public static let kinds = ["rectangle", "ellipse", "line", "arrow"]

    public var shape: NativeClipShape
    /// The shape's box in composition pixels.
    public var box: CanvasRect

    public static func label(_ kind: String) -> String { kind.prefix(1).uppercased() + kind.dropFirst() }

    public static func make(kind: String, from a: CanvasPoint, to b: CanvasPoint, shift: Bool, alt: Bool, click: Bool) -> StageShapeDraft {
        let isLine = kind == "line" || kind == "arrow"
        func shape(start: CanvasPoint = CanvasPoint(0, 0), end: CanvasPoint = CanvasPoint(1, 1)) -> NativeClipShape {
            var s = isLine ? NativeClipShape(kind: kind, stroke: "#ffffff", strokeWidth: 6, endX: end.x, endY: end.y)
                           : NativeClipShape(kind: kind)
            if isLine {
                if start.x != 0 { s.raw["startX"] = .number(start.x) }
                if start.y != 0 { s.raw["startY"] = .number(start.y) }
            }
            return s
        }
        if click {
            let size = defaultSize
            return StageShapeDraft(shape: shape(), box: CanvasRect(x: (a.x - size.width / 2).rounded(), y: (a.y - size.height / 2).rounded(),
                                                                     width: size.width, height: size.height))
        }
        var dx = b.x - a.x, dy = b.y - a.y
        if isLine {
            if shift {
                let length = hypot(dx, dy), step = Double.pi / 4
                let angle = (atan2(dy, dx) / step).rounded() * step
                dx = cos(angle) * length; dy = sin(angle) * length
            }
            let start = alt ? CanvasPoint(a.x - dx, a.y - dy) : a, end = CanvasPoint(a.x + dx, a.y + dy)
            let (x, w) = span(start.x, end.x), (y, h) = span(start.y, end.y)
            let box = CanvasRect(x: x, y: y, width: w, height: h)
            // Whole-pixel rounding of the box can leave an end a hair outside it: the fractions stay within 0 ... 1.
            func fraction(_ p: CanvasPoint) -> CanvasPoint {
                CanvasPoint(min(1, max(0, (p.x - box.x) / box.width)), min(1, max(0, (p.y - box.y) / box.height)))
            }
            return StageShapeDraft(shape: shape(start: fraction(start), end: fraction(end)), box: box)
        }
        if shift {
            let side = max(abs(dx), abs(dy))
            dx = (dx < 0 ? -1 : 1) * side; dy = (dy < 0 ? -1 : 1) * side
        }
        let (x, w) = alt ? span(a.x - abs(dx), a.x + abs(dx), minimum: 1) : span(a.x, a.x + dx, minimum: 1)
        let (y, h) = alt ? span(a.y - abs(dy), a.y + abs(dy), minimum: 1) : span(a.y, a.y + dy, minimum: 1)
        return StageShapeDraft(shape: shape(), box: CanvasRect(x: x, y: y, width: w, height: h))
    }

    /// Whole-pixel origin and length covering both values, at least `minimum` long and centred on them when widened.
    private static func span(_ p: Double, _ q: Double, minimum: Double = minimumBox) -> (Double, Double) {
        let lo = min(p, q), hi = max(p, q)
        if hi - lo >= minimum { return (lo.rounded(), max(minimum, (hi - lo).rounded())) }
        return (((lo + hi) / 2 - minimum / 2).rounded(), minimum)
    }
}

/// The picker's chips, along the top left of the stage viewport while the tool is on.
public enum StageShapePicker {
    public static let chipWidth = 78.0, chipHeight = 28.0, gap = 4.0, inset = 10.0

    public static func rects(in viewport: CanvasRect) -> [(kind: String, rect: CanvasRect)] {
        StageShapeDraft.kinds.enumerated().map { index, kind in
            (kind, CanvasRect(x: viewport.x + inset + Double(index) * (chipWidth + gap), y: viewport.y + inset,
                              width: chipWidth, height: chipHeight))
        }
    }

    public static func kind(at p: CanvasPoint, in viewport: CanvasRect) -> String? {
        rects(in: viewport).first { $0.rect.contains(p) }?.kind
    }
}
