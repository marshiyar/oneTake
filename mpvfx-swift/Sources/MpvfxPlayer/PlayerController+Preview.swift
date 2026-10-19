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

/// Gesture recording, asset drops, arrow-key nudge, gesture cancel and persisted preferences.
extension PlayerController {
    /// Work done at the start of each draw: sample the recording, commit a settled nudge, persist a settled zoom.
    func frameTick() {
        recordingTick()
        // The crop tool and the selection chrome stand down while playing (shouldShowSelectedDomBounds).
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

    // MARK: Gesture recording

    /// Turns on the tools bar Record button and the R key. `document` reads the open document; `commit` stores the
    /// recorded one as a single undo step and returns whether it was accepted.
    public func enableGestureRecording(engine: KeyframeEngine? = nil, document: @escaping () -> NativeProjectDocument?,
                                       commit: @escaping (_ edited: NativeProjectDocument, _ before: NativeProjectDocument) -> Bool) {
        recordingEngine = engine
        recordingDocument = document
        onRecordingCommit = commit
        view.toolbar.onToggleRecording = { [weak self] in self?.toggleRecording() }
    }

    public var isRecording: Bool { recorder != nil }

    /// handleToggleRecording: start on the selected element at the playhead, or stop and commit.
    public func toggleRecording() {
        if recorder != nil { stopRecording(commit: true); return }
        guard view.selectedIds.count == 1, let e = selected else { view.showToast("Select an element first", isError: true); needsDisplay?(); return }
        guard let doc = recordingDocument?() else { view.showToast("Native keyframing is not ready for this recording", isError: true); needsDisplay?(); return }
        let pb = view.playback
        let start = pb.currentTime >= pb.duration - 1e-9 ? 0 : pb.currentTime   // play() rewinds from the very end
        guard let base = GestureKeyframes.base(doc, clipId: e.id, time: start, engine: recordingEngine) else {
            view.showToast("This layer is not available for native gesture recording", isError: true); needsDisplay?(); return
        }
        if view.cropActive { cancelCrop() }
        gesture = nil
        recorder = GestureRecorder(clipId: e.id, startTime: start, fps: pb.fps, base: base, viewScale: view.scale(in: size), pointer: lastPointer)
        recordingStart = e
        recordingProjectId = doc.id
        let clipEnd = doc.sequence.tracks.lazy.flatMap(\.clips).first { $0.id == e.id }.map { ($0.startFrame + $0.durationFrames) / max(pb.fps, 1) }
        recordingLimit = min(clipEnd ?? .infinity, pb.duration)
        view.toolbar.recording = .recording
        view.recordingTrail = []
        // Recording runs on the transport clock: forward at 1×, from the playhead (the original seeks per frame).
        if pb.isPlaying { pb.pause() }
        pb.togglePlay()
        needsDisplay?()
    }

    /// One display frame while recording: sample the pointer at the transport time, preview it on the element,
    /// and stop at the clip's end, the composition's end, or when playback stops.
    func recordingTick() {
        guard var r = recorder else { return }
        let pb = view.playback
        let time = max(0, pb.currentTime - r.startTime)
        if r.tick(time: time) {
            recorder = r
            view.recordingTrail = r.trail
            preview(r)
        }
        if !pb.isPlaying || (recordingLimit > 0 && pb.currentTime >= recordingLimit - 0.05) { stopRecording(commit: true) }
    }

    /// Shows the live values on the recorded element (position, rotation, opacity, scale).
    func preview(_ r: GestureRecorder) {
        guard let start = recordingStart, let i = view.elements.firstIndex(where: { $0.id == r.clipId }) else { return }
        var e = view.elements[i]
        if let x = r.live["x"] { e.rect.x = start.rect.x + x - r.base.x }
        if let y = r.live["y"] { e.rect.y = start.rect.y + y - r.base.y }
        if let a = r.live["rotation"] { e.rotation = a }
        if let o = r.live["opacity"] { e.opacity = o }
        if let s = r.live["scale"] { e.scale = s }
        view.elements[i] = e
    }

    /// stopAndCommitRecording: freeze the samples, pause, write the keyframes (one undo step), seek back to the start.
    public func stopRecording(commit: Bool) {
        guard let r = recorder else { return }
        recorder = nil
        view.toolbar.recording = .idle
        view.recordingTrail = []
        let pb = view.playback
        if pb.isPlaying { pb.pause() }
        defer {
            if let i = view.elements.firstIndex(where: { $0.id == r.clipId }), let s = recordingStart {
                view.elements[i].opacity = nil; view.elements[i].scale = nil
                if view.elements[i].rect != s.rect || view.elements[i].rotation != s.rotation { view.elements[i].rect = s.rect; view.elements[i].rotation = s.rotation }
            }
            recordingStart = nil
            pb.seek(r.startTime)
            needsDisplay?()
        }
        guard commit else { return }
        guard let doc = recordingDocument?(), doc.id == recordingProjectId else {
            view.showToast("Recording cancelled because the active project changed"); return
        }
        let samples = r.samples
        let duration = samples.last?.time ?? 0
        let bounds = recordingStart.map { NativeSelectionBounds(width: $0.rect.width, height: $0.rect.height) }
        do {
            let (edited, count) = try GestureKeyframes.apply(doc, clipId: r.clipId, startTime: r.startTime, duration: duration,
                                                             samples: samples, bounds: bounds, engine: recordingEngine)
            guard onRecordingCommit?(edited, doc) == true else {
                view.showToast("Gesture commit failed: the recording could not be saved", isError: true); return
            }
            view.showToast("Recorded \(count) keyframes")
        } catch let f as GestureKeyframes.Failure {
            view.showToast(f.message, isError: true)
        } catch {
            view.showToast("Gesture commit failed: \(error)", isError: true)
        }
    }

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

    /// The speed menu picked a rate (setPlaybackRate persists it; J/L shuttle speeds are not saved).
    public func playbackRateChosen(_ rate: Double) { preferences?.save(PreviewPreferences(playbackRate: rate)) }
    /// The volume slider moved.
    public func volumeChosen(_ volume: Double) { preferences?.save(PreviewPreferences(audioVolume: max(0, min(1, volume)))) }

    // MARK: Fullscreen and global keys

    /// Keys the preview answers from any focus (dispatchPlainAppKey): F toggles fullscreen, R records a gesture.
    public func globalKey(_ k: EditorKey) -> Bool {
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
    public func usePreferences(_ store: PreviewPreferencesStore) {
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
