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

/// The canvas fill rows (#320): what fills the frame behind clips that do not cover it. The Composition section sets the
/// project's fill, the Media group a clip's own (or "Project", which takes the project's). Every pick and value is one
/// undo step through TimelineEditor.setCompositionCanvasFill / setClipCanvasFill, saved as `compositionFill` / `fill`.
extension InspectorPanel {
    /// Row keys: `canvasFill.project.kind`, `canvasFill.clip.blur` … (scripted drives and tests address rows by key).
    static let canvasFillProjectKey = "canvasFill.project", canvasFillClipKey = "canvasFill.clip"

    /// One place a fill is set: the project or one clip.
    struct CanvasFillScope {
        var key: String
        var fill: NativeFill?
        var allowsInherit: Bool
        var images: [NativeProjectAsset]
        var set: (NativeFill?) -> Void
    }

    static func canvasFillKinds(allowsInherit: Bool) -> [String] { allowsInherit ? NativeFill.clipKinds : NativeFill.projectKinds }

    static func canvasFillLabel(_ kind: String) -> String {
        switch kind {
        case "inherit": "Project"
        case "none": "None"
        case "color": "Color"
        case "gradient": "Gradient"
        case "image": "Image"
        default: "Blur"
        }
    }

    /// The kind shown selected: a clip with no fill of its own takes the project's, the project with none shows None.
    static func canvasFillShownKind(_ fill: NativeFill?, allowsInherit: Bool) -> String {
        guard let fill else { return allowsInherit ? "inherit" : "none" }
        return fill.kind ?? "none"
    }

    /// The fill a pick starts from, keeping what the old fill already holds that the new kind shares. Nil: the pick
    /// cannot be made (an image fill needs an image in the project).
    static func canvasFillStart(kind: String, from old: NativeFill?, images: [NativeProjectAsset]) -> NativeFill? {
        switch kind {
        case "color": return NativeFill(kind: "color", color: old?.color ?? "#000000")
        case "gradient":
            let stops = (old?.stops.count ?? 0) >= 2 ? old!.stops : [.init(offset: 0, color: "#000000"), .init(offset: 1, color: "#ffffff")]
            return NativeFill(kind: "gradient", stops: stops, angle: old?.angle)
        case "image":
            guard let id = old?.assetId ?? images.first?.id else { return nil }
            return NativeFill(kind: "image", assetId: id)
        case "blur": return NativeFill(kind: "blur", blur: old?.blur, darken: old?.darken)
        default: return NativeFill(kind: "none")
        }
    }

    func canvasFillRows(_ scope: CanvasFillScope) -> [InspectorRow] {
        let kinds = Self.canvasFillKinds(allowsInherit: scope.allowsInherit)
        let shown = Self.canvasFillShownKind(scope.fill, allowsInherit: scope.allowsInherit)
        let kindRow = dropdownRow(
            id: "\(scope.key).kind", label: "Fill",
            options: kinds.map { PanelDropdown.Option(value: $0, label: Self.canvasFillLabel($0)) }, current: shown,
            tier: scope.fill == nil ? .default : .explicitCustom, reset: scope.fill == nil ? nil : { scope.set(nil) },
            pick: { kind in
                if kind == "inherit" { scope.set(nil); return }
                if let next = Self.canvasFillStart(kind: kind, from: scope.fill, images: scope.images) { scope.set(next) }
            })
        var rows = [kindRow]
        guard let fill = scope.fill else { return rows }
        guard fill.isSupported else {
            rows.append(InspectorRow(.note("This fill is from a newer version of the editor: it is kept in the project and not drawn.")))
            return rows
        }
        switch fill.kind {
        case "color":
            rows.append(hexRow("\(scope.key).color", "Color", fill.color ?? "#000000", def: "#000000") { hex in
                scope.set(NativeFill(kind: "color", color: hex))
            })
        case "gradient":
            let stops = fill.stops
            rows.append(hexRow("\(scope.key).from", "From", stops.first?.color ?? "#000000", def: nil) { hex in
                scope.set(Self.canvasGradient(fill, first: hex, last: nil, angle: fill.angle))
            })
            rows.append(hexRow("\(scope.key).to", "To", stops.last?.color ?? "#ffffff", def: nil) { hex in
                scope.set(Self.canvasGradient(fill, first: nil, last: hex, angle: fill.angle))
            })
            rows.append(fillNumber("\(scope.key).angle", "Angle", fill.resolvedAngle, def: NativeFill.defaultAngle,
                                   range: NativeFill.angleRange) { v in
                scope.set(Self.canvasGradient(fill, first: nil, last: nil, angle: v))
            })
        case "image":
            rows.append(dropdownRow(
                id: "\(scope.key).image", label: "Image",
                options: scope.images.map { PanelDropdown.Option(value: $0.id, label: $0.name) }, current: fill.assetId ?? "",
                tier: .explicitCustom, pick: { id in scope.set(NativeFill(kind: "image", assetId: id)) }))
        case "blur":
            rows.append(fillNumber("\(scope.key).blur", "Blur", fill.resolvedBlur, def: NativeFill.defaultBlur,
                                   range: NativeFill.blurRange) { v in
                scope.set(NativeFill(kind: "blur", blur: v, darken: fill.darken))
            })
            rows.append(fillNumber("\(scope.key).darken", "Darken", fill.resolvedDarken, def: NativeFill.defaultDarken,
                                   range: 0...1) { v in
                scope.set(NativeFill(kind: "blur", blur: fill.blur, darken: v))
            })
        default: break
        }
        return rows
    }

