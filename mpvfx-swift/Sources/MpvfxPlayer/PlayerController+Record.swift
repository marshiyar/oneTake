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

/// Record motion: the Record control (or R) arms the stage; a press on the selected layer or one of its handles
/// starts a take that plays from the playhead while the layer follows the drag by its grab offset; release
/// commits the take as one undo step, Esc cancels it. Nothing moves the system cursor, and hover moves never
/// drive a layer.
extension PlayerController {
    /// The undo entry one take makes.
    public static let recordMotionUndoLabel = "Record motion"
    static let readyRecordMessage = "Drag the selected layer to record its motion"
    static let notReadyMessage = "Keyframing is not ready yet; try again in a moment"

    /// Turns on the tools bar Record control and the R key. `document` reads the open document; `commit` stores the
    /// recorded one as a single undo step and returns whether it was accepted.
    public func enableGestureRecording(engine: KeyframeEngine? = nil, document: @escaping () -> NativeProjectDocument?,
                                       commit: @escaping (_ edited: NativeProjectDocument, _ before: NativeProjectDocument) -> Bool) {
        recordingEngine = engine
        recordingDocument = document
        onRecordingCommit = commit
        view.toolbar.onToggleRecording = { [weak self] in self?.toggleRecording() }
    }

    /// Record is armed: the next press on the selected layer starts a take.
    public var isRecordArmed: Bool { recordArmed }
    /// A take is in progress (the button is held on the layer).
    public var isRecording: Bool { recorder != nil }

    /// The Record control and R: arm, or disarm (a take in progress is kept first).
    public func toggleRecording() {
        if recorder != nil { finishTake() }
        if recordArmed { disarmRecording() } else { armRecording() }
    }

    public func armRecording() {
        guard recordingDocument != nil, !recordArmed else { return }
        if view.cropActive { cancelCrop() }
        _ = cancelGesture()
        recordArmed = true
        refreshRecordOverlay(); needsDisplay?()
    }

    /// Leaves Record mode; a take in progress is cancelled (its keys are never written).
    public func disarmRecording() {
        guard recordArmed else { return }
        if recorder != nil { stopRecording(commit: false) }
        recordArmed = false
        refreshRecordOverlay(); needsDisplay?()
    }

    /// Esc for Record from any focus: hosts call it before panels that consume Esc (the timeline does), so Esc
    /// cancels a take or disarms wherever the focus is. Returns whether Record used the key.
    public func recordEscapeKey(_ k: EditorKey) -> Bool {
        guard k.code == .escape, !k.command, !k.alt else { return false }
        return recordEscape()
    }

    /// Esc: cancels the take in progress, else disarms. Returns whether Record used the key.
    func recordEscape() -> Bool {
        if recorder != nil { cancelTake(); return true }
        if recordArmed { disarmRecording(); return true }
        return false
    }

    /// Why a press on the selection would not record, or nil when it starts a take.
    public func recordBlocker() -> String? {
        guard let e = selected else {
            return view.selectedIds.isEmpty ? "Select a layer, then drag it to record its motion" : "Select one layer to record its motion"
        }
        guard let doc = recordingDocument?() else { return Self.notReadyMessage }
        return Self.layerBlocker(doc, clipId: e.id)
    }

    /// Locked and hidden layers are never recorded.
    static func layerBlocker(_ doc: NativeProjectDocument, clipId: String) -> String? {
        for track in doc.sequence.tracks {
            guard let clip = track.clips.first(where: { $0.id == clipId }) else { continue }
            if track.locked == true { return "This layer's track is locked; unlock it to record" }
            if track.hidden == true || clip.hidden == true { return "This layer is hidden; show it to record" }
            return nil
        }
        return "This layer is not on the timeline"
    }

