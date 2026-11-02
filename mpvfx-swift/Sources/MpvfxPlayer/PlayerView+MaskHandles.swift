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
import MpvfxTheme

/// What the stage draws for the mask being edited (issue #297).
public struct MaskOverlay: Equatable, Sendable {
    public var clipId: String
    public var mask: NativeClipMask
    /// The layer's box in its own pixels (the mask's units).
    public var layerSize: CanvasSize
    /// The handle being dragged or last grabbed, drawn filled.
    public var active: MaskHandle?
}

extension PlayerView {
    /// Side of a mask handle's square, in view px.
    static let maskHandleSide = 9.0

    /// The mask's outline and its handles over the selected layer `ve` (the element as the chrome sees it). The
    /// outline is a plain line; the handles are square, pixel-aligned outlines like the stage's other chrome
    /// (docs/FEATURES.md §4): white with an accent border, filled with the accent while grabbed.
    func drawMask(_ c: CanvasContext, _ ve: StageElement, _ o: MaskOverlay) {
        let size = o.layerSize
        func view(_ p: CanvasPoint) -> CanvasPoint {
            PlayerView.rotate(CanvasPoint(ve.rect.x + p.x / size.width * ve.rect.width, ve.rect.y + p.y / size.height * ve.rect.height),
                              about: ve.centre, ve.rotation)
        }
        let accent = theme.accent
        var outline = CanvasPath()
        let reach = (size.width + size.height) * 2
        let f = MaskStageEditor.frame(o.mask, size)
        func line(_ x: Double) {
            outline.move(to: view(MaskStageEditor.toLayer(f, x, -reach))); outline.line(to: view(MaskStageEditor.toLayer(f, x, reach)))
        }
        switch o.mask.kind {
        case "ellipse":
            for i in 0...64 {
                let t = Double(i) / 64 * 2 * .pi
                let p = view(MaskStageEditor.toLayer(f, cos(t) * f.w / 2, sin(t) * f.h / 2))
                if i == 0 { outline.move(to: p) } else { outline.line(to: p) }
            }
        case "linear": line(0)
        case "band": line(-f.w / 2); line(f.w / 2)
        default:
            let corners = [(-f.w / 2, -f.h / 2), (f.w / 2, -f.h / 2), (f.w / 2, f.h / 2), (-f.w / 2, f.h / 2)]
            for (i, k) in corners.enumerated() {
                let p = view(MaskStageEditor.toLayer(f, k.0, k.1))
                if i == 0 { outline.move(to: p) } else { outline.line(to: p) }
            }
            outline.close()
        }
        c.stroke(outline, Self.contrastRing, StrokeStyle(width: 3))
        c.stroke(outline, accent, StrokeStyle(width: 1.5))
        let half = Self.maskHandleSide / 2
        for h in MaskStageEditor.handles(of: o.mask, layerSize: size) {
            let p = view(h.point), r = CanvasRect(x: p.x - half, y: p.y - half, width: Self.maskHandleSide, height: Self.maskHandleSide)
            let lit = o.active == h.handle
            Self.fillSquare(c, r.insetBy(-1), Self.contrastRing)
            Self.fillSquare(c, r, lit ? accent : PanelTheme.stageInk)
            Self.strokeSquare(c, r, lit ? PanelTheme.stageInk : accent, width: 1.5)
        }
    }
}
