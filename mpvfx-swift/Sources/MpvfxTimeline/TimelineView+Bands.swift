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

/// A vertical slice of the track area: an audio-group header row or a track row.
public enum TimelineBand: Equatable, Sendable { case group(String), track(Int) }

/// Content-space frame of a band (add -scrollY for view coordinates).
public struct TimelineBandFrame: Equatable, Sendable {
    public var band: TimelineBand; public var top: Double; public var height: Double
    public var bottom: Double { top + height }
}

/// timelineNestedStripColor palette (edge colour), indexed by a 31-hash of the strip id.
public enum TimelineStripColor {
    public static let edges = ThemeTokens.bandEdges.map { CanvasColor($0) }
    public static func index(_ id: String) -> Int {
        var h: UInt32 = 0
        for u in id.utf16 { h = h &* 31 &+ UInt32(u) }
        return Int(h % 5)
    }
    public static func color(_ id: String) -> CanvasColor { edges[index(id)] }
}

extension TimelineView {
    typealias BL = TimelineLayout

    /// Effects strips are always shown; a keyed clip shows its lane rows (one summary row, more when expanded).
    public func effectLaneCount(track i: Int) -> Int {
        guard tracks.indices.contains(i) else { return 0 }
        return tracks[i].clips.map(\.effects.count).max() ?? 0
    }
    public func expandedLaneCount(track i: Int) -> Int {
        guard tracks.indices.contains(i) else { return 0 }
        return tracks[i].clips.map { laneRows($0).count }.max() ?? 0
    }
    public func trackRowHeight(_ i: Int) -> Double {
        trackHeight + Double(effectLaneCount(track: i)) * BL.effectStripHeight + Double(expandedLaneCount(track: i)) * BL.laneHeight
    }

    /// Bands in order: group headers sit before the track index they are anchored to.
    public var bands: [TimelineBand] {
        var out: [TimelineBand] = []
        for i in 0...tracks.count {
            for a in groupAnchors where a.beforeTrack == i { out.append(.group(a.groupId)) }
            if i < tracks.count { out.append(.track(i)) }
        }
        return out
    }

    public func bandFrames() -> [TimelineBandFrame] {
        var y = BL.rulerHeight + BL.tracksTopPad
        return bands.map { b in
            let h: Double
            switch b { case .group: h = BL.groupHeaderHeight; case .track(let i): h = trackRowHeight(i) }
            defer { y += h }
            return TimelineBandFrame(band: b, top: y, height: h)
        }
    }

    /// Band under a view-space y, with the y offset inside that band.
    public func band(atY y: Double) -> (band: TimelineBand, localY: Double)? {
        let cy = y + scrollY
        for f in bandFrames() where cy >= f.top && cy < f.bottom { return (f.band, cy - f.top) }
        return nil
    }

    /// Nearest track row for a view-space y (clamped), used while dragging across rows.
    public func trackIndex(nearY y: Double) -> Int {
        let cy = y + scrollY
        let frames = bandFrames().compactMap { f -> (Int, TimelineBandFrame)? in if case .track(let i) = f.band { return (i, f) }; return nil }
        guard let first = frames.first, let last = frames.last else { return 0 }
        if cy < first.1.top { return first.0 }
        for (i, f) in frames where cy < f.bottom { return i }
        return last.0
    }

    func groupHeaderTop(_ id: String) -> Double? {
        bandFrames().first { $0.band == .group(id) }.map { $0.top - scrollY }
    }

    // MARK: Drawing

    func drawTrackExtras(_ c: CanvasContext, track i: Int, _ clip: TimelineClipModel) {
        let r = clipRect(track: i, clip)
        let base = r.y - BL.clipY + trackHeight
        // Effect strips: edge colour, #09110E 10px bold text, padding-inline 6, ellipsis.
        let ef = CanvasFont(family: Self.uiFontFamily, size: 10, weight: .bold)
        for (k, e) in clip.effects.enumerated() {
            let sr = CanvasRect(x: r.x, y: base + Double(k) * BL.effectStripHeight, width: r.width, height: BL.effectStripHeight)
            c.fillRect(sr, TimelineStripColor.color(e.id))
            if let label = Self.ellipsize(c, e.label, font: ef, maxWidth: sr.width - 12) {
                c.drawText(label, at: .init(sr.x + 6, sr.y + 4), font: ef, color: CanvasColor(ThemeTokens.onMint))
            }
        }
        let laneTop = base + Double(effectLaneCount(track: i)) * BL.effectStripHeight
        for (j, row) in laneRows(clip).enumerated() {
            let lr = CanvasRect(x: r.x, y: laneTop + Double(j) * BL.laneHeight, width: r.width, height: BL.laneHeight)
            // The summary and kind rows sit on a slightly stronger wash than the property rows under them.
            c.fillRect(lr, CanvasColor(ThemeTokens.white.alpha(row == .summary ? 0.045 : 0.025)))
            c.fillRect(CanvasRect(x: lr.x, y: lr.maxY - 1, width: lr.width, height: 1), theme.rowBorder)
            drawMarks(c, clip, scope: rowScope(row, clip), origin: CanvasPoint(r.x, lr.y + lr.height / 2))
        }
    }

