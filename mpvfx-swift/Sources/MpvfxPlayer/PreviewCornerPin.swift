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

extension PreviewComposition {
    /// A clip's corner offsets at one moment: the saved `clip.corners`, each keyframed component replaced by its
    /// evaluated track value (`num`). Nil when nothing is distorted.
    static func evaluatedCorners(_ saved: NativeClipCorners?, _ num: (String) -> Double?) -> NativeClipCorners? {
        let resolved = (saved ?? .identity).resolved(num)
        return resolved.isIdentity ? nil : resolved
    }
}

extension PreviewPainter {
    /// Mesh cells per side for a distorted layer. A parallelogram needs one affine map; any other quad is a mesh of
    /// triangles, each drawn with the affine map that takes it exactly onto its projected corners.
    static let pinCells = 8

    /// Draws `content` (the layer's untransformed, view px box) through the layer's corner pin. The caller has set
    /// the scale/rotation transform; without corners `content` is drawn as is.
    static func drawPinned(_ layer: PreviewLayer, box: CanvasRect, scale s: Double, on c: CanvasContext, content: () -> Void) {
        guard let pin = layer.corners?.pin else { content(); return }
        // Unit box point -> view px.
        func map(_ x: Double, _ y: Double) -> CanvasPoint {
            let q = pin.map((x - box.x) / box.width, (y - box.y) / box.height)
            return CanvasPoint(box.x + q.x * box.width, box.y + q.y * box.height)
        }
        func affine(_ src: [CanvasPoint], _ dst: [CanvasPoint]) -> (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double)? {
            let p = src[1].x - src[0].x, q = src[1].y - src[0].y, r = src[2].x - src[0].x, t = src[2].y - src[0].y
            let det = p * t - r * q
            guard abs(det) > 1e-9 else { return nil }
            let dp = dst[1].x - dst[0].x, dq = dst[1].y - dst[0].y, dr = dst[2].x - dst[0].x, dt = dst[2].y - dst[0].y
            let a = (dp * t - dr * q) / det, cc = (dr * p - dp * r) / det
            let b = (dq * t - dt * q) / det, d = (dt * p - dq * r) / det
            return (a, b, cc, d, dst[0].x - a * src[0].x - cc * src[0].y, dst[0].y - b * src[0].x - d * src[0].y)
        }
        guard box.width > 0, box.height > 0 else { return }
        if pin.isAffine {
            let o = [CanvasPoint(box.x, box.y), CanvasPoint(box.x + box.width, box.y), CanvasPoint(box.x, box.y + box.height)]
            guard let m = affine(o, o.map { map($0.x, $0.y) }) else { return }
            c.withState { c.concat(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty); content() }
            return
        }
        // A bow-tie or collapsed quad has no picture to show.
        guard pin.isConvex else { return }
        // The mesh covers the box and any shadow around it.
        var area = box
        for sh in (layer.style?.shadows ?? []) {
            let pad = (abs(sh.x) + abs(sh.y) + max(0, sh.blur) + max(0, sh.spread)) * s
            area = area.insetBy(-pad)
        }
        let n = pinCells
        for j in 0..<n { for i in 0..<n {
            let x0 = area.x + area.width * Double(i) / Double(n), x1 = area.x + area.width * Double(i + 1) / Double(n)
            let y0 = area.y + area.height * Double(j) / Double(n), y1 = area.y + area.height * Double(j + 1) / Double(n)
            for tri in [[CanvasPoint(x0, y0), CanvasPoint(x1, y0), CanvasPoint(x0, y1)],
                        [CanvasPoint(x1, y1), CanvasPoint(x0, y1), CanvasPoint(x1, y0)]] {
                let dst = tri.map { map($0.x, $0.y) }
                guard let m = affine(tri, dst) else { continue }
                // Grow the clip ~0.6 px about the centroid so neighbouring triangles overlap instead of leaving seams.
                let gx = (dst[0].x + dst[1].x + dst[2].x) / 3, gy = (dst[0].y + dst[1].y + dst[2].y) / 3
                var clip = CanvasPath()
                for (k, p) in dst.enumerated() {
                    let dx = p.x - gx, dy = p.y - gy, len = max(1e-6, (dx * dx + dy * dy).squareRoot())
                    let q = CanvasPoint(p.x + dx / len * 0.6, p.y + dy / len * 0.6)
                    if k == 0 { clip.move(to: q) } else { clip.line(to: q) }
                }
                clip.close()
                c.withState {
                    c.clip(clip)
                    c.concat(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty)
                    content()
                }
            }
        } }
    }
}
