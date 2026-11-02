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
        rows += textLookGlowRows(editor, s, text.look?.glow)
        rows += textLookPlateRows(editor, s, text.look?.plate)
        rows += textLookFillRows(editor, s, text.look?.fill)
        return rows
    }

    private func textLookButton(_ key: String, _ label: String, style: InspectorRow.Button.Style, _ action: @escaping () -> Bool) -> InspectorRow {
        .init(.buttons([.init(key: key, label: label, style: style, action: { [weak self] in
            self?.edited(action(), label: Self.textLookLabel)
        })]))
    }

    private func textLookColorRows(_ key: String, _ label: String, _ value: String, alpha: Bool, clipId: String,
                                   _ apply: @escaping (String) -> Bool) -> [InspectorRow] {
        colorRows(ColorFieldSpec(key: key, label: label, value: value, placeholder: value, allowAlpha: alpha,
                                 historyLabel: Self.textLookLabel, tier: .explicitCustom, reset: nil) { hex in
            hex.map(apply) ?? false
        }, clipId: clipId)
    }

    private func textLookGlowRows(_ editor: TimelineEditor, _ s: Selected, _ glow: NativeTextLook.Glow?) -> [InspectorRow] {
        let id = s.id
        guard let glow else {
            return [textLookButton("textLook:glow:add", "Add glow", style: .accent) { editor.addTextLookGlow(clipId: id) }]
        }
        return [
            textLookStaticSlider("textLook:glow:radius", "Glow radius", glow.resolvedRadius, NativeTextLook.glowRadiusRange,
                                 reset: NativeTextLook.defaultGlowRadius) { editor.setTextLookGlow(clipId: id, radius: $0) },
            textLookSlider(editor, s, "textLook:glow:strength", "Glow strength", NativeTextLookParameter.glowStrengthId,
                           reset: NativeTextLook.defaultGlowStrength, scale: 100, suffix: "%"),
        ] + textLookColorRows("textLook:glow:color", "Glow colour", glow.color, alpha: true, clipId: id) {
            editor.setTextLookGlow(clipId: id, color: $0)
        } + [textLookButton("textLook:glow:remove", "Remove glow", style: .muted) { editor.removeTextLookGlow(clipId: id) }]
    }

    private func textLookPlateRows(_ editor: TimelineEditor, _ s: Selected, _ plate: NativeTextLook.Plate?) -> [InspectorRow] {
        let id = s.id
        guard let plate else {
            return [textLookButton("textLook:plate:add", "Add plate", style: .accent) { editor.addTextLookPlate(clipId: id) }]
        }
        let mode = plate.resolvedMode
        let range = NativeTextLook.platePaddingRange
        var rows: [InspectorRow] = [.init(.segmented(.init(key: "textLook:plate:mode", label: "Plate",
            options: [("line", "Per line"), ("block", "Whole block")].map { (key: $0.0, label: $0.1, active: $0.0 == mode) },
            select: { [weak self] key in
                guard key != mode else { return }
                self?.edited(editor.setTextLookPlate(clipId: id, mode: key), label: Self.textLookLabel)
            })))]
        rows.append(textLookStaticSlider("textLook:plate:paddingX", "Plate padding x", plate.resolvedPaddingX, range,
                                         reset: TimelineEditor.defaultPlate.resolvedPaddingX) { editor.setTextLookPlate(clipId: id, paddingX: $0) })
        rows.append(textLookStaticSlider("textLook:plate:paddingY", "Plate padding y", plate.resolvedPaddingY, range,
                                         reset: TimelineEditor.defaultPlate.resolvedPaddingY) { editor.setTextLookPlate(clipId: id, paddingY: $0) })
        rows.append(textLookStaticSlider("textLook:plate:radius", "Plate radius", plate.resolvedRadius, NativeTextLook.plateRadiusRange,
                                         reset: TimelineEditor.defaultPlate.resolvedRadius) { editor.setTextLookPlate(clipId: id, radius: $0) })
        rows.append(textLookSlider(editor, s, "textLook:plate:opacity", "Plate opacity", NativeTextLookParameter.plateOpacityId,
                                   reset: 1, scale: 100, suffix: "%"))
        rows += textLookColorRows("textLook:plate:color", "Plate colour", plate.color, alpha: true, clipId: id) {
            editor.setTextLookPlate(clipId: id, color: $0)
        }
        rows.append(textLookButton("textLook:plate:remove", "Remove plate", style: .muted) { editor.removeTextLookPlate(clipId: id) })
        return rows
    }

    private func textLookFillRows(_ editor: TimelineEditor, _ s: Selected, _ fill: NativeTextLook.Fill?) -> [InspectorRow] {
        let id = s.id
        guard let fill else {
            return [textLookButton("textLook:fill:add", "Add gradient fill", style: .accent) { editor.addTextLookFill(clipId: id) }]
        }
        return textLookColorRows("textLook:fill:from", "Gradient from", fill.from, alpha: false, clipId: id) {
            editor.setTextLookFill(clipId: id, from: $0)
        } + textLookColorRows("textLook:fill:to", "Gradient to", fill.to, alpha: false, clipId: id) {
            editor.setTextLookFill(clipId: id, to: $0)
        } + [
            textLookSlider(editor, s, "textLook:fill:angle", "Gradient angle", NativeTextLookParameter.fillAngleId, reset: 0, scale: 1, suffix: "°"),
            textLookButton("textLook:fill:remove", "Remove gradient fill", style: .muted) { editor.removeTextLookFill(clipId: id) },
        ]
    }

    /// A stored look number as a slider without keyframes; `commit` returns whether the document changed.
    private func textLookStaticSlider(_ key: String, _ label: String, _ value: Double, _ range: ClosedRange<Double>, reset: Double,
                                      _ commit: @escaping (Double) -> Bool) -> InspectorRow {
        let shown = min(max(value, range.lowerBound), range.upperBound)
        let format: (Double) -> String = { "\(PanelFormat.number($0.rounded()))px" }
        return .init(.slider(.init(
            key: key, label: label, position: shown, min: range.lowerBound, max: range.upperBound,
            display: format(shown), format: format, tier: .explicitCustom,
            commit: { [weak self] v in self?.edited(commit(v.rounded()), label: Self.textLookLabel) },
            reset: { [weak self] in self?.edited(commit(reset), label: Self.textLookLabel) }, step: 1)))
    }

    /// A look value as a slider with the keyframe gutter. `reset` is the value ↺ writes back.
    private func textLookSlider(_ editor: TimelineEditor, _ s: Selected, _ key: String, _ label: String, _ pid: String,
                                reset: Double, scale: Double = 1, suffix: String = "px") -> InspectorRow {
        let range = NativeTextLookParameter.range(of: pid) ?? 0...100
        let t = time, id = s.id
        let value = editor.textLookValue(clipId: id, pid, time: t) ?? 0
        let held = min(max(value, range.lowerBound), range.upperBound)
        // The slider works in display units (percent for strength and opacity); the document keeps its own.
        let shown = held * scale
        let format: (Double) -> String = { "\(PanelFormat.number($0.rounded()))\(suffix)" }
        let animated = editor.isAnimated(clipId: id, pid)
        var kf = keyframe(editor, s, pid, fallback: .number(held))
        kf.stopwatch = { [weak self] in
            self?.edited(animated ? editor.stopAnimatingTextLook(clipId: id, pid, time: t)
                                  : editor.setAnimated(clipId: id, [(pid, .number(held))], true, time: t), label: Self.textLookLabel)
        }
        return .init(.slider(.init(
            key: key, label: label, position: shown, min: range.lowerBound * scale, max: range.upperBound * scale,
            display: format(shown), format: format, tier: .explicitCustom,
            commit: { [weak self] v in self?.edited(editor.setTextLookValue(clipId: id, pid, v.rounded() / scale, time: t), label: Self.textLookLabel) },
            reset: { [weak self] in self?.edited(editor.setTextLookValue(clipId: id, pid, reset, time: t), label: Self.textLookLabel) },
            keyframe: kf, step: 1)))
    }
}
