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
import MpvfxTimeline

/// The Text group's Look section (issue #281): up to two outlines and a drop shadow. Width, offset and blur are
/// sliders, so each is reachable by Tab, nudged with the arrow keys, typed into, reset, and keyframed with the
/// diamond. Outline and shadow colours are hex fields.
extension InspectorPanel {
    static let textLookLabel = "Edit text look"

    func textLookRows(_ editor: TimelineEditor, _ s: Selected, _ text: NativeClipText) -> [InspectorRow] {
        let id = s.id
        var rows: [InspectorRow] = [.init(.heading("Look", trailing: nil))]
        if let look = text.look, !look.isSupported {
            rows.append(.init(.note("This text look comes from a newer version of the editor. It is kept in the project but cannot be edited here.")))
            return rows
        }
        let outlines = text.look?.outlines ?? []
        for (index, outline) in outlines.enumerated() {
            let name = outlines.count > 1 ? "Outline \(index + 1)" : "Outline"
            rows.append(textLookSlider(editor, s, "textLook:outline\(index):width", "\(name) width",
                                       NativeTextLookParameter.outlineWidthIds[index], reset: TimelineEditor.defaultOutlineWidth))
            rows += colorRows(ColorFieldSpec(key: "textLook:outline\(index):color", label: "\(name) colour", value: outline.color,
                                             placeholder: outline.color, allowAlpha: false, historyLabel: Self.textLookLabel,
                                             tier: .explicitCustom, reset: nil) { hex in
                hex.map { editor.setTextLookOutline(clipId: id, index: index, color: $0) } ?? false
            }, clipId: id)
            let position = outline.resolvedPosition
            rows.append(.init(.segmented(.init(key: "textLook:outline\(index):position", label: "\(name) position",
                options: [("outside", "Outside"), ("center", "Centre")].map { (key: $0.0, label: $0.1, active: $0.0 == position) },
                select: { [weak self] key in
                    guard key != position else { return }
                    self?.edited(editor.setTextLookOutline(clipId: id, index: index, position: key), label: Self.textLookLabel)
                }))))
        }
        var outlineButtons: [InspectorRow.Button] = []
        if outlines.count < NativeTextLook.maxOutlines {
            outlineButtons.append(.init(key: "textLook:outline:add", label: outlines.isEmpty ? "Add outline" : "Add second outline",
                                        style: outlines.isEmpty ? .accent : .muted, action: { [weak self] in
                self?.edited(editor.addTextLookOutline(clipId: id), label: Self.textLookLabel)
            }))
        }
        if !outlines.isEmpty {
            outlineButtons.append(.init(key: "textLook:outline:remove", label: outlines.count > 1 ? "Remove second outline" : "Remove outline",
                                        style: .muted, action: { [weak self] in
                self?.edited(editor.removeLastTextLookOutline(clipId: id), label: Self.textLookLabel)
            }))
        }
        rows.append(.init(.buttons(outlineButtons)))
        if let shadow = text.look?.shadow {
            let ids = (x: NativeTextLookParameter.shadowXId, y: NativeTextLookParameter.shadowYId, blur: NativeTextLookParameter.shadowBlurId)
            rows.append(textLookSlider(editor, s, "textLook:shadow:x", "Shadow x", ids.x, reset: TimelineEditor.defaultShadow.resolvedX))
            rows.append(textLookSlider(editor, s, "textLook:shadow:y", "Shadow y", ids.y, reset: TimelineEditor.defaultShadow.resolvedY))
            rows.append(textLookSlider(editor, s, "textLook:shadow:blur", "Shadow blur", ids.blur, reset: TimelineEditor.defaultShadow.resolvedBlur))
            rows += colorRows(ColorFieldSpec(key: "textLook:shadow:color", label: "Shadow colour", value: shadow.color,
                                             placeholder: shadow.color, allowAlpha: true, historyLabel: Self.textLookLabel,
                                             tier: .explicitCustom, reset: nil) { hex in
                hex.map { editor.setTextLookShadowColor(clipId: id, $0) } ?? false
            }, clipId: id)
            rows.append(.init(.buttons([.init(key: "textLook:shadow:remove", label: "Remove shadow", style: .muted, action: { [weak self] in
                self?.edited(editor.removeTextLookShadow(clipId: id), label: Self.textLookLabel)
            })])))
        } else {
            rows.append(.init(.buttons([.init(key: "textLook:shadow:add", label: "Add shadow", style: .accent, action: { [weak self] in
                self?.edited(editor.addTextLookShadow(clipId: id), label: Self.textLookLabel)
            })])))
        }
        return rows
    }

    /// A look value as a slider with the keyframe gutter. `reset` is the value ↺ writes back.
    private func textLookSlider(_ editor: TimelineEditor, _ s: Selected, _ key: String, _ label: String, _ pid: String,
                                reset: Double) -> InspectorRow {
        let range = NativeTextLookParameter.range(of: pid) ?? 0...100
        let t = time, id = s.id
        let value = editor.textLookValue(clipId: id, pid, time: t) ?? 0
        let shown = min(max(value, range.lowerBound), range.upperBound)
        let format: (Double) -> String = { "\(PanelFormat.number($0.rounded()))px" }
        let animated = editor.isAnimated(clipId: id, pid)
        var kf = keyframe(editor, s, pid, fallback: .number(shown))
        kf.stopwatch = { [weak self] in
            self?.edited(animated ? editor.stopAnimatingTextLook(clipId: id, pid, time: t)
                                  : editor.setAnimated(clipId: id, [(pid, .number(shown))], true, time: t), label: Self.textLookLabel)
        }
        return .init(.slider(.init(
            key: key, label: label, position: shown, min: range.lowerBound, max: range.upperBound,
            display: format(shown), format: format, tier: .explicitCustom,
            commit: { [weak self] v in self?.edited(editor.setTextLookValue(clipId: id, pid, v.rounded(), time: t), label: Self.textLookLabel) },
            reset: { [weak self] in self?.edited(editor.setTextLookValue(clipId: id, pid, reset, time: t), label: Self.textLookLabel) },
            keyframe: kf, step: 1)))
    }
}
