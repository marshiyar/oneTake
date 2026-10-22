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

/// What releasing a dragged tab does.
public enum DockDragTarget: Equatable, Sendable {
    case move(DockDropTarget)
    /// Exchange places with this panel (⌥ held over another tab).
    case swap(DockPanelID)
}

/// The drop under the pointer and what the overlay shows for it.
public struct DockDropPreview: Equatable, Sendable {
    public var target: DockDragTarget
    /// The area the panel will take, tinted while dragging.
    public var highlight: CanvasRect
    /// For a drop between tabs: the 2 pt insertion bar.
    public var insertion: CanvasRect?
}

/// Maps a pointer position during a tab drag to a drop (pure, so it is tested without drawing).
public enum DockDrop {
    /// Within this many points of the dock's outer edge, a drop docks along the whole window edge.
    public static let windowEdgeBand = 24.0
    /// The outer share of a group's content on each side that splits it on that side; the middle stacks.
    public static let edgeShare = 0.25

    /// The pointer during a tab drag: where it is, which panel it carries, and whether ⌥ (swap) is held.
    public struct Probe: Equatable, Sendable {
        public var point: CanvasPoint
        public var panel: DockPanelID
        public var swap: Bool
        public init(point: CanvasPoint, panel: DockPanelID, swap: Bool = false) { self.point = point; self.panel = panel; self.swap = swap }
    }

    /// What a drop is resolved against: the layout, its geometry and the tab rects of the last draw.
    public struct Scene: Sendable {
        public var layout: DockLayout
        public var geometry: DockGeometry
        public var tabs: [String: [DockTabBar.Tab]]
        /// Resolves a panel that is not open yet (a Design group dragged in from outside the dock).
        public var registry: DockRegistry
        public init(layout: DockLayout, geometry: DockGeometry, tabs: [String: [DockTabBar.Tab]], registry: DockRegistry = .editor) {
            self.layout = layout; self.geometry = geometry; self.tabs = tabs; self.registry = registry
        }
    }

    public static func preview(_ probe: Probe, scene: Scene) -> DockDropPreview? {
        guard scene.geometry.bounds.contains(probe.point), let candidate = candidate(probe, scene: scene) else { return nil }
        return isUseful(candidate.target, dragging: probe.panel, scene: scene) ? candidate : nil
    }

    static func candidate(_ probe: Probe, scene: Scene) -> DockDropPreview? {
        let p = probe.point, geometry = scene.geometry
        // Tab bars first: the top row's bars lie inside the window's top edge band.
        if let frame = geometry.groups.first(where: { $0.strip.contains(p) }) {
            return stripPreview(probe, frame, scene.tabs[frame.group.id] ?? [])
        }
        if let edge = windowEdge(p, geometry.bounds) { return windowPreview(edge, geometry.bounds) }
        guard let frame = geometry.groups.first(where: { $0.frame.contains(p) }) else { return nil }
        return contentPreview(p, frame)
    }

    /// A drop that would change nothing (a lone tab onto its own bar) or that the layout refuses shows no overlay.
    static func isUseful(_ target: DockDragTarget, dragging panel: DockPanelID, scene: Scene) -> Bool {
        guard case .success(let after) = applying(target, dragging: panel, to: scene.layout, registry: scene.registry) else { return false }
        return after != scene.layout
    }

    /// The layout after the drop, or the operation's typed error.
    public static func applying(_ target: DockDragTarget, dragging panel: DockPanelID, to layout: DockLayout,
                                registry: DockRegistry) -> Result<DockLayout, DockOpError> {
        var copy = layout
        do {
            switch target {
            case .move(let t):
                // A panel from outside the dock (a Design group header) is opened at the drop.
                if copy.isOpen(panel) { try copy.move(panel, to: t, fraction: fraction(for: t)) }
                else { try copy.dock(panel, at: t, registry: registry, fraction: fraction(for: t)) }
            case .swap(let other): try copy.swap(panel, other)
            }
            return .success(copy)
        } catch let e as DockOpError {
            return .failure(e)
        } catch {
            return .failure(.invalidTarget)
        }
    }

    /// A window edge takes a quarter of the window, a group edge half the group.
    static func fraction(for target: DockDropTarget) -> Double {
        if case .window = target { return DockLayout.defaultSideFraction }
        return 0.5
    }

    static func windowEdge(_ p: CanvasPoint, _ b: CanvasRect) -> DockEdge? {
        let distances: [(DockEdge, Double)] = [(.left, p.x - b.x), (.right, b.maxX - p.x), (.top, p.y - b.y), (.bottom, b.maxY - p.y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < windowEdgeBand else { return nil }
        return nearest.0
    }

    static func windowPreview(_ edge: DockEdge, _ b: CanvasRect) -> DockDropPreview {
        DockDropPreview(target: .move(.window(edge)), highlight: side(of: b, edge, share: DockLayout.defaultSideFraction), insertion: nil)
    }

    static func stripPreview(_ probe: Probe, _ frame: DockGroupFrame, _ tabs: [DockTabBar.Tab]) -> DockDropPreview {
        let p = probe.point
        if probe.swap, let over = tabs.first(where: { $0.rect.contains(p) && $0.panel != probe.panel }) {
            return DockDropPreview(target: .swap(over.panel), highlight: over.rect, insertion: nil)
        }
        let index = tabs.filter { $0.rect.midX < p.x }.count
        let x = index < tabs.count ? tabs[index].rect.x : (tabs.last?.rect.maxX ?? frame.strip.x + PanelTabStrip.edgeInset)
        let bar = CanvasRect(x: x - 1, y: frame.strip.y + 4, width: 2, height: frame.strip.height - 8)
        return DockDropPreview(target: .move(.stack(group: frame.group.id, index: index)), highlight: frame.frame, insertion: bar)
    }

    static func contentPreview(_ p: CanvasPoint, _ frame: DockGroupFrame) -> DockDropPreview {
        let r = frame.content
        guard r.width > 0, r.height > 0 else {
            return DockDropPreview(target: .move(.stack(group: frame.group.id, index: nil)), highlight: frame.frame, insertion: nil)
        }
        let rel: [(DockEdge, Double)] = [(.left, (p.x - r.x) / r.width), (.right, (r.maxX - p.x) / r.width),
                                         (.top, (p.y - r.y) / r.height), (.bottom, (r.maxY - p.y) / r.height)]
        if let nearest = rel.min(by: { $0.1 < $1.1 }), nearest.1 < edgeShare {
            return DockDropPreview(target: .move(.split(group: frame.group.id, edge: nearest.0)),
                                   highlight: side(of: frame.frame, nearest.0, share: 0.5), insertion: nil)
        }
        return DockDropPreview(target: .move(.stack(group: frame.group.id, index: nil)), highlight: frame.frame, insertion: nil)
    }

    /// The `share` of `r` along its `edge`.
    static func side(of r: CanvasRect, _ edge: DockEdge, share: Double) -> CanvasRect {
        switch edge {
        case .left: return CanvasRect(x: r.x, y: r.y, width: (r.width * share).rounded(), height: r.height)
        case .right: let w = (r.width * share).rounded(); return CanvasRect(x: r.maxX - w, y: r.y, width: w, height: r.height)
        case .top: return CanvasRect(x: r.x, y: r.y, width: r.width, height: (r.height * share).rounded())
        case .bottom: let h = (r.height * share).rounded(); return CanvasRect(x: r.x, y: r.maxY - h, width: r.width, height: h)
        }
    }
}
