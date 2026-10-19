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

/// Timeline layout constants. The media row height is the one
/// value the user changes (toolbar Track height slider, timelineTrackHeight), so it is instance
/// state; everything else is fixed.
public struct TimelineLayout: Equatable, Sendable {
    /// Media row height: 32...96 in steps of 8 on the slider, stored rounded and clamped (setTimelineTrackHeight).
    public var trackHeight: Double { didSet { trackHeight = Self.clampTrackHeight(trackHeight) } }
    public init(trackHeight: Double = defaultTrackHeight) { self.trackHeight = Self.clampTrackHeight(trackHeight) }
    /// TRACK_H: default media row height and the fixed height of an audio-group header row.
    public static let defaultTrackHeight = 48.0, groupHeaderHeight = 48.0
    public static let minTrackHeight = 32.0, maxTrackHeight = 96.0, trackHeightStep = 8.0
    public static func clampTrackHeight(_ h: Double) -> Double {
        guard h.isFinite else { return defaultTrackHeight }
        return max(minTrackHeight, min(maxTrackHeight, (h + 0.5).rounded(.down)))
    }
    public static let gutter = 32.0, labelColumnWidth = 232.0, rulerHeight = 24.0
    public static let clipY = 3.0, tracksTopPad = 16.0, tracksBottomPad = 12.0, playheadHeadWidth = 9.0
    public static let playheadHeadHeight = 9.0
    public static let laneHeight = 28.0, effectStripHeight = 18.0, clipHandleWidth = 14.0
    /// contentOrigin = LABEL_COL_W + GUTTER.
    public static let contentOrigin = labelColumnWidth + gutter
    /// getTimelineRowTop: ruler + top pad + cumulative row heights (collapsed media rows only).
    public static func rowTop(_ index: Int) -> Double { rulerHeight + tracksTopPad + Double(index) * defaultTrackHeight }
    /// getTimelinePlayheadLeft: line centre on contentOrigin + t*pps.
    public static func playheadLeft(time: Double, pps: Double, contentOrigin: Double = contentOrigin) -> Double {
        guard time.isFinite, pps.isFinite else { return contentOrigin - playheadHeadWidth / 2 }
        return contentOrigin + max(0, time) * max(0, pps) - playheadHeadWidth / 2
    }
}

/// defaultTimelineTheme.
public struct TimelineTheme: Sendable {
    // Colours follow `Theme.mode` (ThemeTokens): dark is the studio timeline theme, light the derived palette.
    // `ink` is white in dark mode and near-black in light, so the white/alpha washes keep their weight.
    private var ink: CanvasColor { CanvasColor(ThemeTokens.white) }
    public var shellBackground: CanvasColor { CanvasColor(ThemeTokens.timelineSurface) }
    public var rowBackground: CanvasColor { CanvasColor(ThemeTokens.timelineRowPair.now) }
    public var rowBorder: CanvasColor { ink.withAlpha(0.06) }
    public var gutterBackground: CanvasColor { CanvasColor(ThemeTokens.timelineGutterPair.now) }
    public var gutterBorder: CanvasColor { ink.withAlpha(0.10) }
    public var textPrimary: CanvasColor { ink.withAlpha(0.92) }
    public var textSecondary: CanvasColor { ink.withAlpha(Theme.mode == .light ? 0.68 : 0.62) }
    public var tickText: CanvasColor { ink.withAlpha(Theme.mode == .light ? 0.45 : 0.34) }
    public var tickMajor: CanvasColor { ink.withAlpha(0.10) }
    public var tickMinor: CanvasColor { ink.withAlpha(0.06) }
    public var clip: CanvasColor { CanvasColor(ThemeTokens.clipVideoPair.now) }
    public var clipActive: CanvasColor { accent.withAlpha(0.16) }      // TRACK_STYLE.clipActive
    public var trackLabel: CanvasColor { ink.withAlpha(Theme.mode == .light ? 0.6 : 0.5) }   // TRACK_STYLE.label
    public var accent: CanvasColor { CanvasColor(ThemeTokens.mint) }   // the accent's line form
    public var preRoll: CanvasColor { CanvasColor(ThemeTokens.preRoll) }   // preRollBackground
    public var clipRadius = 3.0
    public init() {}
    public static let `default` = TimelineTheme()
}

/// Ruler tick math.
public enum TimelineRuler {
    static let zoomIntervals: [Double] = [0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    public static func majorInterval(duration: Double, pps: Double?, frameRate: Double? = nil) -> Double {
        var interval: Double
        if let pps, pps.isFinite, pps > 0 {
            interval = zoomIntervals.first { $0 * pps >= 88 } ?? 3600
        } else {
            interval = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60].first { $0 >= duration / 6 } ?? 60
        }
        if let fps = frameRate, fps.isFinite, fps > 0 { return max(1, (interval * fps - 1e-6).rounded(.up)) / fps }
        return interval
    }

