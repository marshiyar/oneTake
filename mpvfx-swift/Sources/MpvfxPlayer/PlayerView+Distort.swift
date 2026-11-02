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
import MpvfxPanels
import MpvfxShared

extension PlayerView {
    /// The distort tool's chrome: the distorted outline and a knob on each corner (the active one filled with the accent).
    func drawDistort(_ c: CanvasContext, _ ve: StageElement) {
        let points = PlayerController.cornerPoints(ve, ve.corners ?? .identity)
        var outline = CanvasPath()
        for (i, p) in points.enumerated() { if i == 0 { outline.move(to: p.1) } else { outline.line(to: p.1) } }
        outline.close()
        c.stroke(outline, theme.accent, StrokeStyle(width: 1))
        // The plain box, faint, so the distance each corner has moved reads.
        let r = ve.rect
        c.withState {
            c.translate(ve.centre.x, ve.centre.y); c.rotate(ve.rotation * .pi / 180); c.translate(-ve.centre.x, -ve.centre.y)
            var box = CanvasPath(); box.addRect(r)
            c.stroke(box, theme.accent.withAlpha(0.3), StrokeStyle(width: 1, dash: [4, 4]))
        }
        for (corner, p) in points {
            let k = CanvasRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            c.fillRect(k, corner == activeCorner ? theme.accent : PanelTheme.stageInk)
            c.strokeRect(k.insetBy(0.5), theme.accent, width: 1)
        }
    }
}
