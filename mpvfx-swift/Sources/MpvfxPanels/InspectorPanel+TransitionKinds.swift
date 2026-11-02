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

extension InspectorPanel {
    /// Per-kind option rows for a known cut transition, in a fixed order:
    /// direction (push/slide/wipe) → wipe angle → softness (wipe/iris) →
    /// iris shape + centre → zoom-through strength → ease (every kind).
    /// Every edit goes through `apply`, so each is one undo step.
    func kindOptionRows(
        transition: NativeCutTransition,
        id: String,
        apply: @escaping (NativeCutTransitionCommand) -> Void
    ) -> [InspectorRow] {
        var rows: [InspectorRow] = []
        if transition.kind?.usesDirection == true {
            rows.append(.init(.segmented(.init(key: "transition:direction", label: "Direction",
                options: NativeTransitionDirection.allCases.map {
                    ($0.rawValue, Self.directionLabel($0), $0 == transition.direction)
                },
                select: { value in
                    if let direction = NativeTransitionDirection(rawValue: value) {
                        apply(.setDirection(id: id, direction: direction))
                    }
                }))))
        }
        if transition.kind == .wipe {
            let angleText = transition.angle.map { PanelFormat.number($0, decimals: 0) } ?? ""
            rows.append(.init(.number(.init(key: "transition:angle", label: "Angle (°)",
                text: angleText, tier: .explicitCustom,
                commit: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { apply(.setAngle(id: id, angle: nil)); return }
                    if let angle = PanelFormat.parse(trimmed) {
                        apply(.setAngle(id: id, angle: angle))
                    }
                }))))
        }
        if transition.kind?.usesSoftness == true {
            rows.append(.init(.slider(.init(key: "transition:softness", label: "Softness",
                position: transition.softness * 100, min: 0, max: 100,
                display: "\(Int((transition.softness * 100).rounded()))%",
                format: { "\(Int($0.rounded()))%" }, tier: .explicitCustom,
                commit: { apply(.setSoftness(id: id, softness: $0 / 100)) }))))
        }
        if transition.kind == .iris {
            rows.append(.init(.segmented(.init(key: "transition:shape", label: "Shape",
                options: NativeIrisShape.allCases.map {
                    ($0.rawValue, $0.rawValue.capitalized, $0 == transition.irisShape)
                },
                select: { value in
                    if let shape = NativeIrisShape(rawValue: value) {
                        apply(.setIris(id: id, shape: shape,
                            centreX: transition.centreX, centreY: transition.centreY))
                    }
                }))))
            rows.append(.init(.number(.init(key: "transition:centreX", label: "Centre X (%)",
                text: PanelFormat.number(transition.centreX * 100, decimals: 0), tier: .explicitCustom,
                commit: { value in
                    if let percent = PanelFormat.parse(value) {
                        apply(.setIris(id: id, shape: transition.irisShape ?? .circle,
                            centreX: percent / 100, centreY: transition.centreY))
                    }
                }))))
            rows.append(.init(.number(.init(key: "transition:centreY", label: "Centre Y (%)",
                text: PanelFormat.number(transition.centreY * 100, decimals: 0), tier: .explicitCustom,
                commit: { value in
                    if let percent = PanelFormat.parse(value) {
                        apply(.setIris(id: id, shape: transition.irisShape ?? .circle,
                            centreX: transition.centreX, centreY: percent / 100))
                    }
                }))))
        }
        if transition.kind == .zoomThrough {
            rows.append(.init(.slider(.init(key: "transition:strength", label: "Strength",
                position: transition.strength,
                min: NativeCutTransition.strengthRange.lowerBound,
                max: NativeCutTransition.strengthRange.upperBound,
                display: "\(PanelFormat.number(transition.strength, decimals: 1))x",
                format: { "\(PanelFormat.number($0, decimals: 1))x" }, tier: .explicitCustom,
                commit: { apply(.setStrength(id: id, strength: $0)) }))))
        }
        let current = Self.easePresetKey(transition.ease)
        rows.append(.init(.segmented(.init(key: "transition:ease", label: "Ease",
            options: Self.transitionEaseOptions.map { ($0.key, $0.label, $0.key == current) },
            select: { value in
                if let preset = Self.transitionEaseOptions.first(where: { $0.key == value })?.value {
                    apply(.setEase(id: id, ease: preset))
                }
            }))))
        return rows
    }

    private static func directionLabel(_ direction: NativeTransitionDirection) -> String {
        switch direction {
        case .left: "← Left"
        case .right: "→ Right"
        case .up: "↑ Up"
        case .down: "↓ Down"
        }
    }

    /// Ease presets for transitions, with the keyframe engine's control points
    /// (`TimelineKeyframeMenu.eases` / `easePresets`).
    fileprivate static let transitionEaseOptions: [(key: String, label: String, value: NativeInterpolation)] = [
        ("linear", "Linear", .linear),
        ("in", "Ease in", .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 1, y2: 1))),
        ("out", "Ease out", .cubicBezier(CubicBezierControlPoints(x1: 0, y1: 0, x2: 0.58, y2: 1))),
        ("inout", "Ease in-out", .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 0.58, y2: 1))),
    ]
}