    /// The gradient with its first and/or last stop colour or its angle replaced; the other stops, type and centre stay.
    static func canvasGradient(_ old: NativeFill, first: String?, last: String?, angle: Double?) -> NativeFill {
        var stops = old.stops
        if let first, !stops.isEmpty { stops[0].color = first }
        if let last, !stops.isEmpty { stops[stops.count - 1].color = last }
        let type = old.raw["gradient"]?["type"]?.stringValue
        return NativeFill(kind: "gradient", stops: stops, angle: angle, gradientType: type,
                          centerX: old.raw["gradient"]?["centerX"]?.numberValue,
                          centerY: old.raw["gradient"]?["centerY"]?.numberValue)
    }

    /// A number field that writes its default as "absent", with a reset back to it.
    private func fillNumber(_ key: String, _ label: String, _ value: Double, def: Double, range: ClosedRange<Double>,
                            apply: @escaping (Double?) -> Void) -> InspectorRow {
        let text = value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
        return InspectorRow(.number(.init(
            key: key, label: label, text: text, tier: abs(value - def) < 1e-9 ? .default : .explicitCustom,
            commit: { typed in
                guard let v = Double(typed.trimmingCharacters(in: .whitespaces)), range.contains(v) else { return }
                apply(abs(v - def) < 1e-9 ? nil : v)   // the default is written as absent
            },
            reset: abs(value - def) < 1e-9 ? nil : { apply(nil) })))
    }

    private func hexRow(_ key: String, _ label: String, _ value: String, def: String?, apply: @escaping (String) -> Void) -> InspectorRow {
        InspectorRow(.number(.init(
            key: key, label: label, text: value, tier: value == def || def == nil ? .default : .explicitCustom,
            commit: { typed in
                let hex = typed.trimmingCharacters(in: .whitespaces)
                if !hex.isEmpty { apply(hex) }   // the document validates the colour; a bad one changes nothing
            },
            reset: def.flatMap { d in value == d ? nil : { apply(d) } })))
    }

    // MARK: Scopes

    func projectCanvasFillScope(_ editor: TimelineEditor) -> CanvasFillScope {
        CanvasFillScope(key: Self.canvasFillProjectKey, fill: editor.document.compositionFill, allowsInherit: false,
                        images: editor.document.assets.filter { $0.kind == .image }) { [weak self] fill in
            self?.edited(editor.setCompositionCanvasFill(fill), label: "Set canvas fill")
        }
    }

    func clipCanvasFillScope(_ editor: TimelineEditor, _ s: Selected) -> CanvasFillScope {
        CanvasFillScope(key: Self.canvasFillClipKey, fill: s.clip.fill.flatMap { $0.kind == "inherit" ? nil : $0 }, allowsInherit: true,
                        images: editor.document.assets.filter { $0.kind == .image }) { [weak self] fill in
            self?.edited(editor.setClipCanvasFill(clipId: s.id, fill), label: "Set clip fill")
        }
    }
}
