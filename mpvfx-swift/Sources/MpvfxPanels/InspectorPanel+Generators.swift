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

extension InspectorPanel {
    func generatorGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup? {
        guard let fill = s.clip.generator, fill.isGenerator else { return nil }
        let id = s.id
        var rows: [InspectorRow] = []
        let kind: NativeGeneratorKind = fill.kind == "color" ? .solid : (fill.gradientType == "radial" ? .radial : .linear)
        rows.append(.init(.segmented(.init(key: "generatorKind", label: "Background", options: NativeGeneratorKind.allCases.map {
            (key: $0.rawValue, label: $0.label, active: kind == $0)
        }, select: { [weak self] key in
            guard let next = NativeGeneratorKind(rawValue: key), next != kind else { return }
            self?.edited(editor.editGenerator(clipId: id) { $0 = next.fill.raw }, label: "Edit background")
        }))))
        let colors = fill.kind == "color" ? [fill.color ?? "#4050B8"] : fill.stops.map(\.color)
        for (i, color) in colors.enumerated() {
            rows += colorRows(ColorFieldSpec(key: "generatorColor\(i)", label: colors.count == 1 ? "Colour" : "Colour \(i + 1)",
                value: color, placeholder: color, allowAlpha: true, historyLabel: "Edit background") { value in
                guard let value else { return false }
                return editor.editGenerator(clipId: id) { raw in
                    if fill.kind == "color" { raw["color"] = .string(value) }
                    else if var stops = raw["gradient"]?["stops"]?.arrayValue, stops.indices.contains(i), var gradient = raw["gradient"] {
                        stops[i]["color"] = .string(value); gradient["stops"] = .array(stops); raw["gradient"] = gradient
                    }
                }
            }, clipId: id)
        }
        func number(_ key: String, _ label: String, _ value: Double) -> InspectorRow {
            .init(.number(.init(key: key, label: label, text: PanelFormat.number(value), tier: .explicitCustom,
                commit: { [weak self] text in
                    guard let v = PanelFormat.parse(text), v.isFinite else { return }
                    self?.edited(editor.editGenerator(clipId: id) { raw in
                        guard var gradient = raw["gradient"] else { return }
                        gradient[key] = .number(v); raw["gradient"] = gradient
                    }, label: "Edit background")
                }, reset: nil)))
        }
        if kind == .linear { rows.append(number("angle", "Angle (degrees)", fill.resolvedAngle)) }
        if kind == .radial {
            rows.append(number("centerX", "Centre X (0–1)", fill.centerX))
            rows.append(number("centerY", "Centre Y (0–1)", fill.centerY))
        }
        return InspectorGroup(id: "generator", title: "Background", summary: kind.label, rows: rows)
    }
}
