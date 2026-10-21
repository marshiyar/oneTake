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

/// The Design tab's groups as dock panels. A group lives in exactly one place: its panel is closed (the group shows
/// in the Design tab) or open (the group shows in that panel and is gone from the tab). The ids are saved in layouts:
/// never rename one.
public enum DesignGroups {
    public struct Entry: Equatable, Sendable {
        public let panel: DockPanelID
        public let title: String
        /// The inspector group ids this panel shows (`InspectorGroup.id`), in tab order.
        public let groups: [String]
    }

    public static let style: DockPanelID = "design.style"
    public static let transform: DockPanelID = "design.transform"
    public static let grade: DockPanelID = "design.grade"
    public static let effects: DockPanelID = "design.effects"
    public static let audioFx: DockPanelID = "design.audio-fx"
    public static let media: DockPanelID = "design.media"

    /// In the Design tab's default order.
    public static let all: [Entry] = [
        Entry(panel: transform, title: "Transform", groups: ["layout"]),
        Entry(panel: style, title: "Style", groups: ["style"]),
        Entry(panel: grade, title: "Grade", groups: ["grade"]),
        Entry(panel: effects, title: "Effects", groups: ["effects", "clip-effects"]),
        Entry(panel: audioFx, title: "Audio FX", groups: ["audio-fx"]),
        Entry(panel: media, title: "Media", groups: ["media"]),
    ]

    public static var panelIDs: [DockPanelID] { all.map(\.panel) }

    /// Registered closed by default, on the right (the Design tab's side), as wide as the Design tab.
    public static var specs: [DockPanelSpec] {
        all.map { DockPanelSpec(id: $0.panel, title: $0.title, defaultDock: .right, minSize: CanvasSize(PanelFit.minRight, 80))
            .preferring(CanvasSize(409, 0)).closedByDefault() }
    }

    public static func isDesignPanel(_ id: DockPanelID) -> Bool { all.contains { $0.panel == id } }
    /// The panel that carries an inspector group (nil: the group cannot be detached, e.g. Text).
    public static func panel(forGroup group: String) -> DockPanelID? { all.first { $0.groups.contains(group) }?.panel }
    public static func groups(of panel: DockPanelID) -> [String] { all.first { $0.panel == panel }?.groups ?? [] }

    /// `order` with unknown and repeated ids dropped and the missing panels appended in the default order.
    public static func sanitized(order: [DockPanelID]?) -> [DockPanelID] {
        var seen = Set<DockPanelID>(), out: [DockPanelID] = []
        for id in (order ?? []) + panelIDs where isDesignPanel(id) && seen.insert(id).inserted { out.append(id) }
        return out
    }
}

extension DockLayout {
    /// The Design groups currently shown in their own panels.
    public var detachedDesignPanels: Set<DockPanelID> { Set(openPanels.filter(DesignGroups.isDesignPanel)) }

    /// Opens a registered panel that is not open at a drop target (a drag from outside the dock, such as a Design
    /// group header). An open panel is moved instead. Throws and changes nothing when the target is not there.
    public mutating func dock(_ panel: DockPanelID, at target: DockDropTarget, registry: DockRegistry, fraction: Double = 0.5) throws {
        guard registry.contains(panel) else { throw DockOpError.unknownPanel(panel) }
        if isOpen(panel) { try move(panel, to: target, fraction: fraction); return }
        var next = self
        guard next.insert(panel, at: target, fraction: fraction) else {
            switch target {
            case .stack(let id, _), .split(let id, _): throw DockOpError.unknownGroup(id)
            case .window: throw DockOpError.invalidTarget
            }
        }
        next.closed.removeValue(forKey: panel)
        self = next
    }

    /// "Move to Panel": the group gets its own panel under the Design tab's, else where a new panel opens by default.
    public mutating func moveToPanel(_ panel: DockPanelID, registry: DockRegistry) throws {
        guard DesignGroups.isDesignPanel(panel) else { throw DockOpError.unknownPanel(panel) }
        if let design = root.group(containing: DockPanels.inspector), !isOpen(panel) {
            try dock(panel, at: .split(group: design.id, edge: .bottom), registry: registry)
        } else {
            try open(panel, registry: registry)
        }
    }

    /// "Return to Design": closes the group's panel, so the Design tab shows the group again.
    public mutating func returnToDesign(_ panel: DockPanelID, registry: DockRegistry) throws {
        guard DesignGroups.isDesignPanel(panel) else { throw DockOpError.unknownPanel(panel) }
        guard isOpen(panel) else { return }
        try close(panel, registry: registry)
    }
}
