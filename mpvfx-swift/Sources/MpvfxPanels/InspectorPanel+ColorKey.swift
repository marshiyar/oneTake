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
    func colorKeyRows(_ editor: TimelineEditor, _ s: Selected) -> [InspectorRow] {
        guard s.kind == .video || s.kind == .image else { return [] }
        guard let settings = editor.colorKey(clipId: s.id) else {
            return [InspectorRow(.buttons([.init(key: "colorKey.add", label: "Add color key", style: .chip,
                action: { [weak self] in
                    self?.edited(editor.setColorKey(clipId: s.id, ColorKeySettings(), label: "Add color key"), label: "Add color key")
                })]))]
        }
        func apply(_ label: String, _ edit: (inout ColorKeySettings) -> Void) {
            guard var value = editor.colorKey(clipId: s.id) else { return }
            edit(&value)
            edited(editor.setColorKey(clipId: s.id, value, label: label), label: label)
        }
        let enabled = editor.isColorKeyEnabled(clipId: s.id)
        var rows = [InspectorRow(.toggle(.init(
            key: "colorKey.enabled", label: "Color key", on: enabled, tier: enabled ? .default : .explicitCustom,
            set: { [weak self] on in
                self?.edited(editor.setColorKeyEnabled(clipId: s.id, on), label: on ? "Turn on color key" : "Turn off color key")
            })))]
        rows.append(InspectorRow(.number(.init(
            key: "colorKey.color", label: "Color", text: Self.colorKeyHex(settings.color),
            tier: settings.color == ColorKeySettings.defaultColor ? .default : .explicitCustom,
            commit: { typed in
                guard let color = Self.colorKeyChannels(typed) else { return }
                apply("Set key color") { $0.color = color }
            }, reset: settings.color == ColorKeySettings.defaultColor ? nil : {
                apply("Reset key color") { $0.color = ColorKeySettings.defaultColor }
            }))))
        rows.append(InspectorRow(.buttons([.init(
            key: "colorKey.pick", label: "Pick from stage", style: keyEyedropperActive ? .chipActive : .chip,
            action: { [weak self] in self?.onPickKeyColor?() })])))
        let fields: [(String, String, WritableKeyPath<ColorKeySettings, Double>, Double)] = [
            ("similarity", "Similarity %", \.similarity, ColorKeySettings.defaultSimilarity),
            ("smoothness", "Smoothness %", \.smoothness, ColorKeySettings.defaultSmoothness),
            ("spill", "Spill %", \.spill, ColorKeySettings.defaultSpill),
        ]
        for (key, label, path, def) in fields {
            let value = settings[keyPath: path]
            rows.append(InspectorRow(.number(.init(
                key: "colorKey.\(key)", label: label, text: String(format: "%g", value * 100),
                tier: value == def ? .default : .explicitCustom,
                commit: { typed in
                    guard let percent = Double(typed.trimmingCharacters(in: .whitespacesAndNewlines)),
                          percent.isFinite, (0...100).contains(percent) else { return }
                    apply("Set key \(key)") { $0[keyPath: path] = percent / 100 }
                }, reset: value == def ? nil : { apply("Reset key \(key)") { $0[keyPath: path] = def } }))))
        }
        rows.append(dropdownRow(
            id: "colorKey.view", label: "View",
            options: ColorKeyViewMode.allCases.map { .init(value: $0.rawValue, label: $0.label) },
            current: colorKeyView.rawValue, tier: colorKeyView == .result ? .default : .explicitCustom,
            pick: { [weak self] raw in
                guard let self, let view = ColorKeyViewMode(rawValue: raw) else { return }
                self.colorKeyView = view
                self.onColorKeyViewChange?(view)
            }))
        rows.append(InspectorRow(.buttons([.init(key: "colorKey.remove", label: "Remove", style: .danger,
            action: { [weak self] in
                self?.edited(editor.setColorKey(clipId: s.id, nil, label: "Remove color key"), label: "Remove color key")
            })])))
        return rows
    }

    private static func colorKeyHex(_ color: [Double]) -> String {
        "#" + color.map { String(format: "%02x", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
    }

    private static func colorKeyChannels(_ typed: String) -> [Double]? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.first == "#" else { return nil }
        var digits = Array(text.dropFirst())
        guard [3, 6].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
        return stride(from: 0, to: 6, by: 2).map { index in
            Double(UInt8(String(digits[index...index + 1]), radix: 16)!) / 255
        }
    }
}
