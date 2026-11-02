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
    /// Eased progress, 0 at the start of the range and 1 at its end.
    public var progress: Double
    public var incoming: Bool
    /// Wipe edge angle in degrees (0 right, 90 down, 180 left, 270 up); nil: `direction`.
    public var angle: Double? = nil
    public var irisShape: NativeIrisShape = .circle
    /// Iris centre as a fraction of the frame.
    public var centreX = 0.5, centreY = 0.5
    /// Zoom-through factor.
    public var strength = NativeCutTransition.defaultStrength
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
        if transition.kind == .slide {
            guard transition.incoming else { content(c, frame, 1); return }
            let v = transition.direction.vector
            c.withState {
                c.clip(frame)
                c.translate(v.x * frame.width * (p - 1), v.y * frame.height * (p - 1))
                content(c, frame, 1)
            }
            return
        }
        if transition.kind == .zoomThrough {
            let scale = transition.incoming
                ? transition.strength - (transition.strength - 1) * p
                : 1 + (transition.strength - 1) * p
            let cx = frame.x + frame.width / 2, cy = frame.y + frame.height / 2
            c.withState {
                c.clip(frame)
                c.translate(cx, cy)
                c.scale(scale, scale)
                c.translate(-cx, -cy)
                content(c, frame, 1)
            }
            return
        }
        guard transition.incoming else { content(c, frame, 1); return }
        guard p > 0 else { return }
        if p >= 1 { content(c, frame, 1); return }
        // Rasterize only the incoming wipe or iris, including its fill, text, crop, transforms and shadows. The mask
        // operates in canvas coordinates rather than image coordinates, so all layer content crosses one edge.
        let k = max(1, c.deviceScale)
        let w = max(1, Int((frame.width * k).rounded(.up))), h = max(1, Int((frame.height * k).rounded(.up)))
        guard let canvas = try? RasterCanvas(width: w, height: h) else { return }
        canvas.clear(.transparent)
        content(canvas, CanvasRect(x: 0, y: 0, width: Double(w), height: Double(h)), k)
        var pixels = canvas.image().rgba
        let softness = min(1, max(0, transition.softness))
        // Pixel centres and mask geometry share raster coordinates, independent of the output scale.
        let cx = transition.centreX * Double(w), cy = transition.centreY * Double(h)
        let maxDx = max(abs(cx), abs(Double(w) - cx))
        let maxDy = max(abs(cy), abs(Double(h) - cy))
        let radius = hypot(maxDx, maxDy)
        let radians = (transition.angle ?? 0) * .pi / 180
        let vx = cos(radians), vy = sin(radians)
        let minProjection = min(0, vx * Double(w)) + min(0, vy * Double(h))
        let projectionRange = abs(vx) * Double(w) + abs(vy) * Double(h)
        for y in 0..<h {
            for x in 0..<w {
                let q: Double
                if transition.kind == .iris {
                    let dx = abs(Double(x) + 0.5 - cx), dy = abs(Double(y) + 0.5 - cy)
                    q = transition.irisShape == .rectangle
                        ? max(dx / maxDx, dy / maxDy)
                        : hypot(dx, dy) / radius
                } else if transition.angle != nil {
                    q = ((Double(x) + 0.5) * vx + (Double(y) + 0.5) * vy - minProjection) / projectionRange
                } else {
                    switch transition.direction {
                    case .left: q = 1 - (Double(x) + 0.5) / Double(w)
                    case .right: q = (Double(x) + 0.5) / Double(w)
                    case .up: q = 1 - (Double(y) + 0.5) / Double(h)
                    case .down: q = (Double(y) + 0.5) / Double(h)
                    }
                }
                let alpha = softness > 0 ? min(1, max(0, (p * (1 + softness) - q) / softness)) : (q < p ? 1.0 : 0.0)
                let i = (y * w + x) * 4 + 3
                pixels[i] = UInt8((Double(pixels[i]) * alpha).rounded())
            }
        }
        c.drawImage(CanvasImage(width: w, height: h, rgba: pixels), in: frame, opacity: 1)
    }
}