    /// The header column of a track's lane rows (for `headerClip`): the summary row's disclosure and "Keyframes",
    /// each kind row's disclosure, mark and name, each property row's spine, mark and label; then ‹ ◆ ›.
    func drawLaneHeaders(_ c: CanvasContext, track i: Int, top: Double) {
        guard let clip = headerClip(track: i) else { return }
        let rows = laneRows(clip)
        let base = top + trackHeight + Double(effectLaneCount(track: i)) * BL.effectStripHeight
        for (j, row) in rows.enumerated() {
            let y = base + Double(j) * BL.laneHeight
            c.fillRect(CanvasRect(x: 0, y: y, width: BL.labelColumnWidth, height: BL.laneHeight), theme.gutterBackground)
            drawLaneHeaderLabel(c, clip, row, y: y)
            drawLaneNavigation(c, clip, row, y: y)
        }
    }

    func drawLaneHeaderLabel(_ c: CanvasContext, _ clip: TimelineClipModel, _ row: TimelineLaneRow, y: Double) {
        let last = laneRows(clip).last == row
        let f = CanvasFont(family: Self.uiFontFamily, size: 10, weight: row == .summary ? .medium : .regular)
        let ink = CanvasColor(ThemeTokens.white.alpha(0.65)), cy = y + BL.laneHeight / 2
        var x = 22.0
        switch row {
        case .summary, .kind:
            let open = row == .summary ? expandedClips.contains(clip.id) : !(collapsedKinds[clip.id]?.contains(rowKind(row, clip) ?? .transform) ?? false)
            let d = Self.disclosureRect(laneTop: y, row: row)
            c.drawText(open ? "▾" : "▸", at: .init(d.centerX - 4, cy - 7), font: .mono(12), color: ink)
            x = d.maxX + 2
        case .property:
            c.fillRect(CanvasRect(x: 12, y: y, width: 1, height: last ? BL.laneHeight / 2 : BL.laneHeight), CanvasColor(ThemeTokens.white.alpha(0.15)))
            c.fillRect(CanvasRect(x: 12, y: cy, width: 6, height: 1), CanvasColor(ThemeTokens.white.alpha(0.15)))
        }
        if let kind = rowKind(row, clip) {
            TimelineKeyframeGlyph.draw(c, .init(kind), at: CanvasPoint(x + 5, cy), r: 4.5)
            x += 14
        }
        if let l = Self.ellipsize(c, rowLabel(row, clip), font: f, maxWidth: Self.laneControlsX - 6 - x) {
            c.drawText(l, at: .init(x, y + 9), font: f, color: ink)
        }
    }

    /// PropertyGroupNavigation: ‹ (white/55, white/15 disabled), the row's mark (filled on a key, outlined elsewhere;
    /// the summary's in the accent), ›.
    func drawLaneNavigation(_ c: CanvasContext, _ clip: TimelineClipModel, _ row: TimelineLaneRow, y: Double) {
        let nav = laneRowNavigation?(clip.id, row) ?? TimelineKeyframeNavigation()
        for (ctl, r) in Self.laneControlRects(laneTop: y) {
            switch ctl {
            case .prev, .next:
                let off = (ctl == .prev ? nav.prev : nav.next) == nil
                let gf = CanvasFont(size: 12), glyph = ctl == .prev ? "‹" : "›"
                let w = c.measureText(glyph, font: gf).width
                c.drawText(glyph, at: .init(r.centerX - w / 2, r.centerY - gf.size / 2 - 1), font: gf, color: CanvasColor(ThemeTokens.white.alpha(off ? 0.15 : 0.55)))
            case .toggle:
                let kind = rowKind(row, clip)
                let style = TimelineKeyframeGlyph.Style(shape: kind?.shape ?? .diamond, color: kind?.color ?? theme.accent)
                if nav.current == nil { TimelineKeyframeGlyph.drawOutline(c, style, at: CanvasPoint(r.centerX, r.centerY), r: 4.5) }
                else { TimelineKeyframeGlyph.draw(c, style, at: CanvasPoint(r.centerX, r.centerY), r: 4.5) }
            }
        }
    }

