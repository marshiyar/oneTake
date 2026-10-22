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

/// A dock group's tab bar, drawn with the editor's tab strip (`PanelTabStrip`: height, font, padding, accent
/// underline, icon buttons), so the system tab bar's metrics apply to every dock group. Adds the per-tab × and
/// the group's panel menu button.
public enum DockTabBar {
    /// The × button: a 24 × 24 pt target (the minimum target size) with a 10 pt glyph.
    public static let closeSize = PanelTabStrip.buttonSize
    static let closeGlyph = 10.0
    /// A tab never narrows below this when a group holds more tabs than fit.
    public static let minTabWidth = 72.0

    public struct Tab: Equatable, Sendable {
        public var panel: DockPanelID
        public var title: String
        public var rect: CanvasRect
        /// nil: the panel cannot be closed.
        public var close: CanvasRect?
    }

    /// The group's menu button at the strip's right end.
    public static func menuRect(_ strip: CanvasRect) -> CanvasRect { PanelTabStrip.buttonRect(strip, index: 0) }

    /// The tabs laid left to right; they share the width left of the menu button, never below `minTabWidth`.
    public static func layout(_ c: CanvasContext, _ strip: CanvasRect, _ group: DockGroup, _ registry: DockRegistry) -> [Tab] {
        let avail = max(0, menuRect(strip).x - strip.x - PanelTabStrip.edgeInset * 2)
        let natural = group.panels.map { naturalWidth(c, registry.title($0), closable: registry.isClosable($0)) }
        let total = natural.reduce(0, +)
        let scale = total > avail && total > 0 ? avail / total : 1
        var x = strip.x + PanelTabStrip.edgeInset
        return zip(group.panels, natural).map { panel, w in
            let width = max(min(w, minTabWidth), (w * scale).rounded(.down))
            let r = CanvasRect(x: x, y: strip.y, width: width, height: strip.height)
            x = r.maxX
            let closable = registry.isClosable(panel)
            let close = closable ? CanvasRect(x: r.maxX - closeSize - 2, y: r.y + (r.height - closeSize) / 2,
                                              width: closeSize, height: closeSize) : nil
            return Tab(panel: panel, title: registry.title(panel), rect: r, close: close)
        }
    }

    static func naturalWidth(_ c: CanvasContext, _ title: String, closable: Bool) -> Double {
        PanelTabStrip.tabWidth(c, title) + (closable ? closeSize - 4 : 0)
    }

    /// One tab: its label (muted unless active or hovered), the accent underline when active, and the × (muted, lit
    /// on hover); a dimmed tab is the one being dragged away.
    /// How a tab is shown: the visible one, under the pointer, its × under the pointer, being dragged away.
    public struct State: Equatable, Sendable {
        public var active = false, hovered = false, closeHovered = false, dimmed = false
        public init(active: Bool = false, hovered: Bool = false, closeHovered: Bool = false, dimmed: Bool = false) {
            self.active = active; self.hovered = hovered; self.closeHovered = closeHovered; self.dimmed = dimmed
        }
    }

    public static func draw(_ c: CanvasContext, _ tab: Tab, _ state: State) {
        let active = state.active, hovered = state.hovered, closeHovered = state.closeHovered, dimmed = state.dimmed
        let labelRect = tab.close.map { CanvasRect(x: tab.rect.x, y: tab.rect.y, width: $0.x - tab.rect.x + 4, height: tab.rect.height) } ?? tab.rect
        if dimmed { c.fillRect(tab.rect, PanelTheme.panelHover) }
        PanelTabStrip.tab(c, labelRect, label: tab.title, active: active && !dimmed, hovered: hovered)
        if active && !dimmed {
            c.fillRect(CanvasRect(x: tab.rect.x, y: tab.rect.maxY - PanelTabStrip.underline, width: tab.rect.width,
                                  height: PanelTabStrip.underline), PanelTheme.accent)
        }
        guard let close = tab.close else { return }
        if closeHovered { c.fillRoundedRect(close.insetBy(2), radius: PanelTheme.radius, PanelTheme.panelHover) }
        let g = closeGlyph
        let box = CanvasRect(x: close.midX - g / 2, y: close.midY - g / 2, width: g, height: g)
        PanelIcon.close.draw(c, in: box, color: closeHovered ? PanelTheme.text0 : (active || hovered ? PanelTheme.text2 : PanelTheme.text3))
    }
}
