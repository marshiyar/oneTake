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
    func drawShapeTool(_ c: CanvasContext, size: CanvasSize, frame: CanvasRect) {
        guard let tool = shapeTool else { return }
        if let draft = shapeDraft {
            let s = scale(in: size)
            let box = CanvasRect(x: frame.x + draft.box.x * s, y: frame.y + draft.box.y * s,
                                 width: draft.box.width * s, height: draft.box.height * s)
            c.withState {
                c.clip(frame)
                NativeShapeRendering.draw(draft.shape, box: box, scale: s, opacity: 0.85, on: c)
            }
            Self.strokeSquare(c, box, theme.accent, width: 1)
        }
        let font = CanvasFont(size: 11, weight: .semibold)
        for (kind, rect) in StageShapePicker.rects(in: viewportRect(in: size)) {
            let on = kind == tool
            c.fillRoundedRect(rect, radius: 6, on ? theme.accent : CanvasColor(r: 0, g: 0, b: 0, a: 0.6))
            let label = StageShapeDraft.label(kind)
            let w = c.measureText(label, font: font).width
            c.drawText(label, at: CanvasPoint(rect.x + (rect.width - w) / 2, rect.y + 8), font: font, color: PanelTheme.stageInk)
        }
    }
}
