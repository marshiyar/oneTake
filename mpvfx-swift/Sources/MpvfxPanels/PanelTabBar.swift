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
import MpvfxCanvas
import MpvfxTimeline

/// One tab of a `PanelTabBar`.
public struct PanelTab: Equatable, Sendable {
    public var id: String
    public var label: String
    /// Shows a × after the label (a dockable panel's tab); the bar reports a press on it as `.close(id)`.
    public var closable: Bool
    public init(id: String, label: String, closable: Bool = false) { self.id = id; self.label = label; self.closable = closable }
}

/// The one tab bar of the side panels (docs/DESIGN.md "Tabs"): the panel header strip (`.strip`, 12px labels in a
/// 32 pt strip) and the tab rows inside a panel (`.inline`: the curve, scope and effect-family tabs, 11px labels in a
/// 32 pt row). Every tab is at least 24 × 24 pt; the selected one is drawn in full ink and medium weight on a 2px
/// accent underline, the others in `text2` (4.5:1 on the panel surfaces), hover in `text1`.
///
/// It scales: tabs keep their natural width while they fit; when they do not, the bar keeps the tabs that fit, always
/// including the selected one, and puts the rest behind an overflow button (a 24 pt chevron at the end) whose menu
/// the host opens with `hidden`. Keyboard: the bar is one Tab stop (the selected tab, a roving focus); Left / Right
/// move to the previous / next tab and select it (wrapping), Home / End to the first / last. Pointer: a press on a
/// tab selects it, a press on its × closes it, and `PanelTabDrag` reports a drag that starts on a tab (docking).
///
/// The bar is a value: hosts keep the tabs and the selection, build a `PanelTabBar` each draw and call `layout`,
/// `draw` and the static helpers.
public struct PanelTabBar: Equatable {
    public enum Style: Sendable { case strip, inline }
    public var tabs: [PanelTab]
    public var selected: String?
    public var style: Style
    public init(tabs: [PanelTab], selected: String?, style: Style) { self.tabs = tabs; self.selected = selected; self.style = style }

    /// What a point on the bar is.
    public enum Part: Equatable, Sendable { case tab(String), close(String), overflow }

    /// One laid-out tab: its rect and, for a closable one, the close button's rect inside it.
    public struct Slot: Equatable {
        public var tab: PanelTab
        public var rect: CanvasRect
        public var close: CanvasRect?
    }

    public struct Layout: Equatable {
        public var slots: [Slot]
        /// The overflow button, when some tabs did not fit.
        public var overflow: CanvasRect?
        /// The tabs behind the overflow button, in bar order.
        public var hidden: [PanelTab]
        public static let empty = Layout(slots: [], overflow: nil, hidden: [])
    }

    static let padding = 10.0, closeSize = 16.0, closeGap = 2.0, underline = 2.0

    public static func font(_ style: Style, selected: Bool) -> CanvasFont {
        PanelTheme.font(style == .strip ? PanelTheme.textXs : 11, selected ? .medium : .regular)
    }

    /// A tab's natural width: its label (in the selected weight, so selecting never reflows), the padding, the close
    /// button, and never under a target.
    public static func naturalWidth(_ c: CanvasContext, _ t: PanelTab, style: Style) -> Double {
        let label = c.measureText(t.label, font: font(style, selected: true)).width + padding * 2
        return max(PanelGrid.minTarget, label + (t.closable ? closeSize + closeGap : 0))
    }

    /// Lays the tabs out left to right in `area`: all of them when they fit, else the ones that fit with the selected
    /// one among them and an overflow button at the end.
    public func layout(_ c: CanvasContext, in area: CanvasRect) -> Layout {
        let widths = tabs.map { Self.naturalWidth(c, $0, style: style) }
        if widths.reduce(0, +) <= area.width + 0.01 { return place(Array(tabs.indices), widths, in: area) }
        let room = area.width - PanelGrid.minTarget
        var shown = Self.fitting(widths, room: room)
        if let sel = tabs.firstIndex(where: { $0.id == selected }), !shown.contains(sel) {
            while !shown.isEmpty && shown.map({ widths[$0] }).reduce(0, +) + widths[sel] > room { shown.removeLast() }
            shown.append(sel)
        }
        return place(shown, widths, in: area)
    }

    /// The leading tabs whose widths fit in `room`.
    static func fitting(_ widths: [Double], room: Double) -> [Int] {
        var used = 0.0, out: [Int] = []
        for (i, w) in widths.enumerated() {
            guard used + w <= room + 0.01 else { break }
            used += w; out.append(i)
        }
        return out
    }

    /// The `shown` tabs from the area's left edge, and the overflow button after them when some are not shown.
    func place(_ shown: [Int], _ widths: [Double], in area: CanvasRect) -> Layout {
        let overflow = shown.count < tabs.count, padding = Self.padding, closeSize = Self.closeSize
        var x = area.x
        let slots: [Slot] = shown.map { i in
            let w = min(widths[i], max(0, area.maxX - (overflow ? PanelGrid.minTarget : 0) - x))
            let r = CanvasRect(x: x, y: area.y, width: w, height: area.height)
            x += w
            let close = tabs[i].closable
                ? CanvasRect(x: r.maxX - padding / 2 - closeSize, y: r.midY - closeSize / 2, width: closeSize, height: closeSize) : nil
            return Slot(tab: tabs[i], rect: r, close: close)
        }
        let hidden = tabs.indices.filter { !shown.contains($0) }.map { tabs[$0] }
        let button = overflow ? CanvasRect(x: x, y: area.midY - PanelGrid.minTarget / 2, width: PanelGrid.minTarget, height: PanelGrid.minTarget) : nil
        return Layout(slots: slots, overflow: button, hidden: hidden)
    }

