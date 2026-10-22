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

/// Pointer and keys, in dock coordinates. Resolve against the hit regions of the last `draw`.
extension DockView {
    // MARK: Pointer

    /// A primary press: the chrome (tab, ×, ⋯, splitter, empty strip) takes it, else it lands in a panel's content.
    public func pointerDown(_ p: CanvasPoint, button: Int = PointerButton.primary) -> Outcome {
        focusVisible = false
        guard button == PointerButton.primary, let hit = hits.hit(p) else { return contentOutcome(p) }
        pressChrome(hit, at: p)
        return .handled
    }

    func pressChrome(_ hit: Hit, at p: CanvasPoint) {
        switch hit {
        case .tab(let id): activateTab(id); press = (id, p)
        case .close(let id): perform { try $0.close(id, registry: registry) }
        case .menu(let gid): openMenu(gid)
        case .strip(let gid): if let g = layout.root.group(id: gid) { focused = g.active }
        case .splitter(let i): pressSplitter(i, at: p)
        }
    }

    func contentOutcome(_ p: CanvasPoint) -> Outcome {
        guard let hit = content(at: p) else { return .none }
        focused = hit.panel
        return .content(hit.panel, local: hit.local)
    }

    func activateTab(_ id: DockPanelID) {
        focused = id
        guard layout.root.group(containing: id)?.active != id else { return }
        perform { $0.activate(id) }
    }

    /// The group whose tab bar is under `p` and its menu button (a secondary click there opens the group's menu).
    public func menuAnchor(at p: CanvasPoint) -> (group: DockGroup, anchor: CanvasRect)? {
        guard let f = geometry.groups.first(where: { $0.strip.contains(p) }) else { return nil }
        return (f.group, DockTabBar.menuRect(f.strip))
    }

    func openMenu(_ groupID: String) {
        guard let f = geometry.frame(of: groupID) else { return }
        onMenu(f.group, DockTabBar.menuRect(f.strip))
    }

    /// A press on a splitter starts a resize; a second press within the double-click interval resets it.
    func pressSplitter(_ i: Int, at p: CanvasPoint) {
        guard geometry.splitters.indices.contains(i) else { return }
        let s = geometry.splitters[i], t = now()
        if let last = lastSplitterPress, last.path == s.path, last.index == s.index, t - last.at <= Self.doubleClickInterval {
            lastSplitterPress = nil
            perform { try $0.setWeights(at: s.path, DockGeometry.weights(resetting: s)) }
            return
        }
        lastSplitterPress = (s.path, s.index, t)
        splitterDrag = SplitterDrag(splitter: s, start: p)
    }

    /// Returns whether the dock needs a redraw (hover, drag, resize). Moves during a press go to the gesture.
    @discardableResult
    public func pointerMove(_ p: CanvasPoint, swap: Bool = false) -> Bool {
        if let s = splitterDrag { return resize(s, to: p) }
        startDragIfMoved(p)
        if let d = drag {
            drag = moved(d, to: p, swap: swap)
            return true
        }
        return hover(p)
    }

    /// A press on a tab becomes a drag once the pointer has moved `dragThreshold` points.
    func startDragIfMoved(_ p: CanvasPoint) {
        guard let pr = press, drag == nil, hypot(p.x - pr.at.x, p.y - pr.at.y) >= Self.dragThreshold else { return }
        drag = Drag(panel: pr.panel, point: p, preview: nil)
    }

    func moved(_ d: Drag, to p: CanvasPoint, swap: Bool) -> Drag {
        let scene = DockDrop.Scene(layout: layout, geometry: geometry, tabs: tabs, registry: registry)
        let preview = DockDrop.preview(DockDrop.Probe(point: p, panel: d.panel, swap: swap), scene: scene)
        return Drag(panel: d.panel, point: p, preview: preview, swap: swap)
    }

    func hover(_ p: CanvasPoint) -> Bool {
        let h = hits.hit(p)
        guard h != hovered else { return false }
        hovered = h
        return true
    }

    /// A transient resize: the layout follows the pointer, and is committed on release.
    func resize(_ s: SplitterDrag, to p: CanvasPoint) -> Bool {
        let delta = s.splitter.axis == .row ? p.x - s.start.x : p.y - s.start.y
        guard let next = Self.withWeights(layout, at: s.splitter.path, DockGeometry.weights(dragging: s.splitter, by: delta)) else { return false }
        layout = next
        return true
    }

    /// `layout` with the split at `path` set to `weights`; nil when the split is gone (the layout changed under the drag).
    static func withWeights(_ layout: DockLayout, at path: [Int], _ weights: [Double]) -> DockLayout? {
        var copy = layout
        do {
            try copy.setWeights(at: path, weights)
            return copy
        } catch {
            return nil
        }
    }

