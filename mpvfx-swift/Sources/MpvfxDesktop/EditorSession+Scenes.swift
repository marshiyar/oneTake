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
import MpvfxDesktopCore

extension EditorSession {
    /// Keyboard equivalents while the timeline or player has focus.
    func sceneSplitKey(_ key: EditorKey) -> Bool {
        guard let toolbar = timelineRegion?.toolbar, toolbar.onSplitScenes != nil else { return false }
        if key.code == .escape, toolbar.sceneProgress != nil { toolbar.onSplitScenes?(); return true }
        guard key.command, key.alt, !key.shift, case .char(let char) = key.code else { return false }
        switch char.lowercased() {
        case "s": toolbar.activate(.splitScenes)
        case "[": toolbar.adjustSceneThreshold(increase: false)
        case "]": toolbar.adjustSceneThreshold(increase: true)
        default: return false
        }
        return true
    }

    func installSceneSplitHook() {
        guard let toolbar = timelineRegion?.toolbar else { return }
        var task: Task<Void, Never>?
        var cancelled = false
        toolbar.onSplitScenes = { [weak self, weak toolbar] in
            guard let self, let toolbar else { return }
            if let task { cancelled = true; task.cancel(); return }
            let toast: (String, Bool) -> Void = { [weak self] message, error in
                self?.player.view.showToast(message, isError: error); self?.redraw()
            }
            guard let backend = self.backend, let project = self.project,
                  self.timeline.view.selection.count == 1, let id = self.timeline.view.selection.first,
                  let (_, clip) = self.editor.clip(id), !self.editor.isClipLocked(id),
                  let asset = self.editor.document.assets.first(where: { $0.id == clip.assetId && $0.kind == .video }),
                  let source = asset.source else { toast("Select an editable video clip with a media source", true); return }
            guard clip.speedRamp == nil, clip.holdSourceFrame == nil else {
                toast("Scene splitting requires a video without a speed ramp or held frame", true); return
            }
            let rate = clip.playbackRate.map { $0.numerator / $0.denominator } ?? 1
            guard rate.isFinite, rate > 0 else { toast("Invalid clip playback rate", true); return }
            let fps = self.editor.fps
            let sourceStart = sourceFrameValue(.init(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction)) / fps
            let threshold = toolbar.sceneThreshold, original = self.editor.document
            toolbar.sceneProgress = 0; cancelled = false; self.redraw()
            task = Task { [weak self, weak toolbar] in
                let result: Result<[Double], Error>
                do {
                    result = .success(try await backend.sceneCuts(projectId: project.id, source: source,
                        sourceStart: sourceStart, sourceDuration: clip.durationFrames / fps * rate,
                        framesPerSecond: fps / rate, threshold: threshold, onProgress: { [weak self, weak toolbar] progress in
                            self?.postToUI { toolbar?.sceneProgress = progress; self?.redraw() }
                        }))
                } catch { result = .failure(error) }
                self?.postToUI {
                    guard let self, let toolbar else { return }
                    defer { task = nil; toolbar.sceneProgress = nil; self.redraw() }
                    guard !cancelled else { toast("Scene analysis cancelled; no clips changed", false); return }
                    guard self.project?.id == project.id, self.editor.document == original else {
                        toast("Project changed during scene analysis; run it again", true); return
                    }
                    switch result {
                    case .failure(let error): toast((error as? DesktopError)?.message ?? "Scene analysis failed; run it again", true)
                    case .success(let cuts):
                        guard !cuts.isEmpty else { toast("No scene changes found at this threshold", false); return }
                        guard self.editor.splitScenes(clipId: id, sourceTimes: cuts) else {
                            toast(self.editor.lastFailure?.message ?? "Scene splits could not be applied", true); return
                        }
                        self.syncStage()
                        toast("Split at \(cuts.count) scene changes", false)
                    }
                }
            }
        }
    }
}
