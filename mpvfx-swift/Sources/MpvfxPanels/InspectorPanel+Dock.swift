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

/// The Design tab's groups as dock panels: dragging a header out, reordering by header, the ⋯ menu, and the
/// detached instance a dock panel hosts. A group lives in exactly one place: `buildGroups()` leaves out the groups
/// whose panel is open, and a pinned instance shows only its own panel's groups.
extension InspectorPanel {
    public struct GroupPress: Equatable {
        public var panel: DockPanelID
        /// The open group before the press toggled it (a drag gives it back).
        public var previousOpen: String
        public var at: CanvasPoint
    }

    /// A header being dragged. `slotBefore` is the panel it would land above in the Design tab (nil: the end);
    /// `outside` once the pointer left the panel, where the dock takes over.
    public struct GroupDrag: Equatable {
        public var panel: DockPanelID
        public var point: CanvasPoint
        public var outside: Bool
        public var slotBefore: DockPanelID?
        public var slotY: Double?
    }

    public enum GroupDragEvent: Equatable {
        case moved(DockPanelID, CanvasPoint)
        case dropped(DockPanelID, CanvasPoint)
        case cancelled(DockPanelID)
    }

    public struct GroupMenuRequest {
        public struct Item { public let title: String; public let run: () -> Void }
        public let panel: DockPanelID
        public let anchor: CanvasRect
        public let items: [Item]
    }

    /// A header press becomes a drag after this many points.
    public static let groupDragThreshold = 4.0
    public static let moveToPanelTitle = "Move to Panel"
    public static let returnToDesignTitle = "Return to Design"

    func isOpen(_ groupId: String) -> Bool { pinnedPanel != nil || groupId == openGroupId }

    /// Takes the open panels of the dock layout as the detached groups (call when the layout changes).
    public func syncDock(_ layout: DockLayout) { detachedPanels = layout.detachedDesignPanels }

    /// Copies what a detached instance needs from the Design tab's: the document, selection, playhead and the host
    /// hooks. The groups' own UI state (open curve tab, catalog family) stays with each instance.
    public func follow(_ source: InspectorPanel) {
        editor = source.editor; selection = source.selection; time = source.time
        audioGroupId = source.audioGroupId; selectedKeyframes = source.selectedKeyframes
        onEdited = source.onEdited; onSeek = source.onSeek; onClearSelection = source.onClearSelection
        userLookStore = source.userLookStore; resolveUserLookLut = source.resolveUserLookLut; userLookLutExists = source.userLookLutExists
        onAnimate = source.onAnimate; onAudition = source.onAudition; onImportLut = source.onImportLut
        presetPreview = source.presetPreview; effectPreview = source.effectPreview
        presetPreviewsAvailable = source.presetPreviewsAvailable; onRetryPresetPreviews = source.onRetryPresetPreviews
        scopeFrame = source.scopeFrame; lutAssets = source.lutAssets; onOpenDropdown = source.onOpenDropdown
        onMoveToPanel = source.onMoveToPanel; onReturnToDesign = source.onReturnToDesign; onGroupMenu = source.onGroupMenu
    }

    // MARK: Menu

    func drawGroupMenuButton(_ c: CanvasContext, _ header: CanvasRect, _ id: String, rightEdge: Double) {
        let r = CanvasRect(x: rightEdge - 14, y: header.y + (header.height - 14) / 2, width: 14, height: 14)
        PanelIcon.panelMenu.draw(c, in: r, color: hovered == .groupMenu(id) ? PanelTheme.text1 : PanelTheme.text4)
        addHit(r.insetBy(-4), .groupMenu(id))
    }

    func openGroupMenu(_ groupId: String) {
        guard let panel = DesignGroups.panel(forGroup: groupId), let anchor = hits.rect(where: { $0 == .groupMenu(groupId) }) else { return }
        let item = pinnedPanel != nil
            ? GroupMenuRequest.Item(title: Self.returnToDesignTitle) { [weak self] in self?.onReturnToDesign?(panel) }
            : GroupMenuRequest.Item(title: Self.moveToPanelTitle) { [weak self] in self?.onMoveToPanel?(panel) }
        onGroupMenu?(GroupMenuRequest(panel: panel, anchor: anchor, items: [item]))
    }

    // MARK: Header drag

    func groupPointerMove(_ p: CanvasPoint) -> Bool {
        if groupDrag == nil, let press = groupPress {
            guard hypot(p.x - press.at.x, p.y - press.at.y) >= Self.groupDragThreshold else { return false }
            // The press toggled the accordion; a drag is not a click, so the open group comes back.
            if openGroupId != press.previousOpen { openGroupId = press.previousOpen; onOpenGroupChanged?(openGroupId) }
            groupDrag = GroupDrag(panel: press.panel, point: p, outside: false)
        }
        guard var d = groupDrag else { return false }
        d.point = p
        d.outside = !lastRect.contains(p)
        if d.outside {
            d.slotBefore = nil; d.slotY = nil
            onGroupDrag?(.moved(d.panel, p))
        } else {
            (d.slotBefore, d.slotY) = slot(at: p)
        }
        groupDrag = d
        onEdited?()
        return true
    }

    /// The detachable group header the pointer is above (insert before it), else the end; with its y.
    func slot(at p: CanvasPoint) -> (DockPanelID?, Double?) {
        let headers = hits.regions.compactMap { region -> (DockPanelID, CanvasRect)? in
            if case .group(let id) = region.action, let panel = DesignGroups.panel(forGroup: id) { return (panel, region.rect) }
            return nil
        }
        if let h = headers.first(where: { $0.1.midY > p.y }) { return (h.0, h.1.y) }
        let bottom = hits.regions.compactMap { region -> Double? in
            switch region.action { case .group, .body: return region.rect.maxY; default: return nil }
        }.max()
        return (nil, bottom.map { min($0, bodyRect.maxY) })
    }

    func groupPointerUp(_ p: CanvasPoint) {
        defer { groupPress = nil; groupDrag = nil }
        guard let d = groupDrag else { return }
        if !lastRect.contains(p) { onGroupDrag?(.dropped(d.panel, p)) }
        else { reorder(d.panel, before: slot(at: p).0) }
        onEdited?()
    }

    /// Escape during a header drag: the group stays where it was.
    @discardableResult
    public func cancelGroupDrag() -> Bool {
        guard let d = groupDrag else { return false }
        groupDrag = nil; groupPress = nil
        if d.outside { onGroupDrag?(.cancelled(d.panel)) }
        onEdited?()
        return true
    }

    /// Moves a group's place in the Design tab: above `target`'s, or last when nil.
    public func reorder(_ panel: DockPanelID, before target: DockPanelID?) {
        guard DesignGroups.isDesignPanel(panel), panel != target else { return }
        var order = DesignGroups.sanitized(order: designOrder)
        order.removeAll { $0 == panel }
        if let target, let i = order.firstIndex(of: target) { order.insert(panel, at: i) } else { order.append(panel) }
        designOrder = order
    }
}
