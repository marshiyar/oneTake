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
// The Shape group (issue #324): a shape clip's kind and the values that belong to that kind (corner radius, sides,
// inner radius, arrow head length), with its stroke width, dash and colours. Every pick and value is one undo step
// through TimelineEditor.setClipShape; a value left at its default is not stored, and its reset removes the key.
// Every row and button is a focusable control, so Tab, the arrows and Return reach all of them.
import Foundation
import MpvfxShared
import MpvfxTimeline

extension InspectorPanel {
    static let shapeGroupId = "shape"

    /// Kind, in the order of the picks.
    static let shapeKindLabels: [(kind: String, label: String)] = [
        ("rectangle", "Rectangle"), ("ellipse", "Ellipse"), ("triangle", "Triangle"), ("diamond", "Diamond"),
        ("polygon", "Polygon"), ("star", "Star"), ("line", "Line"), ("arrow", "Arrow"),
    ]

    func shapeGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup? {
        guard let shape = s.clip.shape, shape.isSupported else { return nil }
        let id = s.id, kind = shape.kind
        let isLine = kind == "line" || kind == "arrow"
        func edit(_ change: @escaping (inout NativeClipShape) -> Void) {
            var next = shape
            change(&next)
            edited(editor.setClipShape(clipId: id, next), label: "Edit shape")
        }
        let picks = Self.shapeKindLabels.map { entry in
            InspectorRow.Button(key: "shape.kind.\(entry.kind)", label: entry.label, style: entry.kind == kind ? .chipActive : .chip,
                                action: {
                                    guard entry.kind != kind else { return }
                                    edit { $0.raw["kind"] = .string(entry.kind) }
                                })
        }
        var rows: [InspectorRow] = [InspectorRow(.buttons(picks))]
        /// A number stored under `key` (removed when it equals `fallback`); the document refuses a value out of range.
        func number(_ key: String, _ label: String, fallback: Double, whole: Bool = false) {
            let stored = shape.raw[key]?.numberValue
            rows.append(.init(.number(.init(
                key: "shape.\(key)", label: label, text: PanelFormat.number(stored ?? fallback),
                tier: stored == nil ? .default : .explicitCustom,
                commit: { text in
                    guard let v = PanelFormat.parse(text), v.isFinite, !whole || v == v.rounded() else { return }
                    edit { if v == fallback { $0.raw[key] = nil } else { $0.raw[key] = .number(v) } }
                },
                reset: stored == nil ? nil : { edit { $0.raw[key] = nil } }))))
        }
        switch kind {
        case "rectangle": number("radius", "Corner radius (px)", fallback: 0)
        case "polygon": number("sides", "Sides", fallback: 5, whole: true)
        case "star":
            number("sides", "Points", fallback: 5, whole: true)
            number("innerRadius", "Inner radius (0–1)", fallback: 0.5)
        case "arrow": number("headLength", "Head length (px)", fallback: 20)
        default: break
        }
        number("strokeWidth", "Stroke width (px)", fallback: 0)
        let dash = shape.dash
        rows.append(.init(.number(.init(
            key: "shape.dash", label: "Dash (px)", text: dash.map { PanelFormat.number($0) }.joined(separator: " "),
            tier: dash.isEmpty ? .default : .explicitCustom,
            commit: { text in
                let parts = text.split(whereSeparator: { $0 == " " || $0 == "," }).map { PanelFormat.parse(String($0)) }
                guard parts.allSatisfy({ $0 != nil }) else { return }
                let values = parts.compactMap { $0 }
                edit { $0.raw["dash"] = values.isEmpty ? nil : .array(values.map(NativeJSONValue.number)) }
            },
            reset: dash.isEmpty ? nil : { edit { $0.raw["dash"] = nil } }))))
        func colour(_ key: String, _ label: String, fallback: String) {
            rows += colorRows(ColorFieldSpec(key: "shape.\(key)", label: label, value: shape.raw[key]?.stringValue, placeholder: fallback,
                                             allowAlpha: true, historyLabel: "Edit shape") { value in
                var next = shape
                next.raw[key] = value.map(NativeJSONValue.string)
                return editor.setClipShape(clipId: id, next)
            }, clipId: id)
        }
        if !isLine { colour("fill", "Fill", fallback: "#ffffff") }
        colour("stroke", "Stroke", fallback: "#000000")
        return InspectorGroup(id: Self.shapeGroupId, title: "Shape", summary: Self.shapeKindLabels.first { $0.kind == kind }?.label ?? kind,
                              rows: rows)
    }
}
