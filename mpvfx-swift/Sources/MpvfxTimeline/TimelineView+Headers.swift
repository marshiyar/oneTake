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

/// Track header row (TimelineTrackHeader / PlainTrackHeader / TrackClipCount / VisibilityButton /
/// TimelineFxButton): audio glyph, name, clip-count pill, then right-aligned eye (or speaker on audio
/// rows) and the FX entry point.
public enum TimelineHeaderControl: Equatable, Sendable {
    /// Eye on video rows (hide), speaker on audio rows (mute).
    case visibility
    /// FX chain of the track's single audio clip.
    case fx(clipId: String)
    /// Several ungrouped audio clips: FX needs a group first (group-pointer variant).
    case groupPointer
}

extension TimelineView {
    static let headerPadX = 6.0          // px-1.5
    static let headerButton = 24.0       // h-6 w-6
    static let headerGap = 4.0           // gap-1
    static let groupMemberIndent = 14.0  // GROUP_MEMBER_INDENT
    static var groupMemberRail: CanvasColor { CanvasColor(ThemeTokens.mint.alpha(0x59 / 255)) }

    /// Controls on a track header, left to right, with their hit boxes.
    public func headerControls(row i: Int) -> [(control: TimelineHeaderControl, rect: CanvasRect)] {
        guard tracks.indices.contains(i) else { return [] }
        let track = tracks[i], top = rowTop(i)
        let audioClips = track.clips.filter { $0.kind == .audio }
        let audioTrack = track.kind == "audio"
        var items: [(TimelineHeaderControl, Double)] = []
        // VisibilityButton keeps a spacer when the track is empty, so control columns stay aligned.
        items.append((.visibility, Self.headerButton))
        if audioClips.count == 1, track.clips.count == 1 {
            items.append((.fx(clipId: audioClips[0].id), Self.fxWidth(audioClips[0].fxCount)))
        } else if track.clips.count > 1 && track.groupId == nil && audioTrack {
            items.append((.groupPointer, Self.fxWidth(0)))
        }
        var x = TimelineLayout.labelColumnWidth - Self.headerPadX
        var out: [(TimelineHeaderControl, CanvasRect)] = []
        for (control, w) in items.reversed() {
            x -= w
            out.insert((control, CanvasRect(x: x, y: top + (trackHeight - Self.headerButton) / 2, width: w, height: Self.headerButton)), at: 0)
            x -= Self.headerGap
        }
        return out
    }

    static func fxWidth(_ count: Int) -> Double { count > 0 ? 30 : 20 }   // px-1 + "FX" / "FX n" at 10px semibold

    public func headerControl(atX x: Double, y: Double, row: Int) -> TimelineHeaderControl? {
        headerControls(row: row).first { x >= $0.rect.x && x <= $0.rect.maxX && y >= $0.rect.y && y <= $0.rect.maxY }
            .flatMap { c in c.control == .visibility && tracks[row].clips.isEmpty ? nil : c.control }
    }

    func drawTrackHeader(_ c: CanvasContext, track i: Int, top: Double) {
        let track = tracks[i], h = trackHeight
        let audio = track.kind == "audio"
        var x = Self.headerPadX
        let midY = top + h / 2
        // Group member: 2px accent rail (#3CE6AC59) flush with the gutter edge, content inset 14px.
        if track.groupId != nil {
            c.fillRect(CanvasRect(x: 0, y: top, width: 2, height: trackRowHeight(i)), Self.groupMemberRail)
            x += 2 + Self.groupMemberIndent
        }
        let dim = CanvasColor(ThemeTokens.white.alpha(0.35))
        if audio { Self.drawMusicGlyph(c, x: x, midY: midY, color: dim); x += 12 + 4 }
        // Name: first clip's label, else "Track N" (TimelineLanes trackLabel), text-[11px] white/55.
        let controls = headerControls(row: i)
        let nameFont = CanvasFont(family: Self.uiFontFamily, size: 11)
        let countW: Double = track.clips.count >= 2 ? Self.countPillWidth(track.clips.count) + 4 : 0
        let maxName = (controls.first?.rect.x ?? TimelineLayout.labelColumnWidth) - 4 - x - countW
        if let name = Self.ellipsize(c, track.name, font: nameFont, maxWidth: max(0, maxName)) {
            c.drawText(name, at: .init(x, midY - 6), font: nameFont, color: CanvasColor(ThemeTokens.white.alpha(0.55)))
            x += c.measureText(name, font: nameFont).width + 4
        }
        // TrackClipCount: shown from two clips; rounded-full bg-white/10 px-1, 9px white/55, 14px tall.
        if track.clips.count >= 2 {
            let label = "\(track.clips.count)", w = Self.countPillWidth(track.clips.count)
            let r = CanvasRect(x: x, y: midY - 7, width: w, height: 14)
            c.fillRoundedRect(r, radius: 7, CanvasColor(ThemeTokens.white.alpha(0.10)))
            c.drawText(label, at: .init(r.x + 4, r.y + 2.5), font: CanvasFont(family: Self.uiFontFamily, size: 9), color: CanvasColor(ThemeTokens.white.alpha(0.55)))
        }
        for (control, r) in controls {
            switch control {
            case .visibility:
                guard !track.clips.isEmpty else { continue }
                // hidden: #3CE6AC; shown: white/35.
                let on = audio ? track.muted : track.hidden
                let color = on ? theme.accent : dim
                if audio { Self.drawSpeaker(c, center: .init(r.centerX, r.centerY), muted: on, color: color) }
                else { Self.drawEye(c, center: .init(r.centerX, r.centerY), slashed: on, color: color) }
            case .fx(let id):
                let n = track.clips.first { $0.id == id }?.fxCount ?? 0
                let text = n > 0 ? "FX \(n)" : "FX"
                c.drawText(text, at: .init(r.x + 4, r.centerY - 5.5), font: CanvasFont(family: Self.uiFontFamily, size: 10, weight: .semibold),
                           color: n > 0 ? theme.accent : dim)
            case .groupPointer:
                c.drawText("FX", at: .init(r.x + 4, r.centerY - 5.5), font: CanvasFont(family: Self.uiFontFamily, size: 10, weight: .semibold), color: dim)
            }
        }
    }

    static func countPillWidth(_ n: Int) -> Double { 8 + 5.5 * Double(String(n).count) }

    // MARK: Glyphs (Phosphor Music / Eye / EyeSlash / SpeakerHigh / SpeakerSlash, drawn as paths)

    static func drawMusicGlyph(_ c: CanvasContext, x: Double, midY: Double, color: CanvasColor) {
        var p = CanvasPath()
        p.addRect(CanvasRect(x: x + 3.5, y: midY - 5, width: 1.4, height: 8))
        p.addRect(CanvasRect(x: x + 9.6, y: midY - 6, width: 1.4, height: 8))
        p.move(to: .init(x + 3.5, midY - 5)); p.line(to: .init(x + 11, midY - 7)); p.line(to: .init(x + 11, midY - 5.3)); p.line(to: .init(x + 3.5, midY - 3.3)); p.close()
        c.fill(p, color)
        c.fill(ellipse(CanvasRect(x: x + 1, y: midY + 1.6, width: 4, height: 3)), color)
        c.fill(ellipse(CanvasRect(x: x + 7.1, y: midY + 0.6, width: 4, height: 3)), color)
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
