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
import MpvfxTimeline
import MpvfxPanels
import MpvfxDesktopCore

/// Timeline callbacks the app answers (group rows, toolbar, Remove silence):
/// the audio-group FX button and name open the bus rack in the inspector; Remove silence analyses the selected
/// video's media through the backend and cuts the silent spans in one undo step.
extension EditorSession {
    func installTimelineHooks() {
        timeline.onOpenGroupFx = { [weak self] groupId, _ in self?.openAudioGroupRack(groupId) }
        timeline.onOpenGroupFxRack = { [weak self] groupId in self?.openAudioGroupRack(groupId) }
        timelineRegion?.toolbar.onRemoveSilence = { [weak self] clipId in self?.removeSilence(clipId: clipId) }
        timeline.onNativeAudioAction = { [weak self] clipId, action in self?.nativeAudioAction(clipId: clipId, action) }
        timeline.onAddText = { [weak self] time in self?.addText(at: time) }
        // onAddBeat stays unset: the toolbar's own addBeat(at:) is used, and the button is enabled only once a music clip
        // has beat analysis (beatMusicClipId), which the native app does not produce yet.
    }

    /// T: a new text layer at the playhead, selected, with its Text section open in Design.
    func addText(at time: Double) {
        guard let panels, let id = editor.addTextClip(at: time) else { return }
        timeline.view.selection = [id]
        syncStage()
        let inspector = panels.right.inspector
        inspector.audioGroupId = nil
        inspector.selection = [id]
        inspector.openGroupId = "text"
        panels.right.layout.setRightCollapsed(false)
        panels.right.layout.setRightTab(.design)
        redraw()
    }

    /// Selects the bus (clearing the clip selection) and shows its FX rack in Design.
    func openAudioGroupRack(_ groupId: String) {
        guard let panels, editor.audioGroup(groupId) != nil else { return }
        timeline.view.selection = []
        syncStage()
        let inspector = panels.right.inspector
        inspector.selection = []
        inspector.audioGroupId = groupId
        inspector.openGroupId = "audio-fx"
        panels.right.layout.setRightCollapsed(false)
        panels.right.layout.setRightTab(.design)
        redraw()
    }

    /// useNativeAudioActions handleNativeAudioAction: detach probes the video's file for an audio stream first
    /// ("This video has no audio stream"); either edit is one undo step and its refusal is shown as an error toast.
    func nativeAudioAction(clipId: String, _ action: TimelineController.NativeAudioAction) {
        let toast: (String, Bool) -> Void = { [weak self] m, e in self?.player.view.showToast(m, isError: e); self?.redraw() }
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            guard ok else { toast(self.editor.lastFailure?.message ?? "Video audio edit failed", true); return }
            self.playback.duration = self.editor.duration
            self.syncStage(); self.redraw()
        }
        if action == .reattach { finish(editor.reattachAudio(clipId: clipId)); return }
        guard let (_, original) = editor.clip(clipId),
              let source = editor.document.assets.first(where: { $0.id == original.assetId && $0.kind == .video })?.source, !source.isEmpty else {
            toast("Select a video clip to detach audio", true); return
        }
        guard let backend, let projectId = project?.id else { toast("Could not verify this video's audio stream", true); return }
        Task { [weak self] in
            let streams = try? await backend.mediaStreams(projectId: projectId, source: source)
            self?.postToUI {
                guard let self, self.project?.id == projectId else { return }
                guard let streams else { toast("Could not verify this video's audio stream", true); return }
                guard streams.hasAudio else { toast("This video has no audio stream", true); return }
                guard self.editor.clip(clipId) != nil else { toast("The selected native clip is no longer available", true); return }
                finish(self.editor.detachAudio(clipId: clipId, hasAudioStream: true))
            }
        }
    }

    /// useRemoveSilence handleRemoveSilence for a native clip: detect silence over the clip's source span, check the clip
    /// did not change during analysis, then cut (TimelineEditor.removeSilence snaps to frames and is one undo step).
    func removeSilence(clipId: String) {
        guard let toolbar = timelineRegion?.toolbar, !toolbar.isRemovingSilence else { return }
        let toast: (String, Bool) -> Void = { [weak self] m, e in self?.player.view.showToast(m, isError: e); self?.redraw() }
        guard let backend, let projectId = project?.id else { toast("No active project", true); return }
        guard let (_, original) = editor.clip(clipId),
              let asset = editor.document.assets.first(where: { $0.id == original.assetId }), asset.kind == .video, let source = asset.source, !source.isEmpty else {
            toast("Select a video clip with a media source", true); return
        }
        guard !editor.isClipLocked(clipId) else { toast("This video clip cannot be edited", true); return }
        let fps = editor.fps
        let rate = original.playbackRate.map { $0.denominator != 0 ? $0.numerator / $0.denominator : 1 } ?? 1
        let sourceStart = original.sourceInFrame / fps, duration = original.durationFrames / fps
        toolbar.isRemovingSilence = true
        redraw()
        Task { [weak self] in
            let result: Result<[DesktopTimeRange], Error>
            do { result = .success(try await backend.silences(projectId: projectId, source: source, sourceStart: sourceStart,
                                                               sourceDuration: duration * rate)) }
            catch { result = .failure(error) }
            self?.postToUI {
                guard let self else { return }
                toolbar.isRemovingSilence = false
                defer { self.redraw() }
                guard self.project?.id == projectId else { toast("Project changed during silence removal. No further edits were applied.", true); return }
                let ranges: [SilenceRange]
                switch result {
                case .failure(let e): toast((e as? DesktopError)?.message ?? "Failed to remove silence", true); return
                case .success(let r): ranges = r.map { SilenceRange(start: $0.start, end: $0.end) }
                }
                guard let (_, live) = self.editor.clip(clipId), live == original else {
                    toast("The selected clip changed during analysis. Run silence removal again.", true); return
                }
                let plan = TimelineSilencePlan(start: original.startFrame / fps, duration: duration, sourceStart: sourceStart, rate: rate, silences: ranges)
                let removed = plan.removed.isEmpty ? 0 : self.editor.removeSilence(clipId: clipId, sourceSilences: ranges)
                guard removed > 0 else { toast("No silence found in the selected clip.", false); return }
                self.timeline.view.selection = []
                self.playback.duration = self.editor.duration
                self.syncStage()
                toast("Removed \(plan.removed.count) silences, \(String(format: "%.1f", removed))s", false)
            }
        }
    }
}
