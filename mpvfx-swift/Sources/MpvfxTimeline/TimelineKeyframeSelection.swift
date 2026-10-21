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
import MpvfxShared

// Timeline keyframe diamonds: hit-testing, selection, drag-to-retime, delete and nudge
// (diamonds, keyframe handlers, drag, nudge and delete of the selected keys,
// and the range selection's keyframe marquee).

/// One authored keyframe on one parameter track: clip id, parameter id and clip-local frame.
public struct TimelineKeyframeRef: Hashable, Sendable {
    public var clipId: String, parameterId: String, frame: Double
    public init(clipId: String, parameterId: String, frame: Double) { self.clipId = clipId; self.parameterId = parameterId; self.frame = frame }
}

/// A parameter track's keyframe frames (clip-local), with its property group (the lane it shows in).
public struct TimelineKeyframeChannel: Equatable, Sendable {
    public var parameterId: String, group: String, frames: [Double]
    /// Each key's outgoing interpolation by frame (missing: linear), drawn as the mark's variant.
    public var eases: [Double: TimelineKeyframeEase]
    public init(parameterId: String, group: String, frames: [Double], eases: [Double: TimelineKeyframeEase] = [:]) {
        self.parameterId = parameterId; self.group = group; self.frames = frames; self.eases = eases
    }
}

/// A mark under the pointer: on the clip bar (`lane` nil, every channel) or on a lane row (`laneRow`: the summary,
/// a kind or one property; `lane` is the property's index in the clip's lanes when the row is one property's).
public struct TimelineKeyframeHit: Equatable, Sendable {
    public var clipId: String, row: Int, lane: Int?, frame: Double
    /// Every channel keyed at `frame` in the mark's scope (one summary or group mark moves them together).
    public var refs: Set<TimelineKeyframeRef>
    public var laneRow: TimelineLaneRow? = nil
}

/// Live retime preview: `refs` drawn `deltaFrames` away from their authored frames.
public struct TimelineKeyframeDragPreview: Equatable, Sendable {
    public var refs: Set<TimelineKeyframeRef>, deltaFrames: Double
}

extension TimelineView {
    /// TimelineClipDiamonds: glyph round(LANE_H * 0.8), hit box 24 high, width min(glyph, neighbour gap), floor 12.
    public static let keyframeDiamondSize = (TimelineLayout.laneHeight * 0.8).rounded()
    public static let keyframeHitHeight = 24.0, keyframeMinHitWidth = 12.0

    /// Channels of a clip in a scope of property groups (nil = every channel: the clip bar and the summary row).
    /// Demo models without channels fall back to their merged keyframe times on one anonymous channel.
    func keyframeChannels(_ clip: TimelineClipModel, scope: Set<String>?) -> [TimelineKeyframeChannel] {
        if clip.channels.isEmpty {
            let times = scope.map { s in clip.lanes.filter { s.contains($0.group) }.flatMap(\.keyframes) } ?? clip.keyframes
            return [TimelineKeyframeChannel(parameterId: "", group: scope?.first ?? "", frames: Array(Set(times.map { ($0 * frameRate).rounded() })).sorted())]
        }
        return scope.map { s in clip.channels.filter { s.contains($0.group) } } ?? clip.channels
    }
    func keyframeChannels(_ clip: TimelineClipModel, group: String?) -> [TimelineKeyframeChannel] { keyframeChannels(clip, scope: group.map { [$0] }) }

    /// Diamond frames of a scope, with the live drag preview applied, unique and sorted.
    func diamondFrames(_ clip: TimelineClipModel, group: String?) -> [Double] { diamondFrames(clip, scope: group.map { [$0] }) }
    func diamondFrames(_ clip: TimelineClipModel, scope: Set<String>?) -> [Double] {
        var out = Set<Double>()
        for ch in keyframeChannels(clip, scope: scope) {
            for f in ch.frames { out.insert(previewFrame(TimelineKeyframeRef(clipId: clip.id, parameterId: ch.parameterId, frame: f))) }
        }
        return out.sorted()
    }

    func previewFrame(_ r: TimelineKeyframeRef) -> Double {
        if let d = keyframeDrag, d.refs.contains(r) { return r.frame + d.deltaFrames }
        return r.frame
    }

