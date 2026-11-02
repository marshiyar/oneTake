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
// The camera-moves effect on a layer (issue #307): applied after keyframes and Layer moves; export draws the same layers.
import Foundation
import MpvfxCanvas
import MpvfxShared

extension PreviewComposition {
    /// `layer` moved by the clip's camera moves at clip frame `local`. A failed evaluation (no keyframe engine) draws it unmoved.
    func cameraMoved(_ layer: PreviewLayer, _ clip: NativeProjectClip, local: Double) -> PreviewLayer {
        guard let moves = clip.cameraMoves else { return layer }
        let canvas = NativeCanvas(width: self.canvas.width, height: self.canvas.height, background: "")
        guard let o = try? moves.offsets(clipFrame: Int(local), duration: Int(clip.durationFrames), fps: fps, canvas: canvas,
                                         width: layer.box.width, height: layer.box.height, engine: engine ?? keyframeEngine()) else { return layer }
        return layer.moved(by: o)
    }
}
