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
import MpvfxTimeline

extension InspectorPanel {
    /// Standard segmented/buttons rows provide the same Tab, arrows and Enter/Space path as the other Design tools.
    func alignmentGroup(_ editor: TimelineEditor) -> InspectorGroup {
        let ids = Set(selection), t = time
        let enabled = editor.canArrangeClips(ids, time: t)
        let reference = alignmentReference
        func button(_ value: TimelineAlignment, _ label: String) -> InspectorRow.Button {
            .init(key: "align:\(value.rawValue)", label: label, style: .muted, action: { [weak self] in
                self?.edited(editor.alignClips(ids, to: value, relativeTo: reference, time: t), label: "Align clips")
            }, disabled: !enabled)
        }
        return InspectorGroup(id: "layout", title: "Align and distribute", summary: reference == .frame ? "Frame" : "Selection", rows: [
            .init(.segmented(.init(key: "align:reference", label: "Relative to", options: [
                ("frame", "Frame", reference == .frame), ("selection", "Selection", reference == .selection)],
                select: { [weak self] value in
                    self?.alignmentReference = value == "selection" ? .selection : .frame; self?.onEdited?()
                }))),
            .init(.buttons([button(.left, "Left"), button(.centre, "Centre"), button(.right, "Right")])),
            .init(.buttons([button(.top, "Top"), button(.middle, "Middle"), button(.bottom, "Bottom")])),
            .init(.buttons([
                .init(key: "distribute:horizontal", label: "Distribute H", style: .muted, action: { [weak self] in
                    self?.edited(editor.distributeClips(ids, along: .horizontal, time: t), label: "Distribute clips")
                }, disabled: !enabled || ids.count < 3),
                .init(key: "distribute:vertical", label: "Distribute V", style: .muted, action: { [weak self] in
                    self?.edited(editor.distributeClips(ids, along: .vertical, time: t), label: "Distribute clips")
                }, disabled: !enabled || ids.count < 3),
            ])),
        ])
    }
}
