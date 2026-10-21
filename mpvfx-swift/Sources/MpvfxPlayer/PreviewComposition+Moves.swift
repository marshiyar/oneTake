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
// A clip's In, Out and Loop moves on its evaluated layer (NativeClipMoves.swift): applied after the static and
// keyframed values, so the user's keyframes keep working under them. Export draws the same layers.
import Foundation
import MpvfxCanvas
import MpvfxShared

extension PreviewLayer {
    /// The layer moved by `o`: the box shifts by (dx, dy), scale and opacity multiply, rotation adds.
    public func moved(by o: NativeMoveOffsets) -> PreviewLayer {
        guard !o.isIdentity else { return self }
        var l = self
        l.box = CanvasRect(x: box.x + o.dx, y: box.y + o.dy, width: box.width, height: box.height)
        l.scaleX = scaleX * o.scale; l.scaleY = scaleY * o.scale
        l.rotation = rotation + o.rotation
        l.opacity = max(0, min(1, opacity * o.opacity))
        return l
    }
}

extension PreviewComposition {
    /// What the clip's moves add at clip frame `local`. A failed evaluation (no keyframe engine) draws the layer
    /// unmoved, as a keyframe track that fails to evaluate keeps its static value.
    func moveOffsets(_ clip: NativeProjectClip, local: Double) -> NativeMoveOffsets {
        guard clip.moves != nil else { return .identity }
        let canvas = NativeCanvas(width: self.canvas.width, height: self.canvas.height, background: "")
        do { return try nativeClipMoveOffsets(clip, clipFrame: Int(local), canvas: canvas, engine: engine) } catch { return .identity }
    }
}