    /// Ends a press: drops a dragged tab on its target (nothing when there is none), commits a resize.
    @discardableResult
    public func pointerUp(_ p: CanvasPoint) -> Bool {
        press = nil
        if splitterDrag != nil {
            splitterDrag = nil
            onCommit(layout)
            return true
        }
        guard let last = drag else { return false }
        drag = nil
        // The drop is where the pointer is released, not where it last moved (a host may send no move before it).
        let d = moved(last, to: p, swap: last.swap)
        if let target = d.preview?.target {
            if DesignGroups.isDesignPanel(d.panel), returnsToDesign(target) {
                // Dropped on the Design tab: the group goes back there (its panel closes) instead of stacking.
                perform { try $0.returnToDesign(d.panel, registry: registry) }
            } else if case .success(let next) = DockDrop.applying(target, dragging: d.panel, to: layout, registry: registry) {
                perform { $0 = next }
                focused = d.panel
            }
        }
        return true
    }

    /// Whether a drop lands on the Design tab's own tab strip or content (a stack into its group).
    func returnsToDesign(_ target: DockDragTarget) -> Bool {
        guard case .move(.stack(let id, _)) = target, let g = layout.root.group(id: id) else { return false }
        return g.panels.contains(DockPanels.inspector)
    }

    /// Starts a drag of a panel that is not a tab: a Design group header pulled out of the Design tab. `p` is in
    /// dock coordinates; moves and the release then go through `pointerMove` / `pointerUp` like a tab drag.
    public func beginExternalDrag(_ panel: DockPanelID, at p: CanvasPoint, swap: Bool = false) {
        guard registry.contains(panel), !layout.isOpen(panel) else { return }
        press = nil
        drag = moved(Drag(panel: panel, point: p, preview: nil), to: p, swap: swap)
    }

    /// Escape during a drag: the tab stays where it was.
    public func cancelDrag() -> Bool {
        guard drag != nil || splitterDrag != nil else { return false }
        drag = nil; press = nil
        splitterDrag = nil
        return true
    }

    // MARK: Status line and cursor

    public static let tabHint = "Drag to move the panel · ⌥ drop on a tab to swap"
    public static let closeHint = "Close the panel (⌘⇧W)"
    public static let menuHint = "Panels and workspaces"
    public static let splitterHint = "Drag to resize · double-click to reset"
    public static let dragHint = "Drop on a tab bar to stack, on an edge to split · Esc cancels"

    /// The status line's text for what is under the pointer (nil: the content's own hint).
    public var hint: String? {
        if drag != nil { return Self.dragHint }
        if splitterDrag != nil { return Self.splitterHint }
        switch hovered {
        case .tab?, .strip?: return Self.tabHint
        case .close?: return Self.closeHint
        case .menu?: return Self.menuHint
        case .splitter?: return Self.splitterHint
        case nil: return nil
        }
    }

    public enum Cursor: Equatable, Sendable { case arrow, columnResize, rowResize }
    public func cursor(at p: CanvasPoint) -> Cursor? {
        guard let splitter = splitterUnder(p) else { return drag == nil ? nil : .arrow }
        return splitter.axis == .row ? .columnResize : .rowResize
    }

    /// The splitter being dragged, else the one under `p`.
    func splitterUnder(_ p: CanvasPoint) -> DockSplitter? {
        if let s = splitterDrag { return s.splitter }
        guard case .splitter(let i)? = hits.hit(p), geometry.splitters.indices.contains(i) else { return nil }
        return geometry.splitters[i]
    }

    // MARK: Keys

    /// ⌘⇧W / Ctrl+Shift+W closes the focused panel; Ctrl+Tab / Ctrl+Shift+Tab move focus to the next or previous
    /// open panel (reading order) and show its tab's focus ring; Escape cancels a drag. Other keys: false.
    public func keyDown(_ k: EditorKey) -> Bool {
        if k.code == .escape { return cancelDrag() }
        if k.code == .tab, k.ctrl { cycleFocus(forward: !k.shift); return true }
        if k.command, k.shift, case .char(let ch) = k.code, ch.lowercased() == "w" { return closeFocused() }
        return false
    }

    /// Closes the focused panel; false when nothing is focused or it cannot be closed.
    @discardableResult
    public func closeFocused() -> Bool {
        guard let f = focused, registry.isClosable(f), layout.isOpen(f) else { return false }
        return perform { try $0.close(f, registry: registry) } == nil
    }

    /// Focuses the next (or previous) open panel and makes it its group's visible tab.
    public func cycleFocus(forward: Bool) {
        let order = layout.openPanels
        guard !order.isEmpty else { return }
        let i = focused.flatMap { order.firstIndex(of: $0) }
        let next = i.map { forward ? (($0 + 1) % order.count) : (($0 - 1 + order.count) % order.count) } ?? 0
        focus(order[next], visible: true)
    }

    /// Focuses an open panel (a menu pick, a click); `visible` shows the focus ring.
    public func focus(_ panel: DockPanelID, visible: Bool = false) {
        guard layout.isOpen(panel) else { return }
        activateTab(panel)
        focusVisible = visible
    }
}
