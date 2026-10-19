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

/// Outlines that mark a media item's real bounds on the stage (selection, hover, multi-select, marquee candidates,
/// crop frame, drop target, z-order flash, the composition frame) are square: radius 0, edges snapped to device
/// pixels and drawn as four filled bars inside the box, so the line is exact with no rounded or half-pixel corners.
/// A deliberate choice over rounded-md / rounded-sm boxes (docs/FEATURES.md §4).
extension PlayerView {
    /// `r` with each edge rounded to the nearest device pixel (`scale` device px per point).
    public static func pixelAligned(_ r: CanvasRect, scale: Double) -> CanvasRect {
        let k = max(scale, 1)
        func s(_ v: Double) -> Double { (v * k).rounded() / k }
        let x0 = s(r.x), y0 = s(r.y), x1 = s(r.maxX), y1 = s(r.maxY)
        return CanvasRect(x: x0, y: y0, width: max(1 / k, x1 - x0), height: max(1 / k, y1 - y0))
    }

    /// A square outline `width` points thick lying inside `r` (border-box), pixel-aligned. The four bars do not
    /// overlap, so a translucent colour stays even at the corners.
    public static func strokeSquare(_ c: CanvasContext, _ r: CanvasRect, _ color: CanvasColor, width: Double) {
        let k = max(c.deviceScale, 1)
        let b = pixelAligned(r, scale: k)
        let w = min(max(1, (width * k).rounded()) / k, b.width / 2, b.height / 2)
        c.fillRect(CanvasRect(x: b.x, y: b.y, width: b.width, height: w), color)
        c.fillRect(CanvasRect(x: b.x, y: b.maxY - w, width: b.width, height: w), color)
        c.fillRect(CanvasRect(x: b.x, y: b.y + w, width: w, height: b.height - 2 * w), color)
        c.fillRect(CanvasRect(x: b.maxX - w, y: b.y + w, width: w, height: b.height - 2 * w), color)
    }

    /// A pixel-aligned square fill of `r`.
    public static func fillSquare(_ c: CanvasContext, _ r: CanvasRect, _ color: CanvasColor) {
        c.fillRect(pixelAligned(r, scale: c.deviceScale), color)
    }
}
