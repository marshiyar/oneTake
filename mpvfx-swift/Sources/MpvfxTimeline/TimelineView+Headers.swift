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

/// Compact track header (docs/DESIGN.md step 4), left to right: the track tag (`V1`, `A1`; filled in the accent when
/// targeted), the name, the clip-count pill, then right-aligned the FX entry point on audio rows, solo (audio rows),
/// the eye (or speaker on audio rows) and the lock. The fixed-width buttons share columns on every row.
public enum TimelineHeaderControl: Equatable, Sendable {
    /// The track tag: a click targets the track (TimelineTrackTargets).
    case target
    /// Locks the track against clip edits.
    case lock
    /// Eye on video rows (hide), speaker on audio rows (mute).
    case visibility
    /// Audio rows: hear only the soloed tracks.
    case solo
    /// FX chain of the track's single audio clip.
    case fx(clipId: String)
    /// Several ungrouped audio clips: FX needs a group first (group-pointer variant).
    case groupPointer
}

/// The header control under the pointer, drawn with a hover wash.
public struct TimelineHeaderHover: Equatable, Sendable {
    public var row: Int, control: TimelineHeaderControl
    public init(row: Int, control: TimelineHeaderControl) { self.row = row; self.control = control }
}

extension TimelineView {
    static let headerPadX = 6.0          // px-1.5
    /// Hit box of every header control: 24 x 24, the timeline's minimum target, which fits the 28 px row.
    static let headerButton = 24.0
    static let headerGap = 2.0
    /// The track tag: a 26 x 24 hit box around a 26 x 18 pill, wide enough for "V10".
    static let tagWidth = 26.0, tagPillHeight = 18.0
    static let groupMemberIndent = 14.0  // GROUP_MEMBER_INDENT
    static var groupMemberRail: CanvasColor { CanvasColor(ThemeTokens.mint.alpha(0x59 / 255)) }

    /// Tags of the current tracks (`V1`, `A1`, ...), in display order.
    public var trackTags: [String] { TimelineTrackTargets.tags(tracks) }
    /// Ids of the targeted tracks.
    public var targetedTrackIds: Set<String> { trackTargets.targeted(in: tracks) }

    /// Left edge of a row's header content: after the group rail and indent for a group member.
    func headerContentX(row i: Int) -> Double {
        Self.headerPadX + (tracks[i].groupId != nil ? 2 + Self.groupMemberIndent : 0)
    }

    /// Controls on a track header, left to right, with their hit boxes.
    public func headerControls(row i: Int) -> [(control: TimelineHeaderControl, rect: CanvasRect)] {
        guard tracks.indices.contains(i) else { return [] }
        let y = rowTop(i) + (trackHeight - Self.headerButton) / 2
        let tag = CanvasRect(x: headerContentX(row: i), y: y, width: Self.tagWidth, height: Self.headerButton)
        var x = TimelineLayout.labelColumnWidth - Self.headerPadX
        var right: [(control: TimelineHeaderControl, rect: CanvasRect)] = []
        for (control, w) in rightHeaderItems(row: i).reversed() {
            x -= w
            right.insert((control, CanvasRect(x: x, y: y, width: w, height: Self.headerButton)), at: 0)
            x -= Self.headerGap
        }
        return [(control: .target, rect: tag)] + right
    }

    /// The right-aligned controls of a row, left to right, with their widths.
    func rightHeaderItems(row i: Int) -> [(TimelineHeaderControl, Double)] {
        let track = tracks[i], audioTrack = track.kind == "audio"
        let audioClips = track.clips.filter { $0.kind == .audio }
        var items: [(TimelineHeaderControl, Double)] = []
        if audioClips.count == 1, track.clips.count == 1 {
            items.append((.fx(clipId: audioClips[0].id), Self.fxWidth(audioClips[0].fxCount)))
        } else if track.clips.count > 1 && track.groupId == nil && audioTrack {
            items.append((.groupPointer, Self.fxWidth(0)))
        }
        if audioTrack { items.append((.solo, Self.headerButton)) }
        // The eye / speaker keeps its column on an empty track (nothing is drawn), so the lock column stays aligned.
        items.append((.visibility, Self.headerButton))
        items.append((.lock, Self.headerButton))
        return items
    }