    /// Refs keyed at a displayed frame in a scope (preview applied).
    func diamondRefs(_ clip: TimelineClipModel, scope: Set<String>?, frame: Double) -> Set<TimelineKeyframeRef> {
        var out = Set<TimelineKeyframeRef>()
        for ch in keyframeChannels(clip, scope: scope) {
            for f in ch.frames {
                let r = TimelineKeyframeRef(clipId: clip.id, parameterId: ch.parameterId, frame: f)
                if previewFrame(r) == frame { out.insert(r) }
            }
        }
        return out
    }

    /// Selected when every channel of the diamond is selected (the same key in the clip row and in its lanes).
    func isDiamondSelected(_ clip: TimelineClipModel, group: String?, frame: Double) -> Bool {
        isDiamondSelected(clip, scope: group.map { [$0] }, frame: frame)
    }
    func isDiamondSelected(_ clip: TimelineClipModel, scope: Set<String>?, frame: Double) -> Bool {
        let refs = diamondRefs(clip, scope: scope, frame: frame)
        return !refs.isEmpty && refs.isSubset(of: selectedKeyframes.union(keyframeDrag?.refs ?? []))
    }

    /// Authored frames of a scope with no preview (the neighbours a single dragged diamond stays between).
    func authoredDiamondFrames(_ clip: TimelineClipModel, scope: Set<String>?) -> [Double] {
        Array(Set(keyframeChannels(clip, scope: scope).flatMap(\.frames))).sorted()
    }

    /// Hit boxes of a scope's diamonds: centre x, half width (neighbour gap clamp, floor 12).
    func diamondHitBoxes(_ clip: TimelineClipModel, scope: Set<String>?, barX: Double) -> [(frame: Double, cx: Double, halfWidth: Double)] {
        let frames = diamondFrames(clip, scope: scope)
        let xs = frames.map { barX + $0 / max(frameRate, 1e-9) * pixelsPerSecond }
        return frames.indices.map { i in
            let prev = i > 0 ? xs[i] - xs[i - 1] : .infinity, next = i + 1 < xs.count ? xs[i + 1] - xs[i] : .infinity
            let w = max(Self.keyframeMinHitWidth, min(Self.keyframeDiamondSize, max(1, min(prev, next))))
            return (frames[i], xs[i], w / 2)
        }
    }

    /// The diamond under (x, y): clip bars first (topmost clip), then expanded lanes.
    public func keyframeHit(x: Double, y: Double) -> TimelineKeyframeHit? {
        guard x >= TimelineLayout.contentOrigin, y >= TimelineLayout.rulerHeight else { return nil }
        for (i, track) in tracks.enumerated() {
            for clip in track.clips.reversed() {
                let r = clipRect(track: i, clip, preview: false)
                // Clip bar: diamonds are drawn when the bar is at least 20 px wide.
                if r.width >= 20 {
                    let cy = r.y + r.height / 2, half = min(Self.keyframeHitHeight, r.height) / 2
                    if abs(y - cy) <= half, x >= r.x - Self.keyframeDiamondSize / 2, x <= r.maxX + Self.keyframeDiamondSize / 2,
                       let h = nearest(diamondHitBoxes(clip, scope: nil, barX: r.x), x) {
                        return TimelineKeyframeHit(clipId: clip.id, row: i, lane: nil, frame: h, refs: diamondRefs(clip, scope: nil, frame: h))
                    }
                }
                if let hit = laneRowHit(clip, track: i, barX: r.x, at: CanvasPoint(x, y)) { return hit }
            }
        }
        return nil
    }

    /// The mark under (x, y) on one of `clip`'s lane rows.
    func laneRowHit(_ clip: TimelineClipModel, track i: Int, barX: Double, at p: CanvasPoint) -> TimelineKeyframeHit? {
        let x = p.x
        guard let lr = laneRow(clip, track: i, y: p.y) else { return nil }
        let scope = rowScope(lr.row, clip)
        guard let h = nearest(diamondHitBoxes(clip, scope: scope, barX: barX), x) else { return nil }
        return TimelineKeyframeHit(clipId: clip.id, row: i, lane: propertyLaneIndex(lr.row, clip), frame: h,
                                   refs: diamondRefs(clip, scope: scope, frame: h), laneRow: lr.row)
    }

    private func nearest(_ boxes: [(frame: Double, cx: Double, halfWidth: Double)], _ x: Double) -> Double? {
        boxes.filter { abs(x - $0.cx) <= $0.halfWidth }.min { abs(x - $0.cx) < abs(x - $1.cx) }?.frame
    }