    /// getMinorSubdivisions
    public static func minorSubdivisions(major: Double, pps: Double, frameRate: Double? = nil) -> Int {
        guard pps.isFinite, pps > 0 else { return 4 }
        let fps = frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let majorFrames = fps > 0 ? Int((major * fps).rounded()) : 0
        for parts in (fps > 0 ? [4, 5, 3, 2] : [4, 2]) {
            if fps > 0 && majorFrames % parts != 0 { continue }
            if (major / Double(parts)) * pps >= 8 { return parts }
        }
        return 0
    }

    public static func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let m = Int((t / 60).rounded(.down)), s = Int(t.truncatingRemainder(dividingBy: 60).rounded(.down))
        return String(format: "%02d:%02d", m, s)
    }

    public static func label(_ time: Double, duration: Double, major: Double) -> String {
        guard time.isFinite else { return "00:00" }
        let t = max(0, time)
        if major < 0.1 {
            let h = Int((t * 100).rounded()); return "\(formatTime(Double(h / 100))).\(String(format: "%02d", h % 100))"
        }
        if major < 1 {
            let h = Int((t * 10).rounded()); return "\(formatTime(Double(h / 10))).\(h % 10)"
        }
        if duration >= 3600 || t >= 3600 {
            let s = Int(t); return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return formatTime(t)
    }
}

/// One expanded property lane (a property group, e.g. Position), keyframe times clip-local seconds.
public struct TimelineLaneModel: Sendable, Equatable {
    public var group: String; public var label: String; public var keyframes: [Double]
    public init(group: String, label: String, keyframes: [Double]) { self.group = group; self.label = label; self.keyframes = keyframes }
}
/// A permanently visible effect strip under the media bar (timelineAttachedEffects).
public struct TimelineEffectModel: Sendable, Equatable {
    public var id: String; public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}
/// An audio group (bus) and its member tracks, positioned before its first member.
public struct TimelineGroupModel: Sendable, Equatable {
    public var id: String; public var label: String; public var memberTrackIds: [String]
    /// Enabled nodes in the group's own FX chain (the header's "FX n").
    public var fxCount = 0
    public init(id: String, label: String, memberTrackIds: [String], fxCount: Int = 0) {
        self.id = id; self.label = label; self.memberTrackIds = memberTrackIds; self.fxCount = fxCount
    }
}

public struct TimelineClipModel: Sendable, Equatable {
    public var id: String; public var name: String; public var start: Double; public var duration: Double
    public var kind: TimelineClipKind; public var keyframes: [Double]; public var effectCount: Int
    public var lanes: [TimelineLaneModel] = []
    /// Keyframed parameter tracks (clip-local frames), the source of the clip-bar and lane diamonds.
    public var channels: [TimelineKeyframeChannel] = []
    public var effects: [TimelineEffectModel] = []
    public var muted = false
    /// Asset this clip plays and the slice of it in use (0...1 of the source), for waveform windowing.
    public var assetId: String?
    public var sourceStartFraction = 0.0, sourceEndFraction = 1.0
    /// Clip hidden with the eye toggle (still on the timeline, out of the stage).
    public var hidden = false
    public var audioDetachedFrom: String?
    public var canDetachAudio = false
    /// False on a video whose sound is detached (TimelineOverlays muteAvailable: its linked audio clip carries the mute).
    public var canMute = true
    /// Enabled nodes in the clip's audio FX chain (TimelineFxButton nodeCount: enabledAudioFxNodes).
    public var fxCount = 0
    public var end: Double { start + duration }
    public init(id: String? = nil, name: String, start: Double, duration: Double, kind: TimelineClipKind = .video,
                keyframes: [Double] = [], effectCount: Int = 0) {
        self.id = id ?? name; self.name = name; self.start = start; self.duration = duration
        self.kind = kind; self.keyframes = keyframes; self.effectCount = effectCount
    }
}
public struct TimelineTrackModel: Sendable, Equatable {
    public var id: String; public var name: String; public var kind: String; public var clips: [TimelineClipModel]
    public var groupId: String?
    /// Track header state mirrored from the document (TimelineEditor+Tracks).
    public var hidden = false, locked = false, muted = false
    public init(id: String? = nil, name: String, kind: String = "video", clips: [TimelineClipModel]) {
        self.id = id ?? name; self.name = name; self.kind = kind; self.clips = clips
    }
}
/// Filmstrip frames for one asset: tiles of `aspect` (w/h) repeat across the clip (urls[index % count]).
public struct TimelineThumbnailStrip: Equatable, Sendable {
    public var frames: [CanvasImage]; public var aspect: Double
    public init(frames: [CanvasImage], aspect: Double) { self.frames = frames; self.aspect = aspect }
}

public struct TimelineBeat: Sendable, Equatable { public var time: Double; public var strength: Double?
    public init(time: Double, strength: Double? = nil) { self.time = time; self.strength = strength } }
public enum TimelineTimeDisplay: Sendable { case time, frame }