    static func fxWidth(_ count: Int) -> Double { count > 0 ? 30 : 20 }   // px-1 + "FX" / "FX n" at 10px semibold

    public func headerControl(atX x: Double, y: Double, row: Int) -> TimelineHeaderControl? {
        headerControls(row: row).first { x >= $0.rect.x && x <= $0.rect.maxX && y >= $0.rect.y && y <= $0.rect.maxY }
            .flatMap { c in c.control == .visibility && tracks[row].clips.isEmpty ? nil : c.control }
    }

    func drawTrackHeader(_ c: CanvasContext, track i: Int, top: Double) {
        // Group member: 2px accent rail (#3CE6AC59) flush with the gutter edge, content inset 14px.
        if tracks[i].groupId != nil {
            c.fillRect(CanvasRect(x: 0, y: top, width: 2, height: trackRowHeight(i)), Self.groupMemberRail)
        }
        let controls = headerControls(row: i)
        for (control, r) in controls {
            if hoveredHeader == TimelineHeaderHover(row: i, control: control), headerControl(atX: r.centerX, y: r.centerY, row: i) != nil {
                c.fillRoundedRect(r, radius: 4, CanvasColor(ThemeTokens.trackControlHoverPair.now))
            }
            drawHeaderControl(c, control, in: r, row: i)
        }
        let nameX = (controls.first?.rect.maxX ?? headerContentX(row: i)) + 6
        let nameEnd = controls.dropFirst().first?.rect.x ?? TimelineLayout.labelColumnWidth
        drawHeaderName(c, row: i, x: nameX, maxX: nameEnd - 4)
    }

    /// Name (first clip's label, else "Track N") and, from two clips, the clip-count pill after it.
    func drawHeaderName(_ c: CanvasContext, row i: Int, x: Double, maxX: Double) {
        let track = tracks[i], midY = rowTop(i) + trackHeight / 2
        let nameFont = CanvasFont(family: Self.uiFontFamily, size: 11)
        let countW: Double = track.clips.count >= 2 ? Self.countPillWidth(track.clips.count) + 4 : 0
        var x = x
        if let name = Self.ellipsize(c, track.name, font: nameFont, maxWidth: max(0, maxX - x - countW)) {
            c.drawText(name, at: .init(x, midY - 6), font: nameFont, color: theme.textSecondary)
            x += c.measureText(name, font: nameFont).width + 4
        }
        // TrackClipCount: shown from two clips; rounded-full bg-white/10 px-1, 9px, 14px tall.
        guard track.clips.count >= 2 else { return }
        let label = "\(track.clips.count)", w = Self.countPillWidth(track.clips.count)
        let r = CanvasRect(x: x, y: midY - 7, width: w, height: 14)
        c.fillRoundedRect(r, radius: 7, CanvasColor(ThemeTokens.white.alpha(0.10)))
        c.drawText(label, at: .init(r.x + 4, r.y + 2.5), font: CanvasFont(family: Self.uiFontFamily, size: 9), color: theme.textSecondary)
    }

