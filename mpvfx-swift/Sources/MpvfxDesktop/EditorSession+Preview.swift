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
import MpvfxShared
import MpvfxTimeline
import MpvfxPlayer
import MpvfxPanels

/// Preview features that need the document or the user-data folder: persisted snap/grid/zoom, Record motion takes
/// committed as keyframes (one undo step), assets dropped on the stage, and the z-order "crossed" flash.
extension EditorSession {
    func installPreview(userData: String) {
        // Every document change (inspector, media bin, timeline, undo, reload) re-evaluates the composition and the
        // stage, whichever path made it.
        let previousOnChange = editor.onChange
        editor.onChange = { [weak self] in previousOnChange?(); self?.syncStage(); self?.redraw() }
        let prefs = FilePreviewPreferencesStore.at(userData: userData)
        player.attachPreferencesStore(prefs)
        if let v = prefs.load().audioVolume { transport.volume.volume = v }
        let rateChange = transport.speed.onRateChange, volumeChange = transport.volume.onChange
        transport.speed.onRateChange = { [weak self] r in rateChange?(r); self?.player.playbackRateChosen(r) }
        transport.volume.onChange = { [weak self] v, m in volumeChange?(v, m); self?.player.volumeChosen(v) }
        player.enableGestureRecording(engine: engine, document: { [weak self] in self?.editor.document }) { [weak self] edited, before in
            guard let self, self.editor.document == before else { return false }
            self.editor.withHistory(PlayerController.recordMotionUndoLabel) { self.editor.replaceDocument(edited, inverse: .restoreDocument(before)) }
            self.syncStage(); self.redraw()
            return true
        }
        player.onInsertAsset = { [weak self] assetId, time in
            guard let self, let id = self.editor.insertClip(assetId: assetId, at: time,
                                                            trackId: self.timeline.targetedInsertTrack(assetId: assetId, at: time)) else { return nil }
            self.timeline.view.selection = [id]
            self.syncStage(); self.redraw()
            return id
        }
        player.onZOrder = { [weak self] ids, action in self?.applyZOrderShowingCrossed(ids, action) }
    }

    /// Bring forward / send backward on one element flashes the sibling it stepped over (resolveCrossedNeighbor).
    func applyZOrderShowingCrossed(_ ids: [String], _ action: StageZOrderAction) {
        var crossed: String?
        if ids.count == 1, action == .bringForward || action == .sendBackward {
            let stack = zStack()
            if let i = stack.firstIndex(where: { $0.id == ids[0] }) {
                let j = action == .bringForward ? i + 1 : i - 1
                if stack.indices.contains(j) { crossed = stack[j].id }
            }
        }
        applyZOrder(ids, action)
        if let crossed { player.view.flashZOrderCrossed(crossed); redraw() }
    }
}
