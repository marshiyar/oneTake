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
// Cut transitions on the timeline: a band across the cut between two clips, drawn over the clips, with a cross-fade glyph
// and its length as timecode when wide enough. The band is the accent (a token, in both appearances); a selected one
// gets the selection outline a selected clip has.
import Foundation
import MpvfxCanvas
import MpvfxTheme

extension TimelineView {
    /// The band's two grab edges are this wide on each side, in points (a narrower band gives each a third).
    public static let transitionEdgePx = 6.0
    /// The length shows as timecode from this width.
    public static let transitionLabelMinPx = 32.0

    /// The transition's range in seconds, with `frames` as its length (a live resize shows the length being dragged).
    func transitionRange(_ t: TimelineTransitionModel, frames: Double) -> (start: Double, end: Double) {
        let fps = max(frameRate, 1e-9)
        switch t.alignment {
        case "endsAtCut": return (t.cut - frames / fps, t.cut)
        case "startsAtCut": return (t.cut, t.cut + frames / fps)
        default:
            let before = (frames / 2).rounded(.down)
            return (t.cut - before / fps, t.cut - before / fps + frames / fps)
        }
    }

    /// The length a band shows: the one being dragged, else the stored one.
    func shownTransitionFrames(_ t: TimelineTransitionModel) -> Double {
        transitionDrag?.id == t.id ? transitionDrag?.frames ?? t.durationFrames : t.durationFrames
    }

    /// The band of `t` on track row `i`, in view coordinates, with the live resize applied.
    public func transitionRect(row i: Int, _ t: TimelineTransitionModel) -> CanvasRect {
        let r = transitionRange(t, frames: shownTransitionFrames(t))
        return CanvasRect(x: x(for: r.start), y: rowTop(i) + TimelineLayout.clipY, width: max(1, (r.end - r.start) * pixelsPerSecond),
                          height: trackHeight - 2 * TimelineLayout.clipY)
    }

    /// Draws every track's transition bands (after the clips, so a band covers the two edges it softens).
    func drawTransitions(_ c: CanvasContext) {
        let accent = CanvasColor(ThemeTokens.mint)
        for (i, track) in tracks.enumerated() {
            for t in track.transitions {
                let r = transitionRect(row: i, t)
                let selected = selectedTransitionId == t.id
                c.fillRoundedRect(r, radius: 3, accent.withAlpha(selected ? 0.55 : 0.38))
                c.strokeRoundedRect(r.insetBy(0.5), radius: 2.5, selected ? CanvasColor(ThemeTokens.white.alpha(0.98)) : accent, width: selected ? 2 : 1)
                guard r.width >= 12 else { continue }
                // The cross-fade glyph: two strokes crossing, one fading in and one out.
                let inset = min(5, r.width / 4), gy = r.height * 0.3
                var p = CanvasPath()
                p.move(to: .init(r.x + inset, r.y + gy)); p.line(to: .init(r.maxX - inset, r.maxY - gy))
                p.move(to: .init(r.x + inset, r.maxY - gy)); p.line(to: .init(r.maxX - inset, r.y + gy))
                c.stroke(p, CanvasColor(ThemeTokens.white.alpha(0.92)), StrokeStyle(width: 1.5))
                if r.width >= Self.transitionLabelMinPx {
                    let label = TimelineRuler.timecode(shownTransitionFrames(t) / max(frameRate, 1e-9), frameRate: frameRate)
                    c.drawText(label, at: .init(r.x + 3, r.y + 2), font: CanvasFont(family: Self.clipMonoFamily, size: 9),
                               color: CanvasColor(ThemeTokens.white.alpha(0.95)))
                }
            }
        }
    }
}
