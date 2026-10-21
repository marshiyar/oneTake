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

/// A dockable panel's stable id ("media", "timeline", "easing"): the key of its saved place and of its content.
public typealias DockPanelID = String

/// Where a panel goes the first time it opens (and after "Reset to default layout").
public enum DockZone: String, Codable, Sendable, CaseIterable { case left, right, bottom, center }

/// A side of a group or of the window.
public enum DockEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom
    /// The split axis a drop on this edge creates: left/right put groups side by side.
    public var axis: DockAxis { self == .left || self == .right ? .row : .column }
    /// Whether the dropped panel goes before (left of / above) the target.
    public var isLeading: Bool { self == .left || self == .top }
    public var opposite: DockEdge {
        switch self { case .left: return .right; case .right: return .left; case .top: return .bottom; case .bottom: return .top }
    }
}

/// `row`: children side by side, left to right. `column`: children stacked, top to bottom.
public enum DockAxis: String, Codable, Sendable { case row, column }

/// A stack of panels shown one at a time behind a tab bar.
public struct DockGroup: Equatable, Sendable {
    public var id: String
    public var panels: [DockPanelID]
    public var active: DockPanelID
    public init(id: String, panels: [DockPanelID], active: DockPanelID? = nil) {
        self.id = id; self.panels = panels; self.active = active ?? panels.first ?? ""
    }
}

/// Children laid along one axis; `weights` are their shares of the split's length (same count, sum 1).
public struct DockSplit: Equatable, Sendable {
    public var axis: DockAxis
    public var children: [DockNode]
    public var weights: [Double]
    public init(axis: DockAxis, children: [DockNode], weights: [Double]) {
        self.axis = axis; self.children = children; self.weights = weights
    }
}

/// The layout tree: groups at the leaves, splits inside.
public indirect enum DockNode: Equatable, Sendable {
    case group(DockGroup)
    case split(DockSplit)

    /// Every group, in reading order (depth first, children in order).
    public var groups: [DockGroup] {
        switch self {
        case .group(let g): return [g]
        case .split(let s): return s.children.flatMap(\.groups)
        }
    }

    /// Every open panel, in reading order.
    public var panels: [DockPanelID] { groups.flatMap(\.panels) }

    /// Nesting depth (a lone group is 1).
    public var depth: Int {
        switch self {
        case .group: return 1
        case .split(let s): return 1 + (s.children.map(\.depth).max() ?? 0)
        }
    }

    public func group(containing panel: DockPanelID) -> DockGroup? { groups.first { $0.panels.contains(panel) } }
    public func group(id: String) -> DockGroup? { groups.first { $0.id == id } }

    /// The child-index path from this node to the split at `path` (empty = this node).
    public func node(at path: [Int]) -> DockNode? {
        guard let first = path.first else { return self }
        guard case .split(let s) = self, s.children.indices.contains(first) else { return nil }
        return s.children[first].node(at: Array(path.dropFirst()))
    }

    /// The path of the group with `id`.
    public func path(toGroup id: String) -> [Int]? {
        switch self {
        case .group(let g): return g.id == id ? [] : nil
        case .split(let s):
            for (i, child) in s.children.enumerated() {
                if let rest = child.path(toGroup: id) { return [i] + rest }
            }
            return nil
        }
    }

    /// This node with the node at `path` replaced by `transform` of it (unchanged when the path is not there).
    func replacing(at path: [Int], _ transform: (DockNode) -> DockNode) -> DockNode {
        guard let first = path.first else { return transform(self) }
        guard case .split(var s) = self, s.children.indices.contains(first) else { return self }
        s.children[first] = s.children[first].replacing(at: Array(path.dropFirst()), transform)
        return .split(s)
    }

    /// This node with every group passed through `transform`; a group that becomes nil is removed.
    /// The result is not normalized.
    func mapGroups(_ transform: (DockGroup) -> DockGroup?) -> DockNode? {
        switch self {
        case .group(let g): return transform(g).map(DockNode.group)
        case .split(var s):
            var kids: [DockNode] = [], weights: [Double] = []
            for (child, w) in zip(s.children, s.weights) {
                guard let n = child.mapGroups(transform) else { continue }
                kids.append(n); weights.append(w)
            }
            guard !kids.isEmpty else { return nil }
            s.children = kids; s.weights = weights
            return .split(s)
        }
    }
}

/// Where a closed panel was, so reopening puts it back: beside the panels it shared a group with, else on the
/// remembered side of the group next to it, else at its default zone.
public struct DockPlace: Codable, Equatable, Sendable {
    /// The other panels of its group when it closed, in tab order.
    public var mates: [DockPanelID] = []
    /// Its tab index in that group.
    public var index = 0
    /// When it was alone: the panels of the neighbouring group, and the side of that group it sat on.
    public var neighbour: [DockPanelID] = []
    public var edge: DockEdge?
    /// Its share of the space it and the neighbour had together (0…1).
    public var fraction: Double?
    /// Nowhere remembered: reopening uses the default zone.
    public init() {}

    /// A tab among `mates` at `index`.
    public static func tab(mates: [DockPanelID], index: Int) -> DockPlace {
        var p = DockPlace()
        p.mates = mates; p.index = index
        return p
    }

    /// Its own group on `edge` of the group holding `neighbour`, with `fraction` of their space.
    public static func beside(_ neighbour: [DockPanelID], edge: DockEdge?, fraction: Double?) -> DockPlace {
        var p = DockPlace()
        p.neighbour = neighbour; p.edge = edge; p.fraction = fraction
        return p
    }
}
