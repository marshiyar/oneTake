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
// Draw-on (issue #325): the first part of a shape's stroke path, by arc length. Preview and export both paint through
// NativeShapeRendering.draw, so they trim the same way. Curves are measured and cut as polylines of
// `curveSteps` chords, so the cut is within a fraction of a pixel of the true arc length at any canvas size.
import Foundation
import MpvfxCanvas

public enum NativeShapeDrawOn {
    static let curveSteps = 48

    /// The total arc length of the path's strokes (a closed subpath counts its closing edge; the jumps between
    /// subpaths do not count).
    public static func length(_ path: CanvasPath) -> Double {
        var total = 0.0
        walk(path) { _, segment in total += segment.length; return true }
        return total
    }

    /// The first `fraction` of the path's arc length, in drawing order (the shaft of an arrow before its head). 0 or
    /// less gives an empty path; 1 or more gives `path` itself, curves untouched.
    public static func trimmed(_ path: CanvasPath, fraction: Double) -> CanvasPath {
        guard fraction > 0 else { return CanvasPath() }
        guard fraction < 1 else { return path }
        var remaining = length(path) * fraction
        var out = CanvasPath()
        var openAt: CanvasPoint?
        walk(path) { start, segment in
            if openAt != start { out.move(to: start) }
            if segment.length <= remaining {
                out.line(to: segment.end)
                remaining -= segment.length
                openAt = segment.end
                return remaining > 0
            }
            let t = segment.length > 0 ? remaining / segment.length : 0
            out.line(to: CanvasPoint(start.x + (segment.end.x - start.x) * t, start.y + (segment.end.y - start.y) * t))
            return false
        }
        return out
    }

    private struct Segment { var end: CanvasPoint; var length: Double }

    /// Calls `body` with each straight chord of the path (curves flattened) and its start point; stops when it
    /// returns false.
    private static func walk(_ path: CanvasPath, _ body: (CanvasPoint, Segment) -> Bool) {
        var current = CanvasPoint(0, 0), subpathStart = CanvasPoint(0, 0)
        func chord(to end: CanvasPoint) -> Bool {
            let start = current
            current = end
            return body(start, Segment(end: end, length: hypot(end.x - start.x, end.y - start.y)))
        }
        for element in path.elements {
            switch element {
            case .move(let p): current = p; subpathStart = p
            case .line(let p): if !chord(to: p) { return }
            case .close: if current != subpathStart, !chord(to: subpathStart) { return }
            case .curve(let c1, let c2, let end):
                let from = current
                for step in 1...curveSteps {
                    let t = Double(step) / Double(curveSteps), u = 1 - t
                    let x = u * u * u * from.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
                    let y = u * u * u * from.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
                    if !chord(to: step == curveSteps ? end : CanvasPoint(x, y)) { return }
                }
            }
        }
    }
}
