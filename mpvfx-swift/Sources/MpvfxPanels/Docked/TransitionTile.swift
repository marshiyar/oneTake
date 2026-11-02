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

/// How a Transitions browser tile draws a transition at a moment of its length: the outgoing picture, the incoming one,
/// and what the kind does between them. The two sides are the user's own clips around the selected cut, or two
/// neutral colour cards when no cut is selected.
public enum TransitionTile {
    /// One side of the cut.
    public enum Side {
        case image(CanvasImage)
        case color(CanvasColor)
    }

    /// Frames shown before and after the transition while a tile plays, and the playing rate.
    public static let leadFrames = 10.0, previewFPS = 30.0

    /// Where a tile that plays is in its transition: `phase` (0...1) runs once around the loop of `leadFrames`, the
    /// `lengthFrames` of the transition and `leadFrames` again, and the result is the transition's progress (0
    /// before it, 1 after it).
    public static func progress(phase: Double, lengthFrames: Double) -> Double {
        let length = max(1, lengthFrames)
        let frames = phase.truncatingRemainder(dividingBy: 1) * (2 * leadFrames + length)
        return min(1, max(0, (frames - leadFrames) / length))
    }

    /// Seconds one loop of a transition of `lengthFrames` takes.
    public static func loopSeconds(lengthFrames: Double) -> Double { (2 * leadFrames + max(1, lengthFrames)) / previewFPS }

    /// Draws `entry` at `progress` (0 = only the outgoing picture, 1 = only the incoming one) inside `r`.
    public static func draw(_ c: CanvasContext, _ r: CanvasRect, entry: TransitionEntry, progress: Double, from: Side, to: Side) {
        let p = min(1, max(0, progress))
        c.save()
        c.clip(r)
        switch entry.kind {
        case .dissolve:
            side(c, r, from, opacity: 1)
            side(c, r, to, opacity: p)
        case .dip:
            // Out to the colour up to the cut, in from it after, like the preview's dip.
            let colour = entry.color.flatMap(CanvasColor.init(hex:)) ?? CanvasColor(hex: NativeCutTransition.defaultDipColor) ?? CanvasColor(r: 0, g: 0, b: 0, a: 1)
            if p < 0.5 { side(c, r, from, opacity: 1); c.fillRect(r, colour.withAlpha(2 * p)) }
            else { side(c, r, to, opacity: 1); c.fillRect(r, colour.withAlpha(2 * (1 - p))) }
        case .push:
            let v = (entry.direction ?? .left).vector
            side(c, r.offsetBy(dx: v.x * r.width * p, dy: v.y * r.height * p), from, opacity: 1)
            side(c, r.offsetBy(dx: v.x * r.width * (p - 1), dy: v.y * r.height * (p - 1)), to, opacity: 1)
        case .slide:
            // The incoming picture slides in over the one that stays still.
            let v = (entry.direction ?? .left).vector
            side(c, r, from, opacity: 1)
            side(c, r.offsetBy(dx: v.x * r.width * (p - 1), dy: v.y * r.height * (p - 1)), to, opacity: 1)
        case .iris:
            side(c, r, from, opacity: 1)
            guard p > 0 else { break }
            // A circle or rectangle growing from the centre (the tile skips the centre point and the softness).
            let half = p * (entry.irisShape == .rectangle ? 1 : 0.5 * (r.width * r.width + r.height * r.height).squareRoot())
            let region: CanvasPath
            if entry.irisShape == .rectangle {
                region = .rect(CanvasRect(x: r.midXValue - r.width * p / 2, y: r.midYValue - r.height * p / 2, width: r.width * p, height: r.height * p))
            } else {
                region = .roundedRect(CanvasRect(x: r.midXValue - half, y: r.midYValue - half, width: 2 * half, height: 2 * half), radius: half)
            }
            c.save(); c.clip(region); side(c, r, to, opacity: 1); c.restore()
        case .zoomThrough:
            // The outgoing picture grows and fades out while the incoming one settles to full size from the same factor.
            let outScale = 1 + p, inScale = 2 - p
            side(c, r.scaledAboutCentre(outScale), from, opacity: 1 - p)
            side(c, r.scaledAboutCentre(inScale), to, opacity: p)
        case .wipe:
            side(c, r, from, opacity: 1)
            guard p > 0 else { break }
            // A hard edge: the incoming picture grows in from the side it travels from (the tile skips softness).
            let revealed: CanvasRect
            switch entry.direction ?? .left {
            case .left: revealed = CanvasRect(x: r.maxX - r.width * p, y: r.y, width: r.width * p, height: r.height)
            case .right: revealed = CanvasRect(x: r.x, y: r.y, width: r.width * p, height: r.height)
            case .up: revealed = CanvasRect(x: r.x, y: r.maxY - r.height * p, width: r.width, height: r.height * p)
            case .down: revealed = CanvasRect(x: r.x, y: r.y, width: r.width, height: r.height * p)
            }
            c.save(); c.clip(revealed); side(c, r, to, opacity: 1); c.restore()
        }
        c.restore()
    }

    private static func side(_ c: CanvasContext, _ r: CanvasRect, _ s: Side, opacity: Double) {
        guard opacity > 0 else { return }
        switch s {
        case .image(let image): c.drawImage(image, in: r, opacity: opacity)
        case .color(let colour): c.fillRect(r, colour.withAlpha(opacity))
        }
    }
}

private extension CanvasRect {
    func offsetBy(dx: Double, dy: Double) -> CanvasRect { CanvasRect(x: x + dx, y: y + dy, width: width, height: height) }
    var midXValue: Double { x + width / 2 }
    var midYValue: Double { y + height / 2 }
    func scaledAboutCentre(_ k: Double) -> CanvasRect {
        CanvasRect(x: midXValue - width * k / 2, y: midYValue - height * k / 2, width: width * k, height: height * k)
    }
}
