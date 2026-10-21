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

/// Slip and roll previews: a slipped clip's waveform shifts with its source and carries a frame-offset badge; a roll
/// (or the roll tool hovering a cut) draws a double bracket at the cut over both clip edges.
extension TimelineView {
    /// The clip as drawn during a slip: its source window moved by the preview's shift.
    func slipPreview(_ clip: TimelineClipModel) -> TimelineClipModel {
        guard case let .slip(id, _, shift)? = drag, id == clip.id else { return clip }
        var c = clip
        c.sourceStartFraction += shift; c.sourceEndFraction += shift
        return c
    }

    /// The cut a roll is moving (or the roll tool is hovering): row and time.
    var rollCut: (row: Int, time: Double)? {
        guard case let .roll(outgoing, _, t)? = drag else { return rollHover }
        guard let row = tracks.firstIndex(where: { $0.clips.contains { $0.id == outgoing } }) else { return nil }
        return (row, t)
    }

    /// The badge text for a slip of `frames` timeline frames ("Slip +10f", "Slip −3f").
    static func slipLabel(_ frames: Double) -> String {
        let n = Int(frames)
        return n > 0 ? "Slip +\(n)f" : n < 0 ? "Slip \u{2212}\(-n)f" : "Slip 0f"
    }

    func drawSlipRollOverlay(_ c: CanvasContext) {
        if case let .slip(id, frames, _)? = drag, let row = tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
           let clip = tracks[row].clips.first(where: { $0.id == id }) {
            drawSlipBadge(c, Self.slipLabel(frames), in: clipRect(track: row, clip))
        }
        if let cut = rollCut { drawRollBracket(c, row: cut.row, time: cut.time) }
    }

    func drawSlipBadge(_ c: CanvasContext, _ text: String, in r: CanvasRect) {
        let f = CanvasFont(family: Self.uiFontFamily, size: 10, weight: .semibold)
        let w = c.measureText(text, font: f).width + 12, h = 16.0
        let box = CanvasRect(x: r.centerX - w / 2, y: r.centerY - h / 2, width: w, height: h)
        c.fillRoundedRect(box, radius: 4, CanvasColor(ThemeTokens.neutral900.alpha(0.9)))
        c.strokeRoundedRect(box.insetBy(0.5), radius: 4, theme.accent, width: 1)
        c.drawText(text, at: .init(box.x + 6, box.y + 2), font: f, color: theme.accent)
    }

    /// "][" in the accent: the outgoing clip's end bracket left of the cut, the incoming clip's start bracket right of it.
    func drawRollBracket(_ c: CanvasContext, row: Int, time: Double) {
        let cx = x(for: time), top = rowTop(row) + TimelineLayout.clipY, h = trackHeight - 2 * TimelineLayout.clipY
        var p = CanvasPath()
        p.move(to: .init(cx - 6, top + 1)); p.line(to: .init(cx - 2, top + 1)); p.line(to: .init(cx - 2, top + h - 1)); p.line(to: .init(cx - 6, top + h - 1))
        p.move(to: .init(cx + 6, top + 1)); p.line(to: .init(cx + 2, top + 1)); p.line(to: .init(cx + 2, top + h - 1)); p.line(to: .init(cx + 6, top + h - 1))
        c.stroke(p, theme.accent, StrokeStyle(width: 2))
    }
}
