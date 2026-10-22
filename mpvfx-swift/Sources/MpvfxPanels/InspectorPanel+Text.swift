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

/// The Text group (FlatTextSection / FlatTextFieldEditor, design handoff #10a), first in the inspector for a
/// text clip: Content, Font, Size, Weight, Letter spacing, Line height, Align, Case · Style and Color, in that
/// order. Values live on the clip (`clip.text`); preview and export draw them with the same layout
/// (NativeTextRendering). Not supported: several text fields per layer (a native text clip holds one block; add
/// another text clip instead), the font picker popover and importing font files (the Font row takes a family name).
extension InspectorPanel {
    func textGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup? {
        guard let t = editor.clipText(clipId: s.id) else { return nil }
        let id = s.id
        func tier(_ explicit: Bool) -> PropertyValueTier { explicit ? .explicitCustom : .default }
        func isExplicit(_ field: String, fallback: Bool) -> Bool {
            s.clip.textStyle.map { $0.overrides.contains(field) } ?? fallback
        }
        func field(_ key: String, _ label: String, _ text: String, explicit: Bool, step: Double? = nil, value: Double = 0,
                   format: @escaping (Double) -> String = { PanelFormat.number($0) },
                   commit: @escaping (String) -> Bool, scrub: ((Double) -> Bool)? = nil, reset: @escaping () -> Bool) -> InspectorRow {
            let explicit = isExplicit(key, fallback: explicit)
            var row = InspectorRow.Number(
                key: key, label: label, text: text, tier: tier(explicit),
                commit: { [weak self] value in self?.edited(commit(value), label: "Edit text") })
            if explicit {
                row.reset = { [weak self] in
                    let changed = s.clip.textStyle == nil ? reset() : editor.resetTextStyleOverride(clipId: id, field: key)
                    self?.edited(changed, label: "Edit text")
                }
            }
            if let step, let scrub {
                row.scrub = (value, step, { [weak self] value in self?.edited(scrub(value), label: "Edit text") }, format)
            }
            return .init(.number(row))
        }
        var rows: [InspectorRow] = []
        // Content: one line in the field; "\n" types a line break.
        rows.append(field("textContent", "Content", t.content.replacingOccurrences(of: "\n", with: "\\n"), explicit: false,
                          commit: { editor.setTextContent(clipId: id, $0.replacingOccurrences(of: "\\n", with: "\n")) },
                          reset: { false }))
        rows.append(field("fontFamily", "Font", t.resolvedFontFamily, explicit: t.fontFamily != nil,
                          commit: { editor.setTextFontFamily(clipId: id, $0) }, reset: { editor.setTextFontFamily(clipId: id, nil) }))
        let size = t.resolvedFontSize
        rows.append(field("fontSize", "Size", "\(PanelFormat.number(size))px", explicit: t.fontSize != nil, step: 1, value: size,
                          format: { "\(PanelFormat.number($0.rounded()))px" },
                          commit: { v in PanelFormat.parse(v).map { editor.setTextFontSize(clipId: id, $0) } ?? false },
                          scrub: { editor.setTextFontSize(clipId: id, max(1, $0.rounded())) },
                          reset: { editor.setTextFontSize(clipId: id, nil) }))
        let weight = t.resolvedFontWeight
        rows.append(field("fontWeight", "Weight", NativeClipText.weightLabels[weight] ?? "\(weight)", explicit: t.fontWeight != nil,
                          commit: { v in TextMetric.weight(v).map { editor.setTextFontWeight(clipId: id, $0) } ?? false },
                          reset: { editor.setTextFontWeight(clipId: id, nil) }))
        let spacing = t.resolvedLetterSpacing
        rows.append(field("letterSpacing", "Letter spacing", "\(PanelFormat.number(spacing))px", explicit: t.letterSpacing != nil,
                          step: 0.1, value: spacing, format: { "\(PanelFormat.number(($0 * 10).rounded() / 10))px" },
                          commit: { v in TextMetric.letterSpacing(v, fontSize: size).map { editor.setTextLetterSpacing(clipId: id, $0) } ?? false },
                          scrub: { editor.setTextLetterSpacing(clipId: id, ($0 * 10).rounded() / 10) },
                          reset: { editor.setTextLetterSpacing(clipId: id, nil) }))
        rows.append(field("lineHeight", "Line height", t.lineHeight.map { PanelFormat.number($0, decimals: 2) } ?? "normal",
                          explicit: t.lineHeight != nil, step: 0.01, value: t.resolvedLineHeight,
                          format: { PanelFormat.number(($0 * 100).rounded() / 100, decimals: 2) },
                          commit: { v in TextMetric.lineHeight(v, fontSize: size).map { editor.setTextLineHeight(clipId: id, $0) } ?? false },
                          scrub: { editor.setTextLineHeight(clipId: id, max(0.1, ($0 * 100).rounded() / 100)) },
                          reset: { editor.setTextLineHeight(clipId: id, nil) }))
        let align = t.resolvedAlign
        rows.append(.init(.segmented(.init(key: "textAlign", label: "Align",
            options: [("left", "Align left"), ("center", "Align center"), ("right", "Align right"), ("justify", "Justify")].map { (key: $0.0, label: $0.1, active: $0.0 == align) },
            select: { [weak self] k in
                guard k != align else { return }
                self?.edited(editor.setTextAlign(clipId: id, k), label: "Edit text")
            }, icons: ["left": .alignLeft, "center": .alignCenter, "right": .alignRight, "justify": .alignJustify]))))
        let transform = t.resolvedTransform, italic = t.isItalic
        rows.append(.init(.segmented(.init(key: "textCase", label: "Case and style",
            options: [("none", "Original case"), ("uppercase", "Uppercase"), ("lowercase", "Lowercase"), ("capitalize", "Capitalize")].map { (key: $0.0, label: $0.1, active: $0.0 == transform) }
                + [(key: "normal", label: "Regular", active: !italic), (key: "italic", label: "Italic", active: italic)],
            select: { [weak self] k in
                let ok = k == "normal" || k == "italic" ? editor.setTextFontStyle(clipId: id, k) : editor.setTextTransform(clipId: id, k)
                self?.edited(ok, label: "Edit text")
            }, icons: ["none": .reset, "uppercase": .textUppercase, "lowercase": .textLowercase, "capitalize": .textCapitalize, "normal": .font, "italic": .textItalic]))))
        rows += colorRows(ColorFieldSpec(key: "textColor", label: "Color", value: t.color, placeholder: t.resolvedColor, allowAlpha: false,
                                         historyLabel: "Edit text", tier: tier(isExplicit("color", fallback: t.color != nil)),
                                         reset: {
                                             s.clip.textStyle == nil ? editor.setTextColor(clipId: id, nil)
                                                 : editor.resetTextStyleOverride(clipId: id, field: "color")
                                         }) { editor.setTextColor(clipId: id, $0) }, clipId: id)
        let preview = t.preview
        return InspectorGroup(id: "text", title: "Text", summary: preview.isEmpty ? "empty" : preview, rows: rows)
    }
}
