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
import MpvfxTheme
import MpvfxTimeline

/// The Grade group's "Auto balance" button: measures the clip's current frame (`AutoBalance`) and writes Exposure,
/// Warmth and Tint as one undoable edit. Tab reaches it and Enter or Space presses it.
extension InspectorPanel {
    func autoBalanceRow(_ clipId: String) -> InspectorRow {
        .init(.custom(InspectorCustomRow(id: "grade:autobalance", height: 28, draw: { [weak self] c, r, panel in
            guard let self else { return }
            if self.grade.autoBalancePending { self.runAutoBalance(clipId) }   // a frame still rendering
            let pending = self.grade.autoBalancePending, failed = self.grade.autoBalanceFailed
            let button = CanvasRect(x: r.x, y: r.y + 2, width: min(r.width, 120), height: 24)
            PanelDraw.smallButton(c, button, label: pending ? "Balancing" : "Auto balance",
                                  fill: panel.hovered == .custom("grade:autobalance", 0) ? PanelTheme.panelHover : PanelTheme.panelSurface,
                                  color: PanelTheme.text1)
            panel.addHit(button, .custom("grade:autobalance", 0))
            if failed {
                PanelDraw.text(c, "No frame to measure", in: CanvasRect(x: button.maxX + 8, y: r.y + 6.5, width: max(0, r.maxX - button.maxX - 8), height: 15),
                               font: PanelTheme.font(11), color: PanelTheme.red400)
            }
        }, pointer: { [weak self] _, _, phase in
            guard let self, phase == 0 else { return }
            self.grade.autoBalanceFailed = false
            self.runAutoBalance(clipId)
            self.onEdited?()
        })))
    }

    /// Balances `clipId` from its frame at the playhead; a frame still rendering is asked for again on the next draw.
    func runAutoBalance(_ clipId: String) {
        guard let editor else { return }
        switch scopeFrame?(clipId, Self.sampleFrameSize, Self.sampleFrameSize) ?? .unavailable {
        case .rendering: grade.autoBalancePending = true
        case .unavailable, .failed: grade.autoBalancePending = false; grade.autoBalanceFailed = true
        case .ready(let frame):
            grade.autoBalancePending = false
            let shown = editor.gradeShown(clipId: clipId, time: time)
            guard let next = AutoBalance.balanced(shown, frame: frame) else { grade.autoBalanceFailed = true; return }
            edited(editor.commitGrade(clipId: clipId, time: time, shown: shown, next: next))
        }
    }
}
