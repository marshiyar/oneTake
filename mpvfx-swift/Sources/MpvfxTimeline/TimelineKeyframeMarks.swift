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

/// What one mark on a row stands for: the keys at one frame in the row's scope. Coincident keys of several
/// properties stack into one mark: their kinds pick its shape and colour (one kind: that kind's mark with a count of
/// its properties; several kinds: a neutral stack mark with the count), and their outgoing interpolation its variant.
public struct TimelineKeyframeMark: Equatable, Sendable {
    public var frame: Double
    /// The properties keyed at this frame, by lane label, in kind order.
    public var labels: [String]
    public var kinds: [TimelineKeyframeKind]
    public var ease: TimelineKeyframeEase
    public var count: Int { labels.count }
    /// The one kind of the mark, nil when it stacks several.
    public var kind: TimelineKeyframeKind? { kinds.count == 1 ? kinds[0] : nil }
}

extension TimelineView {
    /// Fill radius of a mark: the original diamond's 4 of 10 units of the 22 px glyph box.
    static var keyframeMarkRadius: Double { keyframeDiamondSize * 0.4 }

    /// The marks of a scope (`scope` nil: every channel of the clip), with the live drag preview applied.
    public func keyframeMarks(_ clip: TimelineClipModel, scope: Set<String>?) -> [TimelineKeyframeMark] {
        let channels = keyframeChannels(clip, scope: scope)
        return diamondFrames(clip, scope: scope).map { frame in
            let refs = diamondRefs(clip, scope: scope, frame: frame)
            let groups = Set(channels.filter { ch in refs.contains { $0.parameterId == ch.parameterId } }.map(\.group))
            let props = groups.map { g in
                // A model without channels (the demo timeline) keys one anonymous group: it draws as a transform key.
                (kind: g.isEmpty ? TimelineKeyframeKind.transform : TimelineKeyframeCatalog.kind(ofGroup: g),
                 label: clip.lanes.first { $0.group == g }?.label ?? g, order: TimelineKeyframeCatalog.order(ofGroup: g))
            }
                .sorted { ($0.kind, $0.order, $0.label) < ($1.kind, $1.order, $1.label) }
            let eases = Set(channels.compactMap { ch in refs.first { $0.parameterId == ch.parameterId }.map { ch.eases[$0.frame] ?? .linear } })
            return TimelineKeyframeMark(frame: frame, labels: props.map(\.label), kinds: Array(Set(props.map(\.kind))).sorted(),
                                        ease: eases.count == 1 ? eases.first ?? .linear : .linear)
        }
    }

    /// Draws a scope's marks along a row centred at `cy`. `rowKind` (a kind or property row) forces that kind's mark.
    /// `origin`: the clip's left edge (frame 0) and the row's centre line.
    func drawMarks(_ c: CanvasContext, _ clip: TimelineClipModel, scope: Set<String>?, origin: CanvasPoint) {
        let barX = origin.x, cy = origin.y
        let playheadFrame: Double? = selection.contains(clip.id) && currentTime >= clip.start && currentTime < clip.end
            ? ((currentTime - clip.start) * frameRate + 1e-9).rounded(.down) : nil
        let r = Self.keyframeMarkRadius
        for m in keyframeMarks(clip, scope: scope) {
            let cx = barX + m.frame / max(frameRate, 1e-9) * pixelsPerSecond
            let selected = isDiamondSelected(clip, scope: scope, frame: m.frame)
            let ring: CanvasColor? = selected ? theme.accent : (m.frame == playheadFrame ? theme.textSecondary : nil)
            let at = CanvasPoint(cx, cy)
            if let kind = m.kind {
                TimelineKeyframeGlyph.draw(c, .init(kind, ease: m.ease, ring: ring), at: at, r: r)
            } else {
                drawStackMark(c, at: at, ring: ring)
            }
            if m.count > 1 { drawMarkCount(c, m.count, at: at, inside: m.kind == nil) }
        }
    }

    /// Several kinds at one frame: a neutral rounded block (no kind's shape, so it is never read as one kind).
    func drawStackMark(_ c: CanvasContext, at p: CanvasPoint, ring: CanvasColor?) {
        let r = Self.keyframeMarkRadius, cx = p.x, cy = p.y
        let box = CanvasRect(x: cx - r, y: cy - r * 0.75, width: 2 * r, height: 1.5 * r)
        if let ring { c.strokeRoundedRect(box.insetBy(-2.5), radius: 5, ring, width: 1.5) }
        c.fillRoundedRect(box, radius: 4, theme.textPrimary)
    }

    /// The count of stacked properties: inside a stack mark, else a small badge at the mark's upper right.
    func drawMarkCount(_ c: CanvasContext, _ n: Int, at p: CanvasPoint, inside: Bool) {
        let r = Self.keyframeMarkRadius, cx = p.x, cy = p.y
        let f = CanvasFont(family: Self.uiFontFamily, size: inside ? 10 : 8, weight: .bold)
        let text = n > 9 ? "9+" : "\(n)"
        let w = c.measureText(text, font: f).width
        if inside {
            c.drawText(text, at: .init(cx - w / 2, cy - 6), font: f, color: theme.shellBackground)
            return
        }
        let badge = CanvasRect(x: cx + r * 0.35, y: cy - r - 3, width: max(10, w + 4), height: 10)
        c.fillRoundedRect(badge, radius: 5, theme.textPrimary)
        c.drawText(text, at: .init(badge.x + (badge.width - w) / 2, badge.y), font: f, color: theme.shellBackground)
    }

    /// Hovering a stacked mark lists what it stands for under the pointer.
    func drawKeyframeTooltip(_ c: CanvasContext, size: CanvasSize) {
        guard let h = hoveredKeyframe, keyframeDrag == nil, tracks.indices.contains(h.row),
              let clip = tracks[h.row].clips.first(where: { $0.id == h.clipId }) else { return }
        let scope = h.laneRow.flatMap { rowScope($0, clip) }
        guard let m = keyframeMarks(clip, scope: scope).first(where: { $0.frame == h.frame }), m.count > 1 else { return }
        let f = CanvasFont(family: Self.uiFontFamily, size: 10)
        let text = m.labels.joined(separator: " · ")
        let w = c.measureText(text, font: f).width + 12
        let cx = clipRect(track: h.row, clip, preview: false).x + m.frame / max(frameRate, 1e-9) * pixelsPerSecond
        let box = CanvasRect(x: min(max(TimelineLayout.contentOrigin, cx - w / 2), size.width - w), y: max(TimelineLayout.rulerHeight, rowTop(h.row) - 22), width: w, height: 18)
        c.fillRoundedRect(box, radius: 4, CanvasColor(ThemeTokens.popoverPair.now))
        c.strokeRoundedRect(box, radius: 4, theme.gutterBorder, width: 1)
        c.drawText(text, at: .init(box.x + 6, box.y + 3), font: f, color: theme.textPrimary)
    }
}
