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

/// Clip fades on the timeline: the ramp line drawn on a faded clip and the handle at its top-left (fade in) and
/// top-right (fade out) corner that the user drags to set it (`TimelineController+Fades.swift`).
extension TimelineView {
    /// A fade handle is a small square at the top corner of a clip; clips narrower than this show none.
    static let fadeHandleSize = 8.0, fadeHandleMinClipWidth = 24.0
    /// The press target around a handle, past its drawn square.
    static let fadeHandleSlop = 3.0

    /// The clip as drawn during a fade drag: the dragged edge's fade is the preview's length.
    func fadePreview(_ clip: TimelineClipModel) -> TimelineClipModel {
        guard case let .fade(id, edge, seconds, _)? = drag, id == clip.id else { return clip }
        var c = clip
        if edge == .start { c.fadeIn = seconds } else { c.fadeOut = seconds }
        return c
    }

    /// Where a clip's fade handle sits: its ramp ends at the top edge `fadePx` in from the clip's `edge`, and the handle
    /// is held inside the clip when the fade is shorter than the handle. Nil when the clip is too narrow for handles.
    static func fadeHandleRect(_ r: CanvasRect, edge: TrimEdge, fadePx: Double) -> CanvasRect? {
        guard r.width >= fadeHandleMinClipWidth else { return nil }
        let s = fadeHandleSize
        let inset = max(0, min(fadePx, r.width - s))
        let x = edge == .start ? r.x + inset : r.maxX - inset - s
        return CanvasRect(x: x, y: r.y + 2, width: s, height: s)
    }

    func fadePixels(_ seconds: Double) -> Double { max(0, seconds) * pixelsPerSecond }

    /// The ramp lines and, when `handles`, the corner handles of `clip` drawn in `r`. The caller clips to the clip.
    func drawFades(_ c: CanvasContext, _ clip: TimelineClipModel, in r: CanvasRect, handles opacity: Double) {
        let inPx = min(fadePixels(clip.fadeIn), r.width), outPx = min(fadePixels(clip.fadeOut), r.width)
        let line = CanvasColor(ThemeTokens.white.alpha(0.85)), shade = CanvasColor(ThemeTokens.neutral950.alpha(0.35))
        if inPx > 0 {
            var area = CanvasPath()
            area.move(to: .init(r.x, r.y)); area.line(to: .init(r.x + inPx, r.y)); area.line(to: .init(r.x, r.maxY)); area.close()
            c.fill(area, shade)
            var ramp = CanvasPath()
            ramp.move(to: .init(r.x, r.maxY)); ramp.line(to: .init(r.x + inPx, r.y))
            c.stroke(ramp, line, StrokeStyle(width: 1.5))
        }
        if outPx > 0 {
            var area = CanvasPath()
            area.move(to: .init(r.maxX, r.y)); area.line(to: .init(r.maxX - outPx, r.y)); area.line(to: .init(r.maxX, r.maxY)); area.close()
            c.fill(area, shade)
            var ramp = CanvasPath()
            ramp.move(to: .init(r.maxX - outPx, r.y)); ramp.line(to: .init(r.maxX, r.maxY))
            c.stroke(ramp, line, StrokeStyle(width: 1.5))
        }
        guard opacity > 0 else { return }
        for (edge, px) in [(TrimEdge.start, inPx), (.end, outPx)] {
            guard let h = Self.fadeHandleRect(r, edge: edge, fadePx: px) else { continue }
            c.fillRoundedRect(h, radius: 2, CanvasColor(ThemeTokens.white.alpha(0.9 * opacity)))
            c.strokeRoundedRect(h.insetBy(0.5), radius: 2, CanvasColor(ThemeTokens.neutral950.alpha(0.6 * opacity)), width: 1)
        }
    }
}
