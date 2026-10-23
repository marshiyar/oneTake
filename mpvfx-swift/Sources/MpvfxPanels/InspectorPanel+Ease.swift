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
import MpvfxTheme

/// The keyframe easing block of the Transform, Compositing and Media blocks: a heading with the key count and an "Easing…"
/// button that opens the Keyframe Easing panel on those keys (the timeline's selected keys on this clip's eased
/// channels, else the key at/before the playhead of each). The presets, curve and numbers live in the panel
/// (KeyframeEasingPanel); this block replaced the segmented Ease row, whose options drew over its label (#154).
extension InspectorPanel {
    /// DEFAULT_CUBIC: where a custom curve starts from a linear or hold key.
    public static let defaultCubic = CubicBezierControlPoints(x1: 0.33, y1: 0, x2: 0.67, y2: 1)
    public static let cubicYRange: ClosedRange<Double> = -1...2

    /// Presets in the picker's order; `value` nil is Custom.
    static let easePresets: [(key: String, label: String, value: NativeInterpolation?)] = [
        ("linear", "Linear", .linear),
        ("in", "In", .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 1, y2: 1))),
        ("out", "Out", .cubicBezier(CubicBezierControlPoints(x1: 0, y1: 0, x2: 0.58, y2: 1))),
        ("inout", "In & out", .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 0.58, y2: 1))),
        ("hold", "Hold", .hold),
        ("custom", "Custom", nil),
    ]

    static func easePresetKey(_ v: NativeInterpolation) -> String {
        easePresets.first { $0.value == v }?.key ?? "custom"
    }

    /// Clamp one handle coordinate (normalizeControl), rounded to 0.001 so typed and dragged values stay tidy.
    static func clampCubic(_ p: CubicBezierControlPoints) -> CubicBezierControlPoints {
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        func x(_ v: Double) -> Double { r(max(0, min(1, v))) }
        func y(_ v: Double) -> Double { r(max(cubicYRange.lowerBound, min(cubicYRange.upperBound, v))) }
        var q = p   // keeps any unknown keys the document carried
        q.x1 = x(p.x1); q.y1 = y(p.y1); q.x2 = x(p.x2); q.y2 = y(p.y2)
        return q
    }

    /// The keys the easing block points at: the timeline's selected keys on this clip's eased channels, else the playhead's.
    func easeTargets(_ editor: TimelineEditor, _ s: Selected, channels: [String]) -> (refs: [TimelineKeyframeRef], selected: Bool) {
        let picked = selectedKeyframes.filter { $0.clipId == s.id && channels.contains($0.parameterId) && editor.outgoing($0) != nil }
            .sorted(by: KeyframeEasingTarget.inTimeOrder)
        if !picked.isEmpty { return (picked, true) }
        return (editor.keyframesAtOrBefore(clipId: s.id, parameterIds: channels, time: time), false)
    }

    func easingRows(_ editor: TimelineEditor, _ s: Selected, channels: [String]) -> [InspectorRow] {
        let (refs, selected) = easeTargets(editor, s, channels: channels)
        guard let first = refs.first, editor.outgoing(first) != nil else { return [] }
        let trailing = selected ? "\(refs.count) selected" : (refs.count > 1 ? "\(refs.count) channels" : nil)
        let open = InspectorRow.Button(key: "openEasing", label: "Easing…", style: .chip, action: { [weak self] in
            self?.onOpenEasing?(s.id, Set(refs))
        })
        return [.init(.spacer(PanelGrid.unit)), .init(.heading("Keyframe easing", trailing: trailing)), .init(.buttons([open]))]
    }
}