    /// Diamond hit boxes overlapping a view rect (keyframe marquee).
    func keyframeRefs(in rect: CanvasRect) -> Set<TimelineKeyframeRef> {
        var out = Set<TimelineKeyframeRef>()
        func add(_ clip: TimelineClipModel, scope: Set<String>?, barX: Double, cy: Double) {
            for b in diamondHitBoxes(clip, scope: scope, barX: barX) {
                let box = CanvasRect(x: b.cx - b.halfWidth, y: cy - Self.keyframeHitHeight / 2, width: 2 * b.halfWidth, height: Self.keyframeHitHeight)
                if box.x < rect.maxX && box.maxX > rect.x && box.y < rect.maxY && box.maxY > rect.y {
                    out.formUnion(diamondRefs(clip, scope: scope, frame: b.frame))
                }
            }
        }
        for (i, track) in tracks.enumerated() {
            for clip in track.clips {
                let r = clipRect(track: i, clip, preview: false)
                if r.width >= 20 { add(clip, scope: nil, barX: r.x, cy: r.y + r.height / 2) }
                for row in laneRows(clip) {
                    guard let top = laneTop(row, track: i) else { continue }
                    add(clip, scope: rowScope(row, clip), barX: r.x, cy: top + TimelineLayout.laneHeight / 2)
                }
            }
        }
        return out
    }

    /// The marks of a scope along one row (`scope` nil: every channel, the clip bar and the summary row).
}

public extension TimelineController {
    /// KEYFRAME_DRAG_THRESHOLD_PX: a press travelling less than this is a click.
    static let keyframeDragThresholdPx = 4.0

    /// Clip-local frame range and parameter address for a clip's keyframes.
    internal func keyframeAddress(_ r: TimelineKeyframeRef) -> NativeProjectParameterAddress? {
        guard let editor, let a = editor.address(clipId: r.clipId) else { return nil }
        return NativeProjectParameterAddress(sequenceId: a.sequenceId, trackId: a.trackId, clipId: r.clipId, parameterId: r.parameterId)
    }

    /// onClickKeyframe: the key alone becomes the selection, its clip the selected clip, and the playhead seeks to it.
    /// onShiftClickKeyframe: toggle it; a key on another clip starts a new selection there (selections stay clip-scoped).
    func selectKeyframe(_ hit: TimelineKeyframeHit, additive: Bool) {
        if additive, view.selectedKeyframes.allSatisfy({ $0.clipId == hit.clipId }) {
            if hit.refs.isSubset(of: view.selectedKeyframes) { view.selectedKeyframes.subtract(hit.refs) }
            else { view.selectedKeyframes.formUnion(hit.refs) }
            view.selection.insert(hit.clipId)
        } else {
            view.selectedKeyframes = hit.refs
            view.selection = [hit.clipId]
            if !additive, let (_, c) = clip(hit.clipId) {
                if playback.isPlaying { playback.pause() }
                playback.seek(c.start + hit.frame / max(view.frameRate, 1e-9)); syncFromPlayback()
            }
        }
        needsDisplay?()
    }

    /// The frames a set of refs may move by: never past the clip's first/last frame, never onto (or across) an unmoved
    /// keyframe of the same parameter (nudgeSelectedKeyframes movementCapacity, both directions).
    internal func keyframeDeltaRange(_ refs: Set<TimelineKeyframeRef>) -> ClosedRange<Double>? {
        guard let first = refs.first, let (_, c) = clip(first.clipId), !refs.isEmpty else { return nil }
        let lastFrame = (c.duration * view.frameRate).rounded() - 1
        var lo = -Double.infinity, hi = Double.infinity
        let byParam = Dictionary(grouping: refs, by: \.parameterId)
        for (pid, moving) in byParam {
            let all = c.channels.first { $0.parameterId == pid }?.frames ?? moving.map(\.frame)
            let movingFrames = Set(moving.map(\.frame))
            let stationary = all.filter { !movingFrames.contains($0) }
            for f in movingFrames {
                lo = max(lo, -f); hi = min(hi, lastFrame - f)
                if let prev = stationary.filter({ $0 < f }).max() { lo = max(lo, prev + 1 - f) }
                if let next = stationary.filter({ $0 > f }).min() { hi = min(hi, next - 1 - f) }
            }
        }
        return lo <= hi ? lo...hi : nil
    }

