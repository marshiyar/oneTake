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
import MpvfxPanels
import MpvfxTimeline

// MARK: Draw

extension EditorShellRouter {
    func draw(_ c: CanvasContext, size window: CanvasSize) {
        resized(window)
        let k = interfaceScale
        guard k != 1 else { drawLayout(c); return }
        c.save()
        c.scale(k, k)
        drawLayout(c)
        c.restore()
    }

    private func drawLayout(_ c: CanvasContext) {
        let f = relayout()
        if isFullscreen() {
            c.fillRect(f.preview, PanelTheme.neutral950)
            paintPane(.player, c, f.player)
        } else {
            dock.draw(c, in: f.dock) { [self] id, c, size in paintPanel(id, c, size) }
            c.fillRect(CanvasRect(x: 0, y: f.dock.maxY, width: size.width, height: PanelTheme.seamWidth), PanelTheme.studioBg)
            ShellStatusLine.draw(c, f.statusLine, hint: statusHint, error: saveFailureStatus())
        }
        crossPaneDrag?.drawDrag(c)
        dockMenu.draw(c)
        if let modal, modal.isOpen { modal.draw(c, size: size) }
    }

    /// A panel's content in its content rect (the dock has translated and clipped to it). The Preview is its top
    /// bar (the panel grey) over the player.
    func paintPanel(_ id: DockPanelID, _ c: CanvasContext, _ size: CanvasSize) {
        guard id == DockPanels.preview else { paintPane(.of(id), c, CanvasRect(x: 0, y: 0, width: size.width, height: size.height)); return }
        let barH = min(EditorShellFrames.previewTopBarHeight, size.height)
        paintPane(.previewTopBar, c, CanvasRect(x: 0, y: 0, width: size.width, height: barH))
        paintPane(.player, c, CanvasRect(x: 0, y: barH, width: size.width, height: max(0, size.height - barH)))
    }

    /// One pane in `r` (current coordinates), told when its size changed.
    func paintPane(_ region: Region, _ c: CanvasContext, _ r: CanvasRect) {
        guard r.width > 0, r.height > 0, let pane = panes[region] else { return }
        let local = CanvasSize(r.width, r.height)
        if local != pane.lastSize { pane.lastSize = local; pane.input?.resized(local) }
        c.save()
        c.translate(r.x, r.y)
        c.clip(CanvasRect(x: 0, y: 0, width: r.width, height: r.height))
        pane.paint(c, local)
        c.restore()
    }

    // MARK: Panel menu

    /// The ⋯ menu of a group: close its panel and the panel's own commands, then every panel with a checkmark.
    func openDockMenu(_ group: DockGroup, anchor: CanvasRect) {
        let items = DockMenu.groupMenu(group, layout: dock.layout, registry: dock.registry, extras: menuExtras)
        let options = items.map { PanelDropdown.Option(value: $0.key, label: $0.title, group: $0.section) }
        let bounds = CanvasRect(x: 0, y: 0, width: size.width, height: size.height)
        dockMenu.checked = Set(items.filter(\.checked).map(\.key))
        dockMenu.open(key: "dock-menu", options: options, selected: nil, anchor: anchor, bounds: bounds) { [weak self] key in
            guard let self, let item = items.first(where: { $0.key == key }) else { return }
            self.run(item.action)
        }
        needsDisplay()
    }

    /// Runs a menu entry (the ⋯ menu, the macOS Window menu).
    func run(_ action: DockMenuItem.Action) {
        if case .extra(let id, let command) = action { onMenuExtra(id, command) } else { DockMenu.apply(action, to: dock) }
        needsDisplay()
    }
}

// MARK: CanvasInput (window coordinates in, region-local coordinates out)

extension EditorShellRouter {
    func pointerDown(x: Double, y: Double, shift: Bool) { pointerDown(x: x, y: y, button: PointerButton.primary, modifiers: shift ? .shift : []) }
    func pointerMove(x: Double, y: Double) { pointerMove(x: x, y: y, modifiers: []) }
    func pointerUp(x: Double, y: Double) { pointerUp(x: x, y: y, button: PointerButton.primary) }

    func pointerDown(x: Double, y: Double, button: Int, modifiers: PointerModifiers) {
        let (x, y) = toLayout(x, y)
        let p = CanvasPoint(x, y)
        if modalOpen, captured == nil {
            if button == PointerButton.primary { _ = modal?.pointerDown(p) }
            needsDisplay(); return
        }
        if dockMenu.isOpen { _ = dockMenu.pointerDown(p); needsDisplay(); return }
        if !isFullscreen() {
            let outcome = dock.pointerDown(p, button: button)
            if outcome == .handled { dockCaptured = true; needsDisplay(); return }
            if outcome == .none { return }
        }
        guard let region = region(at: x, y) else { return }
        captured = region
        let (lx, ly) = local(region, x, y)
        panes[region]?.input?.pointerDown(x: lx, y: ly, button: button, modifiers: modifiers)
    }

