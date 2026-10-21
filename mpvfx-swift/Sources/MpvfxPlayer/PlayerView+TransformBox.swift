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
import MpvfxTheme

/// Drawing of the transform box over the selected element: the square outline, four corner dots and four edge
/// pills (white with an accent border, accent-filled while hovered or dragged), the anchor crosshair, the rotate
/// chip, and while a drag runs the readout pill beside the cursor and the rotate glyph. Everything is drawn in view
/// px, so it keeps its on-screen size at any zoom; a dark ring around each handle keeps it visible on light pictures.
/// The outline itself stays the square, pixel-exact 2 px line with nothing drawn outside it (docs/FEATURES.md §4).
extension PlayerView {
    static let contrastRing = CanvasColor(ThemeTokens.stageScrim.alpha(0.45))
    static let edgePill = CanvasSize(16, 6)

    /// Edge handles show on sides long enough to hold them beside the corners.
    public func showsHandle(_ h: TransformHandle, of ve: StageElement) -> Bool {
        if h.isCorner { return true }
        let v = ve.visibleRect
        return (h.movesX ? v.height : v.width) >= Self.edgeHandleMinSide
    }

    /// The selected element's box: outline, handles, anchor and rotate chip; a locked layer gets the outline only.
    func drawSelection(_ c: CanvasContext, _ ve: StageElement) {
        let r = ve.visibleRect
        rotated(c, ve) {
            Self.strokeSquare(c, r, theme.accent.withAlpha(ve.locked ? 0.45 : (ve.crop.isZero ? 0.8 : 0.6)), width: 2)
            guard !ve.locked else { return }
            for h in TransformHandle.allCases where showsHandle(h, of: ve) {
                drawHandle(c, h, at: TransformBox.localPoint(ve, unit: h.unit), lit: isLit(.handle(h)))
            }
            drawAnchor(c, TransformBox.localPoint(ve, unit: transformChrome.anchor(ve.id)), lit: isLit(.anchor))
            drawRotateChip(c, CanvasPoint(r.x + r.width / 2, r.maxY + 12 + 11), lit: isLit(.rotateChip))
        }
    }

    func isLit(_ hit: TransformHit) -> Bool { transformChrome.active == hit || (transformChrome.active == nil && transformChrome.hover == hit) }

    /// Corner: 12 px dot; edge: 16 × 6 pill along its side. White with a 1.5 px accent border, inverted when lit.
    func drawHandle(_ c: CanvasContext, _ h: TransformHandle, at p: CanvasPoint, lit: Bool) {
        let size = h.isCorner ? CanvasSize(Self.handleDot, Self.handleDot)
            : (h.movesX ? CanvasSize(Self.edgePill.height, Self.edgePill.width) : Self.edgePill)
        let r = CanvasRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
        let radius = min(size.width, size.height) / 2
        c.strokeRoundedRect(r.insetBy(-0.5), radius: radius + 0.5, Self.contrastRing, width: 1)
        c.fillRoundedRect(r, radius: radius, lit ? theme.accent : PanelTheme.stageInk)
        c.strokeRoundedRect(r.insetBy(0.75), radius: max(0, radius - 0.75), lit ? PanelTheme.stageInk : theme.accent, width: 1.5)
    }

    /// Anchor: a 10 px ring with crosshair arms, white over a dark outline (accent when lit).
    func drawAnchor(_ c: CanvasContext, _ p: CanvasPoint, lit: Bool) {
        let ink = lit ? theme.accent : PanelTheme.stageInk
        var arms = CanvasPath()
        for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1)] {
            arms.move(to: .init(p.x + dx * 5, p.y + dy * 5)); arms.line(to: .init(p.x + dx * 9, p.y + dy * 9))
        }
        let ring = CanvasRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        c.stroke(arms, Self.contrastRing, StrokeStyle(width: 3))
        c.strokeRoundedRect(ring, radius: 5, Self.contrastRing, width: 3)
        c.stroke(arms, ink, StrokeStyle(width: 1.5))
        c.strokeRoundedRect(ring, radius: 5, ink, width: 1.5)
    }

    /// Rotate chip below the box: 18 px, surface fill, accent ring and circular-arrows icon.
    func drawRotateChip(_ c: CanvasContext, _ p: CanvasPoint, lit: Bool) {
        let chip = CanvasRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)
        c.fillRoundedRect(chip, radius: 9, lit ? theme.accent : Self.studioSurface)
        c.strokeRoundedRect(chip.insetBy(0.5), radius: 9, theme.accent.withAlpha(lit ? 1 : 0.7), width: 1)
        Self.drawRotateIcon(c, in: CanvasRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11),
                            color: lit ? PanelTheme.stageInk : theme.accent, width: 2.5)
    }

    /// The two circular arrows of a 24-unit icon box, drawn into the square `box`.
    static func drawRotateIcon(_ c: CanvasContext, in box: CanvasRect, color: CanvasColor, width: Double) {
        c.withState {
            c.translate(box.x, box.y); c.scale(box.width / 24, box.width / 24)
            var a = CanvasPath(); a.move(to: .init(3, 12)); a.curve(to: .init(18.74, 5.74), c1: .init(3, 4), c2: .init(13, 1))
            a.line(to: .init(21, 8))
            var b = CanvasPath(); b.move(to: .init(21, 3)); b.line(to: .init(21, 8)); b.line(to: .init(16, 8))
            var d = CanvasPath(); d.move(to: .init(21, 12)); d.curve(to: .init(5.26, 18.26), c1: .init(21, 20), c2: .init(11, 23))
            d.line(to: .init(3, 16))
            var e = CanvasPath(); e.move(to: .init(8, 16)); e.line(to: .init(3, 16)); e.line(to: .init(3, 21))
            for path in [a, b, d, e] { c.stroke(path, color, StrokeStyle(width: width)) }
        }
    }

    /// Over the stage while a drag runs or the pointer is in a rotate zone: the readout pill and the rotate glyph.
    func drawTransformFeedback(_ c: CanvasContext, size: CanvasSize) {
        let v = viewportRect(in: size)
        if transformChrome.cursor == .rotate, let p = transformChrome.pointer, v.contains(p) {
            let glyph = CanvasRect(x: p.x + 6, y: p.y + 6, width: 16, height: 16)
            Self.drawRotateIcon(c, in: glyph, color: Self.contrastRing, width: 5)
            Self.drawRotateIcon(c, in: glyph, color: PanelTheme.stageInk, width: 2.5)
        }
        guard let r = transformChrome.readout else { return }
        let font = CanvasFont.mono(11, weight: .medium)
        let tw = c.measureText(r.text, font: font).width
        let w = tw + 16, h = 22.0
        let x = min(max(v.x + 4, r.at.x + 16), v.maxX - w - 4), y = min(max(v.y + 4, r.at.y + 20), v.maxY - h - 4)
        let pill = CanvasRect(x: x, y: y, width: w, height: h)
        c.fillRoundedRect(pill, radius: 6, PanelTheme.stageScrim.withAlpha(0.88))
        c.strokeRoundedRect(pill.insetBy(0.5), radius: 5.5, PanelTheme.stageInk.withAlpha(0.2), width: 1)
        c.drawText(r.text, at: .init(pill.x + 8, pill.y + 5), font: font, color: PanelTheme.stageInk)
    }
}
