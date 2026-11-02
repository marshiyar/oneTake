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

/// The Masks group (#297): add a rectangle, ellipse, linear or band mask to the selected picture, text or shape layer,
/// then set each mask's mode, geometry, feather, expansion and opacity, invert it or remove it. Every pick and typed
/// value is one undo step through TimelineEditor.addMask / setMask / removeMask; a default is stored as absent.
/// Row keys are `masks.add.<kind>` and `masks.<id>.<field>` (scripted drives and tests address rows by key).
extension InspectorPanel {
    static let masksGroupId = "masks"
    static let maskKinds = ["rectangle", "ellipse", "linear", "band"]
    static let maskModes = ["add", "subtract", "intersect"]

    static func maskKindLabel(_ kind: String) -> String { kind.prefix(1).uppercased() + kind.dropFirst() }

    /// One numeric mask field: where it is stored, how it reads (`scale` 100 shows a fraction as a percent), its
    /// default, and the stored range a typed value must fall in.
    struct MaskField {
        var key: String, label: String
        var path: WritableKeyPath<NativeClipMask, Double?>
        var def: Double, scale = 1.0
        var range: ClosedRange<Double>
    }

    /// The fields each kind uses, in the order they are listed.
    static func maskFields(_ kind: String) -> [MaskField] {
        let x = MaskField(key: "x", label: "X %", path: \.x, def: 0.5, scale: 100, range: -1...2)
        let y = MaskField(key: "y", label: "Y %", path: \.y, def: 0.5, scale: 100, range: -1...2)
        let w = MaskField(key: "width", label: "Width %", path: \.width, def: 1, scale: 100, range: 0...4)
        let h = MaskField(key: "height", label: "Height %", path: \.height, def: 1, scale: 100, range: 0...4)
        let angle = MaskField(key: "angle", label: "Angle", path: \.angle, def: 0, range: -360...360)
        let tail = [MaskField(key: "feather", label: "Feather px", path: \.feather, def: 0, range: 0...1000),
                    MaskField(key: "expansion", label: "Expand px", path: \.expansion, def: 0, range: -1000...1000),
                    MaskField(key: "opacity", label: "Opacity %", path: \.opacity, def: 1, scale: 100, range: 0...1)]
        switch kind {
        case "linear": return [x, y, angle] + tail
        case "band": return [x, y, w, angle] + tail
        default: return [x, y, w, h, angle] + tail
        }
    }

    /// The group for a layer that can take masks; nil for a sound.
    func masksGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup? {
        guard s.isVisual else { return nil }
        let masks = s.clip.masks ?? []
        var rows: [InspectorRow] = [InspectorRow(.buttons(Self.maskKinds.map { kind in
            InspectorRow.Button(key: "masks.add.\(kind)", label: "+ \(Self.maskKindLabel(kind))", style: .chip,
                                action: { [weak self] in self?.edited(editor.addMask(clipId: s.id, kind: kind) != nil, label: "Add mask") })
        }))]
        for (index, mask) in masks.enumerated() {
            rows.append(contentsOf: maskRows(editor, s, mask, number: index + 1))
        }
        if masks.isEmpty { rows.append(InspectorRow(.note("Show part of the layer through a shape. Masks follow the layer when it moves, scales or rotates."))) }
        let summary = masks.isEmpty ? "none" : "\(masks.count)"
        return InspectorGroup(id: Self.masksGroupId, title: "Masks", summary: summary, rows: rows)
    }

    private func maskRows(_ editor: TimelineEditor, _ s: Selected, _ m: NativeClipMask, number: Int) -> [InspectorRow] {
        guard m.isSupported else {
            return [InspectorRow(.note("Mask \(number) is from a newer version of the editor: it is kept in the project and not drawn."))]
        }
        let prefix = "masks.\(m.id)"
        func apply(_ label: String, _ edit: @escaping (inout NativeClipMask) -> Void) {
            edited(editor.setMask(clipId: s.id, maskId: m.id, label: label, edit), label: label)
        }
        var rows: [InspectorRow] = [InspectorRow(.heading("Mask \(number) · \(Self.maskKindLabel(m.kind))", trailing: nil))]
        rows.append(dropdownRow(
            id: "\(prefix).mode", label: "Mode", options: Self.maskModes.map { PanelDropdown.Option(value: $0, label: Self.maskKindLabel($0)) },
            current: m.resolvedMode, tier: m.mode == nil ? .default : .explicitCustom,
            reset: m.mode == nil ? nil : { apply("Reset mask mode") { $0.mode = nil } },
            pick: { mode in apply("Set mask mode") { $0.mode = mode == "add" ? nil : mode } }))
        for f in Self.maskFields(m.kind) {
            let stored = m[keyPath: f.path] ?? f.def
            let shown = (stored * f.scale * 100).rounded() / 100
            rows.append(InspectorRow(.number(.init(
                key: "\(prefix).\(f.key)", label: f.label, text: shown == shown.rounded() ? String(Int(shown)) : String(format: "%g", shown),
                tier: abs(stored - f.def) < 1e-9 ? .default : .explicitCustom,
                commit: { typed in
                    guard let v = Double(typed.trimmingCharacters(in: .whitespaces)), v.isFinite else { return }
                    let value = v / f.scale
                    guard f.range.contains(value) else { return }
                    apply("Set mask \(f.key)") { $0[keyPath: f.path] = abs(value - f.def) < 1e-9 ? nil : value }
                },
                reset: abs(stored - f.def) < 1e-9 ? nil : { apply("Reset mask \(f.key)") { $0[keyPath: f.path] = nil } }))))
        }
        let inverted = m.invert == true
        rows.append(InspectorRow(.toggle(.init(key: "\(prefix).invert", label: "Invert", on: inverted, tier: inverted ? .explicitCustom : .default,
                                               set: { on in apply("Set mask invert") { $0.invert = on ? true : nil } },
                                               reset: inverted ? { apply("Reset mask invert") { $0.invert = nil } } : nil))))
        rows.append(InspectorRow(.buttons([
            InspectorRow.Button(key: "\(prefix).stage", label: "Edit on stage", style: .chip,
                                action: { [weak self] in self?.onEditMaskOnStage?(s.id, m.id) }),
            InspectorRow.Button(
            key: "\(prefix).remove", label: "Remove mask", style: .danger,
            action: { [weak self] in self?.edited(editor.removeMask(clipId: s.id, maskId: m.id), label: "Remove mask") })])))
        return rows
    }
}
