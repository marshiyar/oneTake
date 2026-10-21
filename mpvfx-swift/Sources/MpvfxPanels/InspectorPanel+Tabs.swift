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

/// An inline tab bar a bespoke row drew (curve modes, scope modes, effect families), as the last draw laid it out:
/// its tabs are the row's parts `base`, `base + 1`, … and the overflow button is part `base + ids.count`.
struct InlineTabBar: Equatable {
    var base: Int
    var ids: [String]
    var selected: Int
    var hidden: [PanelTab]
    var overflow: CanvasRect?
}

/// The inspector's inline tab bars on the shared `PanelTabBar`: drawn by the bespoke rows, one Tab stop each (the
/// selected tab), Left / Right / Home / End move the selection, and the overflow button opens the hidden tabs' menu.
extension InspectorPanel {
    /// Draws an inline tab bar for bespoke row `id` in `area` (a 32 pt line with a hairline under it), its tabs the
    /// row's parts from `base`, and records it for keyboard focus and the overflow menu.
    func drawInlineTabs(_ c: CanvasContext, _ bar: PanelTabBar, row id: (String, base: Int), in area: CanvasRect) {
        c.fillRect(CanvasRect(x: area.x, y: area.maxY - 1, width: area.width, height: 1).snapped, PanelTheme.panelHairline)
        let l = bar.layout(c, in: area)
        let ids = bar.tabs.map(\.id), base = id.base
        for (rect, part) in PanelTabBar.hitRects(l) {
            if case .tab(let tab) = part, let index = ids.firstIndex(of: tab) {
                targetHover(c, rect, .custom(id.0, base + index))
            }
        }
        bar.draw(c, l, hovered: inlineHover(id.0, base: base, ids: ids))
        for (rect, part) in PanelTabBar.hitRects(l) {
            switch part {
            case .tab(let t): if let i = ids.firstIndex(of: t) { addHit(rect, .custom(id.0, base + i)) }
            case .overflow: addHit(rect, .custom(id.0, base + ids.count))
            case .close: continue
            }
        }
        tabBars[id.0] = InlineTabBar(base: base, ids: ids, selected: ids.firstIndex { $0 == bar.selected } ?? 0, hidden: l.hidden, overflow: l.overflow)
    }

    /// The bar part under the pointer, from the row's hovered part.
    func inlineHover(_ id: String, base: Int, ids: [String]) -> PanelTabBar.Part? {
        guard case .custom(id, let p)? = hovered else { return nil }
        if ids.indices.contains(p - base) { return .tab(ids[p - base]) }
        return p == base + ids.count ? .overflow : nil
    }

    /// A press on part `part` of row `id`'s inline bar: the tab index it selects, or nil (the overflow button opens
    /// the menu of hidden tabs, whose pick calls `select`; any other part is not the bar's).
    func inlineTab(_ id: String, part: Int, select: @escaping (Int) -> Void) -> Int? {
        guard let bar = tabBars[id] else { return nil }
        let i = part - bar.base
        if bar.ids.indices.contains(i) { return i }
        guard i == bar.ids.count, let anchor = bar.overflow else { return nil }
        let options = bar.hidden.map { PanelDropdown.Option(value: $0.id, label: $0.label) }
        onOpenDropdown?("tabs:\(id)", options, nil, anchor) { v in if let j = bar.ids.firstIndex(of: v) { select(j) } }
        return nil
    }

    /// Whether Tab stops on `h`: an inline bar's unselected tabs are skipped (the bar is one stop).
    func isFocusable(_ h: Hit) -> Bool {
        guard Self.focusable(h) else { return false }
        guard case .custom(let id, let p) = h, let bar = tabBars[id] else { return true }
        let i = p - bar.base
        return !bar.ids.indices.contains(i) || i == bar.selected
    }

    /// A key no field took: an inline tab bar's arrows first, then the Grade group's keys.
    func bodyKey(_ k: EditorKey) -> Bool { inlineTabKey(k) || gradeKey(k) }

    /// Left / Right / Home / End on a focused inline tab: select the next one (a press on it) and keep focus on it.
    func inlineTabKey(_ k: EditorKey) -> Bool {
        guard focus.visible, case .custom(let id, let p)? = focus.current, let bar = tabBars[id], bar.ids.indices.contains(p - bar.base) else { return false }
        let tabs = bar.ids.map { PanelTab(id: $0, label: $0) }
        guard let next = PanelTabBar.tab(after: k, from: bar.ids[p - bar.base], in: tabs), let j = bar.ids.firstIndex(of: next) else { return false }
        customRow(id)?.pointer(bar.base + j, .init(0, 0), 0)
        customRow(id)?.pointer(bar.base + j, .init(0, 0), 2)
        focus.current = .custom(id, bar.base + j)
        onEdited?()
        return true
    }
}