    /// Draws `layout`: each tab's label (truncated to its slot), the selected tab's underline along the bar's bottom
    /// edge, close buttons, and the overflow chevron.
    public func draw(_ c: CanvasContext, _ layout: Layout, hovered: Part?) {
        for slot in layout.slots { drawSlot(c, slot, hovered: hovered) }
        guard let o = layout.overflow else { return }
        if hovered == .overflow { c.fillRoundedRect(o, radius: PanelTheme.radius, PanelTheme.panelHover) }
        PanelIcon.groupCaretDown.draw(c, in: CanvasRect(x: o.midX - 6, y: o.midY - 6, width: 12, height: 12),
                                      color: hovered == .overflow ? PanelTheme.text1 : PanelTheme.text2)
    }

    func drawSlot(_ c: CanvasContext, _ s: Slot, hovered: Part?) {
        let on = s.tab.id == selected, padding = Self.padding
        let hot = hovered == .tab(s.tab.id) || hovered == .close(s.tab.id)
        let ink = on ? PanelTheme.text0 : (hot ? PanelTheme.text1 : PanelTheme.text2)
        let labelRight = s.close.map { $0.x - Self.closeGap } ?? s.rect.maxX - padding
        // Half a point of slack each side: a slot at its natural width holds its label exactly, and float rounding
        // must not truncate it.
        let lr = CanvasRect(x: s.rect.x + padding - 0.5, y: s.rect.y, width: max(0, labelRight - s.rect.x - padding + 1), height: s.rect.height - 1)
        PanelDraw.text(c, s.tab.label, in: lr, font: Self.font(style, selected: on), color: ink, align: s.close == nil ? .center : .left)
        if on { c.fillRect(CanvasRect(x: s.rect.x, y: s.rect.maxY - Self.underline, width: s.rect.width, height: Self.underline), PanelTheme.accent) }
        if let x = s.close { Self.drawClose(c, x, hovered: hovered == .close(s.tab.id)) }
    }

    static func drawClose(_ c: CanvasContext, _ r: CanvasRect, hovered: Bool) {
        if hovered { c.fillRoundedRect(r, radius: PanelTheme.radius, PanelTheme.panelHover) }
        PanelIcon.close.draw(c, in: r.insetBy(4), color: hovered ? PanelTheme.text1 : PanelTheme.text2)
    }

    /// The part of `layout` under `p`: a close button wins over its tab.
    public static func part(at p: CanvasPoint, in layout: Layout) -> Part? {
        if let o = layout.overflow, o.contains(p) { return .overflow }
        for s in layout.slots where s.rect.contains(p) {
            if let x = s.close, PanelTabBar.target(x).contains(p) { return .close(s.tab.id) }
            return .tab(s.tab.id)
        }
        return nil
    }

    /// The hit rects of `layout` for a host's `HitMap`, in draw order (each close after its tab, so it wins).
    public static func hitRects(_ layout: Layout) -> [(CanvasRect, Part)] {
        var out: [(CanvasRect, Part)] = []
        for s in layout.slots {
            out.append((s.rect, .tab(s.tab.id)))
            if let x = s.close { out.append((target(x), .close(s.tab.id))) }
        }
        if let o = layout.overflow { out.append((o, .overflow)) }
        return out
    }

    /// A close button's 24 pt target, centred on its glyph box.
    static func target(_ r: CanvasRect) -> CanvasRect {
        CanvasRect(x: r.midX - PanelGrid.minTarget / 2, y: r.midY - PanelGrid.minTarget / 2, width: PanelGrid.minTarget, height: PanelGrid.minTarget)
    }

    /// The tab a key moves the selection to from `current` (nil: the key is not the bar's): Left / Right step and
    /// wrap, Home / End jump to the ends.
    public static func tab(after key: EditorKey, from current: String?, in tabs: [PanelTab]) -> String? {
        guard !tabs.isEmpty else { return nil }
        let i = tabs.firstIndex { $0.id == current } ?? 0
        switch key.code {
        case .left: return tabs[(i - 1 + tabs.count) % tabs.count].id
        case .right: return tabs[(i + 1) % tabs.count].id
        case .home: return tabs.first?.id
        case .end: return tabs.last?.id
        default: return nil
        }
    }
}

/// A drag that starts on a tab (a dockable panel's tab being pulled out): `press` on a tab, then `move` reports the
/// tab id once the pointer has travelled `threshold` points, so a plain click never starts a drag.
public struct PanelTabDrag: Equatable {
    public static let threshold = 4.0
    public private(set) var pressed: (id: String, at: CanvasPoint)?
    public private(set) var dragging: String?
    public init() {}

    public static func == (a: PanelTabDrag, b: PanelTabDrag) -> Bool {
        a.pressed?.id == b.pressed?.id && a.pressed?.at == b.pressed?.at && a.dragging == b.dragging
    }

    public mutating func press(_ id: String, at p: CanvasPoint) { pressed = (id, p); dragging = nil }

    /// The tab whose drag starts with this move (once), else nil.
    public mutating func move(_ p: CanvasPoint) -> String? {
        guard dragging == nil, let pr = pressed else { return nil }
        let dx = p.x - pr.at.x, dy = p.y - pr.at.y
        guard (dx * dx + dy * dy).squareRoot() >= Self.threshold else { return nil }
        dragging = pr.id
        return pr.id
    }

    public mutating func release() { pressed = nil; dragging = nil }
}
