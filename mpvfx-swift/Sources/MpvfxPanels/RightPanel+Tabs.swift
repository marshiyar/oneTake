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

/// The right panel's tab strip on the shared `PanelTabBar`, and its keyboard: the header (the selected tab, hide,
/// panel menu) is reached by Tab on both tabs, Left / Right / Home / End switch tabs, and on the Design tab Tab
/// moves on from the header into the inspector and Shift+Tab back.
extension RightPanel {
    var stripTabs: [PanelTab] {
        [PanelTab(id: RightPanelTab.design.rawValue, label: "Design"), PanelTab(id: RightPanelTab.renders.rawValue, label: rendersLabel)]
    }

    static func hit(_ part: PanelTabBar.Part) -> Hit? {
        switch part {
        case .tab(let id): return id == RightPanelTab.renders.rawValue ? .renders : .design
        case .overflow: return .tabOverflow
        case .close: return nil
        }
    }

    var tabHover: PanelTabBar.Part? {
        switch hovered {
        case .design?: return .tab(RightPanelTab.design.rawValue)
        case .renders?: return .tab(RightPanelTab.renders.rawValue)
        case .tabOverflow?: return .overflow
        default: return nil
        }
    }

    /// The tabs from the strip's left inset to `end` (the first strip button's left edge).
    func drawTabs(_ c: CanvasContext, strip: CanvasRect, end: Double) {
        let x = strip.x + PanelTabStrip.edgeInset
        let area = CanvasRect(x: x, y: strip.y, width: max(0, end - x), height: strip.height)
        let bar = PanelTabBar(tabs: stripTabs, selected: shownTab.rawValue, style: .strip)
        tabLayout = bar.layout(c, in: area)
        bar.draw(c, tabLayout, hovered: tabHover)
        for (r, part) in PanelTabBar.hitRects(tabLayout) { if let h = Self.hit(part) { hits.add(r, h) } }
    }

    /// The panel menu, or the menu of the tabs the strip had no room for.
    func openMenu(for hit: Hit) {
        guard hit == .tabOverflow else { openPanelMenu(); return }
        guard let a = hits.rect(where: { $0 == .tabOverflow }) else { return }
        let options = tabLayout.hidden.map { PanelDropdown.Option(value: $0.id, label: $0.label) }
        dropdown.open(key: "tabs", options: options, selected: nil, anchor: a, bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)) { [weak self] v in
            guard let self, let tab = RightPanelTab(rawValue: v) else { return }
            self.layout.setRightTab(tab); self.onChange?()
        }
    }

    // MARK: Keyboard

    func designKey(_ k: EditorKey) -> Bool {
        if focus.visible, let cur = focus.current, Self.isHeader(cur) { return headerKey(k) }
        if k.code == .tab && !k.shift && !inspector.focus.visible && !inspector.isEditingText { return enterHeader(forward: true) }
        let handled = inspector.keyDown(k)
        if !handled && k.code == .tab && k.shift { return enterHeader(forward: false) }
        return handled
    }

    /// Focus the header's first (or, backwards, last) stop.
    func enterHeader(forward: Bool) -> Bool {
        focus.current = nil
        let moved = focus.move(hits, forward: forward) { [unowned self] in Self.isHeader($0) && self.isFocusable($0) }
        onChange?(); return moved
    }

    /// Keys while the Design tab's header has focus: Tab past its last stop goes on into the inspector.
    func headerKey(_ k: EditorKey) -> Bool {
        guard k.code == .tab else { return focusKey(k, forward: { _ in false }) }
        if focus.move(hits, forward: !k.shift, { [unowned self] in Self.isHeader($0) && self.isFocusable($0) }) { onChange?(); return true }
        guard !k.shift else { onChange?(); return false }
        inspector.focus.current = nil
        let moved = inspector.keyDown(k)
        onChange?(); return moved
    }

    /// Tab (through `forward`), Enter / Space (a press on the focused control), Escape (hide the ring), and the
    /// arrows on a focused tab.
    func focusKey(_ k: EditorKey, forward: (Bool) -> Bool) -> Bool {
        switch k.code {
        case .tab:
            let moved = forward(!k.shift)
            onChange?(); return moved
        case .enter, .space:
            guard focus.visible, let cur = focus.current, let r = hits.rect(where: { $0 == cur }) else { return false }
            _ = pointerDown(CanvasPoint(r.midX, r.midY))
            focus.visible = true; focus.current = cur   // the press keeps keyboard focus where it was
            onChange?(); return true
        case .escape:
            guard focus.visible else { return false }
            focus.visible = false; onChange?(); return true
        default: return tabArrow(k)
        }
    }

    /// Left / Right / Home / End on the focused tab: switch to the next tab and keep focus on it.
    func tabArrow(_ k: EditorKey) -> Bool {
        guard focus.visible, let cur = focus.current, cur == .design || cur == .renders,
              let next = PanelTabBar.tab(after: k, from: shownTab.rawValue, in: stripTabs), let tab = RightPanelTab(rawValue: next) else { return false }
        layout.setRightTab(tab)
        focus.current = tab == .renders ? .renders : .design
        onChange?(); return true
    }
}