    /// One header control in its hit box. A control that is on is drawn in the accent and changes shape too
    /// (filled lock and headphones, slashed eye, crossed speaker, filled tag), so the state never rests on colour alone.
    func drawHeaderControl(_ c: CanvasContext, _ control: TimelineHeaderControl, in r: CanvasRect, row i: Int) {
        let track = tracks[i], o = CanvasPoint(r.centerX, r.centerY)
        let idle = CanvasColor(ThemeTokens.trackControlIdlePair.now)
        let fxFont = CanvasFont(family: Self.uiFontFamily, size: 10, weight: .semibold)
        switch control {
        case .target:
            drawTrackTag(c, row: i, in: r)
        case .lock:
            Self.drawLock(c, center: o, locked: track.locked, color: track.locked ? theme.accent : idle)
        case .visibility:
            guard !track.clips.isEmpty else { return }
            let audio = track.kind == "audio", on = audio ? track.muted : track.hidden
            if audio { Self.drawSpeaker(c, center: o, muted: on, color: on ? theme.accent : idle) }
            else { Self.drawEye(c, center: o, slashed: on, color: on ? theme.accent : idle) }
        case .solo:
            Self.drawHeadphones(c, center: o, filled: track.soloed, color: track.soloed ? theme.accent : idle)
        case .fx(let id):
            let n = track.clips.first { $0.id == id }?.fxCount ?? 0
            c.drawText(n > 0 ? "FX \(n)" : "FX", at: .init(r.x + 4, r.centerY - 5.5), font: fxFont, color: n > 0 ? theme.accent : idle)
        case .groupPointer:
            c.drawText("FX", at: .init(r.x + 4, r.centerY - 5.5), font: fxFont, color: idle)
        }
    }

    /// The track tag: an accent pill with `onAccentMint` text when targeted, else a 1 px outline.
    func drawTrackTag(_ c: CanvasContext, row i: Int, in r: CanvasRect) {
        let tags = trackTags
        guard tags.indices.contains(i) else { return }
        let pill = CanvasRect(x: r.x, y: r.centerY - Self.tagPillHeight / 2, width: r.width, height: Self.tagPillHeight)
        let targeted = targetedTrackIds.contains(tracks[i].id)
        if targeted { c.fillRoundedRect(pill, radius: 3, theme.accent) }
        else { c.strokeRoundedRect(pill.insetBy(0.5), radius: 3, CanvasColor(ThemeTokens.trackTagOutlinePair.now)) }
        let font = CanvasFont(family: Self.uiFontFamily, size: 10, weight: .semibold)
        let w = c.measureText(tags[i], font: font).width
        c.drawText(tags[i], at: .init(pill.centerX - w / 2, pill.centerY - 6), font: font,
                   color: CanvasColor(targeted ? ThemeTokens.onAccentMintPair.now : ThemeTokens.trackTagTextPair.now))
    }

    static func countPillWidth(_ n: Int) -> Double { 8 + 5.5 * Double(String(n).count) }

    // MARK: Glyphs (Phosphor Eye / EyeSlash / SpeakerHigh / SpeakerSlash / Lock / Headphones, drawn as paths)

    static func drawLock(_ c: CanvasContext, center o: CanvasPoint, locked: Bool, color: CanvasColor) {
        let body = CanvasRect(x: o.x - 5, y: o.y - 1, width: 10, height: 7.5)
        if locked { c.fillRoundedRect(body, radius: 1.5, color) }
        else { c.strokeRoundedRect(body, radius: 1.5, color, width: 1.4) }
        // Shackle: closed over the body when locked, swung open (right leg lifted) when not.
        var s = CanvasPath()
        s.move(to: .init(o.x - 3, o.y - 1)); s.line(to: .init(o.x - 3, o.y - 3.5))
        s.curve(to: .init(o.x + 3, o.y - 3.5), c1: .init(o.x - 3, o.y - 7.5), c2: .init(o.x + 3, o.y - 7.5))
        s.line(to: .init(o.x + 3, locked ? o.y - 1 : o.y - 3))
        c.stroke(s, color, StrokeStyle(width: 1.4))
    }

    static func drawHeadphones(_ c: CanvasContext, center o: CanvasPoint, filled: Bool, color: CanvasColor) {
        var band = CanvasPath()
        band.move(to: .init(o.x - 5.5, o.y + 2)); band.line(to: .init(o.x - 5.5, o.y))
        band.curve(to: .init(o.x + 5.5, o.y), c1: .init(o.x - 5.5, o.y - 7.5), c2: .init(o.x + 5.5, o.y - 7.5))
        band.line(to: .init(o.x + 5.5, o.y + 2))
        c.stroke(band, color, StrokeStyle(width: 1.4))
        for cup in [CanvasRect(x: o.x - 6.5, y: o.y + 0.5, width: 3.5, height: 5.5), CanvasRect(x: o.x + 3, y: o.y + 0.5, width: 3.5, height: 5.5)] {
            if filled { c.fillRoundedRect(cup, radius: 1.2, color) }
            else { c.strokeRoundedRect(cup.insetBy(0.35), radius: 1.2, color, width: 1.2) }
        }
    }