    /// The Record control's state and the stage banner, from the current selection and take.
    func refreshRecordOverlay() {
        view.toolbar.recording = recorder != nil ? .recording : recordArmed ? .armed : .idle
        guard recordArmed else { view.recordOverlay = nil; return }
        if let r = recorder {
            view.recordOverlay = RecordOverlay(state: .recording, message: "Release to finish, Esc to cancel", elapsed: r.duration)
            return
        }
        let blocker = recordBlocker()
        view.recordOverlay = RecordOverlay(state: blocker == nil ? .ready : .blocked, message: blocker ?? Self.readyRecordMessage)
    }

    // MARK: Takes

    /// Whether Record handles this stage press: a take in progress swallows it, and armed Record routes it to
    /// `recordPress`. False: the stage's normal tools take it.
    func recordTakesPress(_ p: CanvasPoint, shift: Bool) -> Bool {
        if recorder != nil { return true }
        guard recordArmed else { return false }
        recordPress(p, shift: shift)
        return true
    }

    /// A stage press while armed: on the selected layer or a handle it starts a take; elsewhere it only selects or
    /// starts a marquee, so no layer moves.
    func recordPress(_ p: CanvasPoint, shift: Bool) {
        defer { refreshRecordOverlay(); needsDisplay?() }
        guard recorder == nil else { return }
        if let e = selected, pressHitsSelection(p, e) {
            if let reason = recordBlocker() { view.showToast(reason, isError: true) } else { startTake(e, at: p) }
            return
        }
        if let hit = hitElement(p) {
            var ids = shift ? view.selectedIds : []
            if let i = ids.firstIndex(of: hit.id) { ids.remove(at: i) } else { ids.append(hit.id) }
            setSelection(ids)
        } else if view.frameRect(in: size).contains(p) {
            if !shift { setSelection([]) }
            gesture = .marquee(x: p.x, y: p.y, additive: shift)
        } else {
            setSelection([])
        }
    }

    /// The press lands on the selected layer's visible box, a corner handle, the rotate handle, or any handle a
    /// stage tool reports through `extraHandleHit` (the hook new handles use so a press on them starts a take too).
    func pressHitsSelection(_ p: CanvasPoint, _ e: StageElement) -> Bool {
        let ve = view.chromeElement(e, in: size)
        let lp = local(p, ve), r = ve.visibleRect
        if lp.x >= r.x && lp.x <= r.maxX && lp.y >= r.y && lp.y <= r.maxY { return true }
        if extraHandleHit?(p, ve) == true { return true }
        let rh = view.rotateHandleCentre(ve)
        if hypot(rh.x - p.x, rh.y - p.y) <= 11 { return true }
        return PlayerView.HandleCorner.allCases.contains { h in
            let c = view.handleCentre(h, of: r)
            return abs(c.x - lp.x) <= PlayerView.handleHit / 2 && abs(c.y - lp.y) <= PlayerView.handleHit / 2
        }
    }

    /// Starts a take on `e` grabbed at `p`: the transport runs forward at 1x from the playhead.
    func startTake(_ e: StageElement, at p: CanvasPoint) {
        guard let doc = recordingDocument?() else { view.showToast(Self.notReadyMessage, isError: true); return }
        let pb = view.playback
        let start = pb.currentTime >= pb.duration - 1e-9 ? 0 : pb.currentTime   // play() rewinds from the very end
        guard let base = GestureKeyframes.base(doc, clipId: e.id, time: start, engine: recordingEngine) else {
            view.showToast("This layer can't be keyframed, so it can't be recorded", isError: true); return
        }
        recorder = GestureRecorder(clipId: e.id, startTime: start, fps: pb.fps, base: base, viewScale: view.scale(in: size),
                                   pointer: p, anchored: true, modifiers: modifiers)
        recordingStart = e
        recordingProjectId = doc.id
        pressPoint = p; dragEngaged = false
        let clip = doc.sequence.tracks.lazy.flatMap(\.clips).first { $0.id == e.id }
        let clipEnd = clip.map { ($0.startFrame + $0.durationFrames) / max(pb.fps, 1) }
        recordingLimit = min(clipEnd ?? .infinity, pb.duration)
        view.recordingTrail = []
        if pb.isPlaying { pb.pause() }
        pb.togglePlay()
    }

