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

/// Move snapping on the stage: edges and centres of the moving box
/// snap to other elements, the composition frame and (optionally) grid lines within 6 px; ties pointing both ways
/// cancel the snap. Equal-gap guides appear when the moving box sits evenly between neighbours.
/// All coordinates are view pixels.
public enum SnapEngine {
    public static let thresholdPx = 6.0
    static let engageTravelPx = 4.0
    static let equidistanceTolerancePx = 1.0

    public struct Target: Equatable, Sendable {
        public var left, top, right, bottom: Double
        public var id: String
        public var centerX: Double { (left + right) / 2 }
        public var centerY: Double { (top + bottom) / 2 }
        public init(_ r: CanvasRect, id: String) { left = r.x; top = r.y; right = r.maxX; bottom = r.maxY; self.id = id }
    }
    public enum Axis: Sendable { case x, y }
    /// A matched line: vertical at `position` (axis x) or horizontal (axis y), spanning [from, to] across.
    public struct Guide: Equatable, Sendable { public var axis: Axis; public var position, from, to: Double }
    /// An equal gap of `size` starting at `position`, spanning [from, to] across.
    public struct SpacingGuide: Equatable, Sendable { public var axis: Axis; public var position, size, from, to: Double }
    public struct Result: Equatable, Sendable {
        public var dx, dy: Double
        public var guides: [Guide]
        public var spacingGuides: [SpacingGuide]
    }

    public static func engaged(dx: Double, dy: Double) -> Bool { (dx * dx + dy * dy).squareRoot() >= engageTravelPx }

    /// Grid lines at 1/n … (n-1)/n of the composition frame (n = 2, 3 or 4; anything else is thirds).
    public static func gridEdges(frame: CanvasRect, divisions: Int) -> (x: [Double], y: [Double]) {
        let n = [2, 3, 4].contains(divisions) ? divisions : 3
        return ((1..<n).map { frame.x + frame.width * Double($0) / Double(n) },
                (1..<n).map { frame.y + frame.height * Double($0) / Double(n) })
    }

    struct Candidate { var adjustment, distance, guide: Double; var grid: Bool; var target: String }

    static func candidates(_ moving: [Double], _ targets: [Target], _ edges: (Target) -> [Double], grid: [Double], threshold: Double) -> [Candidate] {
        var out: [Candidate] = []
        for t in targets { for m in moving { for e in edges(t) {
            let adj = e - m
            if abs(adj) <= threshold { out.append(Candidate(adjustment: adj, distance: abs(adj), guide: e, grid: false, target: t.id)) }
        } } }
        for (i, g) in grid.enumerated() { for m in moving {
            let adj = g - m
            if abs(adj) <= threshold { out.append(Candidate(adjustment: adj, distance: abs(adj), guide: g, grid: true, target: "grid-\(i)")) }
        } }
        return out
    }

    static func pickBest(_ cs: [Candidate]) -> (adjustment: Double, matches: [Candidate])? {
        guard !cs.isEmpty else { return nil }
        let elems = cs.filter { !$0.grid }, grid = cs.filter { $0.grid }
        let bestElem = elems.map(\.distance).min() ?? .infinity, bestGrid = grid.map(\.distance).min() ?? .infinity
        let pool = bestElem <= bestGrid ? elems : grid
        let minDist = pool.map(\.distance).min()!
        let winners = pool.filter { $0.distance == minDist }
        if winners.contains(where: { $0.adjustment > 0 }) && winners.contains(where: { $0.adjustment < 0 }) { return nil }
        let adj = winners[0].adjustment
        return (adj, pool.filter { $0.adjustment == adj })
    }

    public static func resolve(moving mr: CanvasRect, dx: Double, dy: Double, targets: [Target],
                               grid: (x: [Double], y: [Double])? = nil, threshold: Double = thresholdPx, disabled: Bool = false) -> Result {
        if disabled || threshold <= 0 { return Result(dx: dx, dy: dy, guides: [], spacingGuides: []) }
        let p = CanvasRect(x: mr.x + dx, y: mr.y + dy, width: mr.width, height: mr.height)
        let bx = pickBest(candidates([p.x, p.x + p.width / 2, p.maxX], targets, { [$0.left, $0.centerX, $0.right] }, grid: grid?.x ?? [], threshold: threshold))
        let by = pickBest(candidates([p.y, p.y + p.height / 2, p.maxY], targets, { [$0.top, $0.centerY, $0.bottom] }, grid: grid?.y ?? [], threshold: threshold))
        let adx = dx + (bx?.adjustment ?? 0), ady = dy + (by?.adjustment ?? 0)
        let adjusted = CanvasRect(x: mr.x + adx, y: mr.y + ady, width: mr.width, height: mr.height)
        let byId = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var guides: [Guide] = []
        for (axis, best) in [(Axis.x, bx), (Axis.y, by)] {
            guard let best else { continue }
            var seen = Set<Double>()
            for m in best.matches where !seen.contains(m.guide) {
                seen.insert(m.guide)
                var ext: [Double] = axis == .x ? [adjusted.y, adjusted.maxY] : [adjusted.x, adjusted.maxX]
                for mm in best.matches where mm.guide == m.guide {
                    if let t = byId[mm.target] { ext += axis == .x ? [t.top, t.bottom] : [t.left, t.right] }
                }
                guides.append(Guide(axis: axis, position: m.guide, from: ext.min()!, to: ext.max()!))
            }
        }
        return Result(dx: adx, dy: ady, guides: guides, spacingGuides: [])
    }

    public static func equidistance(moving mr: CanvasRect, targets: [Target]) -> [SpacingGuide] {
        let movingId = "\u{0}moving"
        let all = targets + [Target(mr, id: movingId)]
        var out: [SpacingGuide] = []
        let sx = all.sorted { $0.centerX < $1.centerX }
        if sx.count >= 3 { for i in 0..<(sx.count - 2) {
            let a = sx[i], b = sx[i + 1], c = sx[i + 2]
            let ab = b.left - a.right, bc = c.left - b.right
            guard ab >= 0, bc >= 0, [a, b, c].contains(where: { $0.id == movingId }), abs(ab - bc) <= equidistanceTolerancePx else { continue }
            let lo = min(a.top, b.top, c.top), hi = max(a.bottom, b.bottom, c.bottom)
            out.append(SpacingGuide(axis: .x, position: a.right, size: ab, from: lo, to: hi))
            out.append(SpacingGuide(axis: .x, position: b.right, size: bc, from: lo, to: hi))
        } }
        let sy = all.sorted { $0.centerY < $1.centerY }
        if sy.count >= 3 { for i in 0..<(sy.count - 2) {
            let a = sy[i], b = sy[i + 1], c = sy[i + 2]
            let ab = b.top - a.bottom, bc = c.top - b.bottom
            guard ab >= 0, bc >= 0, [a, b, c].contains(where: { $0.id == movingId }), abs(ab - bc) <= equidistanceTolerancePx else { continue }
            let lo = min(a.left, b.left, c.left), hi = max(a.right, b.right, c.right)
            out.append(SpacingGuide(axis: .y, position: a.bottom, size: ab, from: lo, to: hi))
            out.append(SpacingGuide(axis: .y, position: b.bottom, size: bc, from: lo, to: hi))
        } }
        return out
    }
}
