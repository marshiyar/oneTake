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
import MpvfxTimeline
import MpvfxShared

/// The per-draw tick, asset drops, arrow-key nudge, gesture cancel and persisted preferences (Record motion is in
/// PlayerController+Record.swift).
extension PlayerController {
    /// Work done at the start of each draw: sample the recording, commit a settled nudge, persist a settled zoom.
    func frameTick() {
        recordingTick()
        // The crop tool and selection chrome stand down while playing.
        if view.playback.isPlaying, view.cropActive { cancelCrop() }
        if let store = preferences, view.playback.audioMuted != savedMuted {
            savedMuted = view.playback.audioMuted
            store.save(PreviewPreferences(audioMuted: savedMuted))
        }
        let t = view.now()
        if let at = nudgeAt, t - at >= Self.nudgeCommitSeconds { flushNudge() }
        if let at = zoomTouchedAt, t - at >= PlayerView.zoomSettleSeconds { zoomTouchedAt = nil; persistZoom() }
    }

    var wantsFrames: Bool { recorder != nil || nudgeAt != nil || zoomTouchedAt != nil }

    // MARK: Asset drop (a hook for the media bin / library panels)

    /// A library or media asset dragged over the preview at a player-local point. Returns whether a drop there
    /// would be taken (and highlights the stage while it would).
    @discardableResult
    public func assetDragMoved(x: Double, y: Double) -> Bool {
        let accepts = onInsertAsset != nil && recorder == nil && view.viewportRect(in: size).contains(CanvasPoint(x, y))
        if accepts != view.assetDropActive { view.assetDropActive = accepts; needsDisplay?() }
        return accepts
    }

    /// The drag left the preview or was cancelled.
    public func assetDragEnded() {
        if view.assetDropActive { view.assetDropActive = false; needsDisplay?() }
    }

    /// Drops an asset on the preview: it is placed on the timeline at the playhead (TimelineEditor.insertClip) and selected.
    /// Returns the new clip id, or nil when the point is outside the preview or the asset can't be placed.
    @discardableResult
    public func dropAsset(_ assetId: String, x: Double, y: Double) -> String? {
        defer { assetDragEnded() }
        guard recorder == nil, view.viewportRect(in: size).contains(CanvasPoint(x, y)), let insert = onInsertAsset,
              let id = insert(assetId, view.playback.currentTime) else { return nil }
        if view.elements.contains(where: { $0.id == id }) { setSelection([id]) } else {
            view.selectedIds = [id]; onSelect?(id); onSelectionChange?([id])
        }
        needsDisplay?()
        return id
    }

    // MARK: Arrow-key nudge and gesture cancel

    public static let nudgeStep = 1.0, nudgeShiftStep = 10.0

