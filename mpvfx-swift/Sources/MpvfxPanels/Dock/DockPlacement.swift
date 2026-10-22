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

/// Remembering and restoring a panel's place, and the default zone placement.
extension DockLayout {
    /// Where an open panel is: its group mates and tab index, or (alone in its group) the neighbouring group in
    /// its parent split, the side of it the panel sits on and its share of the two.
    func place(of panel: DockPanelID) -> DockPlace {
        guard let g = root.group(containing: panel), let index = g.panels.firstIndex(of: panel) else { return DockPlace() }
        let mates = g.panels.filter { $0 != panel }
        if !mates.isEmpty { return .tab(mates: mates, index: index) }
        guard let path = root.path(toGroup: g.id), let i = path.last,
              case .split(let s)? = root.node(at: Array(path.dropLast())) else { return DockPlace() }
        return Self.beside(s, child: i)
    }

    /// The place of the group at `children[i]` of `s`, relative to the sibling after it (else before it).
    static func beside(_ s: DockSplit, child i: Int) -> DockPlace {
        let j = i + 1 < s.children.count ? i + 1 : i - 1
        let after = j > i
        let near = after ? s.children[j].groups.first : s.children[j].groups.last
        let edge = after ? (s.axis == .row ? DockEdge.left : .top) : (s.axis == .row ? DockEdge.right : .bottom)
        return .beside(near?.panels ?? [], edge: edge, fraction: s.weights[i] / (s.weights[i] + s.weights[j]))
    }

    /// Puts a panel back at `place`; false when none of the panels it was remembered beside is open.
    mutating func restore(_ panel: DockPanelID, _ place: DockPlace) -> Bool {
        let tree = root
        if let g = place.mates.lazy.compactMap({ tree.group(containing: $0) }).first {
            return insert(panel, at: .stack(group: g.id, index: place.index), fraction: 0.5)
        }
        if let edge = place.edge, let g = place.neighbour.lazy.compactMap({ tree.group(containing: $0) }).first {
            return insert(panel, at: .split(group: g.id, edge: edge), fraction: place.fraction ?? 0.5)
        }
        return false
    }

    /// The share a panel opened beside the centre gets when its zone has no group yet.
    static let defaultSideFraction = 0.25

    /// Opens a panel at its default zone: as a tab of the group that already holds a panel of that zone, else beside
    /// the centre group (left / right) or along the window's bottom.
    mutating func placeAtDefault(_ spec: DockPanelSpec, registry: DockRegistry) {
        let fraction = spec.defaultDock == .center ? 0.5 : Self.defaultSideFraction
        // `defaultTarget` names only groups that are open, and a window edge always takes a panel.
        if !insert(spec.id, at: defaultTarget(for: spec, registry: registry), fraction: fraction) {
            insert(spec.id, at: .window(.right), fraction: fraction)
        }
    }

    func defaultTarget(for spec: DockPanelSpec, registry: DockRegistry) -> DockDropTarget {
        func group(of zone: DockZone) -> DockGroup? {
            root.groups.first { g in g.panels.contains { registry.spec($0)?.defaultDock == zone } }
        }
        if let g = group(of: spec.defaultDock) { return .stack(group: g.id, index: nil) }
        let centre = group(of: .center)
        switch spec.defaultDock {
        case .left: return centre.map { .split(group: $0.id, edge: .left) } ?? .window(.left)
        case .right: return centre.map { .split(group: $0.id, edge: .right) } ?? .window(.right)
        case .bottom: return .window(.bottom)
        // No centre group: its own group right of the first one (the left zone's, in the default layout).
        case .center: return root.groups.first.map { .split(group: $0.id, edge: .right) } ?? .window(.right)
        }
    }
}

/// Old panel sizes that seed the first dock layout (`panel-layout.json` from before the dock), in points.
public struct DockSeeds: Equatable, Sendable {
    public var leftWidth: Double?
    public var rightWidth: Double?
    public var bottomHeight: Double?
    public init(leftWidth: Double? = nil, rightWidth: Double? = nil, bottomHeight: Double? = nil) {
        self.leftWidth = leftWidth; self.rightWidth = rightWidth; self.bottomHeight = bottomHeight
    }
}

/// The default layout: `[left | centre | right]` above `[bottom]`, every zone's panels stacked in one group in
/// registration order (the first one active), shares from the panels' preferred sizes at a 1440 × 900 window.
public enum DockDefaults {
    public static let referenceWidth = 1440.0, referenceHeight = 900.0

    /// The height the panels share at the reference size: the window less the status line and its seam.
    static var referenceContainerHeight: Double { referenceHeight - ShellStatusLine.height - PanelTheme.seamWidth }

    public static func layout(_ registry: DockRegistry, seeds: DockSeeds = DockSeeds()) -> DockLayout {
        let lw = share(seeds.leftWidth ?? preferred(registry, .left, \.width), of: referenceWidth)
        let rw = share(seeds.rightWidth ?? preferred(registry, .right, \.width), of: referenceWidth)
        // A bottom panel's height is its content; its group adds the tab strip.
        let bh = share((seeds.bottomHeight ?? preferred(registry, .bottom, \.height)) + PanelTabStrip.height, of: referenceContainerHeight)
        let left = group(registry, .left), right = group(registry, .right)
        // The centre takes what the sides leave.
        let centreShare = max(0.1, 1 - (left == nil ? 0 : lw) - (right == nil ? 0 : rw))
        let row = [left.map { ($0, lw) }, group(registry, .center).map { ($0, centreShare) }, right.map { ($0, rw) }].compactMap { $0 }
        var parts: [(DockNode, Double)] = []
        if !row.isEmpty { parts.append((.split(DockSplit(axis: .row, children: row.map(\.0), weights: row.map(\.1))), 1 - bh)) }
        if let bottom = group(registry, .bottom) { parts.append((bottom, bh)) }
        return DockLayout(root: .split(DockSplit(axis: .column, children: parts.map(\.0), weights: parts.map(\.1))))
    }

    /// One zone's panels stacked in one group with a fixed id per zone (`g1` left, `g2` centre, `g3` right, `g4` bottom).
    static func group(_ registry: DockRegistry, _ zone: DockZone) -> DockNode? {
        let ids = registry.specs.filter { $0.defaultDock == zone && !$0.startsClosed }.map(\.id)
        guard !ids.isEmpty else { return nil }
        let n: Int
        switch zone { case .left: n = 1; case .center: n = 2; case .right: n = 3; case .bottom: n = 4 }
        return .group(DockGroup(id: "g\(n)", panels: ids))
    }

    /// The largest preferred extent among a zone's panels (0: none prefers one).
    static func preferred(_ registry: DockRegistry, _ zone: DockZone, _ axis: KeyPath<CanvasSize, Double>) -> Double {
        registry.specs.filter { $0.defaultDock == zone && !$0.startsClosed }.map { $0.preferredSize[keyPath: axis] }.max() ?? 0
    }

    /// A point length as a share of `total`, 0.1…0.6 (0 or unknown: a quarter).
    static func share(_ points: Double, of total: Double) -> Double {
        guard points.isFinite, points > 0, total > 0 else { return 0.25 }
        return min(0.6, max(0.1, points / total))
    }
}
