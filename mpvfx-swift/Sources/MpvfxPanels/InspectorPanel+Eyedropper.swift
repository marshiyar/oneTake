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
import MpvfxTheme

/// The Grade secondary's "Sample color from frame": capture the clip's current
/// frame, click a colour on it to key the selection (SecondaryColorKey.sample), then check the Selection matte.
/// The key is written to the clip's grade, which preview and export both grade with.
extension InspectorPanel {
    /// Longest side of the captured frame (the host renders the clip's graded frame at most this big).
    static let sampleFrameSize = 320

    func eyedropperRows(_ g: ColorGrading, sel: Int, commit: @escaping (ColorGrading) -> Void) -> [InspectorRow] {
        let clipId = selected()?.id
        var rows: [InspectorRow] = [.init(.custom(InspectorCustomRow(id: "sec:sample", height: 28, draw: { [weak self] c, r, panel in
            guard let self else { return }
            if self.grade.samplePending, let clipId { self.captureSampleFrame(clipId) }   // a capture still rendering
            let hot = panel.hovered == .custom("sec:sample", 0)
            let color = hot ? PanelTheme.accent : PanelTheme.accent
            PanelIcon.phosphor(.eyedropper).draw(c, in: CanvasRect(x: r.x, y: r.y + 8, width: 12, height: 12), color: color)
            let label = self.grade.samplePending ? "Capturing frame" : "Sample color from frame"
            let w = c.measureText(label, font: PanelTheme.font(11, .medium)).width
            PanelDraw.text(c, label, in: CanvasRect(x: r.x + 18, y: r.y + 6.5, width: r.width - 18, height: 15), font: PanelTheme.font(11, .medium), color: color)
            panel.addHit(CanvasRect(x: r.x, y: r.y, width: 18 + w, height: r.height), .custom("sec:sample", 0))
        }, pointer: { [weak self] _, _, phase in
            guard let self, phase == 0, let clipId else { return }
            self.grade.sampleFrame = nil; self.grade.sampleError = false; self.grade.showMatte = false; self.grade.matteMemo = nil
            self.captureSampleFrame(clipId)
        })))]
        if grade.sampleError {
            rows.append(.init(.custom(InspectorCustomRow(id: "sec:sampleError", height: 16, draw: { c, r, _ in
                PanelDraw.text(c, "Preview frame unavailable. Try again after the media loads.", in: r, font: PanelTheme.font(11), color: PanelTheme.red400)
            }))))
        }
        guard let frame = grade.sampleFrame, g.secondaries.indices.contains(sel) else { return rows }
        let key = grade.qualifierDraft ?? g.secondaries[sel]
        // Source / Selection matte (`flex gap-2 text-[9px]`, the active one in the accent).
        rows.append(.init(.custom(InspectorCustomRow(id: "sec:view", height: 16, draw: { [weak self] c, r, panel in
            guard let self else { return }
            var x = r.x
            for (i, label) in ["Source", "Selection matte"].enumerated() {
                let on = (i == 1) == self.grade.showMatte
                let w = c.measureText(label, font: PanelTheme.font(11)).width
                PanelDraw.text(c, label, in: CanvasRect(x: x, y: r.y + 1, width: w + 1, height: 14), font: PanelTheme.font(11),
                               color: on ? PanelTheme.accent : (panel.hovered == .custom("sec:view", i) ? PanelTheme.text2 : PanelTheme.inspectorText))
                panel.addHit(CanvasRect(x: x - 2, y: r.y, width: w + 4, height: r.height), .custom("sec:view", i))
                x += w + 8
            }
        }, pointer: { [weak self] part, _, phase in if phase == 0 { self?.grade.showMatte = part == 1 } }))))
        // The frame (`block w-full border border-panel-hairline`, contain): click a colour on Source to key it.
        let width = bodyContentWidth
        let height = min(220, max(40, width * Double(frame.height) / Double(max(1, frame.width))))
        rows.append(.init(.custom(InspectorCustomRow(id: "sec:frame", height: height, draw: { [weak self] c, r, panel in
            guard let self else { return }
            c.fillRect(r, PanelTheme.black)
            let pic = PreviewImageFit.contain(frame.width, frame.height, in: r)
            self.grade.sampleRect = pic
            if self.grade.showMatte {
                if self.grade.matteMemo?.key != key { self.grade.matteMemo = (key, SecondaryColorKey.matte(frame, key)) }
                if let m = self.grade.matteMemo?.image { c.drawImage(m, in: pic) }
            } else {
                c.drawImage(frame, in: pic)
                panel.addHit(pic, .custom("sec:frame", 0))
            }
            c.strokeRect(r.insetBy(0.5), PanelTheme.panelHairline)
        }, pointer: { [weak self] _, p, phase in
            guard let self, phase == 0, !self.grade.showMatte, let frame = self.grade.sampleFrame else { return }
            let pic = self.grade.sampleRect
            guard pic.width > 0, pic.height > 0 else { return }
            let x = (p.x - pic.x) / pic.width * Double(frame.width), y = (p.y - pic.y) / pic.height * Double(frame.height)
            var n = g
            guard SecondaryColorKey.sample(frame, x: x, y: y, into: &n.secondaries[sel]) else { return }
            self.grade.showMatte = true
            commit(n)
        }))))
        return rows
    }

    /// Asks the host for the clip's frame; a frame still rendering is asked for again on the next draw.
    func captureSampleFrame(_ clipId: String) {
        switch scopeFrame?(clipId, Self.sampleFrameSize, Self.sampleFrameSize) ?? .unavailable {
        case .ready(let img): grade.sampleFrame = img; grade.samplePending = false; grade.sampleError = false
        case .rendering: grade.samplePending = true
        case .unavailable, .failed: grade.samplePending = false; grade.sampleError = true
        }
    }
}

/// Contain-fit of an image in a rect, centred.
enum PreviewImageFit {
    static func contain(_ w: Int, _ h: Int, in r: CanvasRect) -> CanvasRect {
        guard w > 0, h > 0 else { return r }
        let s = min(r.width / Double(w), r.height / Double(h))
        return CanvasRect(x: r.x + (r.width - Double(w) * s) / 2, y: r.y + (r.height - Double(h) * s) / 2, width: Double(w) * s, height: Double(h) * s)
    }
}
