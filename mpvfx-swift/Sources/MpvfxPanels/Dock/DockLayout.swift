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

/// Where a dragged or reopened panel goes.
public enum DockDropTarget: Equatable, Sendable {
    /// Into a group as a tab at `index` (nil: last); within its own group this reorders.
    case stack(group: String, index: Int?)
    /// A new group on `edge` of an existing group.
    case split(group: String, edge: DockEdge)
    /// A new group along the whole window edge.
    case window(DockEdge)
}

public enum DockOpError: Error, Equatable, CustomStringConvertible {
    case unknownPanel(DockPanelID)
    case notOpen(DockPanelID)
    case notClosable(DockPanelID)
    case unknownGroup(String)
    case invalidTarget
    case invalidWeights

    public var description: String {
        switch self {
        case .unknownPanel(let id): return "No panel \"\(id)\" is registered"
        case .notOpen(let id): return "Panel \"\(id)\" is not open"
        case .notClosable(let id): return "Panel \"\(id)\" cannot be closed"
        case .unknownGroup(let id): return "No panel group \"\(id)\" is open"
        case .invalidTarget: return "A panel cannot be dropped there"
        case .invalidWeights: return "Splitter sizes must be finite, positive and one per side"
        }
    }
}

/// The dock's state: the open panels' tree and where each closed panel was. A value: every operation either
/// applies completely and leaves the invariants in place (see `normalize`), or throws and changes nothing.
public struct DockLayout: Equatable, Sendable {
    public internal(set) var root: DockNode
    public internal(set) var closed: [DockPanelID: DockPlace]
    /// The last number used for a generated group id (`g<n>`).
    var serial: Int

    public init(root: DockNode, closed: [DockPanelID: DockPlace] = [:]) {
        self.root = root
        self.closed = closed
        serial = Self.highestSerial(in: root)
        normalizeTree()
    }

    /// An empty dock (no panel open): what normalizing an empty tree leaves.
    static var empty: DockLayout { DockLayout(root: .group(DockGroup(id: "g1", panels: []))) }

    public var openPanels: [DockPanelID] { root.panels }
    public var groups: [DockGroup] { root.groups }
    public func isOpen(_ panel: DockPanelID) -> Bool { root.group(containing: panel) != nil }

    static func highestSerial(in root: DockNode) -> Int {
        root.groups.compactMap { g in g.id.hasPrefix("g") ? Int(g.id.dropFirst()) : nil }.max() ?? 0
    }

    mutating func newGroupID() -> String {
        let used = Set(root.groups.map(\.id))
        repeat { serial += 1 } while used.contains("g\(serial)")
        return "g\(serial)"
    }

    // MARK: Normalize

    /// Restores the structural invariants: no empty group, an active tab in each group, no split with fewer than
    /// two children, no split directly inside a split of the same axis, weights finite, positive and summing to 1,
    /// unique group ids.
    mutating func normalizeTree() {
        root = Self.normalized(root) ?? .group(DockGroup(id: newGroupID(), panels: []))
        makeGroupIDsUnique()
    }

    /// A group whose id is malformed or already taken gets a fresh `g<n>`.
    private mutating func makeGroupIDsUnique() {
        var seen = Set<String>(), used = Set(root.groups.map(\.id)), counter = serial
        root = root.mapGroups { g in
            if DockRegistry.isValidID(g.id), !seen.contains(g.id) { seen.insert(g.id); return g }
            var copy = g
            repeat { counter += 1 } while used.contains("g\(counter)")
            copy.id = "g\(counter)"
            used.insert(copy.id); seen.insert(copy.id)
            return copy
        } ?? root
        serial = counter
    }

    static func normalized(_ node: DockNode) -> DockNode? {
        switch node {
        case .group(var g):
            guard !g.panels.isEmpty else { return nil }
            if !g.panels.contains(g.active) { g.active = g.panels[0] }
            return .group(g)
        case .split(let s):
            return normalizedSplit(s)
        }
    }

    private static func normalizedSplit(_ s: DockSplit) -> DockNode? {
        var kids: [DockNode] = [], weights: [Double] = []
        let own = fixedWeights(s.weights, count: s.children.count)
        for (child, w) in zip(s.children, own) {
            guard let n = normalized(child) else { continue }
            if case .split(let inner) = n, inner.axis == s.axis {
                kids += inner.children
                weights += inner.weights.map { $0 * w }
            } else {
                kids.append(n); weights.append(w)
            }
        }
        guard kids.count > 1 else { return kids.first }
        return .split(DockSplit(axis: s.axis, children: kids, weights: fixedWeights(weights, count: kids.count)))
    }

    /// The smallest share a child keeps (a child that cannot be seen cannot be dragged back).
    static let minShare = 0.01

    /// `count` shares summing to 1: a missing, non-finite or non-positive share becomes the mean of the valid ones,
    /// and none is below `minShare` (below `1 / count` when there are more than 100 children).
    static func fixedWeights(_ raw: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let given = (0..<count).map { i in i < raw.count && raw[i].isFinite && raw[i] > 0 ? raw[i] : nil }
        // Scaled by the largest first, so huge values cannot overflow the sum.
        let top = given.compactMap { $0 }.max() ?? 1
        let known = given.compactMap { $0.map { $0 / top } }
        let mean = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
        return floored(given.map { $0.map { $0 / top } ?? mean }, minimum: min(minShare, 1 / Double(count)))
    }

    /// Shares summing to 1 with none below `m`: a share under it is raised to it and the others share what is left
    /// in proportion, repeated until none falls below (`m × count ≤ 1`).
    static func floored(_ w: [Double], minimum m: Double) -> [Double] {
        var fixed = Set<Int>(), out = w
        for _ in 0...w.count {
            let free = w.indices.filter { !fixed.contains($0) }
            let freeSum = free.map { w[$0] }.reduce(0, +), rest = 1 - m * Double(fixed.count)
            var changed = false
            for i in free {
                out[i] = freeSum > 0 ? w[i] / freeSum * rest : rest / Double(free.count)
                if out[i] < m { out[i] = m; fixed.insert(i); changed = true }
            }
            if !changed { break }
        }
        return out
    }
}