    /// Plain or ⇧ arrows move the selection 1 / 10 composition px; a burst commits after 400 ms idle.
    func nudgeKey(_ k: EditorKey) -> Bool {
        guard !k.ctrl, !k.meta, !k.alt, gesture == nil, recorder == nil, !view.cropActive, !view.selectedIds.isEmpty else { return false }
        let step = k.shift ? Self.nudgeShiftStep : Self.nudgeStep
        var dx = 0.0, dy = 0.0
        switch k.code {
        case .left: dx = -step; case .right: dx = step; case .up: dy = -step; case .down: dy = step
        default: return false
        }
        let ids = view.selectedIds
        let targets = view.elements.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return false }
        for e in targets where !nudgeStarts.contains(where: { $0.id == e.id }) { nudgeStarts.append(e) }
        for e in targets { update(e.id) { $0.rect.x += dx; $0.rect.y += dy } }
        nudgeAt = view.now()
        view.requestAnimationFrame?()
        needsDisplay?()
        return true
    }

    /// Commits a pending nudge burst (one commit per moved element).
    public func flushNudge() {
        guard !nudgeStarts.isEmpty else { nudgeAt = nil; return }
        let starts = nudgeStarts
        nudgeStarts = []; nudgeAt = nil
        let changed = starts.compactMap { st in view.elements.first { $0.id == st.id && $0 != st } }
        for e in changed { onCommit?(e) }
        needsDisplay?()
    }

    /// Esc during a drag puts the elements back where the gesture started (cancelCanvasGesture).
    func cancelGesture() -> Bool {
        guard let g = gesture else { return false }
        gesture = nil
        view.snapGuides = []; view.spacingGuides = []
        switch g {
        case let .move(id, start, _, _), let .resize(id, _, start, _), let .rotate(id, start, _), let .crop(id, _, start):
            update(id) { $0 = start }
        case let .group(starts, _, _):
            for st in starts { update(st.id) { $0 = st } }
        case .marquee:
            view.marquee = nil; view.marqueeCandidates = []
        case .pan: break
        }
        needsDisplay?()
        return true
    }

    /// Esc, innermost first: a take, a drag, the menu, the grid popover, the crop tool, armed Record, fullscreen.
    func escapeKey() -> Bool {
        if recorder != nil { return recordEscape() }
        if cancelGesture() { return true }
        if view.contextMenu != nil { view.contextMenu = nil; needsDisplay?(); return true }
        if view.toolbar.gridPopoverOpen { view.toolbar.gridPopoverOpen = false; needsDisplay?(); return true }
        if view.cropActive { cancelCrop(); return true }
        if recordEscape() { return true }   // disarms Record
        if view.isFullscreen { view.isFullscreen = false; needsDisplay?(); return true }   // Esc leaves fullscreen
        return false
    }

    /// The speed menu picked a rate (setPlaybackRate persists it; J/L shuttle speeds are not saved).
    public func playbackRateChosen(_ rate: Double) { preferences?.save(PreviewPreferences(playbackRate: rate)) }
    /// The volume slider moved.
    public func volumeChosen(_ volume: Double) { preferences?.save(PreviewPreferences(audioVolume: max(0, min(1, volume)))) }

    // MARK: Fullscreen and global keys

    /// Keys the preview answers from any focus (dispatchPlainAppKey): F toggles fullscreen, R arms or disarms Record,
    /// Esc cancels a take or disarms Record.
    public func globalKey(_ k: EditorKey) -> Bool {
        if k.code == .escape, !k.command, !k.alt { return recordEscape() }
        guard !k.command, !k.alt, !k.shift, !k.isRepeat, case .char(let ch) = k.code else { return false }
        switch ch {
        case "f", "F": view.isFullscreen.toggle(); needsDisplay?(); return true
        case "r", "R":
            guard let toggle = view.toolbar.onToggleRecording else { return false }
            toggle(); return true
        default: return false
        }
    }

    // MARK: Preferences

    /// Restores snap, grid and zoom from `store` and saves every later change back to it.
    public func attachPreferencesStore(_ store: PreviewPreferencesStore) {
        preferences = store
        let p = store.load()
        let tb = view.toolbar
        tb.snapEnabled = p.snapEnabled ?? true
        tb.gridVisible = p.gridVisible ?? false
        tb.gridDivisions = p.resolvedGridSpacing
        tb.snapToGrid = p.snapToGrid ?? false
        view.zoom = p.initialZoom
        savedZoom = view.zoom
        if let r = p.playbackRate { view.playback.setPlaybackRate(r) }
        if let m = p.audioMuted { view.playback.audioMuted = m }
        savedMuted = view.playback.audioMuted
        clampZoomToViewport()
        tb.onPrefsChange = { [weak store] tb in
            store?.save(PreviewPreferences(snapEnabled: tb.snapEnabled, gridVisible: tb.gridVisible, gridSpacing: tb.gridDivisions, snapToGrid: tb.snapToGrid))
        }
    }

    /// A pan persisted on a large window can restore the frame mostly off-screen in a smaller one: clamp it.
    public func clampZoomToViewport() {
        guard size.width > 0, size.height > 0, !view.zoom.isAtFit else { return }
        let vp = view.viewportRect(in: size), f = view.fittedRect(in: size)
        let (x, y) = PreviewZoom.clampPan(x: view.zoom.panX, y: view.zoom.panY, percent: view.zoom.percent,
                                          viewport: CanvasSize(vp.width, vp.height), content: CanvasSize(f.width, f.height))
        view.zoom.panX = x; view.zoom.panY = y
    }

    func zoomTouched() {
        guard preferences != nil else { return }
        zoomTouchedAt = view.now()
        view.requestAnimationFrame?()
    }

    /// Writes the settled zoom (the original writes it 200 ms after the last wheel event).
    func persistZoom() {
        guard let store = preferences, view.zoom != savedZoom else { return }
        savedZoom = view.zoom
        store.save(PreviewPreferences(previewZoom: view.zoom))
    }
}
