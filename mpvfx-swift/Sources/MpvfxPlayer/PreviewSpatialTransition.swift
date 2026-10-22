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

/// Canvas-space transition state. Both preview and ExportFramePainter pass through PreviewPainter.
public struct PreviewSpatialTransition: Equatable, Sendable {
    public var kind: NativeCutTransitionKind
    public var direction: NativeTransitionDirection
    public var softness: Double
    public var progress: Double
    public var incoming: Bool
}

extension PreviewPainter {
    static func drawSpatial(_ transition: PreviewSpatialTransition, on c: CanvasContext, frame: CanvasRect,
                            content: (CanvasContext, CanvasRect, Double) -> Void) {
        let p = min(1, max(0, transition.progress))
        if transition.kind == .push {
            let v = transition.direction.vector
            let amount = transition.incoming ? p - 1 : p
            c.withState {
                c.clip(frame)
                c.translate(v.x * frame.width * amount, v.y * frame.height * amount)
                content(c, frame, 1)
            }
            return
        }
        guard transition.incoming else { content(c, frame, 1); return }
        guard p > 0 else { return }
        if p >= 1 { content(c, frame, 1); return }
        // Rasterize only the incoming wipe, including its fill, text, crop, transforms and shadows. The mask
        // operates in canvas coordinates rather than image coordinates, so all layer content crosses one edge.
        let k = max(1, c.deviceScale)
        let w = max(1, Int((frame.width * k).rounded(.up))), h = max(1, Int((frame.height * k).rounded(.up)))
        guard let canvas = try? RasterCanvas(width: w, height: h) else { return }
        canvas.clear(.transparent)
        content(canvas, CanvasRect(x: 0, y: 0, width: Double(w), height: Double(h)), k)
        var pixels = canvas.image().rgba
        let softness = min(1, max(0, transition.softness))
        for y in 0..<h {
            for x in 0..<w {
                let q: Double
                switch transition.direction {
                case .left: q = 1 - (Double(x) + 0.5) / Double(w)
                case .right: q = (Double(x) + 0.5) / Double(w)
                case .up: q = 1 - (Double(y) + 0.5) / Double(h)
                case .down: q = (Double(y) + 0.5) / Double(h)
                }
                let alpha = softness > 0 ? min(1, max(0, (p * (1 + softness) - q) / softness)) : (q < p ? 1.0 : 0.0)
                let i = (y * w + x) * 4 + 3
                pixels[i] = UInt8((Double(pixels[i]) * alpha).rounded())
            }
        }
        c.drawImage(CanvasImage(width: w, height: h, rgba: pixels), in: frame, opacity: 1)
    }
}
