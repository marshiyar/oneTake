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
import MpvfxPlayer
import MpvfxPanels

extension SessionPanels {
    /// One crop session (issue #188): the inspector's "Edit crop" and edge fields drive the stage's crop tool, the
    /// same session the stage toolbar's Crop and the C key start; Apply commits it as one undo step.
    func wireCrop(_ inspector: InspectorPanel) {
        let player = session.player
        inspector.cropLink = InspectorCropLink(
            activeClip: { [weak player] in player?.cropClipId },
            insets: { [weak player] in player?.cropDraft.map { NativeClipCrop(top: $0.top, right: $0.right, bottom: $0.bottom, left: $0.left) } },
            run: { [weak self, weak player] cmd in
                switch cmd {
                case .start: player?.runCrop(.start)
                case .reset: player?.runCrop(.reset)
                case .cancel: player?.runCrop(.cancel)
                case .apply: player?.runCrop(.apply)
                }
                self?.redraw()
            },
            setInsets: { [weak self, weak player] c in
                player?.setCropDraft(CropInsets(top: c.top, right: c.right, bottom: c.bottom, left: c.left)); self?.redraw()
            })
    }
}