    /// Audio-group header (TimelineAudioGroupHeader): caret, ▤, label, member-count pill.
    func drawGroupHeader(_ c: CanvasContext, _ g: TimelineGroupModel, top: Double, width: Double) {
        let h = BL.groupHeaderHeight
        c.fillRect(CanvasRect(x: 0, y: top, width: width, height: h), theme.rowBackground)
        c.fillRect(CanvasRect(x: 0, y: top + h - 1, width: width, height: 1), theme.rowBorder)
        c.fillRect(CanvasRect(x: 0, y: top, width: BL.labelColumnWidth, height: h), theme.gutterBackground)
        c.fillRect(CanvasRect(x: BL.labelColumnWidth - 1, y: top, width: 1, height: h), theme.gutterBorder)
        c.fillRect(CanvasRect(x: 0, y: top + h - 1, width: BL.labelColumnWidth, height: 1), theme.rowBorder)
        let collapsed = collapsedGroups.contains(g.id)
        c.drawText(collapsed ? "▸" : "▾", at: .init(6 + 7, top + (h - 15) / 2), font: .mono(13),
                   color: collapsed ? CanvasColor(ThemeTokens.white.alpha(0.55)) : CanvasColor(ThemeTokens.white.alpha(1)))
        c.drawText("▤", at: .init(36, top + (h - 13) / 2), font: CanvasFont(size: 12), color: CanvasColor(ThemeTokens.white.alpha(0.5)))
        let lf = CanvasFont(family: Self.uiFontFamily, size: 11, weight: .medium)
        let lw = min(c.measureText(g.label, font: lf).width, 120)
        if let l = Self.ellipsize(c, g.label, font: lf, maxWidth: 120) {
            c.drawText(l, at: .init(54, top + (h - 12) / 2), font: lf, color: CanvasColor(ThemeTokens.white.alpha(1)))
        }
        let count = "\(g.memberTrackIds.count)"
        let pf = CanvasFont(family: Self.uiFontFamily, size: 9)
        let pw = c.measureText(count, font: pf).width + 8
        let pr = CanvasRect(x: 54 + lw + 6, y: top + (h - 14) / 2, width: max(pw, 14), height: 14)
        c.fillRoundedRect(pr, radius: 7, CanvasColor(ThemeTokens.white.alpha(0.10)))
        c.drawText(count, at: .init(pr.x + (pr.width - pw + 8) / 2, pr.y + 2), font: pf, color: CanvasColor(ThemeTokens.white.alpha(0.55)))
        // ml-auto TimelineFxButton: "FX" white/35, "FX n" mint when the group's chain has enabled nodes.
        let fr = groupFxRect(g, top: top)
        c.drawText(g.fxCount > 0 ? "FX \(g.fxCount)" : "FX", at: .init(fr.x + 4, fr.centerY - 5.5),
                   font: CanvasFont(family: Self.uiFontFamily, size: 10, weight: .semibold),
                   color: g.fxCount > 0 ? theme.accent : CanvasColor(ThemeTokens.white.alpha(0.35)))
    }

    /// The group header's FX button (h-6, right edge at px-1.5 of the label column).
    func groupFxRect(_ g: TimelineGroupModel, top: Double) -> CanvasRect {
        let w = Self.fxWidth(g.fxCount)
        return CanvasRect(x: BL.labelColumnWidth - 6 - w, y: top + (BL.groupHeaderHeight - 24) / 2, width: w, height: 24)
    }

    /// GroupNameButton (▤ + label + count): opens the group's FX rack.
    func groupNameRect(top: Double) -> CanvasRect {
        CanvasRect(x: 34, y: top + (BL.groupHeaderHeight - 24) / 2, width: 150, height: 24)
    }
}
