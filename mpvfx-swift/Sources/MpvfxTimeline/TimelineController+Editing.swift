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

/// Editing actions exposed to every shell: ripple, track ops, duplicate, select all.
public extension TimelineController {
    // MARK: Selection

    /// ⌘A: select every clip on the visible tracks.
    @discardableResult func selectAll() -> Bool {
        let ids = Set(view.tracks.flatMap(\.clips).map(\.id))
        guard !ids.isEmpty else { return false }
        view.selection = ids; needsDisplay?(); return true
    }

    // MARK: Ripple

    /// ⇧Delete: delete the selection and close the holes it leaves on each lane.
    @discardableResult func rippleDeleteSelection() -> Bool {
        guard let editor, !view.selection.isEmpty else { return false }
        guard editor.rippleDelete(view.selection) else { return false }
        view.selection = []; needsDisplay?(); return true
    }

    /// Ripple trim a clip edge to `time` (seconds), snapped to the frame grid.
    @discardableResult func rippleTrim(clipId: String, edge: TrimEdge, to time: Double) -> Bool {
        guard let editor else { return false }
        return editor.rippleTrim(clipId: clipId, edge: edge, toFrame: (time * editor.fps).rounded())
    }

    /// Close the gap at `time` on the track at display row `row`.
    @discardableResult func closeGap(row: Int, at time: Double) -> Bool {
        guard let editor, view.tracks.indices.contains(row), !view.tracks[row].locked else { return false }
        return editor.closeGap(trackId: view.tracks[row].id, at: time)
    }

    /// Close every gap on the track at display row `row`.
    @discardableResult func closeAllGaps(row: Int) -> Bool {
        guard let editor, view.tracks.indices.contains(row), !view.tracks[row].locked else { return false }
        return editor.closeAllGaps(trackId: view.tracks[row].id)
    }

    /// Close every gap on every unlocked track.
    @discardableResult func closeAllGapsEverywhere() -> Bool { editor?.closeAllGapsEverywhere() ?? false }

    // MARK: Duplicate

    /// ⌘D: duplicate the one selected clip right after itself on its track; the clipboard is left
    /// alone (useClipboard handleDuplicate). More than one selected clip is refused.
    @discardableResult func duplicateSelection() -> Bool {
        guard let editor, view.selection.count == 1, let id = view.selection.first, let (_, c) = clip(id) else { return false }
        guard let board = editor.copyClips([id]) else { return false }
        let ids = editor.paste(board, at: c.end)
        guard !ids.isEmpty else { return false }
        view.selection = Set(ids); needsDisplay?(); return true
    }

    // MARK: Tracks (by display row)

    /// Add an empty track below row `row` (nil = at the bottom). Returns the new track id.
    @discardableResult func addTrack(kind: NativeProjectTrackKind, below row: Int? = nil) -> String? {
        guard let editor else { return nil }
        return editor.addTrack(kind: kind, at: row.map { displayIndex(forRow: $0) + 1 })
    }

    /// Remove the track at display row `row` with its clips.
    @discardableResult func removeTrack(row: Int) -> Bool {
        guard let editor, view.tracks.indices.contains(row) else { return false }
        return editor.removeTrack(view.tracks[row].id)
    }

    /// Move the track at display row `row` up (-1) or down (+1).
    @discardableResult func moveTrack(row: Int, by delta: Int) -> Bool {
        guard let editor, view.tracks.indices.contains(row) else { return false }
        let id = view.tracks[row].id
        guard let from = editor.displayTrackIds.firstIndex(of: id) else { return false }
        return editor.moveTrack(id, to: from + delta)
    }

    @discardableResult func toggleTrackHidden(row: Int) -> Bool {
        guard let editor, view.tracks.indices.contains(row) else { return false }
        return editor.setTrackHidden(view.tracks[row].id, !view.tracks[row].hidden)
    }

    @discardableResult func toggleTrackLocked(row: Int) -> Bool {
        guard let editor, view.tracks.indices.contains(row) else { return false }
        return editor.setTrackLocked(view.tracks[row].id, !view.tracks[row].locked)
    }

    @discardableResult func toggleTrackMuted(row: Int) -> Bool {
        guard let editor, view.tracks.indices.contains(row) else { return false }
        return editor.setTrackMuted(view.tracks[row].id, !view.tracks[row].muted)
    }

    /// Display row -> index in the full (uncollapsed) display order.
    internal func displayIndex(forRow row: Int) -> Int {
        guard let editor, view.tracks.indices.contains(row) else { return row }
        return editor.displayTrackIds.firstIndex(of: view.tracks[row].id) ?? row
    }
}

/// Clip, audio and history actions for the shells and the inspector / side panels.
/// Panels may call the TimelineEditor methods directly too; wrap a continuous gesture (slider drag)
/// in `editor.withHistory(label, coalesceKey:)` so it lands as one undo entry.
public extension TimelineController {
    /// Hide the selected clips, or show them when every one is already hidden (timeline eye toggle).
    @discardableResult func toggleSelectionHidden() -> Bool {
        guard let editor, !view.selection.isEmpty else { return false }
        let allHidden = view.selection.allSatisfy { editor.isClipHidden($0) }
        return editor.setClipsHidden(view.selection, !allHidden)
    }

    /// Group the selected audio/video clips onto a new audio bus. Returns the group id.
    @discardableResult func groupSelectedAudio(label: String? = nil) -> String? {
        editor?.createAudioGroup(clipIds: view.selection.sorted(), label: label)
    }

    /// Insert an asset at the playhead (useTimelineAddAtPlayhead) and select it.
    @discardableResult func insertAtPlayhead(assetId: String, trackId: String? = nil) -> String? {
        guard let editor, let id = editor.insertClip(assetId: assetId, at: playback.currentTime, trackId: trackId) else { return nil }
        view.selection = [id]; needsDisplay?(); return id
    }

    /// Remove silence from the one selected clip; `silences` are source-time ranges from analysis.
    @discardableResult func removeSilenceFromSelection(_ silences: [SilenceRange]) -> Double {
        guard let editor, view.selection.count == 1, let id = view.selection.first else { return 0 }
        let removed = editor.removeSilence(clipId: id, sourceSilences: silences)
        if removed > 0 { view.selection = []; needsDisplay?() }
        return removed
    }

    var undoLabel: String? { editor?.undoLabel }
    var redoLabel: String? { editor?.redoLabel }
    @discardableResult func undo() -> Bool { editor?.undo() ?? false }
    @discardableResult func redo() -> Bool { editor?.redo() ?? false }
}
