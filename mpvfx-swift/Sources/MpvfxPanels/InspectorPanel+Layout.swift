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
import MpvfxShared
import MpvfxTimeline

/// Transform group's Layer order row (LayoutZIndexRow). The value is the clip's `layout.zIndex`, the compositing
/// key the preview and export share (the stage menu's Bring forward / Send backward write the same key); empty or
/// reset goes back to the track order. There are no flex rows (direction, justify, align, gap): they lay out child
/// containers, which the native document does not have.
extension InspectorPanel {
    static let zIndexId = "layout.zIndex"

    func layerOrderRow(_ editor: TimelineEditor, _ s: Selected) -> InspectorRow {
        var z: Double? = nil
        if case .number(let v)? = s.clip.staticParameters?[Self.zIndexId] { z = v }
        let id = s.id, trackId = s.track.id
        let row = InspectorRow.Number(
            key: "layerOrder", label: "Layer order", text: PanelFormat.number(z ?? 0, decimals: 0),
            tier: z == nil ? .default : (z == 0 ? .explicitDefault : .explicitCustom),
            commit: { [weak self] text in
                if text.trimmingCharacters(in: .whitespaces).isEmpty || text.lowercased() == "auto" {
                    self?.edited(editor.clearStaticParameter(clipId: id, Self.zIndexId), label: "Edit layer order"); return
                }
                guard let v = PanelFormat.parse(text), v.isFinite else { return }
                self?.edited(Self.setZIndex(editor, trackId: trackId, clipId: id, v.rounded()), label: "Edit layer order")
            },
            reset: z == nil ? nil : { [weak self] in self?.edited(editor.clearStaticParameter(clipId: id, Self.zIndexId), label: "Edit layer order") },
            scrub: (z ?? 0, 0.1, { [weak self] v in self?.edited(Self.setZIndex(editor, trackId: trackId, clipId: id, v.rounded()), label: "Edit layer order") },
                    { PanelFormat.number($0.rounded(), decimals: 0) }))
        return InspectorRow(.number(row))
    }

    static func setZIndex(_ editor: TimelineEditor, trackId: String, clipId: String, _ z: Double) -> Bool {
        let a = NativeProjectParameterAddress(sequenceId: editor.sequenceId, trackId: trackId, clipId: clipId, parameterId: zIndexId)
        return editor.applyProperty(.atomic(.setStatic(address: a, value: .number(z))))
    }
}
