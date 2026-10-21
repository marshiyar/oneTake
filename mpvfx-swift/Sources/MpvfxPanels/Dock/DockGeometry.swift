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
import MpvfxCanvas

/// One group on screen: its tab strip on top, its active panel's content below.
public struct DockGroupFrame: Equatable, Sendable {
    public var group: DockGroup
    public var frame: CanvasRect
    public var strip: CanvasRect
    public var content: CanvasRect
}

/// The seam between `children[index]` and `children[index + 1]` of the split at `path`.
public struct DockSplitter: Equatable, Sendable {
    public var path: [Int]
    public var index: Int
    public var axis: DockAxis
    /// The 1 pt seam drawn between the two sides.
    public var seam: CanvasRect
    /// The pointer band around it (`PanelTheme.seamHitWidth` across, like the shell seams today).
    public var hit: CanvasRect
    /// Every child's length along the axis and its minimum, as laid out (a drag and a reset work from these).
    public var lengths: [Double]
    public var minimums: [Double]
    public var preferred: [Double]
}

/// Where every group and splitter of a layout sits in a rect. Pure: the same layout, registry and rect always give
/// the same frames, on whole points so edges stay crisp.
public struct DockGeometry: Equatable, Sendable {
    public private(set) var groups: [DockGroupFrame] = []
    public private(set) var splitters: [DockSplitter] = []
    public private(set) var bounds = CanvasRect(x: 0, y: 0, width: 0, height: 0)

    public static let stripHeight = PanelTabStrip.height
    public static var seam: Double { PanelTheme.seamWidth }
    /// The splitter's pointer band across the seam.
    public static var splitterHit: Double { PanelTheme.seamHitWidth }

    public init() {}

    public static func compute(_ layout: DockLayout, registry: DockRegistry, in rect: CanvasRect) -> DockGeometry {
        var g = DockGeometry()
        g.bounds = rect
        g.place(layout.root, in: rect, path: [], registry: registry)
        return g
    }

    public func frame(of groupID: String) -> DockGroupFrame? { groups.first { $0.group.id == groupID } }
    public func frame(containing panel: DockPanelID) -> DockGroupFrame? { groups.first { $0.group.panels.contains(panel) } }
    /// The content rect of an open panel when it is its group's visible tab.
    public func content(of panel: DockPanelID) -> CanvasRect? {
        groups.first { $0.group.active == panel }?.content
    }

    private mutating func place(_ node: DockNode, in r: CanvasRect, path: [Int], registry: DockRegistry) {
        switch node {
        case .group(let group):
            let stripH = min(Self.stripHeight, r.height)
            let strip = CanvasRect(x: r.x, y: r.y, width: r.width, height: stripH)
            let content = CanvasRect(x: r.x, y: r.y + stripH, width: r.width, height: max(0, r.height - stripH))
            groups.append(DockGroupFrame(group: group, frame: r, strip: strip, content: content))
        case .split(let s):
            placeSplit(s, in: r, path: path, registry: registry)
        }
    }

    private mutating func placeSplit(_ s: DockSplit, in r: CanvasRect, path: [Int], registry: DockRegistry) {
        let row = s.axis == .row
        let length = row ? r.width : r.height
        let seams = Self.seam * Double(s.children.count - 1)
        let mins = s.children.map { Self.minimum($0, s.axis, registry) }
        let lengths = Self.distribute(s.weights, total: max(0, length - seams), minimums: mins)
        let prefs = s.children.map { Self.preferred($0, s.axis, registry) }
        var at = row ? r.x : r.y
        for (i, child) in s.children.enumerated() {
            let childRect = row ? CanvasRect(x: at, y: r.y, width: lengths[i], height: r.height)
                                : CanvasRect(x: r.x, y: at, width: r.width, height: lengths[i])
            place(child, in: childRect, path: path + [i], registry: registry)
            at += lengths[i]
            guard i + 1 < s.children.count else { continue }
            let seam = row ? CanvasRect(x: at, y: r.y, width: Self.seam, height: r.height)
                           : CanvasRect(x: r.x, y: at, width: r.width, height: Self.seam)
            splitters.append(DockSplitter(path: path, index: i, axis: s.axis, seam: seam, hit: Self.band(seam, s.axis),
                                          lengths: lengths, minimums: mins, preferred: prefs))
            at += Self.seam
        }
    }

    static func band(_ seam: CanvasRect, _ axis: DockAxis) -> CanvasRect {
        let pad = (splitterHit - Self.seam) / 2
        return axis == .row ? CanvasRect(x: seam.x - pad, y: seam.y, width: splitterHit, height: seam.height)
                            : CanvasRect(x: seam.x, y: seam.y - pad, width: seam.width, height: splitterHit)
    }

    // MARK: Sizes

