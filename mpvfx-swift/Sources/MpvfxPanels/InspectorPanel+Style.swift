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

/// The Style group's Fill, Stroke and Shadow rows (FlatFillFields, FlatStrokeRow,
/// FlatShadowBlendRows). Values live on the clip (`clip.style`) and render in preview and export. Not drawn yet:
/// gradient / image fill, the dashed-and-other stroke styles, corner radius, blur and overflow.
extension InspectorPanel {
    func styleRows(_ editor: TimelineEditor, _ s: Selected) -> [InspectorRow] {
        let st = s.clip.style ?? NativeClipStyle()
        let id = s.id
        var rows: [InspectorRow] = []
        // Fill (Solid): the renderer reads an alpha byte here, so the picker offers alpha.
        rows += colorRows(ColorFieldSpec(key: "fill", label: "Fill", value: st.fill, placeholder: "transparent", allowAlpha: true,
                                         historyLabel: "Edit style") { editor.setClipFill(clipId: id, $0) }, clipId: id)
        // Stroke
        rows.append(.init(.heading("Stroke", trailing: nil)))
        let width = st.strokeWidth ?? 0
        rows.append(.init(.slider(InspectorRow.Slider(
            key: "strokeWidth", label: "Stroke width", position: width, min: 0, max: 200,
            display: "\(PanelFormat.number(width, decimals: 0))px", format: { "\(PanelFormat.number($0.rounded(), decimals: 0))px" },
            tier: width != 0 ? .explicitCustom : .default,
            commit: { [weak self] v in self?.edited(editor.setClipStrokeWidth(clipId: id, v), label: "Edit style") },
            reset: { [weak self] in self?.edited(editor.setClipStrokeWidth(clipId: id, 0), label: "Edit style") }, step: 1))))
        let styleNow = st.strokeStyle ?? "none"
        rows.append(.init(.segmented(.init(key: "strokeStyle", label: "Stroke style",
            options: NativeClipStyle.strokeStyles.map { (key: $0, label: $0.prefix(1).uppercased() + $0.dropFirst(), active: $0 == styleNow) },
            select: { [weak self] k in self?.edited(editor.setClipStrokeStyle(clipId: id, k), label: "Edit style") }))))
        rows += colorRows(ColorFieldSpec(key: "strokeColor", label: "Stroke color", value: st.strokeColor,
                                         placeholder: NativeClipStyle.defaultStrokeColor, allowAlpha: false,
                                         historyLabel: "Edit style") { editor.setClipStrokeColor(clipId: id, $0) }, clipId: id)
        // Shadow (presets; a shadow list that is no preset shows none active, "custom")
        let preset = NativeClipShadowPreset.infer(st.shadows)
        rows.append(.init(.segmented(.init(key: "shadow", label: "Shadow",
            options: NativeClipShadowPreset.allCases.map { (key: $0.rawValue, label: $0.rawValue.prefix(1).uppercased() + $0.rawValue.dropFirst(), active: $0 == preset) },
            select: { [weak self] k in
                guard let p = NativeClipShadowPreset(rawValue: k) else { return }
                self?.edited(editor.setClipShadowPreset(clipId: id, p), label: "Edit style")
            }))))
        return rows
    }

    /// Group summary: `fill #rrggbb` / `fill none`, then the opacity.
    static func styleSummary(_ style: NativeClipStyle?, opacityPercent: Int) -> String {
        "Fill \(style?.fill ?? "none") · \(opacityPercent)%"
    }
}
