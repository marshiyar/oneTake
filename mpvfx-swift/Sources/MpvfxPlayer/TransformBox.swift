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

/// The eight handles of the on-canvas transform box: four corners and four edge midpoints.
/// `unit` is the handle's place on the visible box, (0, 0) top-left to (1, 1) bottom-right.
public enum TransformHandle: CaseIterable, Equatable, Sendable {
    case nw, n, ne, e, se, s, sw, w

    public var unit: CanvasPoint {
        switch self {
        case .nw: CanvasPoint(0, 0)
        case .n: CanvasPoint(0.5, 0)
        case .ne: CanvasPoint(1, 0)
        case .e: CanvasPoint(1, 0.5)
        case .se: CanvasPoint(1, 1)
        case .s: CanvasPoint(0.5, 1)
        case .sw: CanvasPoint(0, 1)
        case .w: CanvasPoint(0, 0.5)
        }
    }
    public var isCorner: Bool { movesX && movesY }
    /// The handle changes the box width (left or right side) / height (top or bottom side).
    public var movesX: Bool { unit.x != 0.5 }
    public var movesY: Bool { unit.y != 0.5 }
    public static let corners: [TransformHandle] = [.nw, .ne, .se, .sw]
    public static let edges: [TransformHandle] = [.n, .e, .s, .w]
    /// Screen angle (degrees) a resize cursor for this handle points along, before the element's rotation.
    public var cursorAngle: Double {
        switch self {
        case .e, .w: 0
        case .n, .s: 90
        case .nw, .se: 45
        case .ne, .sw: 135
        }
    }
}

/// What a handle drag asks for: the handle, the pointer in the element's unrotated frame (view px, already
/// corrected by the grab offset), whether the aspect ratio is kept and whether it scales about the anchor.
public struct TransformResize: Equatable, Sendable {
    public var handle: TransformHandle
    public var pointer: CanvasPoint
    public var keepAspect: Bool
    public var fromAnchor: Bool
    /// Anchor point in unit coordinates of the visible box (0.5, 0.5 is the centre).
    public var anchor = TransformBox.centreAnchor
    public init(handle: TransformHandle, pointer: CanvasPoint, keepAspect: Bool = false, fromAnchor: Bool = false) {
        self.handle = handle; self.pointer = pointer; self.keepAspect = keepAspect; self.fromAnchor = fromAnchor
    }
}

/// Geometry of the transform box on a stage element in view px (`StageElement` as `PlayerView.chromeElement`
/// returns it: the full box, its crop insets, and its rotation about the full box centre).
/// Resizes move the handle's side(s) and keep a fixed point where it is on screen: the opposite side or corner, or
/// the anchor with ⌥. Rotations turn the box about the anchor. All results are new elements; nothing is written.
public enum TransformBox {
    public static let centreAnchor = CanvasPoint(0.5, 0.5)
    /// The smallest visible side a resize leaves (view px); a drag past the opposite side stops there (no flip).
    public static let minimumSide = 1.0

    /// Element-local (unrotated) point of a unit point on the visible box.
    public static func localPoint(_ ve: StageElement, unit u: CanvasPoint) -> CanvasPoint {
        let v = ve.visibleRect
        return CanvasPoint(v.x + u.x * v.width, v.y + u.y * v.height)
    }

    /// Screen point of a unit point on the visible box (rotated with the element).
    public static func screenPoint(_ ve: StageElement, unit u: CanvasPoint) -> CanvasPoint {
        PlayerView.rotate(localPoint(ve, unit: u), about: ve.centre, ve.rotation)
    }

    /// Screen point -> element-local (unrotated) point.
    public static func local(_ ve: StageElement, _ p: CanvasPoint) -> CanvasPoint {
        PlayerView.rotate(p, about: ve.centre, -ve.rotation)
    }

    /// Unit coordinates of a screen point on the visible box (the inverse of `screenPoint`).
    public static func unit(_ ve: StageElement, of p: CanvasPoint) -> CanvasPoint {
        let l = local(ve, p), v = ve.visibleRect
        return CanvasPoint((l.x - v.x) / max(v.width, 1e-9), (l.y - v.y) / max(v.height, 1e-9))
    }