    /// The smallest length `node` can take along `axis`: a group's largest panel minimum (plus its tab strip
    /// vertically); a split's children summed with their seams along its own axis, their largest across it.
    public static func minimum(_ node: DockNode, _ axis: DockAxis, _ registry: DockRegistry) -> Double {
        switch node {
        case .group(let g):
            let mins = g.panels.compactMap(registry.spec).map { axis == .row ? $0.minSize.width : $0.minSize.height }
            return (mins.max() ?? 0) + (axis == .column ? stripHeight : 0)
        case .split(let s):
            let kids = s.children.map { minimum($0, axis, registry) }
            return s.axis == axis ? kids.reduce(0, +) + seam * Double(kids.count - 1) : (kids.max() ?? 0)
        }
    }

    /// A group's largest preferred length along `axis` (0: none); a split has no preference.
    static func preferred(_ node: DockNode, _ axis: DockAxis, _ registry: DockRegistry) -> Double {
        guard case .group(let g) = node else { return 0 }
        let prefs = g.panels.compactMap(registry.spec).map { axis == .row ? $0.preferredSize.width : $0.preferredSize.height }
        let p = prefs.max() ?? 0
        return p > 0 ? p + (axis == .column ? stripHeight : 0) : 0
    }

    /// Lengths in whole points summing to `total`: shares by weight, no child below its minimum; when the minimums
    /// do not fit, every child shrinks below its minimum in proportion (never negative, never overlapping).
    public static func distribute(_ weights: [Double], total: Double, minimums: [Double]) -> [Double] {
        let n = weights.count
        guard n > 0, total > 0 else { return Array(repeating: 0, count: n) }
        let minSum = minimums.reduce(0, +)
        let raw = minSum >= total ? minimums.map { minSum > 0 ? $0 / minSum * total : total / Double(n) }
                                  : flexed(weights, total: total, minimums: minimums)
        return wholePoints(raw, total: total)
    }

    /// Weighted shares; a child whose share is under its minimum is fixed there and the rest re-share what is left.
    static func flexed(_ weights: [Double], total: Double, minimums: [Double]) -> [Double] {
        var fixed = Array(repeating: false, count: weights.count)
        var out = Array(repeating: 0.0, count: weights.count)
        for _ in 0...weights.count {
            let free = total - zip(fixed, minimums).filter(\.0).map(\.1).reduce(0, +)
            let wsum = zip(fixed, weights).filter { !$0.0 }.map(\.1).reduce(0, +)
            var changed = false
            for i in weights.indices where !fixed[i] {
                out[i] = wsum > 0 ? weights[i] / wsum * free : 0
                if out[i] < minimums[i] { out[i] = minimums[i]; fixed[i] = true; changed = true }
            }
            if !changed { break }
        }
        for i in weights.indices where fixed[i] { out[i] = minimums[i] }
        return out
    }

    /// Rounds the running edge positions, so the lengths are whole points and still sum to `total`.
    static func wholePoints(_ lengths: [Double], total: Double) -> [Double] {
        var out: [Double] = [], edge = 0.0, prev = 0.0
        for (i, l) in lengths.enumerated() {
            edge += l
            let next = i == lengths.count - 1 ? total.rounded(.down) : edge.rounded()
            out.append(max(0, next - prev))
            prev = max(prev, next)
        }
        return out
    }

    // MARK: Splitter gestures

    /// The split's weights after moving `splitter` by `delta` points, both sides held at their minimums.
    public static func weights(dragging splitter: DockSplitter, by delta: Double) -> [Double] {
        var lengths = splitter.lengths
        let i = splitter.index, pair = lengths[i] + lengths[i + 1]
        let lo = min(splitter.minimums[i], pair / 2), hi = max(pair - splitter.minimums[i + 1], pair / 2)
        lengths[i] = min(hi, max(lo, lengths[i] + (delta.isFinite ? delta : 0)))
        lengths[i + 1] = pair - lengths[i]
        return shares(lengths)
    }

    /// The split's weights after a double-click on `splitter`: the two sides take their preferred lengths (one
    /// with a preference gets it, the other the rest; both: in proportion), else share equally.
    public static func weights(resetting splitter: DockSplitter) -> [Double] {
        var lengths = splitter.lengths
        let i = splitter.index, pair = lengths[i] + lengths[i + 1]
        let a = splitter.preferred[i], b = splitter.preferred[i + 1]
        var first: Double
        switch (a > 0, b > 0) {
        case (true, false): first = a
        case (false, true): first = pair - b
        case (true, true): first = pair * a / (a + b)
        case (false, false): first = pair / 2
        }
        let lo = min(splitter.minimums[i], pair / 2), hi = max(pair - splitter.minimums[i + 1], pair / 2)
        first = min(hi, max(lo, first))
        lengths[i] = first; lengths[i + 1] = pair - first
        return shares(lengths)
    }

    static func shares(_ lengths: [Double]) -> [Double] {
        let total = lengths.reduce(0, +)
        guard total > 0 else { return lengths.map { _ in 1 / Double(max(1, lengths.count)) } }
        return lengths.map { max(1e-3, $0) / total }
    }
}
