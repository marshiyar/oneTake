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

/// Keyframe controls of the Grade and Effects rows (issue #179): the stopwatch and ‹ ◆ › of Amount, the Primary
/// values, Vignette, Grain and each stylize effect's amount, and one set per color wheel (its hue, amount and level
/// key together). Their keys are `grade.*` parameter tracks (`NativeGradeParameter`).
extension InspectorPanel {
    func gradeKeyframe(_ editor: TimelineEditor, _ s: Selected, _ ids: [String], shown g: ColorGrading) -> InspectorRow.Keyframe {
        let t = time
        let animated = ids.filter { editor.isAnimated(clipId: s.id, $0) }
        let here = ids.filter { editor.hasKeyframe(clipId: s.id, $0, time: t) }
        let fallbacks = ids.map { (id: $0, fallback: NativeParameterValue.number(g.value($0) ?? 0)) }
        let prev = animated.compactMap { editor.adjacentKeyframeTime(clipId: s.id, $0, time: t, forward: false) }.max()
        let next = animated.compactMap { editor.adjacentKeyframeTime(clipId: s.id, $0, time: t, forward: true) }.min()
        var kf = InspectorRow.Keyframe(
            state: !here.isEmpty ? .onKey : (animated.isEmpty ? .none : .animated),
            // ◆ on a key removes the keys there; elsewhere it keys every value of the row at the playhead.
            toggle: { [weak self] in
                let targets = here.isEmpty ? fallbacks : fallbacks.filter { here.contains($0.id) }
                self?.edited(InspectorPanel.oneStep(editor, "Edit color grade") {
                    targets.reduce(false) { editor.toggleKeyframe(clipId: s.id, $1.id, time: t, fallback: $1.fallback) || $0 }
                }, label: "Edit color grade")
            },
            stopwatch: { [weak self] in
                self?.edited(animated.isEmpty ? editor.setAnimated(clipId: s.id, fallbacks, true, time: t)
                                              : editor.stopGradeAnimation(clipId: s.id, ids, time: t), label: "Edit color grade")
            },
            prev: prev.map { v in { [weak self] in self?.onSeek?(v) } },
            next: next.map { v in { [weak self] in self?.onSeek?(v) } })
        kf.kind = TimelineKeyframeCatalog.property(ids.first ?? NativeGradeParameter.intensityId).kind
        kf.ease = TimelineKeyframeEase(here.first.flatMap { editor.interpolation(clipId: s.id, $0, time: t) })
        return kf
    }

    /// Under the wheels: each wheel's stopwatch and ‹ ◆ ›, centred in its column.
    func wheelKeyframesRow(_ editor: TimelineEditor, _ s: Selected, shown g: ColorGrading) -> InspectorRow {
        let keys = ColorGrading.wheelKeys.map { w in
            (key: "grade:wheelkey:\(w)", kf: gradeKeyframe(editor, s, NativeGradeParameter.wheelFields.map { NativeGradeParameter.wheelId(w, $0) }, shown: g))
        }
        let custom = InspectorCustomRow(id: "grade:wheelkeys", height: Self.keyframeCell, draw: { [weak self] c, r, _ in
            guard let self else { return }
            let gap = 8.0, colW = (r.width - gap * 2) / 3
            for (i, k) in keys.enumerated() {
                // Centre the four keyframe cells under each tonal wheel.
                let right = r.x + Double(i) * (colW + gap) + colW / 2 + Self.keyframeGutter / 2
                self.drawKeyframeNav(c, right: right, midY: r.midY, key: k.key, k.kf)
            }
        }, pointer: { _, _, _ in })
        // Descriptor rows, so the ◆ / stopwatch / ‹ › hits resolve by key like any slider's.
        let controls = keys.map { k in
            InspectorRow(.number(.init(key: k.key, label: "", text: "", tier: .default, commit: { _ in }, keyframe: k.kf)))
        }
        return InspectorRow(.custom(custom), controls: controls)
    }
}
