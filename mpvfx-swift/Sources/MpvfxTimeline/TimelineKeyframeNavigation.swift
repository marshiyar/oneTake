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
import MpvfxShared

/// getKeyframeNavigationState on native frames: the keyframe at the playhead frame
/// (exact match), and the previous / next keyframes around it.
public struct TimelineKeyframeNavigation: Equatable, Sendable {
    public var prev: Double?, current: Double?, next: Double?

    /// `frames` are clip-local keyframe frames (any order); `currentFrame` is the playhead's clip-local frame.
    public static func state(frames: [Double], currentFrame: Double) -> TimelineKeyframeNavigation {
        let sorted = Array(Set(frames)).sorted()
        if let i = sorted.firstIndex(of: currentFrame) {
            return .init(prev: i > 0 ? sorted[i - 1] : nil, current: sorted[i], next: i + 1 < sorted.count ? sorted[i + 1] : nil)
        }
        return .init(prev: sorted.last { $0 < currentFrame }, current: nil, next: sorted.first { $0 > currentFrame })
    }
}

// MARK: - Editor: per property group
public extension TimelineEditor {
    /// Parameter tracks (with keyframes) of a property group on a clip (propertyGroup ids: position, scale, …).
    func groupTracks(clipId: String, group: String) -> [NativeParameterTrack] {
        guard let (_, c) = clip(clipId) else { return [] }
        return c.parameterTracks.filter { !$0.keyframes.isEmpty && Self.propertyGroup($0.parameterId).group == group }
    }

    func laneNavigation(clipId: String, group: String, time: Double) -> TimelineKeyframeNavigation {
        guard let f = localFrame(clipId: clipId, time: time) else { return .init() }
        return .state(frames: groupTracks(clipId: clipId, group: group).flatMap { $0.keyframes.map(\.frame) }, currentFrame: f)
    }

    /// The lane's ◆/◇ (onTogglePropertyGroupKeyframe): remove the group's keyframes at the playhead frame, or key every
    /// animated parameter of the group at its current value. One undo step; refused on a locked track.
    @discardableResult
    func toggleLaneKeyframe(clipId: String, group: String, time: Double) -> Bool {
        guard let (track, _) = clip(clipId), let f = localFrame(clipId: clipId, time: time) else { return false }
        let tracks = groupTracks(clipId: clipId, group: group)
        guard !tracks.isEmpty else { return false }
        func addr(_ t: NativeParameterTrack) -> NativeProjectParameterAddress {
            NativeProjectParameterAddress(sequenceId: sequenceId, trackId: track.id, clipId: clipId, parameterId: t.parameterId)
        }
        let atFrame = tracks.filter { $0.keyframes.contains { $0.frame == f } }
        let cmds: [NativeProjectAtomicPropertyCommand]
        if !atFrame.isEmpty {
            cmds = atFrame.map { .keyframe(.delete(address: addr($0), frame: f)) }
        } else {
            cmds = tracks.compactMap { t in
                guard let v = parameterValue(clipId: clipId, parameterId: t.parameterId, time: time) else { return nil }
                let (_, c) = clip(clipId)!
                return .keyframe(.upsert(address: addr(t), valueType: t.valueType, frame: f, value: v,
                                         baselineValue: c.staticParameters?[t.parameterId] ?? v))
            }
        }
        guard !cmds.isEmpty else { return false }
        return applyProperty(cmds.count == 1 ? .atomic(cmds[0]) : .batch(cmds))
    }
}

// MARK: - View: lane header controls (PropertyGroupNavigation: ‹ ◆ ›)
public enum TimelineLaneControl: Equatable, Sendable { case prev, toggle, next }

extension TimelineView {
    /// px-1.5, spine w-3, gap-1, 46px label, gap-1, then ‹ (w-3) gap-0.5 ◆ (w-4) gap-0.5 › (w-3), each h-4 centred.
    static func laneControlRects(laneTop y: Double) -> [(TimelineLaneControl, CanvasRect)] {
        let cy = y + TimelineLayout.laneHeight / 2
        var x = 6.0 + 12 + 4 + 46 + 4
        var out: [(TimelineLaneControl, CanvasRect)] = []
        for (ctl, w) in [(TimelineLaneControl.prev, 12.0), (.toggle, 16.0), (.next, 12.0)] {
            out.append((ctl, CanvasRect(x: x, y: cy - 8, width: w, height: 16))); x += w + 2
        }
        return out
    }

    /// The expanded clip whose lanes this track row shows, and the lane index under `y` (row-local band math).
    func laneHit(track i: Int, y: Double) -> (clip: TimelineClipModel, lane: Int, laneTop: Double)? {
        guard tracks.indices.contains(i),
              let clip = tracks[i].clips.filter({ expandedClips.contains($0.id) }).max(by: { $0.lanes.count < $1.lanes.count }),
              !clip.lanes.isEmpty, let frame = bandFrames().first(where: { $0.band == .track(i) }) else { return nil }
        let base = frame.top - scrollY + trackHeight + Double(effectLaneCount(track: i)) * TimelineLayout.effectStripHeight
        let j = Int(((y - base) / TimelineLayout.laneHeight).rounded(.down))
        guard y >= base, clip.lanes.indices.contains(j) else { return nil }
        return (clip, j, base + Double(j) * TimelineLayout.laneHeight)
    }

    func laneControl(atX x: Double, y: Double, track i: Int) -> (clip: TimelineClipModel, lane: Int, control: TimelineLaneControl)? {
        guard let h = laneHit(track: i, y: y) else { return nil }
        // 24×24 targets around the glyphs (the ::before overlay), resolved to the nearest control.
        let hits = Self.laneControlRects(laneTop: h.laneTop).filter { abs($0.1.centerX - x) <= 12 && abs($0.1.centerY - y) <= 12 }
        guard let best = hits.min(by: { abs($0.1.centerX - x) < abs($1.1.centerX - x) }) else { return nil }
        return (h.clip, h.lane, best.0)
    }
}

// MARK: - Controller
public extension TimelineController {
    /// Navigation state of an expanded clip's lane at the playhead.
    func laneNavigation(clipId: String, lane: Int) -> TimelineKeyframeNavigation {
        guard let editor, let (_, c) = clip(clipId), c.lanes.indices.contains(lane) else { return .init() }
        return editor.laneNavigation(clipId: clipId, group: c.lanes[lane].group, time: playback.currentTime)
    }

    /// ‹ / › seek the playhead to the previous / next keyframe of the lane; ◆ toggles the group keyframe.
    @discardableResult
    func laneControlClick(clipId: String, lane: Int, control: TimelineLaneControl) -> Bool {
        guard let editor, let (row, c) = clip(clipId), c.lanes.indices.contains(lane) else { return false }
        let nav = laneNavigation(clipId: clipId, lane: lane)
        let startFrame = (c.start * editor.fps).rounded()
        switch control {
        case .prev, .next:
            guard let f = control == .prev ? nav.prev : nav.next else { return false }
            playback.seek((startFrame + f) / editor.fps); syncFromPlayback(); return true
        case .toggle:
            guard !view.tracks[row].locked else { return false }
            return editor.toggleLaneKeyframe(clipId: clipId, group: c.lanes[lane].group, time: playback.currentTime)
        }
    }
}