    /// Move refs by whole frames as one undo step ("Move keyframe" / "Move N keyframes"); the selection follows them.
    @discardableResult func moveKeyframes(_ refs: Set<TimelineKeyframeRef>, deltaFrames: Double, label: String? = nil) -> Bool {
        guard let editor, deltaFrames != 0, !refs.isEmpty, let range = keyframeDeltaRange(refs), range.contains(deltaFrames) else { return false }
        var cmds: [NativeProjectAtomicKeyframeCommand] = []
        for (pid, moving) in Dictionary(grouping: refs, by: { $0.parameterId }).sorted(by: { $0.key < $1.key }) {
            guard let a = keyframeAddress(moving[0]), a.parameterId == pid else { return false }
            cmds.append(.moveMany(address: a, frames: moving.map(\.frame).sorted(), deltaFrames: deltaFrames))
        }
        let n = refs.count
        guard editor.applyKeyframe(cmds.count == 1 ? .atomic(cmds[0]) : .batch(cmds),
                                   label: label ?? (n == 1 ? "Move keyframe" : "Move \(n) keyframes")) else { return false }
        let moved = Set(refs.map { TimelineKeyframeRef(clipId: $0.clipId, parameterId: $0.parameterId, frame: $0.frame + deltaFrames) })
        view.selectedKeyframes = view.selectedKeyframes.subtracting(refs).union(moved)
        needsDisplay?(); return true
    }

    /// Delete / Backspace with keys selected: delete them (one undo step), never the clip.
    @discardableResult func deleteSelectedKeyframes() -> Bool { deleteKeyframes(view.selectedKeyframes) }

    /// Delete keys as one undo step; the deleted keys leave the selection.
    @discardableResult func deleteKeyframes(_ refs: Set<TimelineKeyframeRef>, label: String = "Delete keyframes") -> Bool {
        guard let editor, !refs.isEmpty else { return false }
        var cmds: [NativeProjectAtomicKeyframeCommand] = []
        let groups = Dictionary(grouping: refs, by: { "\($0.clipId)\u{1}\($0.parameterId)" })
        for key in groups.keys.sorted() {
            let refs = groups[key]!
            guard let a = keyframeAddress(refs[0]) else { continue }
            cmds.append(.deleteMany(address: a, frames: refs.map(\.frame).sorted()))
        }
        guard !cmds.isEmpty else { return false }
        if editor.applyKeyframe(cmds.count == 1 ? .atomic(cmds[0]) : .batch(cmds), label: label) { view.selectedKeyframes.subtract(refs) }
        needsDisplay?(); return true
    }

    /// , / . (⇧ = 10 frames): nudge every selected key by one shared delta, clamped so none crosses a neighbour.
    @discardableResult func nudgeSelectedKeyframes(direction: Double, large: Bool) -> Bool {
        let refs = view.selectedKeyframes
        guard !refs.isEmpty, let range = keyframeDeltaRange(refs) else { return false }
        let want = direction * (large ? 10 : 1)
        let delta = max(range.lowerBound, min(range.upperBound, want))
        guard delta != 0, delta.sign == want.sign else { return false }
        return moveKeyframes(refs, deltaFrames: delta, label: "Nudge keyframes")
    }

    /// Keyframe pointer-down: arms a retime on the diamond (selecting its clip so the drag can start right away).
    internal func keyframePointerDown(_ hit: TimelineKeyframeHit, x: Double, y: Double, shift: Bool) {
        let locked = view.tracks.indices.contains(hit.row) && view.tracks[hit.row].locked
        // The whole selection moves together when the pressed diamond is part of a larger selection on its clip.
        let group = !shift && hit.refs.isSubset(of: view.selectedKeyframes) && view.selectedKeyframes.count > hit.refs.count
            && view.selectedKeyframes.allSatisfy { $0.clipId == hit.clipId }
        keyframeGesture = KeyframeGesture(hit: hit, x0: x, y0: y, shift: shift, moving: group ? view.selectedKeyframes : hit.refs,
                                          moved: false, locked: locked)
        if !view.selection.contains(hit.clipId) && !shift { view.selection = [hit.clipId] }
        needsDisplay?()
    }

