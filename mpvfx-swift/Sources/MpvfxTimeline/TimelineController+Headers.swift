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

/// Track header clicks (track tag, lock, eye / speaker, solo, FX) and the header's hover and status-line hint.
public extension TimelineController {
    /// What a header click did, for hosts and tests.
    enum HeaderAction: Equatable, Sendable {
        case toggledHidden(row: Int), toggledMuted(row: Int)
        case toggledLocked(row: Int), toggledSoloed(row: Int)
        /// The tag was clicked: `targeted` is the track's new state.
        case toggledTarget(row: Int, targeted: Bool)
        case openedFx(clipId: String)
        case groupPointer(row: Int)
        case openedGroupFx(groupId: String), openedGroupRack(groupId: String)
    }

    /// Route a click on track header `row`: tag → target, lock → lock, eye → hide, speaker (audio rows) → mute,
    /// headphones → solo, FX → `onOpenClipFx`, group pointer → select the track's clips and group them
    /// (`onRequestGroupName` first when set, the "Name this group" dialog, which then calls `groupSelectedAudio(label:)`).
    @discardableResult
    func headerClick(x: Double, y: Double, row: Int) -> HeaderAction? {
        guard view.tracks.indices.contains(row), let control = view.headerControl(atX: x, y: y, row: row) else { return nil }
        let action = perform(control, row: row, at: CanvasRect(x: x, y: y, width: 0, height: 0))
        lastHeaderAction = action
        needsDisplay?()
        return action
    }

    /// A header click on a track whose control the user pressed.
    internal func perform(_ control: TimelineHeaderControl, row: Int, at point: CanvasRect) -> HeaderAction {
        let track = view.tracks[row]
        switch control {
        case .target:
            return .toggledTarget(row: row, targeted: view.trackTargets.toggle(track.id, in: view.tracks))
        case .lock:
            toggleTrackLocked(row: row); return .toggledLocked(row: row)
        case .visibility:
            if track.kind == "audio" { toggleTrackMuted(row: row); return .toggledMuted(row: row) }
            toggleTrackHidden(row: row); return .toggledHidden(row: row)
        case .solo:
            toggleTrackSoloed(row: row); return .toggledSoloed(row: row)
        case .fx(let clipId):
            view.selection = [clipId]
            onOpenClipFx?(clipId, view.headerControls(row: row).first { $0.control == control }?.rect ?? point)
            return .openedFx(clipId: clipId)
        case .groupPointer:
            view.selection = Set(track.clips.map(\.id))
            if let ask = onRequestGroupName { ask(track.clips.count, track.name) } else { groupSelectedAudio(label: track.name) }
            return .groupPointer(row: row)
        }
    }

    /// Solo or unsolo the track on `row` (one undo step; allowed on a locked track).
    @discardableResult func toggleTrackSoloed(row: Int) -> Bool {
        guard let editor, view.tracks.indices.contains(row) else { return false }
        return editor.setTrackSoloed(view.tracks[row].id, !view.tracks[row].soloed)
    }

    /// The targeted track a clip of `assetId` added at `time` goes onto: the target of the asset's family (V for
    /// pictures, A for sound) when it is unlocked and free for the clip's frames, else nil, so the editor picks the
    /// first free lane as before (TimelineEditor.insertClip).
    func targetedInsertTrack(assetId: String, at time: Double) -> String? {
        guard let editor, let asset = editor.document.assets.first(where: { $0.id == assetId }) else { return nil }
        let family: TimelineTrackTargets.Family = asset.kind == .audio ? .audio : .video
        guard let id = view.trackTargets.target(family, in: view.tracks),
              let track = editor.document.sequence.tracks.first(where: { $0.id == id }), track.locked != true else { return nil }
        // Frame counts, rounded the way insertClip rounds them.
        let start = max(0, (time * editor.fps).rounded()), end = start + max(1, asset.durationFrames.rounded())
        let busy = track.clips.contains { $0.startFrame < end && start < $0.startFrame + $0.durationFrames }
        return busy ? nil : id
    }

    /// Pointer over the timeline with no gesture: tracks the header control under it. Returns whether it changed.
    @discardableResult func updateHeaderHover(_ hit: Hit, x: Double, y: Double) -> Bool {
        var hover: TimelineHeaderHover?
        if case .header(let row) = hit, let control = view.headerControl(atX: x, y: y, row: row) {
            hover = TimelineHeaderHover(row: row, control: control)
        }
        guard hover != view.hoveredHeader else { return false }
        view.hoveredHeader = hover
        needsDisplay?()
        return true
    }

    /// Status-line text for the header control under the pointer (nil elsewhere).
    var headerHint: String? {
        guard let h = view.hoveredHeader, view.tracks.indices.contains(h.row) else { return nil }
        return Self.hint(h.control, track: view.tracks[h.row], tag: view.trackTags[h.row],
                         targeted: view.targetedTrackIds.contains(view.tracks[h.row].id))
    }

    internal static func hint(_ control: TimelineHeaderControl, track: TimelineTrackModel, tag: String, targeted: Bool) -> String {
        switch control {
        case .target:
            return targeted ? "\(tag) is targeted: clips added at the playhead go here. Click to release it"
                : "Target \(tag): clips added at the playhead go onto this track"
        case .lock: return track.locked ? "Unlock \(tag)" : "Lock \(tag) against edits"
        case .visibility: return visibilityHint(track, tag: tag)
        case .solo: return track.soloed ? "Unsolo \(tag)" : "Solo \(tag): hear only soloed tracks"
        case .fx, .groupPointer: return "Audio effects for \(tag)"
        }
    }

    internal static func visibilityHint(_ track: TimelineTrackModel, tag: String) -> String {
        if track.kind == "audio" { return track.muted ? "Unmute \(tag)" : "Mute \(tag)" }
        return track.hidden ? "Show \(tag)" : "Hide \(tag)"
    }

    /// Group header (TimelineGroupHeader): FX button → `onOpenGroupFx`, name button → `onOpenGroupFxRack`.
    @discardableResult
    func groupHeaderClick(_ id: String, x: Double, y: Double) -> Bool {
        guard let g = view.groups.first(where: { $0.id == id }), let top = view.groupHeaderTop(id) else { return false }
        let fx = view.groupFxRect(g, top: top)
        if x >= fx.x && x <= fx.maxX && y >= fx.y && y <= fx.maxY {
            onOpenGroupFx?(id, fx); lastHeaderAction = .openedGroupFx(groupId: id); needsDisplay?(); return true
        }
        let name = view.groupNameRect(top: top)
        if x >= name.x && x <= name.maxX && y >= name.y && y <= name.maxY {
            onOpenGroupFxRack?(id); lastHeaderAction = .openedGroupRack(groupId: id); needsDisplay?(); return true
        }
        return false
    }
}
