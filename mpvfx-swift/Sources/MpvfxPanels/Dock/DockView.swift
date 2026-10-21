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
import MpvfxTimeline

/// The dock on the canvas: every group's tab bar, its active panel's content (painted by the host), the splitters,
/// and the drag of a tab with its drop-zone overlay. Host-neutral: a shell hands it points in the dock's own
/// coordinates and paints panel content through the closure `draw` takes.
public final class DockView {
    public internal(set) var layout: DockLayout
    public var registry: DockRegistry
    public internal(set) var geometry = DockGeometry()
    /// A gesture changed the layout for good (drop, close, splitter release, reset): persist it.
    public var onCommit: (DockLayout) -> Void = { _ in }
    /// The group's menu button was pressed; `anchor` is the button (dock coordinates).
    public var onMenu: (_ group: DockGroup, _ anchor: CanvasRect) -> Void = { _, _ in }
    /// Seconds, for double-click detection (tests inject a clock).
    public var now: () -> Double = { Date().timeIntervalSinceReferenceDate }
    public static let doubleClickInterval = 0.4
    /// A press on a tab becomes a drag after the pointer moves this far.
    public static let dragThreshold = 4.0

    /// The panel that takes keys; its tab shows the focus ring after keyboard use.
    public internal(set) var focused: DockPanelID?
    public internal(set) var focusVisible = false
    public internal(set) var hovered: Hit?
    public internal(set) var drag: Drag?
    public internal(set) var splitterDrag: SplitterDrag?
    var press: (panel: DockPanelID, at: CanvasPoint)?
    var lastSplitterPress: (path: [Int], index: Int, at: Double)?
    /// Hit regions and tab rects of the last draw (pointer events resolve against them).
    var hits = HitMap<Hit>()
    var tabs: [String: [DockTabBar.Tab]] = [:]

    public enum Hit: Equatable, Sendable {
        case tab(DockPanelID), close(DockPanelID), menu(String), strip(String), splitter(Int)
    }

    public struct Drag: Equatable, Sendable {
        public var panel: DockPanelID
        public var point: CanvasPoint
        public var preview: DockDropPreview?
    }

    public struct SplitterDrag: Equatable, Sendable {
        public var splitter: DockSplitter
        public var start: CanvasPoint
    }

    /// What a press did: the dock's chrome took it, or it lands in a panel's content (`local` in content coordinates).
    public enum Outcome: Equatable, Sendable { case none, handled, content(DockPanelID, local: CanvasPoint) }

    public init(layout: DockLayout, registry: DockRegistry) {
        self.layout = layout
        self.registry = registry
        focused = layout.root.groups.first(where: { $0.panels.contains(DockPanels.timeline) })?.active ?? layout.groups.first?.active
    }

    /// Replaces the layout (a workspace switch or a reset from a menu); not a gesture, so `onCommit` is not called.
    public func setLayout(_ next: DockLayout) {
        layout = next
        drag = nil; splitterDrag = nil; press = nil
        if let f = focused, !layout.isOpen(f) { focused = layout.groups.first?.active }
    }

    /// Runs a layout operation; on success the layout changes and is committed. A refused operation changes
    /// nothing and returns its typed error.
    @discardableResult
    public func perform(_ op: (inout DockLayout) throws -> Void) -> DockOpError? {
        var copy = layout
        do { try op(&copy) } catch let e as DockOpError { return e } catch { return .invalidTarget }
        guard copy != layout else { return nil }
        layout = copy
        if let f = focused, !layout.isOpen(f) { focused = layout.groups.first?.active }
        onCommit(layout)
        return nil
    }

    // MARK: Geometry

    /// Lays the dock out in `rect` (dock coordinates; the shell's full content rect).
    public func layout(in rect: CanvasRect) { geometry = DockGeometry.compute(layout, registry: registry, in: rect) }

    /// The visible content rect of a panel (nil when closed or behind another tab).
    public func contentRect(of panel: DockPanelID) -> CanvasRect? { geometry.content(of: panel) }

    /// The panel whose content is under `p`, and `p` in its content coordinates.
    public func content(at p: CanvasPoint) -> (panel: DockPanelID, local: CanvasPoint)? {
        guard let f = geometry.groups.first(where: { $0.content.contains(p) }), !f.group.active.isEmpty else { return nil }
        return (f.group.active, CanvasPoint(p.x - f.content.x, p.y - f.content.y))
    }
}