    /// A move while the button is held: feeds the take (deltas from the grab point).
    func recordMove(_ p: CanvasPoint) {
        if !dragEngaged, hypot(p.x - pressPoint.x, p.y - pressPoint.y) >= Self.dragThreshold { dragEngaged = true }
        recorder?.pointerMoved(p, modifiers: modifiers)
    }

    /// Release, pause or the clip's end: a take that moved (or used the wheel) is committed with its final pointer
    /// state; a press that never moved writes nothing.
    func finishTake() {
        guard let r = recorder else { return }
        if dragEngaged {
            recorder?.finish(time: max(0, view.playback.currentTime - r.startTime))
            stopRecording(commit: true); return
        }
        stopRecording(commit: false)
        view.showToast("Nothing recorded: hold the button and drag the layer")
    }

    /// Esc during a take: the layer goes back and its keys stay as they were.
    func cancelTake() {
        guard recorder != nil else { return }
        stopRecording(commit: false)
        view.showToast("Take cancelled; the keyframes are unchanged")
    }

    /// One display frame during a take: sample the pointer at the transport time, preview it on the layer, and end
    /// the take at the clip's end, the composition's end, or when playback stops.
    func recordingTick() {
        guard var r = recorder else {
            if recordArmed { refreshRecordOverlay() }   // the selection may have changed from the timeline
            return
        }
        let pb = view.playback
        let time = max(0, pb.currentTime - r.startTime)
        if r.tick(time: time) {
            recorder = r
            view.recordingTrail = r.trail
            preview(r)
        }
        if !pb.isPlaying || (recordingLimit > 0 && pb.currentTime >= recordingLimit - 0.05) { finishTake() }
        refreshRecordOverlay()
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

    /// Ends the take: pause, put the live layer back, seek to the take's start, and when `commit` write the keyframes
    /// (one undo step). Record stays armed for the next take.
    public func stopRecording(commit: Bool) {
        guard let r = recorder else { return }
        recorder = nil
        view.recordingTrail = []
        let pb = view.playback
        if pb.isPlaying { pb.pause() }
        if commit { commitTake(r) }
        restoreRecordedElement(r)
        pb.seek(r.startTime)
        refreshRecordOverlay()
        needsDisplay?()
    }

    /// The stage drops the live preview; the document (with or without the new keys) drives the layer again.
    func restoreRecordedElement(_ r: GestureRecorder) {
        if let i = view.elements.firstIndex(where: { $0.id == r.clipId }), let s = recordingStart {
            view.elements[i].opacity = s.opacity; view.elements[i].scale = s.scale
            view.elements[i].rect = s.rect; view.elements[i].rotation = s.rotation
        }
        recordingStart = nil
    }

    func commitTake(_ r: GestureRecorder) {
        guard let doc = recordingDocument?(), doc.id == recordingProjectId else {
            view.showToast("Recording cancelled because the active project changed"); return
        }
        let duration = r.samples.last?.time ?? 0
        let bounds = recordingStart.map { NativeSelectionBounds(width: $0.rect.width, height: $0.rect.height) }
        do {
            let (edited, count) = try GestureKeyframes.apply(doc, clipId: r.clipId, startTime: r.startTime, duration: duration,
                                                             samples: r.samples, bounds: bounds, engine: recordingEngine)
            guard onRecordingCommit?(edited, doc) == true else {
                view.showToast("The take could not be saved; the keyframes are unchanged", isError: true); return
            }
            view.showToast("Recorded \(count) keyframes")
        } catch let f as GestureKeyframes.Failure {
            view.showToast(f.message, isError: true)
        } catch {
            view.showToast("The take could not be recorded: \(error)", isError: true)
        }
    }
}