    /// Live retime: pointer delta in frames, snapped to the playhead (when snapping is on) and clamped.
    internal func keyframePointerMove(x: Double) {
        guard var g = keyframeGesture else { return }
        if !g.moved {
            guard abs(x - g.x0) >= Self.keyframeDragThresholdPx, !g.locked, editor != nil else { return }
            g.moved = true; cursor = .resize
        }
        keyframeGesture = g
        let fps = max(view.frameRate, 1e-9)
        var target = g.hit.frame + (x - g.x0) / max(view.pixelsPerSecond, 1e-9) * fps
        view.snapType = nil
        if snapEnabled, let (_, c) = clip(g.hit.clipId) {
            let playheadFrame = ((playback.currentTime - c.start) * fps).rounded()
            if abs(target - playheadFrame) / fps * view.pixelsPerSecond <= TimelineSnapping.snapPx { target = playheadFrame; view.snapType = .playhead }
        }
        var delta = target.rounded() - g.hit.frame
        if var range = keyframeDeltaRange(g.moving) {
            // One diamond stays strictly between its row neighbours (clampToNeighbors), so it never lands on another key.
            if g.moving == g.hit.refs, let (_, c) = clip(g.hit.clipId) {
                let scope = g.hit.laneRow.flatMap { view.rowScope($0, c) } ?? g.hit.lane.flatMap { c.lanes.indices.contains($0) ? [c.lanes[$0].group] : nil }
                let row = view.authoredDiamondFrames(c, scope: scope)
                let lo = max(range.lowerBound, (row.filter { $0 < g.hit.frame }.max() ?? -.infinity) + 1 - g.hit.frame)
                let hi = min(range.upperBound, (row.filter { $0 > g.hit.frame }.min() ?? .infinity) - 1 - g.hit.frame)
                range = lo <= hi ? lo...hi : 0...0
            }
            delta = max(range.lowerBound, min(range.upperBound, delta))
        } else { delta = 0 }
        view.keyframeDrag = TimelineKeyframeDragPreview(refs: g.moving, deltaFrames: delta)
        view.keyframeSnapTime = view.snapType == .playhead && delta == target.rounded() - g.hit.frame ? playback.currentTime : nil
        needsDisplay?()
    }

    /// Release: a drag commits one move (one undo step); a click selects the key (⇧ toggles).
    internal func keyframePointerUp() {
        guard let g = keyframeGesture else { return }
        let delta = view.keyframeDrag?.deltaFrames ?? 0
        keyframeGesture = nil; view.keyframeDrag = nil; view.keyframeSnapTime = nil; view.snapType = nil; cursor = .normal
        if g.moved {
            if delta != 0 { moveKeyframes(g.moving, deltaFrames: delta) }
            else if g.moving == g.hit.refs { selectKeyframe(g.hit, additive: false) }
        } else {
            selectKeyframe(g.hit, additive: g.shift)
        }
        needsDisplay?()
    }

    /// Hovered diamond (the original's ew-resize / pointer cursor).
    internal func keyframeHover(x: Double, y: Double) -> Bool {
        guard let hit = view.keyframeHit(x: x, y: y) else {
            if view.hoveredKeyframe != nil { view.hoveredKeyframe = nil; needsDisplay?() }
            return false
        }
        if view.hoveredKeyframe != hit { view.hoveredKeyframe = hit; needsDisplay?() }
        let cur: Cursor = view.tracks.indices.contains(hit.row) && view.tracks[hit.row].locked ? .pointer : .resize
        if cur != cursor || view.hoveredClip != hit.clipId { cursor = cur; view.hoveredClip = hit.clipId; needsDisplay?() }
        return true
    }

    /// Drop selected keys that no longer exist in the document (after an edit, undo or reload).
    internal func pruneKeyframeSelection() {
        guard !view.selectedKeyframes.isEmpty else { return }
        var live = Set<TimelineKeyframeRef>()
        for t in view.tracks { for c in t.clips { for ch in c.channels { for f in ch.frames { live.insert(.init(clipId: c.id, parameterId: ch.parameterId, frame: f)) } } } }
        view.selectedKeyframes.formIntersection(live)
    }
}

struct KeyframeGesture {
    var hit: TimelineKeyframeHit
    var x0: Double, y0: Double, shift: Bool
    var moving: Set<TimelineKeyframeRef>
    var moved: Bool, locked: Bool
}
