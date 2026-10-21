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

/// Event routing for the Easing tab (KeyframeEasingPanel), next to the Design tab's (the inspector).
extension RightPanel {
    /// A press in the open Design or Easing tab's content goes to its pane (the inspector or the Easing panel); nil
    /// when the press is not there (the header, the Renders tab).
    func contentPointerDown(_ p: CanvasPoint) -> Bool? {
        let inContent = !layout.effectiveRightCollapsed && contentRect.contains(p)
        pressedInInspector = inContent && shownTab == .design
        pressedInEasing = inContent && shownTab == .easing
        guard pressedInInspector || pressedInEasing else { return nil }
        let r = pressedInInspector ? inspector.pointerDown(p) : easing.pointerDown(p)
        onChange?()
        return r
    }

    /// The pointer over (or dragging from) the open tab's content; true when it changed what is drawn.
    func contentPointerMove(_ p: CanvasPoint) -> Bool {
        let inContent = contentRect.contains(p)
        if pressedInEasing || (shownTab == .easing && inContent) { return easing.pointerMove(p) }
        if pressedInInspector || (shownTab == .design && inContent) { return inspector.pointerMove(p) }
        guard inspector.hovered != nil else { return false }
        inspector.hovered = nil
        inspector.endAudition()
        return true
    }

    /// The panel menu's choice: hide the panel, show Keyframe easing, or hide the finished renders.
    func panelMenuPicked(_ value: String) {
        switch value {
        case "hide": layout.setRightCollapsed(true)
        case "keyframe-easing": layout.setRightTab(.easing)
        default: onRender?(.hideFinished)
        }
    }
}