/// Live gesture preview, drawn on top of the committed document state.
public enum TimelineDragPreview: Equatable, Sendable {
    case move(clipIds: [String], deltaSeconds: Double, trackDelta: Int, snapTime: Double?)
    case trim(clipId: String, edge: TrimEdge, time: Double, snapTime: Double?)
}
public enum TrimEdge: Sendable, Equatable { case start, end }

/// Custom-drawn timeline (lanes, ruler, canvas, clips, playhead).
public final class TimelineView {
    public var tracks: [TimelineTrackModel]
    public var duration: Double
    public var pixelsPerSecond: Double
    public var currentTime: Double
    public var selection: Set<String> = []
    /// Selected keyframes (one clip at a time), the hovered diamond and a live retime preview.
    public var selectedKeyframes: Set<TimelineKeyframeRef> = []
    public var hoveredKeyframe: TimelineKeyframeHit?
    public var keyframeDrag: TimelineKeyframeDragPreview?
    /// Playhead time a keyframe retime is snapped to (the accent snap guide).
    public var keyframeSnapTime: Double?
    public var hoveredClip: String?
    public var drag: TimelineDragPreview?
    /// Where a live clip move lands (placeholder slot or new-track line); `dragLiftY` is the pointer's vertical travel,
    /// so the dragged clips follow the pointer between rows (TimelineCanvas drag actor).
    public var dropTarget: TimelineDropTarget?
    /// Swap preview: the clips the drop displaces and where they land (a second slot, or a new-track line).
    public var displacedDrop: (clipIds: [String], target: TimelineDropTarget)?
    public var dragLiftY = 0.0
    public var beats: [TimelineBeat] = []
    public var timeDisplay: TimelineTimeDisplay = .time
    public var frameRate = 30.0
    public var scrubbing = false
    public var scrollX = 0.0, scrollY = 0.0
    public var theme = TimelineTheme.default
    /// Clips whose property lanes are expanded (U / auto-expand).
    public var expandedClips: Set<String> = []
    public var groups: [TimelineGroupModel] = []
    public var collapsedGroups: Set<String> = []
    /// Where each group header sits: before visible track index `beforeTrack`.
    public var groupAnchors: [(groupId: String, beforeTrack: Int)] = []
    /// Lane header ‹ ◆ › state for (clip id, lane index); the controller supplies it from the document.
    public var laneNavigation: ((String, Int) -> TimelineKeyframeNavigation)?
    /// Instance layout (media row height).
    public var layout = TimelineLayout()
    public var trackHeight: Double {
        get { layout.trackHeight }
        set { layout.trackHeight = newValue }
    }

    public init(tracks: [TimelineTrackModel], duration: Double, pixelsPerSecond: Double = 100, currentTime: Double = 0) {
        self.tracks = tracks; self.duration = duration; self.pixelsPerSecond = pixelsPerSecond; self.currentTime = currentTime
    }

    /// Kept for the first-slice API/tests.
    public var selectedClip: (track: Int, clip: Int)? {
        get { for (i, t) in tracks.enumerated() { if let j = t.clips.firstIndex(where: { selection.contains($0.id) }) { return (i, j) } }; return nil }
        set { selection = newValue.map { [tracks[$0.track].clips[$0.clip].id] } ?? [] }
    }

    /// Left edge of a 1px vertical line centred on `centre`, snapped to a whole pixel the way
    /// Chromium snaps `left: x - 0.5; width: 1px` boxes (round half up), so the line is one
    /// crisp opaque pixel instead of two 50% antialiased ones.
    public static func snappedLineLeft(centre: Double) -> Double { (centre - 0.5).rounded(.toNearestOrAwayFromZero) }

    public func x(for time: Double) -> Double { TimelineLayout.contentOrigin + time * pixelsPerSecond - scrollX }
    public func time(forX x: Double) -> Double { (x + scrollX - TimelineLayout.contentOrigin) / max(pixelsPerSecond, 1e-9) }
    public func rowTop(_ i: Int) -> Double {
        if let f = bandFrames().first(where: { $0.band == .track(i) }) { return f.top - scrollY }
        return (bandFrames().last?.bottom ?? TimelineLayout.rowTop(0)) - scrollY
    }
    public var contentHeight: Double { (bandFrames().last?.bottom ?? TimelineLayout.rowTop(0)) + TimelineLayout.tracksBottomPad }

    /// getClipHandleOpacity
    public static func handleOpacity(hovered: Bool, selected: Bool, dragging: Bool) -> Double {
        dragging ? 0.95 : selected ? 0.82 : hovered ? 0.76 : 0
    }
    /// timelineTrackOriginGapColor
    public static func originGapColor(_ clips: [TimelineClipModel], theme: TimelineTheme) -> CanvasColor? {
        if clips.contains(where: { $0.kind == .video }) { return theme.preRoll }
        if clips.contains(where: { $0.kind == .image }) { return CanvasColor(ThemeTokens.blue500) }
        if clips.contains(where: { $0.kind == .audio }) { return CanvasColor(ThemeTokens.purple500) }
        return nil
    }

