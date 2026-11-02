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
import MpvfxAudio
import MpvfxAudioGraph
import MpvfxPanels
import MpvfxShared

extension EditorSession {
    /// ⌥⌘D, the clip menu and the Audio FX rack: shows the Make room for voice sheet at the top of the inspector.
    func openMakeRoomForVoice() {
        guard let panels else { return }
        let inspector = panels.right.inspector
        let selected = timeline.view.selection.sorted()
        if Set(inspector.selection) != Set(selected) { inspector.selection = selected }
        inspector.audioGroupId = nil
        panels.right.layout.setRightCollapsed(false)
        panels.right.layout.setRightTab(.design)
        inspector.openVoiceRoomSheet()
        redraw()
    }

    /// Finds the speech off the UI thread, then lowers the beds as one undo step and says what it did, with a Re-run.
    func makeRoomForVoice(_ run: VoiceRoomSheet.Run) {
        let request = VoiceRoomPlanner.Request(mode: run.mode == .carve ? .carve : .volume, settings: run.settings,
                                               voiceClipIds: run.voiceClipIds, bedClipIds: run.bedClipIds)
        let document = editor.document, directory = projectDir
        player.view.showToast("Finding the speech…")
        redraw()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try VoiceRoomPlanner.plan(request, document: document, projectDir: directory) }
            self?.postToUI { self?.finishMakingRoom(result, snapshot: document) }
        }
    }

    func finishMakingRoom(_ result: Result<VoiceRoomPlanner.Outcome, Error>, snapshot: NativeProjectDocument) {
        let title = "Could not make room for voice"
        switch result {
        case .failure(let error):
            onError(title, (error as? VoiceRoomPlanner.Failure)?.description ?? "The sound of a clip could not be read. Check that its file is still there, then try again.")
        case .success(let outcome):
            guard editor.document == snapshot else {
                onError(title, "The project changed while the speech was being found. Make room again."); return
            }
            guard editor.setClipsAudio(automation: outcome.automation, fxChains: outcome.fxChains, label: "Make room for voice") else {
                onError(title, "The clips could not be changed. Unlock their tracks, then try again."); return
            }
            syncStage()
            player.view.showToast(outcome.summary, action: (label: "Re-run", run: { [weak self] in self?.panels?.right.inspector.rerunVoiceRoom() }))
            redraw()
        }
    }
}
