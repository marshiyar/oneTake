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
// A clip's In, Out and Loop moves read through the editor, for the stage chrome (the selection outline sits on
// the moved box). The frame is the one the preview shows at `time` (PreviewComposition.frameIndex).
import Foundation
import MpvfxShared

public extension TimelineEditor {
    /// The clip's moves at composition `time`; identity when it has none, is not under the playhead, or the
    /// keyframe engine cannot evaluate them (the preview then draws the clip unmoved too).
    func moveOffsets(clipId: String, time: Double) -> NativeMoveOffsets {
        guard let (_, c) = clip(clipId), c.moves != nil else { return .identity }
        let shown = (time * fps + 1e-6).rounded(.down)
        let local = Int(max(0, min(c.durationFrames - 1, shown - c.startFrame)))
        do { return try nativeClipMoveOffsets(c, clipFrame: local, canvas: document.canvas, engine: engine) } catch { return .identity }
    }
}
