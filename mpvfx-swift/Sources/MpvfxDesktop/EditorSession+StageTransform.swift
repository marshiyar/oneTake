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
import MpvfxPlayer
import MpvfxTimeline

/// Stage transform commits: every element one stage gesture changed (a drag, a group move, a nudge burst, crop
/// Apply) lands as one undo step, its crop and its transform together; and the move readout shows the position
/// the inspector shows (transform.position, the offset from the clip's laid-out box).
extension EditorSession {
    static let stageTransformLabel = "Transform layer"

    func installStageTransform() {
        player.onCommitGroup = { [weak self] es in self?.stageCommitted(es) }
        player.readoutOrigin = { [weak self] e in
            guard let self else { return nil }
            let base = self.stageBase(e.id, kind: e.kind, time: self.playback.currentTime)
            return CanvasPoint(base.x, base.y)
        }
    }

    /// One history entry for the whole gesture: the edits share a coalesce key no other gesture uses.
    func stageCommitted(_ es: [StageElement]) {
        let key = "stage-transform-\(UUID().uuidString)"
        editor.withHistory(Self.stageTransformLabel, coalesceKey: key) {
            for e in es { writeStage(e) }
        }
        syncStage(); redraw()
    }
}
