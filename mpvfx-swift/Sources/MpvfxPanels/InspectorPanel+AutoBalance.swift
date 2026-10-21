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
import MpvfxShared
import MpvfxTheme
import MpvfxTimeline

/// A frame request belongs to the clip, document and playhead that the user asked to balance. Keeping the editor
/// weak avoids extending the lifetime of a closed project while an asynchronous frame is still rendering.
final class AutoBalanceRequest {
    weak var editor: TimelineEditor?
    let document: NativeProjectDocument
    let clipId: String
    let time: Double

    init(editor: TimelineEditor, clipId: String, time: Double) {
        self.editor = editor; document = editor.document; self.clipId = clipId; self.time = time
    }
}

/// The Grade group's "Auto balance" button: measures the clip's current frame (`AutoBalance`) and writes Exposure,
/// Warmth and Tint as one undoable edit. Tab reaches it and Enter or Space presses it.
extension InspectorPanel {
    func autoBalanceRow(_ clipId: String) -> InspectorRow {
        .init(.custom(InspectorCustomRow(id: "grade:autobalance", height: 28, draw: { [weak self] c, r, panel in
            guard let self else { return }
            if self.grade.autoBalancePending { self.resumeAutoBalance(clipId) }   // a frame still rendering
            let pending = self.grade.autoBalancePending, failed = self.grade.autoBalanceFailed
            let button = CanvasRect(x: r.x, y: r.y + 2, width: min(r.width, 120), height: 24)
            PanelDraw.smallButton(c, button, label: pending ? "Balancing" : "Auto balance",
                                  fill: panel.hovered == .custom("grade:autobalance", 0) ? PanelTheme.panelHover : PanelTheme.panelSurface,
                                  color: PanelTheme.text1)
            panel.addHit(button, .custom("grade:autobalance", 0))
            if failed {
                PanelDraw.text(c, "No frame to measure", in: CanvasRect(x: button.maxX + 8, y: r.y + 6.5, width: max(0, r.maxX - button.maxX - 8), height: 15),
                               font: PanelTheme.font(9), color: PanelTheme.red400)
            }
        }, pointer: { [weak self] _, _, phase in
            guard let self, phase == 0 else { return }
            self.grade.autoBalanceFailed = false
            self.runAutoBalance(clipId)
            self.onEdited?()
        })))
    }

    /// Starts a balance request for this selection. Retries must keep its original context rather than silently
    /// balancing whichever clip happens to be selected when the frame finishes.
    func runAutoBalance(_ clipId: String) {
        guard let editor, selection == [clipId] else { return }
        grade.autoBalanceRequest = AutoBalanceRequest(editor: editor, clipId: clipId, time: time)
        resumeAutoBalance(clipId)
    }

    func cancelAutoBalance() { grade.autoBalanceRequest = nil; grade.autoBalanceFailed = false }

    /// Runs even while Grade is collapsed, so a stale request cannot survive until its row is visible again.
    func validateAutoBalanceContext() {
        guard let request = grade.autoBalanceRequest else { return }
        guard let editor, request.editor === editor, editor.document == request.document,
              selection == [request.clipId], time == request.time else {
            cancelAutoBalance(); return
        }
    }

    /// An intervening selection, project, document edit or seek cancels the pending operation without an undo entry.
    func resumeAutoBalance(_ clipId: String) {
        guard let request = grade.autoBalanceRequest else { return }
        guard let editor, request.editor === editor, editor.document == request.document,
              selection == [request.clipId], clipId == request.clipId, time == request.time else {
            cancelAutoBalance()
            return
        }
        switch scopeFrame?(request.clipId, Self.sampleFrameSize, Self.sampleFrameSize) ?? .unavailable {
        case .rendering: break
        case .unavailable, .failed: grade.autoBalanceRequest = nil; grade.autoBalanceFailed = true
        case .ready(let frame):
            grade.autoBalanceRequest = nil
            let shown = editor.gradeShown(clipId: request.clipId, time: request.time)
            guard let next = AutoBalance.balanced(shown, frame: frame) else { grade.autoBalanceFailed = true; return }
            edited(editor.commitGrade(clipId: request.clipId, time: request.time, shown: shown, next: next))
        }
    }
}
