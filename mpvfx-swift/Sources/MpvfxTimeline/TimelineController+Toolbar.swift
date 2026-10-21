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

/// Toolbar actions on the controller, so keys, menus and the drawn toolbar share them.
public extension TimelineController {
    /// Media row height from the track-height presets (rounded, 32...96).
    func setTrackHeight(_ height: Double) {
        let before = view.trackHeight
        view.trackHeight = height
        guard view.trackHeight != before else { return }
        clampScroll()
        onTrackHeightChange?(view.trackHeight)
        needsDisplay?()
    }

    /// thumbnailMode adaptive (true) / hidden (false); hosts persist it (studioUiPreferences thumbnailMode).
    func setThumbnailsEnabled(_ on: Bool) {
        guard view.thumbnailsEnabled != on else { return }
        view.thumbnailsEnabled = on
        onThumbnailModeChange?(on)
        needsDisplay?()
    }

    /// K / toolbar diamond: toggle the position keyframe at the playhead on the one selected visual clip.
    @discardableResult func togglePositionKeyframeOnSelection() -> Bool {
        guard let editor, view.selection.count == 1, let id = view.selection.first, let (row, c) = clip(id),
              c.kind != .audio, !view.tracks[row].locked else { return false }
        return editor.togglePositionKeyframe(clipId: id, time: playback.currentTime)
    }

    /// Toolbar split (onSplitElement): the one selected clip at the playhead, when the playhead is strictly inside.
    @discardableResult func splitSelectedAtPlayhead() -> Bool {
        guard let editor, view.selection.count == 1, let id = view.selection.first, let (row, c) = clip(id),
              !view.tracks[row].locked else { return false }
        let frame = (playback.currentTime * editor.fps).rounded()
        let t = frame / editor.fps
        guard t > c.start, t < c.end else { return false }
        return editor.split([id], atFrame: frame)
    }

    /// ⇧H / ⌥⇧H pressed: whether the hold was made; nil for any other key.
    func holdKey(_ k: EditorKey) -> Bool? {
        guard !k.command, k.shift, case .char(let ch) = k.code, ch.lowercased() == "h" else { return nil }
        return holdFrameAtPlayhead(overwrite: k.alt)
    }

    /// ⇧H (insert) / ⌥⇧H (overwrite): hold the frame under the playhead of the selected video clip there (else the
    /// video clip on top there) for `holdSeconds`, and select the hold. A refusal is reported through `onEditRefused`.
    @discardableResult func holdFrameAtPlayhead(overwrite: Bool) -> Bool {
        guard let editor else { return false }
        // The frame on screen at the playhead (PreviewComposition.frameIndex), not the nearest frame boundary.
        let frame = (playback.currentTime * editor.fps + 1e-6).rounded(.down)
        guard let target = editor.holdTarget(atFrame: frame, selection: view.selection) else {
            onEditRefused?("Move the playhead onto a video clip to hold its frame"); return false
        }
        guard let length = editor.holdFrames(seconds: holdSeconds),
              let id = editor.holdFrame(clipId: target.clipId, atFrame: frame, lengthFrames: length, overwrite: overwrite) else {
            onEditRefused?(editor.lastFailure?.message ?? "The frame could not be held"); return false
        }
        view.selection = [id]
        needsDisplay?()
        return true
    }

    /// Add a beat to the grid at `time` unless one is already there (within a millisecond).
    @discardableResult func addBeat(at time: Double) -> Bool {
        guard time.isFinite, time >= 0, !view.beats.contains(where: { abs($0.time - time) < 0.001 }) else { return false }
        view.beats.append(TimelineBeat(time: time))
        view.beats.sort { $0.time < $1.time }
        needsDisplay?(); return true
    }
}
