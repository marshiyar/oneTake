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
import MpvfxColor
import MpvfxPanels
import MpvfxPlayer
import MpvfxTimeline

/// Picking the colour key from the stage (issue #300): the inspector's eyedropper waits for one click on the selected
/// layer, then reads the clip's ungraded frame at that place (a 5 x 5 average) and writes it as the key colour. The
/// same click can key a grade secondary instead. Both are one undo step and neither changes the view mode.
extension EditorSession {
    static let pickKeyColorLabel = "Pick key color"
    /// Longest side of the frame the pick reads.
    static let pickFrameSize = 640

    /// The clip's frame with no grade applied (id, time, largest width, largest height): the preview renderer's
    /// unless a test supplies one.
    func rawFrame(_ clipId: String, _ time: Double) -> PresetPreviewRenderer.State {
        let n = Self.pickFrameSize
        if let rawFrameProvider { return rawFrameProvider(clipId, time, n, n) }
        return panels?.presetPreviews?.rawFrame(clipId: clipId, time: time, pixelWidth: n, pixelHeight: n) ?? .unavailable
    }

    /// Tells the stage which clips have an enabled colour key, so an Option-press on one shows its source while held.
    func installColorKeyView() {
        player.colorKeyActive = { [weak self] id in self?.editor.isColorKeyEnabled(clipId: id) ?? false }
    }

    /// Starts the stage eyedropper for the key colour.
    func pickKeyColorFromStage() {
        startStagePick { [weak self] clipId, frame, x, y in
            guard let self, let rgb = ColorKeyMatte.average(rgba: frame.rgba, width: frame.width, height: frame.height,
                                                          x: Int(x), y: Int(y), radius: 2) else { return }
            var key = self.editor.colorKey(clipId: clipId) ?? ColorKeySettings()
            key.color = [rgb.x, rgb.y, rgb.z]
            self.editor.setColorKey(clipId: clipId, key, label: Self.pickKeyColorLabel)
            self.syncStage(); self.redraw()
        }
    }

    /// Starts the stage eyedropper for the selected grade secondary.
    func pickSecondaryColorFromStage() {
        startStagePick { [weak self] clipId, frame, x, y in
            guard let self, let inspector = self.panels?.right.inspector else { return }
            inspector.applyPickedSecondaryColor(clipId: clipId, frame: frame, x: x, y: y)
            self.syncStage(); self.redraw()
        }
    }

    /// Waits for the click, fetches the ungraded frame at the playhead and calls `apply` with the pixel under the click.
    private func startStagePick(_ apply: @escaping (_ clipId: String, _ frame: CanvasImage, _ x: Double, _ y: Double) -> Void) {
        let inspector = panels?.right.inspector
        let started = player.startEyedropper(onEnd: { [weak inspector] in inspector?.keyEyedropperActive = false }) { [weak self] clipId, unit in
            self?.fetchRawFrame(clipId, tries: 40) { frame in
                apply(clipId, frame, min(Double(frame.width - 1), max(0, (unit.x * Double(frame.width)).rounded(.down))),
                      min(Double(frame.height - 1), max(0, (unit.y * Double(frame.height)).rounded(.down))))
            }
        }
        inspector?.keyEyedropperActive = started
        redraw()
    }

    /// The raw frame, asked for again for a while when it is still rendering.
    private func fetchRawFrame(_ clipId: String, tries: Int, _ done: @escaping (CanvasImage) -> Void) {
        switch rawFrame(clipId, playback.currentTime) {
        case .ready(let img): done(img)
        case .rendering:
            guard tries > 0, let schedule else { return }
            _ = schedule(0.05) { [weak self] in self?.fetchRawFrame(clipId, tries: tries - 1, done) }
        case .unavailable: break
        }
    }
}
