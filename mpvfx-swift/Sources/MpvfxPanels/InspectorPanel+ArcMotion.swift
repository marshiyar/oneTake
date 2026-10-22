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

/// Transform group's Arc motion rows (NativeArcMotion over ArcPathControls): with fewer than two position
/// keyframes a note; otherwise the Arc motion switch and, while it is on, Auto-rotate and one curviness slider per
/// segment (0…3). Not drawn: a Reset of hand-placed bezier control points (the native stage has no handles for them).
extension InspectorPanel {
    func arcMotionRows(_ editor: TimelineEditor, _ s: Selected) -> [InspectorRow] {
        guard editor.isAnimated(clipId: s.id, TimelineEditor.positionId) else { return [] }
        guard let path = editor.arcMotionPath(clipId: s.id) else {
            return [.init(.note("Add at least 2 position keyframes to enable arc motion."))]
        }
        let id = s.id
        let enabled = path.segments.contains { $0 != nil }
        var rows: [InspectorRow] = [.init(.spacer(PanelGrid.unit)),
            .init(.toggle(.init(key: "arcMotion", label: "Arc motion", on: enabled, tier: enabled ? .explicitCustom : .default,
                                set: { [weak self] on in self?.edited(editor.setArcMotion(clipId: id, on), label: "Edit arc motion") })))]
        guard enabled else { return rows }
        rows.append(.init(.toggle(.init(key: "arcAutoRotate", label: "Auto-rotate", on: path.autoRotate,
                                        tier: path.autoRotate ? .explicitCustom : .default,
                                        set: { [weak self] on in self?.edited(editor.setArcAutoRotate(clipId: id, on), label: "Edit arc motion") }))))
        let count = path.segments.count
        for (i, seg) in path.segments.enumerated() {
            let v = TimelineEditor.arcCurviness(seg)
            rows.append(.init(.slider(InspectorRow.Slider(
                key: "arcCurviness\(i)", label: count == 1 ? "Curviness" : "Segment \(i + 1)", position: v, min: 0, max: 3,
                display: PanelFormat.number(v, decimals: 1), format: { PanelFormat.number(($0 * 10).rounded() / 10, decimals: 1) },
                tier: v == 1 ? .default : .explicitCustom,
                commit: { [weak self] x in self?.edited(editor.setArcCurviness(clipId: id, segment: i, x), label: "Edit arc motion") },
                reset: { [weak self] in self?.edited(editor.setArcCurviness(clipId: id, segment: i, 1), label: "Edit arc motion") }))))
        }
        return rows
    }
}