    /// Clip rect in view coordinates, including any live move/trim preview.
    public func clipRect(track i: Int, _ clip: TimelineClipModel, preview: Bool = true) -> CanvasRect {
        var start = clip.start, end = clip.end, row = i
        if preview, let drag {
            switch drag {
            case let .move(ids, d, td, _) where ids.contains(clip.id):
                start += d; end += d
                if dropTarget == nil { row = max(0, min(tracks.count - 1, i + td)) }
            case let .trim(id, .start, t, _) where id == clip.id: start = t
            case let .trim(id, .end, t, _) where id == clip.id: end = t
            default: break
            }
        }
        let lift = preview && dropTarget != nil && isMoving(clip.id) ? dragLiftY : 0
        return CanvasRect(x: x(for: start), y: rowTop(row) + TimelineLayout.clipY + lift,
                          width: max(1, (end - start) * pixelsPerSecond), height: trackHeight - 2 * TimelineLayout.clipY)
    }

    // MARK: Overlays (razor guide, marquee, gap strips, gap menu)
    public var razorGuideX: Double?
    public var marquee: CanvasRect?
    public var snapType: TimelineSnapType?
    /// Gap strips to highlight (hovered gap-menu action): row + [start, end) seconds.
    public var gapHighlight: [(row: Int, start: Double, end: Double)] = []
    public var gapMenu: GapMenu?
    public var clipMenu: TimelineClipMenu?
    public var keyframeMenu: TimelineKeyframeMenu?
    /// thumbnailMode: "adaptive" (true, the default) draws filmstrips on video/image clips; "hidden" leaves
    /// plain bars. Audio clips always show their waveform. Toggled from the clip menu.
    public var thumbnailsEnabled = true
    /// Normalized (0...1) waveform peaks per asset id, covering the whole source (AudioWaveform).
    public var waveforms: [String: [Double]] = [:]
    /// Decoded frames per asset id for filmstrips (VideoThumbnail / ImageThumbnail).
    public var thumbnails: [String: TimelineThumbnailStrip] = [:]

    public struct GapMenu: Equatable {
        public static let width = 200.0, height = 68.0, itemHeight = 30.0
        public var x: Double, y: Double, row: Int, time: Double
        public var gapWidth: Double?
        public var canCloseGap: Bool, canCloseAll: Bool, hasAnyGaps: Bool
        public var hovered: Int?
        /// Menu box: py-1 + two 30px rows (px-3 py-1.5 text-xs) + 1px border; min-w 180, laid out at 200.
        public var rect: CanvasRect { CanvasRect(x: x, y: y, width: Self.width, height: Self.height) }
        public func item(atX px: Double, y py: Double) -> Int? {
            guard px >= x, px <= x + Self.width else { return nil }
            let i = Int(((py - y - 4) / Self.itemHeight).rounded(.down))
            return (0...1).contains(i) ? i : nil
        }
    }

    func drawOverlays(_ c: CanvasContext, size: CanvasSize) {
        typealias L = TimelineLayout
        let body = CanvasRect(x: L.contentOrigin, y: L.rulerHeight, width: max(0, size.width - L.contentOrigin), height: size.height - L.rulerHeight)
        c.withState {
            c.clip(body)
            // Gap strips: rgba(60,230,172,0.18) (hover), radius 4, min width 2.
            for g in gapHighlight {
                let r = CanvasRect(x: x(for: g.start), y: rowTop(g.row) + L.clipY,
                                   width: max((g.end - g.start) * pixelsPerSecond, 2), height: trackHeight - 2 * L.clipY)
                c.fillRoundedRect(r, radius: 4, CanvasColor(ThemeTokens.mint.alpha(0.18)))
            }
            // Marquee: rgba(60,230,172,0.10) fill, 1px accent border, radius 2.
            if let m = marquee {
                c.fillRoundedRect(m, radius: 2, CanvasColor(ThemeTokens.mint.alpha(0.10)))
                c.strokeRoundedRect(m.insetBy(0.5), radius: 2, theme.accent, width: 1)
            }
        }
        // Razor guide: 1px rgba(239,68,68,0.7), full height.
        if let gx = razorGuideX {
            c.fillRect(CanvasRect(x: gx.rounded(.down), y: 0, width: 1, height: size.height), CanvasColor(ThemeTokens.red500.alpha(0.7)))
        }
        if let m = gapMenu { drawGapMenu(c, m) }
        if let m = clipMenu { drawClipMenu(c, m) }
        if let m = keyframeMenu { drawKeyframeMenu(c, m) }
    }