    static func drawEye(_ c: CanvasContext, center o: CanvasPoint, slashed: Bool, color: CanvasColor) {
        var p = CanvasPath()
        p.move(to: .init(o.x - 6.5, o.y))
        p.curve(to: .init(o.x + 6.5, o.y), c1: .init(o.x - 3.5, o.y - 5), c2: .init(o.x + 3.5, o.y - 5))
        p.curve(to: .init(o.x - 6.5, o.y), c1: .init(o.x + 3.5, o.y + 5), c2: .init(o.x - 3.5, o.y + 5))
        p.close()
        c.stroke(p, color, StrokeStyle(width: 1.5))
        c.stroke(ellipse(CanvasRect(x: o.x - 2.2, y: o.y - 2.2, width: 4.4, height: 4.4)), color, StrokeStyle(width: 1.5))
        if slashed {
            var s = CanvasPath(); s.move(to: .init(o.x - 5.5, o.y - 5.5)); s.line(to: .init(o.x + 5.5, o.y + 5.5))
            c.stroke(s, color, StrokeStyle(width: 1.5))
        }
    }

    static func drawSpeaker(_ c: CanvasContext, center o: CanvasPoint, muted: Bool, color: CanvasColor) {
        var p = CanvasPath()
        p.move(to: .init(o.x - 6, o.y - 2)); p.line(to: .init(o.x - 3.5, o.y - 2)); p.line(to: .init(o.x + 0.5, o.y - 5.5))
        p.line(to: .init(o.x + 0.5, o.y + 5.5)); p.line(to: .init(o.x - 3.5, o.y + 2)); p.line(to: .init(o.x - 6, o.y + 2)); p.close()
        c.stroke(p, color, StrokeStyle(width: 1.4))
        var w = CanvasPath()
        if muted {
            w.move(to: .init(o.x + 2.5, o.y - 2.5)); w.line(to: .init(o.x + 7, o.y + 2.5))
            w.move(to: .init(o.x + 7, o.y - 2.5)); w.line(to: .init(o.x + 2.5, o.y + 2.5))
        } else {
            w.move(to: .init(o.x + 3, o.y - 2.5)); w.curve(to: .init(o.x + 3, o.y + 2.5), c1: .init(o.x + 4.6, o.y - 1.2), c2: .init(o.x + 4.6, o.y + 1.2))
            w.move(to: .init(o.x + 5, o.y - 5)); w.curve(to: .init(o.x + 5, o.y + 5), c1: .init(o.x + 8.2, o.y - 2.4), c2: .init(o.x + 8.2, o.y + 2.4))
        }
        c.stroke(w, color, StrokeStyle(width: 1.4))
    }

    static func ellipse(_ r: CanvasRect) -> CanvasPath {
        let k = 0.5522847498, cx = r.centerX, cy = r.centerY, rx = r.width / 2, ry = r.height / 2
        var p = CanvasPath()
        p.move(to: .init(cx + rx, cy))
        p.curve(to: .init(cx, cy + ry), c1: .init(cx + rx, cy + k * ry), c2: .init(cx + k * rx, cy + ry))
        p.curve(to: .init(cx - rx, cy), c1: .init(cx - k * rx, cy + ry), c2: .init(cx - rx, cy + k * ry))
        p.curve(to: .init(cx, cy - ry), c1: .init(cx - rx, cy - k * ry), c2: .init(cx - k * rx, cy - ry))
        p.curve(to: .init(cx + rx, cy), c1: .init(cx + k * rx, cy - ry), c2: .init(cx + rx, cy - k * ry))
        p.close()
        return p
    }
}

extension CanvasRect {
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
}
