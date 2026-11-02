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
// Cut transitions on the timeline, by pointer and keyboard: ⌘T adds the default transition at the cut nearest the playhead
// and ⇧⌘T on every cut between the selected clips; a click selects a band, dragging an edge resizes it (stopping at the
// media), ⌥← / ⌥→ walk from cut to cut, ⌥[ / ⌥] shorten and lengthen by a frame (⇧ ten), Delete removes and Enter opens it
// in the inspector. Every edit is one undo step; a refusal says why through the editor's notice.
import Foundation

extension TimelineController {
    // MARK: Hit testing

    /// The band under a point on track `row`, with the edge when the point is on one of its grab strips.
    func transitionHit(row: Int, x: Double, y: Double) -> Hit? {
        for t in view.tracks[row].transitions.reversed() {
            let r = view.transitionRect(row: row, t)
            guard x >= r.x, x <= r.maxX, y >= r.y, y <= r.maxY else { continue }
            let w = min(TimelineView.transitionEdgePx, r.width / 3)
            return .transition(id: t.id, row: row, edge: x <= r.x + w ? .start : x >= r.maxX - w ? .end : nil)
        }
        return nil
    }

    /// The cut under a point: the meeting of two touching clips of one track, within a few points of the boundary.
    func cutHit(x: Double, y: Double) -> TimelineCut? {
        guard let editor, x >= TimelineLayout.contentOrigin, let (band, localY) = view.band(atY: y), case .track(let row) = band,
              localY < view.trackHeight else { return nil }
        let frame = view.time(forX: x) * editor.fps
        let tolerance = max(1, 5 / max(view.pixelsPerSecond, 1e-9) * editor.fps)
        return editor.cut(nearFrame: frame, toleranceFrames: tolerance, trackId: view.tracks[row].id)
    }

    // MARK: Press, drag, release

    func transitionPointerDown(id: String, edge: TrimEdge?) {
        view.selectedKeyframes = []
        view.selectedTransitionId = id
        view.selectedCut = editor?.cut(ofTransition: id)
        if let t = transition(id) { view.selection = [t.fromClipId] }
        guard let edge, let t = transition(id) else { return }
        // The fixed edge of an aligned transition sits on the cut: only the free one resizes.
        let free: Bool
        switch t.alignment { case "endsAtCut": free = edge == .start; case "startsAtCut": free = edge == .end; default: free = true }
        guard free else { return }
        gesture = .transitionResize(id: id, edge: edge)
        view.transitionDrag = (id, t.durationFrames)
        cursor = .resize
    }

    func transition(_ id: String) -> TimelineTransitionModel? {
        for track in view.tracks { if let t = track.transitions.first(where: { $0.id == id }) { return t } }
        return nil
    }

    /// The length the pointer at `x` asks for: twice the distance to the cut for a centred transition, the distance
    /// from the cut for an aligned one, in whole frames and never below 2.
    func transitionResizeLength(_ t: TimelineTransitionModel, x: Double, fps: Double) -> Double {
        let frame = (view.time(forX: x) * fps).rounded()
        let cut = (t.cut * fps).rounded()
        let wanted: Double
        switch t.alignment {
        case "endsAtCut": wanted = cut - frame
        case "startsAtCut": wanted = frame - cut
        default: wanted = 2 * abs(frame - cut)
        }
        return max(2, wanted)
    }

    func transitionResizeMove(_ id: String, x: Double) {
        guard let editor, let t = transition(id) else { return }
        let wanted = transitionResizeLength(t, x: x, fps: editor.fps)
        let limit = editor.maxTransitionLength(id: id) ?? t.durationFrames
        let length = min(wanted, max(2, limit))
        view.transitionDrag = (id, length)
        view.transitionHint = wanted > limit ? "At most \(Self.framesText(limit)): the clips have no more media for this transition" : nil
        needsDisplay?()
    }

    /// Commits the dragged length as one undo step; a refusal is told through the editor's notice.
    func transitionResizeCommit(_ id: String) {
        defer { view.transitionDrag = nil; view.transitionHint = nil }
        guard let editor, let drag = view.transitionDrag, drag.id == id else { return }
        report(editor.setTransitionLength(id: id, frames: drag.frames), editor: editor)
    }

    static func framesText(_ n: Double) -> String { n == 1 ? "1 frame" : "\(Int(n.rounded())) frames" }

    /// Hands a refusal or a shortening to the host's notice.
    func report(_ outcome: TransitionApplyOutcome, editor: TimelineEditor) {
        switch outcome {
        case .refused(let why): editor.onNotice?(why)
        case .applied(let length, let from?): editor.onNotice?("Shortened to \(Self.framesText(length)) (\(Self.framesText(from)) wanted): the clips have no more media.")
        case .applied: break
        }
    }

    // MARK: Keyboard

    /// ⌘T (the cut nearest the playhead) and ⇧⌘T (every cut between the selected clips).
    func addTransitionShortcut(everyCut: Bool) -> Bool {
        guard let editor else { return false }
        if everyCut {
            let outcomes = editor.addDefaultTransitions(forSelection: view.selection)
            if outcomes.isEmpty { editor.onNotice?("Select two or more touching clips that have no transition between them yet.") }
            for outcome in outcomes { report(outcome, editor: editor) }
            needsDisplay?(); return true
        }
        let frame = (playback.currentTime * editor.fps).rounded()
        let outcome = editor.addDefaultTransition(nearFrame: frame, selection: view.selection)
        report(outcome, editor: editor)
        if outcome.applied, let cut = editor.nearestCut(toFrame: frame, selection: view.selection) {
            view.selectedCut = cut
            view.selectedTransitionId = editor.transition(on: cut)?.id
        }
        needsDisplay?(); return true
    }

    /// ⌥← / ⌥→: selects the previous or next cut on the selected clip's track and puts the playhead on it, so ⌘T acts
    /// there and the band, if there is one, is selected.
    func walkToAdjacentCut(forward: Bool) -> Bool {
        guard let editor else { return false }
        let frame = (playback.currentTime * editor.fps).rounded()
        let trackId = editor.transitionTrackId(selection: view.selection)
        guard let cut = editor.adjacentCut(from: view.selectedCut, atFrame: frame, forward: forward, trackId: trackId) else { return true }
        view.selectedCut = cut
        view.selectedTransitionId = editor.transition(on: cut)?.id
        view.selection = [cut.fromClipId]
        playback.seek(cut.frame / editor.fps); syncFromPlayback()
        needsDisplay?(); return true
    }

    /// ⌥[ / ⌥]: one frame shorter or longer (⇧ ten).
    func nudgeSelectedTransition(by delta: Double) -> Bool {
        guard let editor, let id = view.selectedTransitionId, let t = transition(id) else { return false }
        report(editor.setTransitionLength(id: id, frames: t.durationFrames + delta), editor: editor)
        needsDisplay?(); return true
    }

    /// Delete / Backspace on a selected transition: removes it (one undo step), leaving a hard cut.
    func removeSelectedTransition() -> Bool {
        guard let editor, let id = view.selectedTransitionId else { return false }
        if editor.applyTransition(.remove(id: id)) { view.selectedTransitionId = nil }
        else if let why = editor.lastFailure?.message { editor.onNotice?(why) }
        needsDisplay?(); return true
    }

    /// Enter on a selected transition: the host opens its group in the inspector.
    func openSelectedTransition() -> Bool {
        guard let id = view.selectedTransitionId else { return false }
        onEditTransition?(id); return true
    }
}
