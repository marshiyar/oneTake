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
import MpvfxPlayer
import MpvfxShared
import MpvfxTimeline

/// Editing a mask on the stage (issue #297): ⌥M adds a rectangle mask at the centre of the selected layer and puts it
/// on the stage for editing (one undo step); a drag of a handle or a burst of arrow nudges lands as one more
/// (PlayerController+Mask.swift); the inspector's "Edit on stage" button picks another mask.
extension EditorSession {
    static let maskEditLabel = "Edit mask"

    func installMaskStage() {
        player.maskProvider = { [weak self] id in self?.editor.masks(clipId: id) ?? [] }
        player.onMaskCommit = { [weak self] target, mask in
            guard let self else { return }
            self.editor.setMask(clipId: target.clipId, maskId: target.maskId, label: Self.maskEditLabel) { $0 = mask }
            self.syncStage(); self.redraw()
        }
    }

    /// ⌥M with a layer selected: adds a rectangle mask and starts editing it. False (the key falls through) when
    /// nothing, or more than one layer, is selected, or the layer takes no mask.
    @discardableResult
    func addMaskToSelection() -> Bool {
        let ids = player.view.selectedIds
        guard ids.count == 1, let clipId = ids.first, let maskId = editor.addMask(clipId: clipId) else { return false }
        player.maskTarget = MaskStageTarget(clipId: clipId, maskId: maskId)
        syncStage(); redraw()
        return true
    }

    /// Puts an existing mask of the selected layer on the stage.
    func editMaskOnStage(clipId: String, maskId: String) {
        guard player.view.selectedIds == [clipId], editor.masks(clipId: clipId).contains(where: { $0.id == maskId }) else { return }
        player.maskTarget = MaskStageTarget(clipId: clipId, maskId: maskId)
        redraw()
    }
}
