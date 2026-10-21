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

/// Paints a panel's content: its id, the canvas (translated and clipped to the content rect) and the content size.
public typealias DockContentPainter = (DockPanelID, CanvasContext, CanvasSize) -> Void

extension DockView {
    /// Draws the dock in `rect`: the shell colour through the seams, every group's tab bar and its active panel's
    /// content (`content` paints it in content coordinates, clipped), the splitters, the focus ring, and the drag
    /// overlay on top. Records the hit regions pointer events resolve against.
    public func draw(_ c: CanvasContext, in rect: CanvasRect, content: DockContentPainter) {
        layout(in: rect)
        hits.reset()
        tabs = [:]
        c.fillRect(rect, PanelTheme.studioBg)
        for frame in geometry.groups { drawGroup(c, frame, content: content) }
        drawSplitters(c)
        drawFocusRing(c)
        drawDragOverlay(c)
    }

    func drawGroup(_ c: CanvasContext, _ frame: DockGroupFrame, content: DockContentPainter) {
        c.fillRect(frame.frame, PanelTheme.panelBg)
        if frame.content.width > 0, frame.content.height > 0, !frame.group.active.isEmpty {
            c.save()
            c.translate(frame.content.x, frame.content.y)
            c.clip(CanvasRect(x: 0, y: 0, width: frame.content.width, height: frame.content.height))
            content(frame.group.active, c, CanvasSize(frame.content.width, frame.content.height))
            c.restore()
        }
        drawStrip(c, frame)
    }

    func drawStrip(_ c: CanvasContext, _ frame: DockGroupFrame) {
        let strip = frame.strip
        guard strip.width > 0, strip.height > 0 else { return }
        PanelTabStrip.drawBackground(c, strip)
        hits.add(strip, .strip(frame.group.id))
        let laid = DockTabBar.layout(c, strip, frame.group, registry)
        tabs[frame.group.id] = laid
        c.save()
        c.clip(CanvasRect(x: strip.x, y: strip.y, width: max(0, DockTabBar.menuRect(strip).x - strip.x), height: strip.height))
        for tab in laid {
            DockTabBar.draw(c, tab, DockTabBar.State(active: tab.panel == frame.group.active, hovered: hovered == .tab(tab.panel),
                                                     closeHovered: hovered == .close(tab.panel), dimmed: drag?.panel == tab.panel))
            hits.add(tab.rect, .tab(tab.panel))
            if let close = tab.close { hits.add(close, .close(tab.panel)) }
        }
        c.restore()
        let menu = DockTabBar.menuRect(strip)
        PanelTabStrip.iconButton(c, menu, icon: .panelMenu, hovered: hovered == .menu(frame.group.id))
        hits.add(menu, .menu(frame.group.id))
    }

    /// At rest the seams are the shell; the hovered one lights and the dragged one is the accent (as the shell's
    /// seams before the dock).
    func drawSplitters(_ c: CanvasContext) {
        for (i, s) in geometry.splitters.enumerated() {
            if splitterDrag?.splitter.path == s.path && splitterDrag?.splitter.index == s.index {
                c.fillRect(s.seam, PanelTheme.accent)
            } else if hovered == .splitter(i) {
                c.fillRect(s.seam, PanelTheme.seamHover)
            }
            hits.add(s.hit, .splitter(i))
        }
    }

    func drawFocusRing(_ c: CanvasContext) {
        guard focusVisible, let f = focused, let rect = tabs.values.joined().first(where: { $0.panel == f })?.rect else { return }
        PanelDraw.focusRing(c, rect.insetBy(3), radius: PanelTheme.radius)
    }

    /// While a tab is dragged: the drop area tinted with an accent outline, the insertion bar between tabs, and the
    /// tab's title following the pointer.
    func drawDragOverlay(_ c: CanvasContext) {
        guard let drag else { return }
        if let p = drag.preview {
            c.fillRect(p.highlight, PanelTheme.accent.withAlpha(0.18))
            c.strokeRect(p.highlight.insetBy(1), PanelTheme.accent, width: 2)
            if let bar = p.insertion { c.fillRect(bar, PanelTheme.accent) }
        }
        let title = registry.title(drag.panel)
        let font = PanelTheme.font(PanelTheme.textXs, .medium)
        let w = c.measureText(title, font: font).width + 20
        // Beside the pointer, kept inside the dock (near the right or bottom edge it would be cut off).
        let b = geometry.bounds
        let ghost = CanvasRect(x: max(b.x, min(drag.point.x + 8, b.maxX - w - 2)), y: max(b.y, min(drag.point.y + 8, b.maxY - 26)),
                               width: w, height: 24)
        c.fillRoundedRect(ghost, radius: PanelTheme.radius, PanelTheme.panelHover)
        c.strokeRoundedRect(ghost, radius: PanelTheme.radius, PanelTheme.accent, width: 1)
        PanelDraw.text(c, title, in: ghost, font: font, color: PanelTheme.text0, align: .center)
    }
}
