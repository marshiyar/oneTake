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
import MpvfxCanvas

/// Resize snapping: the side a handle drags (one vertical line `x`, one horizontal line `y`, view px) snaps to the
/// other elements' and the composition frame's edges and centres within the same 6 px as a move, and to grid lines
/// when asked. Ties pointing both ways cancel, as for moves.
public extension SnapEngine {
    /// Vertical (`x`) and horizontal (`y`) grid lines, view px.
    typealias GridLines = (x: [Double], y: [Double])

    struct EdgeResult: Equatable, Sendable {
        public var dx, dy: Double
        public var guides: [Guide]
    }

    static func resolveEdges(x: Double?, y: Double?, targets: [Target], grid: GridLines? = nil) -> EdgeResult {
        let bx = x.flatMap { pickBest(candidates([$0], targets, { [$0.left, $0.centerX, $0.right] }, grid: grid?.x ?? [], threshold: thresholdPx)) }
        let by = y.flatMap { pickBest(candidates([$0], targets, { [$0.top, $0.centerY, $0.bottom] }, grid: grid?.y ?? [], threshold: thresholdPx)) }
        var guides: [Guide] = []
        if let bx, let x { guides.append(edgeGuide(.x, at: x + bx.adjustment, bx.matches, targets)) }
        if let by, let y { guides.append(edgeGuide(.y, at: y + by.adjustment, by.matches, targets)) }
        return EdgeResult(dx: bx?.adjustment ?? 0, dy: by?.adjustment ?? 0, guides: guides)
    }

    /// A guide along the matched line spanning the targets it touches.
    internal static func edgeGuide(_ axis: Axis, at position: Double, _ matches: [Candidate], _ targets: [Target]) -> Guide {
        let ids = Set(matches.map(\.target))
        let hit = targets.filter { ids.contains($0.id) }
        let ext = hit.flatMap { axis == .x ? [$0.top, $0.bottom] : [$0.left, $0.right] }
        return Guide(axis: axis, position: position, from: ext.min() ?? position, to: ext.max() ?? position)
    }
}