    /// The element after a handle drag. Edge handles change one side's length; corners change both, freely or
    /// keeping the aspect ratio. The fixed point (opposite side, or the anchor) does not move on screen.
    public static func resized(_ ve: StageElement, _ r: TransformResize) -> StageElement {
        let v = ve.visibleRect, h = r.handle.unit
        let f = r.fromAnchor ? r.anchor : CanvasPoint(1 - h.x, 1 - h.y)
        let fixed = localPoint(ve, unit: f)
        var (w, ht) = (v.width, v.height)
        if r.handle.movesX { w = side(pointer: r.pointer.x, fixed: fixed.x, span: h.x - f.x, current: v.width) }
        if r.handle.movesY { ht = side(pointer: r.pointer.y, fixed: fixed.y, span: h.y - f.y, current: v.height) }
        if r.keepAspect { (w, ht) = keepingAspect(r.handle, w: w, h: ht, of: v) }
        return placed(ve, visibleSize: CanvasSize(w, ht), fixedUnit: f)
    }

    /// New side length so the handle lands on the pointer: the pointer's distance from the fixed point over the
    /// handle's unit distance from it. Clamped to `minimumSide`; a degenerate span keeps the side.
    static func side(pointer: Double, fixed: Double, span: Double, current: Double) -> Double {
        guard abs(span) > 1e-9 else { return current }
        let s = (pointer - fixed) / span
        return s.isFinite ? max(minimumSide, s) : current
    }

    /// Corners scale both sides by the larger change; an edge carries the other side along with it.
    static func keepingAspect(_ handle: TransformHandle, w: Double, h: Double, of v: CanvasRect) -> (Double, Double) {
        guard v.width > 0, v.height > 0 else { return (w, h) }
        if handle.isCorner {
            let q = max(w / v.width, h / v.height)
            return (max(minimumSide, v.width * q), max(minimumSide, v.height * q))
        }
        if handle.movesX { return (w, max(minimumSide, v.height * w / v.width)) }
        return (max(minimumSide, v.width * h / v.height), h)
    }

    /// The element with its visible box resized to `size`, the crop scaled with it, and moved so the unit point
    /// `f` sits where it was on screen (the box turns about its full centre, which moves with the resize).
    static func placed(_ ve: StageElement, visibleSize size: CanvasSize, fixedUnit f: CanvasPoint) -> StageElement {
        let v = ve.visibleRect
        let sx = size.width / max(v.width, 1e-9), sy = size.height / max(v.height, 1e-9)
        let fixedLocal = localPoint(ve, unit: f)
        var out = ve
        out.crop = CropInsets(top: ve.crop.top * sy, right: ve.crop.right * sx, bottom: ve.crop.bottom * sy, left: ve.crop.left * sx)
        let visX = fixedLocal.x - f.x * size.width, visY = fixedLocal.y - f.y * size.height
        // Full box = visible size plus the scaled crop (exactly the visible size when nothing is cropped).
        out.rect = CanvasRect(x: visX - out.crop.left, y: visY - out.crop.top, width: size.width + out.crop.left + out.crop.right,
                              height: size.height + out.crop.top + out.crop.bottom)
        // The fixed point sits at the same local spot in both boxes; on screen it moved by (I − R)(c′ − c) as the
        // centre moved from c to c′. Shifting back by that keeps it put, and is exactly zero for an upright box.
        let d = CanvasPoint(out.centre.x - ve.centre.x, out.centre.y - ve.centre.y)
        let rd = PlayerView.rotate(d, about: CanvasPoint(0, 0), ve.rotation)
        out.rect.x -= d.x - rd.x
        out.rect.y -= d.y - rd.y
        return out
    }

    /// The element turned by `delta` degrees about the anchor (unit point on the visible box): the box centre
    /// travels around the anchor and the rotation grows by `delta`. The anchor itself does not move.
    public static func rotated(_ ve: StageElement, by delta: Double, anchor: CanvasPoint) -> StageElement {
        let pivot = screenPoint(ve, unit: anchor)
        let c = PlayerView.rotate(ve.centre, about: pivot, delta)
        var out = ve
        out.rect.x += c.x - ve.centre.x
        out.rect.y += c.y - ve.centre.y
        out.rotation = ve.rotation + delta
        return out
    }

    /// Pointer angle about `pivot` (degrees, clockwise in y-down space).
    public static func angle(of p: CanvasPoint, about pivot: CanvasPoint) -> Double {
        atan2(p.y - pivot.y, p.x - pivot.x) * 180 / .pi
    }

    /// The rotation a rotate drag reaches: the start plus the pointer's turn (wrapped to ±180° per step), snapped to
    /// `step` degrees when asked, else rounded to 0.01°.
    public static func rotation(start: Double, from a0: Double, to a1: Double, snap step: Double?) -> Double {
        var delta = a1 - a0
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        let angle = start + delta
        guard let step, step > 0 else { return (angle * 100).rounded() / 100 }
        return (angle / step).rounded() * step
    }
}
