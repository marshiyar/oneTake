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

/// The sidebar's tab strip by keyboard: Tab / Shift+Tab walk the selected tab, Import media, hide and the panel
/// menu; Left / Right / Home / End switch tabs; Enter / Space press; Escape hides the ring. The media bin below has
/// its own keys (search, menus), which come first in `keyDown`.
extension LeftSidebarPanel {
    /// The strip's stops: the selected tab (the tab bar is one stop), Import media, hide, the panel menu.
    func isStripStop(_ h: Hit) -> Bool {
        switch h {
        case .tab(let t): return t == tab
        case .importMedia, .hideSidebar, .panelMenu, .showSidebar: return true
        default: return false
        }
    }

    func stripKey(_ k: EditorKey) -> Bool {
        switch k.code {
        case .tab:
            let moved = focus.move(hits, forward: !k.shift) { [unowned self] in self.isStripStop($0) }
            onChange?(); return moved
        case .enter, .space:
            guard focus.visible, let cur = focus.current, let r = hits.rect(where: { $0 == cur }) else { return false }
            _ = pointerDown(CanvasPoint(r.midX, r.midY))
            focus.visible = true; focus.current = cur
            onChange?(); return true
        case .escape:
            guard focus.visible else { return false }
            focus.visible = false; onChange?(); return true
        default: return stripArrow(k)
        }
    }

    func stripArrow(_ k: EditorKey) -> Bool {
        guard focus.visible, case .tab? = focus.current,
              let next = PanelTabBar.tab(after: k, from: tab.rawValue, in: stripTabs), let t = LeftSidebarTab(rawValue: next) else { return false }
        selectTab(t)
        focus.current = .tab(t)
        onChange?(); return true
    }
}
