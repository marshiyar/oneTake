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

extension InspectorPanel {
    /// The open curve's points share one stopwatch and keyframe navigation row.
    func curveKeyframeRows(_ editor: TimelineEditor, _ s: Selected, shown g: ColorGrading) -> [InspectorRow] {
        let tab = openCurveTab
        // Default handles have no stored point positions for parameter tracks to address.
        let points = (tab.hue ? g.hueCurves : g.curves)[tab.key] ?? []
        guard points.count >= 2 else { return [] }
        let ids = NativeGradeParameter.curveIds(tab.key, count: points.count, hue: tab.hue)
        let key = "grade:curvekey", kf = gradeKeyframe(editor, s, ids, shown: g)
        let custom = InspectorCustomRow(id: "grade:curvekeys", height: Self.keyframeCell, draw: { [weak self] c, r, _ in
            self?.drawKeyframeNav(c, right: r.midX + Self.keyframeGutter / 2, midY: r.midY, key: key, kf)
        }, pointer: { _, _, _ in })
        let control = InspectorRow(.number(.init(key: key, label: "", text: "", tier: .default, commit: { _ in }, keyframe: kf)))
        return [InspectorRow(.custom(custom), controls: [control])]
    }
}
