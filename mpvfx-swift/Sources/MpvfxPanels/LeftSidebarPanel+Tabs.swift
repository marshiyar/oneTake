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

/// The sidebar's tab strip by keyboard: the selected tab is one Tab stop (`isFocusable`), and Left / Right / Home /
/// End on it switch tabs (`keyNavigate`); Enter / Space press and Escape hides the ring like for any header control.
extension LeftSidebarPanel {
    func stripArrow(_ k: EditorKey) -> Bool {
        guard focus.visible, case .tab? = focus.current,
              let next = PanelTabBar.tab(after: k, from: tab.rawValue, in: stripTabs.map { PanelTab(id: $0.rawValue, label: Self.tabLabels[$0] ?? $0.rawValue) }), let t = LeftSidebarTab(rawValue: next) else { return false }
        selectTab(t)
        focus.current = .tab(t)
        onChange?(); return true
    }
}
