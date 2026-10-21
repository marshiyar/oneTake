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

/// Move, swap, close, open: each validates first and throws `DockOpError` without touching the layout, so a
/// caller can apply a gesture's result directly. No undo stack: the layout is UI state, not the document.
extension DockLayout {
    /// Moves an open panel to `target`; `fraction` is the share a new group takes of the space it splits.
    public mutating func move(_ panel: DockPanelID, to target: DockDropTarget, fraction: Double = 0.5) throws {
        guard let from = root.group(containing: panel) else { throw DockOpError.notOpen(panel) }
        try checkTarget(target, moving: panel, from: from)
        // A lone tab dropped on its own tab bar stays where it is.
        if case .stack(let id, _) = target, id == from.id, from.panels.count == 1 { activate(panel); return }
        var next = self
        next.detach(panel)
        try next.attach(panel, to: Self.adjusted(target, moving: panel, from: from), fraction: fraction)
        self = next
    }

    /// A stack index counts the gaps between the tabs as they are before the move; within the panel's own group
    /// the tabs after it shift left once it is lifted out.
    static func adjusted(_ target: DockDropTarget, moving panel: DockPanelID, from: DockGroup) -> DockDropTarget {
        guard case .stack(let id, let index?) = target, id == from.id,
              let old = from.panels.firstIndex(of: panel), old < index else { return target }
        return .stack(group: id, index: index - 1)
    }

    /// The two open panels exchange places: their tab slots, and their groups when they are in different ones.
    public mutating func swap(_ a: DockPanelID, _ b: DockPanelID) throws {
        guard let ga = root.group(containing: a) else { throw DockOpError.notOpen(a) }
        guard let gb = root.group(containing: b) else { throw DockOpError.notOpen(b) }
        guard a != b else { return }
        let sameGroup = ga.id == gb.id
        func swapped(_ p: DockPanelID) -> DockPanelID { p == a ? b : (p == b ? a : p) }
        root = root.mapGroups { g in
            var copy = g
            copy.panels = g.panels.map(swapped)
            if !sameGroup { copy.active = swapped(g.active) }
            return copy
        } ?? root
    }

    /// Closes a panel and remembers where it was (`DockPlace`), so `open` puts it back.
    public mutating func close(_ panel: DockPanelID, registry: DockRegistry) throws {
        guard registry.isClosable(panel) else { throw DockOpError.notClosable(panel) }
        guard root.group(containing: panel) != nil else { throw DockOpError.notOpen(panel) }
        let place = self.place(of: panel)
        detach(panel)
        closed[panel] = place
    }

    /// Opens a registered panel at its last place (else its default zone) and makes it the active tab; an open
    /// panel is only activated.
    public mutating func open(_ panel: DockPanelID, registry: DockRegistry) throws {
        guard let spec = registry.spec(panel) else { throw DockOpError.unknownPanel(panel) }
        if isOpen(panel) { activate(panel); return }
        let place = closed.removeValue(forKey: panel)
        if let place, restore(panel, place) { return }
        placeAtDefault(spec, registry: registry)
    }

    /// Makes an open panel its group's visible tab (no-op for a panel that is not open).
    public mutating func activate(_ panel: DockPanelID) {
        guard let g = root.group(containing: panel), g.active != panel else { return }
        root = root.mapGroups { $0.id == g.id ? DockGroup(id: $0.id, panels: $0.panels, active: panel) : $0 } ?? root
    }

    /// Sets the shares of the split at `path` (a splitter drag); `weights` must have one finite positive value per child.
    public mutating func setWeights(at path: [Int], _ weights: [Double]) throws {
        guard case .split(let s)? = root.node(at: path) else { throw DockOpError.invalidTarget }
        guard weights.count == s.children.count, weights.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw DockOpError.invalidWeights }
        let fixed = Self.fixedWeights(weights, count: weights.count)
        root = root.replacing(at: path) { node in
            guard case .split(var split) = node else { return node }
            split.weights = fixed
            return .split(split)
        }
    }

    /// Adds registered panels that cannot be closed but are missing, and forgets closed entries for panels that are
    /// open or no longer registered.
    public mutating func repair(registry: DockRegistry) {
        for spec in registry.specs where !spec.closable && !isOpen(spec.id) {
            closed.removeValue(forKey: spec.id)
            placeAtDefault(spec, registry: registry)
        }
        closed = closed.filter { registry.contains($0.key) && !isOpen($0.key) && registry.isClosable($0.key) }
    }

    // MARK: Internals

    private func checkTarget(_ target: DockDropTarget, moving panel: DockPanelID, from: DockGroup) throws {
        switch target {
        case .stack(let id, _):
            guard root.group(id: id) != nil else { throw DockOpError.unknownGroup(id) }
        case .split(let id, _):
            guard root.group(id: id) != nil else { throw DockOpError.unknownGroup(id) }
            // Splitting a group off itself with nothing left behind would put the panel back where it was.
            if id == from.id, from.panels.count == 1 { throw DockOpError.invalidTarget }
        case .window:
            break
        }
    }

    /// Removes a panel from the tree (normalized; an emptied group disappears).
    mutating func detach(_ panel: DockPanelID) {
        root = root.mapGroups { g in
            var copy = g
            copy.panels.removeAll { $0 == panel }
            return copy.panels.isEmpty ? nil : copy
        } ?? .group(DockGroup(id: "", panels: []))
        normalizeTree()
    }

    mutating func attach(_ panel: DockPanelID, to target: DockDropTarget, fraction: Double) throws {
        guard insert(panel, at: target, fraction: fraction) else {
            if case .stack(let id, _) = target { throw DockOpError.unknownGroup(id) }
            if case .split(let id, _) = target { throw DockOpError.unknownGroup(id) }
            throw DockOpError.invalidTarget
        }
    }

    /// Inserts a panel that is not in the tree; false (nothing changed) when the target group is not open.
    @discardableResult
    mutating func insert(_ panel: DockPanelID, at target: DockDropTarget, fraction: Double) -> Bool {
        let f = min(0.9, max(0.1, fraction.isFinite ? fraction : 0.5))
        switch target {
        case .stack(let id, let index):
            guard root.group(id: id) != nil else { return false }
            root = root.mapGroups { g in g.id == id ? Self.inserting(panel, into: g, at: index) : g } ?? root
        case .split(let id, let edge):
            guard let path = root.path(toGroup: id) else { return false }
            let fresh = DockNode.group(DockGroup(id: newGroupID(), panels: [panel]))
            root = root.replacing(at: path) { Self.splitting($0, with: fresh, edge: edge, fraction: f) }
        case .window(let edge):
            let fresh = DockNode.group(DockGroup(id: newGroupID(), panels: [panel]))
            root = root.panels.isEmpty ? fresh : Self.splitting(root, with: fresh, edge: edge, fraction: f)
        }
        normalizeTree()
        return true
    }

    static func inserting(_ panel: DockPanelID, into g: DockGroup, at index: Int?) -> DockGroup {
        var copy = g
        let i = min(max(0, index ?? copy.panels.count), copy.panels.count)
        copy.panels.insert(panel, at: i)
        copy.active = panel
        return copy
    }

    static func splitting(_ node: DockNode, with fresh: DockNode, edge: DockEdge, fraction f: Double) -> DockNode {
        let kids = edge.isLeading ? [fresh, node] : [node, fresh]
        let weights = edge.isLeading ? [f, 1 - f] : [1 - f, f]
        return .split(DockSplit(axis: edge.axis, children: kids, weights: weights))
    }
}