    /// bg-neutral-900, border-neutral-700, rounded-md, py-1; rows text-xs neutral-300 (disabled neutral-600),
    /// hover bg-neutral-800; gap width in text-[10px] neutral-500.
    func drawGapMenu(_ c: CanvasContext, _ m: GapMenu) {
        let r = m.rect
        c.fillRoundedRect(r, radius: 6, CanvasColor(ThemeTokens.neutral900))
        c.strokeRoundedRect(r.insetBy(0.5), radius: 6, CanvasColor(ThemeTokens.neutral700), width: 1)
        let rows: [(String, Bool, String?)] = [("Close gap", m.canCloseGap, m.gapWidth.map { String(format: "%.2fs", $0) }),
                                               ("Close all gaps", m.canCloseAll, nil)]
        for (i, row) in rows.enumerated() {
            let ir = CanvasRect(x: r.x + 1, y: r.y + 4 + Double(i) * GapMenu.itemHeight, width: r.width - 2, height: GapMenu.itemHeight)
            if m.hovered == i && row.1 { c.fillRect(ir, CanvasColor(ThemeTokens.neutral800)) }
            c.drawText(row.0, at: .init(ir.x + 12, ir.y + 9), font: CanvasFont(size: 12), color: CanvasColor(row.1 ? ThemeTokens.neutral300 : ThemeTokens.neutral600))
            if let w = row.2 {
                c.drawText(w, at: .init(ir.maxX - 12 - 6 * Double(w.count), ir.y + 10), font: CanvasFont(size: 10), color: CanvasColor(ThemeTokens.neutral500))
            }
        }
    }

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        typealias L = TimelineLayout
        let t = theme
        c.fillRect(CanvasRect(x: 0, y: 0, width: size.width, height: size.height), t.shellBackground)
        let body = CanvasRect(x: 0, y: L.rulerHeight, width: size.width, height: size.height - L.rulerHeight)

        c.withState {
            c.clip(body)
            // Rows.
            for (i, _) in tracks.enumerated() {
                let top = rowTop(i), h = trackRowHeight(i)
                c.fillRect(CanvasRect(x: 0, y: top, width: size.width, height: h), t.rowBackground)
                c.fillRect(CanvasRect(x: 0, y: top + h - 1, width: size.width, height: 1), t.rowBorder)
            }
            // Beat grid: rgba(34,197,94, 0.08 + strength^2.2 * 0.62).
            c.withState {
                c.clip(CanvasRect(x: L.contentOrigin, y: L.rulerHeight, width: max(0, size.width - L.contentOrigin), height: body.height))
                // showBeats: only when beats are at least 5px apart on average.
                let sortedBeats = beats.map(\.time).sorted()
                let showBeats = sortedBeats.count > 1
                    && (sortedBeats.last! - sortedBeats.first!) / Double(sortedBeats.count - 1) * pixelsPerSecond >= 5
                for b in beats where showBeats {
                    let strength = pow(min(1, b.strength ?? 0.5), 2.2)
                    c.fillRect(CanvasRect(x: Self.snappedLineLeft(centre: x(for: b.time)), y: L.rulerHeight, width: 1, height: body.height),
                               CanvasColor(ThemeTokens.green500.alpha(0.08 + strength * 0.62)))
                }
            }
            // Clips (non-dragged first, dragged on top).
            c.withState {
                c.clip(CanvasRect(x: L.contentOrigin, y: L.rulerHeight, width: max(0, size.width - L.contentOrigin), height: body.height))
                var dragged: [(Int, TimelineClipModel)] = []
                for (i, track) in tracks.enumerated() {
                    for clip in track.clips {
                        if isDragged(clip.id) { dragged.append((i, clip)); continue }
                        drawTrackExtras(c, track: i, clip)
                        drawClip(c, track: i, clip)
                    }
                }
                drawDropPreview(c, contentWidth: max(0, size.width - L.contentOrigin))
                for (i, clip) in dragged { drawTrackExtras(c, track: i, clip); drawClip(c, track: i, clip) }
                // Snap guide: none for beat snaps; playhead #3CE6AC, clip edge rgba(255,255,255,0.6).
                if let snap = snapTime ?? keyframeSnapTime, snapType != .beat {
                    c.fillRect(CanvasRect(x: Self.snappedLineLeft(centre: x(for: snap)), y: L.rulerHeight, width: 1, height: body.height),
                               snapType == .playhead ? t.accent : CanvasColor(ThemeTokens.white.alpha(0.6)))
                }
            }
            // Sticky header column + origin gap (pre-roll surface).
            for (i, track) in tracks.enumerated() {
                let top = rowTop(i), h = trackRowHeight(i)
                c.fillRect(CanvasRect(x: 0, y: top, width: L.labelColumnWidth, height: h), t.gutterBackground)
                c.fillRect(CanvasRect(x: L.labelColumnWidth - 1, y: top, width: 1, height: h), t.gutterBorder)
                c.fillRect(CanvasRect(x: 0, y: top + h - 1, width: L.labelColumnWidth, height: 1), t.rowBorder)
                drawTrackHeader(c, track: i, top: top)
                drawLaneHeaders(c, track: i, top: top)
                if let gap = Self.originGapColor(track.clips, theme: t) {
                    c.fillRect(CanvasRect(x: L.labelColumnWidth, y: top, width: L.gutter, height: h), gap)
                }
            }
            for f in bandFrames() {
                if case .group(let id) = f.band, let g = groups.first(where: { $0.id == id }) {
                    drawGroupHeader(c, g, top: f.top - scrollY, width: size.width)
                }
            }
        }

