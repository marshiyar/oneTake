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
import MpvfxShared

/// Modifier keys held at a press. `command` is ⌘ on macOS and Ctrl elsewhere.
public struct TimelineGestureKeys: Equatable, Sendable {
    public var shift = false, alt = false, command = false
    public init(shift: Bool = false, alt: Bool = false, command: Bool = false) { self.shift = shift; self.alt = alt; self.command = command }
}

/// Slip and roll gestures. Slip: the slip tool (Y), or ⌘/Ctrl+⌥ drag on a clip. Roll: the roll tool, or ⇧ drag on a
/// clip edge. Both show a live preview and commit once on release (one undo step); Esc cancels like any drag.
extension TimelineController {
    /// A press on a clip: a slip or roll gesture first, else ⇧/⌘ toggles the clip in the selection, else the clip is
    /// selected and a trim (on an edge, ripple with ⌥) or a move may start. A locked track selects but never edits.
    func clipPointerDown(_ hit: Hit, x: Double, y: Double, keys: TimelineGestureKeys) {
        guard case let .clip(id, row, edge) = hit else { return }
        if let g = slipRollGesture(hit, x: x, keys: keys) { beginSlipRoll(g, clipId: id, additive: tool == .select); return }
        if keys.shift || keys.command { toggleSelected(id); return }
        if !view.selection.contains(id) { view.selection = [id] }
        // Keyframe selections stay on one clip: pressing another clip's body drops them.
        if view.selectedKeyframes.contains(where: { $0.clipId != id }) { view.selectedKeyframes = [] }
        guard !view.tracks[row].locked else { return }
        if let edge { gesture = .trim(clipId: id, edge: edge, ripple: keys.alt) } else { gesture = .pendingMove(clipId: id, row: row, x: x, y: y) }
    }

    func toggleSelected(_ id: String) {
        if view.selection.contains(id) { view.selection.remove(id) } else { view.selection.insert(id) }
    }

    /// The hovered clip and cursor with no gesture running: resize on a trim handle, pointer on a body, and the slip
    /// and roll cursors under those tools.
    func hoverState(_ hit: Hit) -> (clipId: String?, cursor: Cursor) {
        guard case let .clip(id, _, edge) = hit else { return (nil, slipRollHover(hit, cursor: .normal)) }
        return (id, slipRollHover(hit, cursor: edge != nil ? .resize : .pointer))
    }

    /// The slip or roll gesture a press starts, or nil for the ordinary select / move / trim handling.
    func slipRollGesture(_ hit: Hit, x: Double, keys: TimelineGestureKeys) -> Gesture? {
        guard case let .clip(id, row, edge) = hit, !view.tracks[row].locked else { return nil }
        // A still or text clip under the slip tool starts the gesture too; it previews and commits nothing.
        if tool == .slip || (keys.command && keys.alt) { return .slip(clipId: id, x: x) }
        if let edge, tool == .roll || (keys.shift && !keys.command) { return .roll(clipId: id, edge: edge) }
        return nil
    }

    /// `additive`: the gesture came from a modifier (⇧ edge, ⌘⌥ body) under the select tool, so the press keeps its
    /// ⇧/⌘-click meaning and toggles the clip in the selection; a press that never drags changes nothing else.
    func beginSlipRoll(_ g: Gesture, clipId: String, additive: Bool) {
        if additive { toggleSelected(clipId) } else { view.selection = [clipId] }
        if view.selectedKeyframes.contains(where: { $0.clipId != clipId }) { view.selectedKeyframes = [] }
        gesture = g
        if case .slip = g { cursor = .slip } else { cursor = .roll }
    }

    func slipRollMove(_ g: Gesture, x: Double) {
        switch g {
        case let .slip(id, x0): slipMove(id, dx: x - x0)
        case let .roll(id, edge): rollMove(id, edge: edge, x: x)
        default: return
        }
        needsDisplay?()
    }

    /// The content follows the pointer: dragging right reveals earlier source, so the in-point moves back.
    func slipMove(_ id: String, dx: Double) {
        guard let editor, let range = editor.slipRange(clipId: id) else { return }
        let frames = -(dx / max(view.pixelsPerSecond, 1e-9) * editor.fps).rounded()
        let delta = min(max(frames, range.lowerBound), range.upperBound) + 0   // + 0 turns -0 into 0
        view.drag = .slip(clipId: id, deltaFrames: delta, sourceShift: editor.sourceFraction(clipId: id, timelineFrames: delta))
    }

    /// A cut with a clip on both sides rolls inside `rollRange`; an edge with a gap behind it previews a plain trim.
    func rollMove(_ id: String, edge: TrimEdge, x: Double) {
        guard let editor, let (_, c) = clip(id) else { return }
        let partner = editor.rollPartner(clipId: id, edge: edge)
        let excluded = Set([id, partner].compactMap { $0 })
        let targets = snapEnabled ? TimelineSnapping.targets(clips: snapClips, playhead: playback.currentTime, beats: view.beats.map(\.time), excluding: excluded) : []
        let s = TimelineSnapping.snap(view.time(forX: x), targets, thresholdSecs: TimelineSnapping.snapPx / max(view.pixelsPerSecond, 1))
        view.snapType = s.target?.type
        guard let partner else {
            let minDur = 1 / max(editor.fps, 1)
            let t = edge == .start ? max(0, min(c.end - minDur, s.time)) : max(c.start + minDur, s.time)
            view.drag = .trim(clipId: id, edge: edge, time: t, snapTime: s.target?.time)
            return
        }
        guard let range = editor.rollRange(clipId: id, edge: edge) else { return }
        let frame = min(max((s.time * editor.fps).rounded(), range.lowerBound), range.upperBound)
        let (outgoing, incoming) = edge == .end ? (id, partner) : (partner, id)
        view.drag = .roll(outgoingId: outgoing, incomingId: incoming, time: frame / editor.fps)
    }

    func commitSlipRoll(_ drag: TimelineDragPreview) {
        guard let editor else { return }
        switch drag {
        case let .slip(id, delta, _): editor.slip(clipId: id, byFrames: delta)
        case let .roll(outgoing, _, t): editor.roll(clipId: outgoing, edge: .end, toFrame: (t * editor.fps).rounded())
        default: break
        }
    }

    /// The hover cursor under the slip and roll tools; the roll tool also marks the cut it would roll.
    /// Redraws when the marked cut moves or goes away, even while the hovered clip and the cursor stay the same.
    func slipRollHover(_ hit: Hit, cursor current: Cursor) -> Cursor {
        let before = view.rollHover
        let cursor = slipRollCursor(hit, current)
        if before?.row != view.rollHover?.row || before?.time != view.rollHover?.time { needsDisplay?() }
        return cursor
    }

    private func slipRollCursor(_ hit: Hit, _ current: Cursor) -> Cursor {
        view.rollHover = nil
        guard tool == .slip || tool == .roll, case let .clip(id, row, edge) = hit, !view.tracks[row].locked else { return current }
        if tool == .slip { return .slip }
        guard let edge, let c = clip(id)?.clip else { return current }
        if editor?.rollPartner(clipId: id, edge: edge) != nil { view.rollHover = (row, edge == .end ? c.end : c.start) }
        return .roll
    }
}