    func pointerMove(x: Double, y: Double, modifiers: PointerModifiers) {
        let (x, y) = toLayout(x, y)
        let p = CanvasPoint(x, y)
        if movedOverOverlay(p, modifiers) { return }
        if let region = captured { movedWhileCaptured(region, x, y, modifiers); return }
        hoverMoved(x, y, modifiers)
    }

    /// The Settings card, an open panel menu or a dock gesture takes the move; true when one did.
    private func movedOverOverlay(_ p: CanvasPoint, _ modifiers: PointerModifiers) -> Bool {
        if modalOpen, captured == nil { if modal?.pointerMove(p) == true { needsDisplay() }; return true }
        if dockMenu.isOpen { if dockMenu.pointerMove(p) { needsDisplay() }; return true }
        guard dockCaptured else { return false }
        if dock.pointerMove(p, swap: modifiers.contains(.alt)) { needsDisplay() }
        return true
    }

    /// No press: the dock's chrome and the pane under the pointer get their hover.
    private func hoverMoved(_ x: Double, _ y: Double, _ modifiers: PointerModifiers) {
        let chrome = isFullscreen() ? false : dock.pointerMove(CanvasPoint(x, y))
        let region = dock.hovered == nil ? self.region(at: x, y) : nil
        if region != hovered || chrome { needsDisplay() }   // the status line follows the pointer
        if let prev = hovered, prev != region {
            // Leaving a pane: one move outside its bounds clears its hover state.
            let (lx, ly) = local(prev, x, y)
            panes[prev]?.input?.pointerMove(x: lx, y: ly, modifiers: modifiers)
        }
        hovered = region
        guard let region else { return }
        let (lx, ly) = local(region, x, y)
        panes[region]?.input?.pointerMove(x: lx, y: ly, modifiers: modifiers)
    }

    private func movedWhileCaptured(_ region: Region, _ x: Double, _ y: Double, _ modifiers: PointerModifiers) {
        let (lx, ly) = local(region, x, y)
        panes[region]?.input?.pointerMove(x: lx, y: ly, modifiers: modifiers)
        guard let d = crossPaneDrag, d.isDragging(from: region) else { return }
        let target = self.region(at: x, y)
        let (tx, ty) = target.map { local($0, x, y) } ?? (x, y)
        d.dragMoved(over: target, local: CanvasPoint(tx, ty), window: CanvasPoint(x, y))
        needsDisplay()
    }

    func pointerUp(x: Double, y: Double, button: Int) {
        let (x, y) = toLayout(x, y)
        if dockCaptured, button == PointerButton.primary {
            dockCaptured = false
            dock.pointerUp(CanvasPoint(x, y))
            needsDisplay(); return
        }
        guard let region = captured else { return }
        captured = nil
        let dragging = crossPaneDrag?.isDragging(from: region) == true
        let (lx, ly) = local(region, x, y)
        panes[region]?.input?.pointerUp(x: lx, y: ly, button: button)
        if dragging, let d = crossPaneDrag {
            let target = self.region(at: x, y)
            let (tx, ty) = target.map { local($0, x, y) } ?? (x, y)
            d.dragEnded(over: target, local: CanvasPoint(tx, ty))
            needsDisplay()
        }
    }

    /// On a tab bar: the group's ⋯ menu. In a pane: the pane's own context menu.
    func secondaryClick(x: Double, y: Double) {
        let (x, y) = toLayout(x, y)
        if modalOpen || dockMenu.isOpen { return }
        if !isFullscreen(), let m = dock.menuAnchor(at: CanvasPoint(x, y)) { openDockMenu(m.group, anchor: m.anchor); return }
        guard let region = region(at: x, y) else { return }
        dock.focus(region.panel)
        let (lx, ly) = local(region, x, y)
        panes[region]?.input?.secondaryClick(x: lx, y: ly)
    }

    /// The Settings card, an open panel menu, then the dock's own keys (⌘⇧W, Ctrl+Tab, Escape during a drag), then
    /// the focused pane; global shortcuts fall back to the timeline (which falls through to playback).
    func keyDown(_ k: EditorKey) -> Bool {
        if modalOpen, modal?.keyDown(k) == true { needsDisplay(); return true }
        if dockMenu.isOpen { _ = dockMenu.key(k); needsDisplay(); return true }
        if dock.keyDown(k) { needsDisplay(); return true }
        let region = focused
        if let input = panes[region]?.input, input.keyDown(k) { return true }
        if region != .timeline, let t = panes[.timeline]?.input { return t.keyDown(k) }
        return false
    }

    func keyUp(_ k: EditorKey) { (panes[focused]?.input ?? panes[.timeline]?.input)?.keyUp(k) }
}