        drawRuler(c, size: size)
        drawPlayhead(c, size: size)
        drawOverlays(c, size: size)
    }

    var snapTime: Double? {
        switch drag { case .move(_, _, _, let s)?: s; case .trim(_, _, _, let s)?: s; case nil: nil }
    }
    func isMoving(_ id: String) -> Bool { if case .move(let ids, _, _, _)? = drag { return ids.contains(id) }; return false }
    func isDragged(_ id: String) -> Bool {
        switch drag { case .move(let ids, _, _, _)?: ids.contains(id); case .trim(let cid, _, _, _)?: cid == id; case nil: false }
    }

    /// studio.css body font stack and .timeline-clip__timecode stack (Pango takes comma-separated families).
    public static let uiFontFamily = "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, sans-serif"
    public static let clipMonoFamily = "SF Mono, Fira Code, monospace"

    /// Clip fill by media kind and state (docs/DESIGN.md): opaque, so a clip reads as a block of its kind.
    static func clipBackground(audio: Bool, hovered: Bool, dragging: Bool) -> CanvasColor {
        if dragging { return CanvasColor((audio ? ThemeTokens.clipDragAudioPair : ThemeTokens.clipDragPair).now) }
        if audio { return CanvasColor((hovered ? ThemeTokens.clipAudioHoverPair : ThemeTokens.clipAudioPair).now) }
        return CanvasColor((hovered ? ThemeTokens.clipVideoHoverPair : ThemeTokens.clipVideoPair).now)
    }

    /// text-overflow: ellipsis within `maxWidth`.
    static func ellipsize(_ c: CanvasContext, _ text: String, font: CanvasFont, maxWidth: Double) -> String? {
        if c.measureText(text, font: font).width <= maxWidth { return text }
        var chars = Array(text)
        while !chars.isEmpty {
            chars.removeLast()
            let t = String(chars) + "…"
            if c.measureText(t, font: font).width <= maxWidth { return t }
        }
        return nil
    }

    func drawClip(_ c: CanvasContext, track i: Int, _ clip: TimelineClipModel) {
        let t = theme
        var r = clipRect(track: i, clip)
        r.width = max(r.width, 4)                                   // Math.max(duration * pps, 4)
        let selected = selection.contains(clip.id), hovered = hoveredClip == clip.id, dragging = isDragged(clip.id)
        let active = clip.start <= currentTime && currentTime < clip.end   // data-active
        if dragging { r.y -= 1 }                                    // transform: translateY(-1px)
        let squareLeft = clip.start <= 0 && !dragging               // startsAtTimelineOrigin: square left corners
        let path = Self.clipPath(r, radius: t.clipRadius, squareLeft: squareLeft)
        c.fill(path, Self.clipBackground(audio: clip.kind == .audio, hovered: hovered, dragging: dragging))
        // .is-selected: outline 2px rgba(255,255,255,.98), offset 2px; #60a5fa when also active.
        if selected {
            let o = r.insetBy(-3)   // offset 2 + half the 2px stroke
            c.stroke(Self.clipPath(o, radius: t.clipRadius + 3, squareLeft: squareLeft),
                     active ? CanvasColor(ThemeTokens.blue400) : CanvasColor(ThemeTokens.white.alpha(0.98)), StrokeStyle(width: 2))
        }
        // Clip content (useRenderClipContent), clipped to the rounded clip: waveform for audio, filmstrip for video/image.
        c.withState {
            c.clip(path)
            if clip.kind == .audio, let id = clip.assetId, let peaks = waveforms[id], !peaks.isEmpty {
                Self.drawWaveform(c, peaks, in: r, startFraction: clip.sourceStartFraction, endFraction: clip.sourceEndFraction)
            } else if thumbnailsEnabled, clip.kind == .video || clip.kind == .image, let id = clip.assetId, let strip = thumbnails[id], !strip.frames.isEmpty {
                Self.drawFilmstrip(c, strip, in: r)
            }
        }
        c.withState {
            c.clip(r)
            // Keyframe diamonds (TimelineClipDiamonds), drawn when the bar is at least 20 px wide.
            if r.width >= 20 { drawDiamonds(c, clip, group: nil, barX: r.x, cy: r.y + r.height / 2) }
            // .timeline-clip__label: top 6, left 12, right 10, rgba(255,255,255,.5), 10px/500, line-height 1, ellipsis.
            if r.width >= 40 || selected {
                let f = CanvasFont(family: Self.uiFontFamily, size: 10, weight: .medium)
                if let label = Self.ellipsize(c, clip.name, font: f, maxWidth: r.width - 22) {
                    c.drawText(label, at: .init(r.x + 12, r.y + 6), font: f, color: CanvasColor(ThemeTokens.white.alpha(0.5)))
                }
                // .timeline-clip__timecode: bottom 6, left 12, rgba(255,255,255,.34), mono 9px, "start-ends".
                let tf = CanvasFont(family: Self.clipMonoFamily, size: 9)
                let tc = String(format: "%.1f-%.1fs", clip.start, clip.end)
                if let tcs = Self.ellipsize(c, tc, font: tf, maxWidth: r.width - 12) {
                    c.drawText(tcs, at: .init(r.x + 12, r.maxY - 6 - 9), font: tf, color: CanvasColor(ThemeTokens.white.alpha(0.34)))
                }
            }
            if clip.effectCount > 0 {
                c.drawText("fx", at: .init(r.maxX - 22, r.y + 6), font: CanvasFont(family: Self.uiFontFamily, size: 10, weight: .semibold), color: t.accent.withAlpha(0.8))
            }
            // Trim handle bars: 2px, inset 4px, top/bottom 6px, rgba(255,255,255,.55) at opacity*0.6 (width >= 32 or selected).
            let op = Self.handleOpacity(hovered: hovered, selected: selected, dragging: dragging) * 0.6
            if op > 0 && (r.width >= 32 || selected) {
                let col = CanvasColor(ThemeTokens.white.alpha(0.55 * op))
                c.fillRoundedRect(CanvasRect(x: r.x + 4, y: r.y + 6, width: 2, height: r.height - 12), radius: 1, col)
                c.fillRoundedRect(CanvasRect(x: r.maxX - 6, y: r.y + 6, width: 2, height: r.height - 12), radius: 1, col)
            }
        }
        // Hidden track: the lane renders at opacity 0.35 (TimelineLanes isTrackHidden). Painting the row
        // background at 1 - opacity over the clip composites to the same result. Locked tracks (native
        // addition) fade less.
        if clip.hidden || (tracks.indices.contains(i) && (tracks[i].hidden || tracks[i].locked)) {
            let hidden = clip.hidden || tracks[i].hidden
            c.fill(path, t.rowBackground.withAlpha(1 - (hidden ? Self.hiddenTrackOpacity : Self.lockedTrackOpacity)))
        }
    }

    static let hiddenTrackOpacity = 0.35, lockedTrackOpacity = 0.7

    /// Audio waveform: 2px bars every 3px, bottom-aligned, height max(2, amp * h),
    /// rgba(75,163,210, 0.45 + amp * 0.4), peaks windowed to the trimmed source slice.
    static let waveformBarWidth = 2.0, waveformBarStep = 3.0
    static func drawWaveform(_ c: CanvasContext, _ peaks: [Double], in r: CanvasRect, startFraction: Double, endFraction: Double) {
        let sf = max(0, min(1, startFraction)), ef = max(sf, min(1, endFraction))
        let start = Int((sf * Double(peaks.count)).rounded(.down))
        let end = max(start + 1, Int((ef * Double(peaks.count)).rounded(.up)))
        let span = end - start
        let bars = Int((r.width / waveformBarStep).rounded(.down))
        guard bars > 0 else { return }
        for i in 0..<bars {
            let lo = start + min(span - 1, Int((Double(i) / Double(bars) * Double(span)).rounded(.down)))
            let hi = start + min(span, Int((Double(i + 1) / Double(bars) * Double(span)).rounded(.up)))
            var amp = 0.0
            for k in lo..<max(lo + 1, hi) where k < peaks.count { amp = max(amp, peaks[k]) }
            let h = max(2, amp * r.height)
            c.fillRect(CanvasRect(x: r.x + Double(i) * waveformBarStep, y: r.maxY - h, width: waveformBarWidth, height: h),
                       CanvasColor(ThemeTokens.waveformPair.now.alpha(((0.45 + amp * 0.4) * 100).rounded() / 100)))
        }
    }

    /// computeThumbnailStrip: tiles round(66 * aspect) wide, ceil(width / tileW) of them, each on neutral-900.
    static let thumbnailClipHeight = 66.0
    static func drawFilmstrip(_ c: CanvasContext, _ strip: TimelineThumbnailStrip, in r: CanvasRect) {
        let aspect = strip.aspect.isFinite && strip.aspect > 0 ? strip.aspect : 16.0 / 9
        let w = max(1, (thumbnailClipHeight * aspect).rounded())
        let count = max(1, Int((r.width / w).rounded(.up)))
        for i in 0..<count {
            let tile = CanvasRect(x: r.x + Double(i) * w, y: r.y, width: w, height: r.height)
            c.fillRect(tile, CanvasColor(ThemeTokens.neutral900))   // bg-neutral-900
            let img = strip.frames[i % strip.frames.count]
            // object-cover: scale to fill the tile, centred, cropped by the tile clip.
            let s = max(tile.width / Double(max(img.width, 1)), tile.height / Double(max(img.height, 1)))
            let iw = Double(img.width) * s, ih = Double(img.height) * s
            c.withState {
                c.clip(tile)
                c.drawImage(img, in: CanvasRect(x: tile.x + (tile.width - iw) / 2, y: tile.y + (tile.height - ih) / 2, width: iw, height: ih))
            }
        }
    }

    static func clipPath(_ r: CanvasRect, radius: Double, squareLeft: Bool) -> CanvasPath {
        guard squareLeft else { return .roundedRect(r, radius: radius) }
        let rad = max(0, min(radius, r.width / 2, r.height / 2)), k = 0.5522847498 * rad
        var p = CanvasPath()
        p.move(to: .init(r.x, r.y)); p.line(to: .init(r.maxX - rad, r.y))
        p.curve(to: .init(r.maxX, r.y + rad), c1: .init(r.maxX - rad + k, r.y), c2: .init(r.maxX, r.y + rad - k))
        p.line(to: .init(r.maxX, r.maxY - rad))
        p.curve(to: .init(r.maxX - rad, r.maxY), c1: .init(r.maxX, r.maxY - rad + k), c2: .init(r.maxX - rad + k, r.maxY))
        p.line(to: .init(r.x, r.maxY)); p.close()
        return p
    }

    func drawRuler(_ c: CanvasContext, size: CanvasSize) {
        typealias L = TimelineLayout
        let t = theme, pps = pixelsPerSecond
        c.fillRect(CanvasRect(x: 0, y: 0, width: size.width, height: L.rulerHeight), t.shellBackground)
        let fps: Double? = timeDisplay == .frame ? frameRate : nil
        let major = TimelineRuler.majorInterval(duration: duration, pps: pps, frameRate: fps)
        let parts = TimelineRuler.minorSubdivisions(major: major, pps: pps, frameRate: fps)
        let firstVisible = max(0, time(forX: L.contentOrigin) - major)
        let lastVisible = min(duration, time(forX: size.width) + major)
        c.withState {
            c.clip(CanvasRect(x: L.contentOrigin, y: 0, width: max(0, size.width - L.contentOrigin), height: L.rulerHeight))
            var k = Int((firstVisible / major).rounded(.down))
            while true {
                let tm = (Double(k) * major * 1e6).rounded() / 1e6
                if tm > lastVisible || tm > duration { break }
                let mx = Self.snappedLineLeft(centre: x(for: tm))
                c.fillRect(CanvasRect(x: mx, y: 0, width: 1, height: L.rulerHeight), t.tickMajor)
                let label = timeDisplay == .frame ? "\(Int((tm * frameRate).rounded()))" : TimelineRuler.label(tm, duration: duration, major: major)
                c.drawText(label, at: .init(mx + 5, 5), font: .mono(10), color: t.tickText)
                if parts > 1 {
                    for s in 1..<parts {
                        let mt = tm + major * Double(s) / Double(parts)
                        if mt >= duration { break }
                        c.fillRect(CanvasRect(x: Self.snappedLineLeft(centre: x(for: mt)), y: L.rulerHeight - 8, width: 1, height: 8), t.tickMinor)
                    }
                }
                k += 1
            }
        }
    }

    func drawPlayhead(_ c: CanvasContext, size: CanvasSize) {
        typealias L = TimelineLayout
        let t = theme
        let left = L.playheadLeft(time: currentTime, pps: pixelsPerSecond) - scrollX
        let cx = left + L.playheadHeadWidth / 2
        guard cx >= L.contentOrigin - L.playheadHeadWidth else { return }
        let lineLeft = Self.snappedLineLeft(centre: cx)
        c.fillRect(CanvasRect(x: lineLeft, y: 1 + L.playheadHeadHeight, width: 1, height: size.height - 10), t.accent)
        c.withState {
            c.translate(lineLeft + 0.5, 1 + L.playheadHeadHeight / 2)
            c.rotate(.pi / 4)
            let head = CanvasRect(x: -L.playheadHeadWidth / 2, y: -L.playheadHeadHeight / 2, width: L.playheadHeadWidth, height: L.playheadHeadHeight)
            if scrubbing { c.fillRoundedRect(head, radius: 2, t.accent) }
            c.strokeRoundedRect(head.insetBy(0.75), radius: 2, t.accent, width: 1.5)
        }
    }

    /// Placeholder content when no project document is loaded.
    public static func demo() -> TimelineView {
        let v = TimelineView(tracks: [
            TimelineTrackModel(name: "Title", kind: "mixed", clips: [TimelineClipModel(name: "Intro title", start: 0.5, duration: 3, kind: .element)]),
            TimelineTrackModel(name: "Video 1", clips: [TimelineClipModel(name: "clip_001.mp4", start: 0, duration: 6),
                                                       TimelineClipModel(name: "clip_002.mp4", start: 6.5, duration: 4)]),
            TimelineTrackModel(name: "Audio", kind: "audio", clips: [TimelineClipModel(name: "music.wav", start: 0, duration: 11, kind: .audio)]),
        ], duration: 12, pixelsPerSecond: 90, currentTime: 2.4)
        v.selectedClip = (1, 0)
        return v
    }
}
