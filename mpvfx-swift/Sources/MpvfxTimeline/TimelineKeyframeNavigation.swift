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
    func groupTracks(clipId: String, group: String) -> [NativeParameterTrack] { scopeTracks(clipId: clipId, groups: [group]) }

    /// Parameter tracks (with keyframes) of the listed property groups; nil = every keyed track of the clip.
    func scopeTracks(clipId: String, groups: Set<String>?) -> [NativeParameterTrack] {
        guard let (_, c) = clip(clipId) else { return [] }
        return c.parameterTracks.filter { !$0.keyframes.isEmpty && (groups?.contains(Self.propertyGroup($0.parameterId).group) ?? true) }
    }

    func laneNavigation(clipId: String, group: String, time: Double) -> TimelineKeyframeNavigation {
        scopeNavigation(clipId: clipId, groups: [group], time: time)
    }

    func scopeNavigation(clipId: String, groups: Set<String>?, time: Double) -> TimelineKeyframeNavigation {
        guard let f = localFrame(clipId: clipId, time: time) else { return .init() }
        return .state(frames: scopeTracks(clipId: clipId, groups: groups).flatMap { $0.keyframes.map(\.frame) }, currentFrame: f)
    }

    /// The lane's ◆/◇ (onTogglePropertyGroupKeyframe): remove the group's keyframes at the playhead frame, or key every
    /// animated parameter of the group at its current value. One undo step; refused on a locked track.
    @discardableResult
    func toggleLaneKeyframe(clipId: String, group: String, time: Double) -> Bool {
        toggleScopeKeyframe(clipId: clipId, groups: [group], time: time)
    }

    /// A summary or kind row's ◆: as the lane's, over every animated parameter of the row's groups (nil: the clip's).
    @discardableResult
    func toggleScopeKeyframe(clipId: String, groups: Set<String>?, time: Double) -> Bool {
        guard let (track, _) = clip(clipId), let f = localFrame(clipId: clipId, time: time) else { return false }
        let tracks = scopeTracks(clipId: clipId, groups: groups)
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
    /// Left edge of a lane row's ‹ ◆ ›: right-aligned in the header column (px-1.5), so the label before it gets the
    /// room the disclosure and the kind mark take.
    static let laneControlsX = TimelineLayout.labelColumnWidth - 6 - (12 + 2 + 16 + 2 + 12)

    /// ‹ (w-3) gap-0.5 ◆ (w-4) gap-0.5 › (w-3), each h-4 centred, from `laneControlsX`.
    static func laneControlRects(laneTop y: Double) -> [(TimelineLaneControl, CanvasRect)] {
        let cy = y + TimelineLayout.laneHeight / 2
        var x = laneControlsX
        var out: [(TimelineLaneControl, CanvasRect)] = []
        for (ctl, w) in [(TimelineLaneControl.prev, 12.0), (.toggle, 16.0), (.next, 12.0)] {
            out.append((ctl, CanvasRect(x: x, y: cy - 8, width: w, height: 16))); x += w + 2
        }
        return out
    }

    /// The clip whose rows this track's header column shows, and its lane row under `y`.
    func laneHit(track i: Int, y: Double) -> (clip: TimelineClipModel, row: TimelineLaneRow, laneTop: Double)? {
        guard let clip = headerClip(track: i), let h = laneRow(clip, track: i, y: y) else { return nil }
        return (clip, h.row, h.top)
    }

    func laneControl(atX x: Double, y: Double, track i: Int) -> (clip: TimelineClipModel, row: TimelineLaneRow, control: TimelineLaneControl)? {
        guard let h = laneHit(track: i, y: y) else { return nil }
        // 24×24 targets around the glyphs (the ::before overlay), resolved to the nearest control.
        let hits = Self.laneControlRects(laneTop: h.laneTop).filter { abs($0.1.centerX - x) <= 12 && abs($0.1.centerY - y) <= 12 }
        guard let best = hits.min(by: { abs($0.1.centerX - x) < abs($1.1.centerX - x) }) else { return nil }
        return (h.clip, h.row, best.0)
    }
}

// MARK: - Controller
public extension TimelineController {
    /// Navigation state of a clip's property lane (index into its lanes) at the playhead.
    func laneNavigation(clipId: String, lane: Int) -> TimelineKeyframeNavigation {
        guard let (_, c) = clip(clipId), c.lanes.indices.contains(lane) else { return .init() }
        return laneNavigation(clipId: clipId, row: .property(c.lanes[lane].group))
    }

    /// Navigation state of a lane row (summary, kind or property) at the playhead.
    func laneNavigation(clipId: String, row: TimelineLaneRow) -> TimelineKeyframeNavigation {
        guard let editor, let (_, c) = clip(clipId) else { return .init() }
        return editor.scopeNavigation(clipId: clipId, groups: view.rowScope(row, c), time: playback.currentTime)
    }

    /// ‹ / › on a property lane (index into the clip's lanes); see `laneRowControlClick`.
    @discardableResult
    func laneControlClick(clipId: String, lane: Int, control: TimelineLaneControl) -> Bool {
        guard let (_, c) = clip(clipId), c.lanes.indices.contains(lane) else { return false }
        return laneRowControlClick(clipId: clipId, row: .property(c.lanes[lane].group), control: control)
    }

    /// ‹ / › seek the playhead to the previous / next keyframe of the row; ◆ toggles the row's keys at the playhead.
    @discardableResult
    func laneRowControlClick(clipId: String, row lane: TimelineLaneRow, control: TimelineLaneControl) -> Bool {
        guard let editor, let (row, c) = clip(clipId) else { return false }
        let nav = laneNavigation(clipId: clipId, row: lane)
        let startFrame = (c.start * editor.fps).rounded()
        switch control {
        case .prev, .next:
            guard let f = control == .prev ? nav.prev : nav.next else { return false }
            playback.seek((startFrame + f) / editor.fps); syncFromPlayback(); return true
        case .toggle:
            guard !view.tracks[row].locked else { return false }
            return editor.toggleScopeKeyframe(clipId: clipId, groups: view.rowScope(lane, c), time: playback.currentTime)
        }
    }
}
