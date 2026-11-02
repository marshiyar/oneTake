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
// The geometry of editing a shape mask on the stage (issue #297), apart from any pointer or view: where a mask's
// handles sit in its layer's own pixels, and what a handle moved to a point (or nudged) makes of the mask.
//
// A mask is in layer-local coordinates (NativeClipMask): centre (x, y) as fractions of the layer's width and height,
// width and height as fractions, angle in degrees clockwise, feather and expansion in layer pixels. A rectangle and an
// ellipse fill the box; a linear mask covers everything on the -x side of a line through the centre turned by the
// angle; a band covers |x| <= width/2 about that line. The caller turns layer pixels into stage points with the
// layer's own transform, so masks move, scale and rotate with the layer.
import Foundation
import MpvfxCanvas
import MpvfxShared

/// What a mask handle does when dragged.
public enum MaskHandle: Equatable, Sendable {
    /// Inside a rectangle or ellipse: moves the whole mask.
    case body
    /// Rectangle and ellipse corners, 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left (in the mask's own turn).
    case corner(Int)
    /// Rectangle and ellipse edges, 0 top, 1 right, 2 bottom, 3 left. A band has 1 and 3 (its two parallel edges).
    case edge(Int)
    /// A linear or band mask's centre: moves the line.
    case center
    /// The end of a linear or band mask's line: turns it about the centre.
    case rotate
    /// A linear or band mask's feather: how far from the line, in pixels, the edge softens.
    case feather
}

public struct MaskHandlePoint: Equatable, Sendable {
    public var handle: MaskHandle
    /// In layer pixels.
    public var point: CanvasPoint
}

public enum MaskStageEditor {
    /// How far from the centre a line mask's turn handle sits, in layer pixels.
    public static let rotateReach = 120.0
    /// Smallest width or height a drag leaves, in layer pixels.
    public static let minimumSide = 1.0

    // MARK: Geometry

    static func frame(_ m: NativeClipMask, _ size: CanvasSize) -> (cx: Double, cy: Double, w: Double, h: Double, cos: Double, sin: Double) {
        let a = (m.angle ?? 0) * .pi / 180
        return ((m.x ?? 0.5) * size.width, (m.y ?? 0.5) * size.height, (m.width ?? 1) * size.width, (m.height ?? 1) * size.height, cos(a), sin(a))
    }

    /// A point of the mask's own frame (x along its width, y along its height from the centre) in layer pixels.
    static func toLayer(_ f: (cx: Double, cy: Double, w: Double, h: Double, cos: Double, sin: Double), _ x: Double, _ y: Double) -> CanvasPoint {
        CanvasPoint(f.cx + x * f.cos - y * f.sin, f.cy + x * f.sin + y * f.cos)
    }

    /// A layer point in the mask's own frame.
    static func toMask(_ f: (cx: Double, cy: Double, w: Double, h: Double, cos: Double, sin: Double), _ p: CanvasPoint) -> CanvasPoint {
        let dx = p.x - f.cx, dy = p.y - f.cy
        return CanvasPoint(dx * f.cos + dy * f.sin, -dx * f.sin + dy * f.cos)
    }

    /// The handles of `mask` on a layer of `size` pixels, in drawing order; the last one wins a tie at a press.
    public static func handles(of mask: NativeClipMask, layerSize size: CanvasSize) -> [MaskHandlePoint] {
        let f = frame(mask, size)
        switch mask.kind {
        case "linear":
            return [MaskHandlePoint(handle: .center, point: toLayer(f, 0, 0)),
                    MaskHandlePoint(handle: .rotate, point: toLayer(f, 0, rotateReach)),
                    MaskHandlePoint(handle: .feather, point: toLayer(f, max(0, mask.feather ?? 0), rotateReach / 2))]
        case "band":
            return [MaskHandlePoint(handle: .center, point: toLayer(f, 0, 0)),
                    MaskHandlePoint(handle: .edge(1), point: toLayer(f, f.w / 2, 0)),
                    MaskHandlePoint(handle: .edge(3), point: toLayer(f, -f.w / 2, 0)),
                    MaskHandlePoint(handle: .rotate, point: toLayer(f, 0, rotateReach)),
                    MaskHandlePoint(handle: .feather, point: toLayer(f, f.w / 2 + max(0, mask.feather ?? 0), rotateReach / 2))]
        default:
            let hw = f.w / 2, hh = f.h / 2
            return [MaskHandlePoint(handle: .corner(0), point: toLayer(f, -hw, -hh)), MaskHandlePoint(handle: .corner(1), point: toLayer(f, hw, -hh)),
                    MaskHandlePoint(handle: .corner(2), point: toLayer(f, hw, hh)), MaskHandlePoint(handle: .corner(3), point: toLayer(f, -hw, hh)),
                    MaskHandlePoint(handle: .edge(0), point: toLayer(f, 0, -hh)), MaskHandlePoint(handle: .edge(1), point: toLayer(f, hw, 0)),
                    MaskHandlePoint(handle: .edge(2), point: toLayer(f, 0, hh)), MaskHandlePoint(handle: .edge(3), point: toLayer(f, -hw, 0))]
        }
    }

    /// Whether `point` (layer pixels) is inside a rectangle or ellipse mask's shape: a press there moves it.
    public static func contains(_ mask: NativeClipMask, _ point: CanvasPoint, layerSize size: CanvasSize) -> Bool {
        guard mask.kind == "rectangle" || mask.kind == "ellipse" else { return false }
        let f = frame(mask, size), p = toMask(f, point)
        if mask.kind == "ellipse" {
            guard f.w > 0, f.h > 0 else { return false }
            return (p.x / (f.w / 2)) * (p.x / (f.w / 2)) + (p.y / (f.h / 2)) * (p.y / (f.h / 2)) <= 1
        }
        return abs(p.x) <= f.w / 2 && abs(p.y) <= f.h / 2
    }

    // MARK: Dragging

    /// `mask` with `handle` dragged to `point` (layer pixels), where the drag started at `start` (the mask as it
    /// was at the press). ⇧ (`keepProportions`) keeps the width to height ratio on a corner or edge; ⌥ (`fromCenter`)
    /// resizes about the centre instead of the opposite side. A mask never flips: a side dragged past the other one
    /// leaves the minimum.
    public static func dragged(_ start: NativeClipMask, handle: MaskHandle, to point: CanvasPoint, from origin: CanvasPoint,
                               layerSize size: CanvasSize, keepProportions: Bool = false, fromCenter: Bool = false) -> NativeClipMask {
        var m = start
        let f = frame(start, size)
        guard size.width > 0, size.height > 0 else { return m }
        switch handle {
        case .body, .center:
            m.x = (start.x ?? 0.5) + (point.x - origin.x) / size.width
            m.y = (start.y ?? 0.5) + (point.y - origin.y) / size.height
        case .rotate:
            // The handle sits on the mask's +y axis: the angle that puts it under the pointer.
            let dx = point.x - f.cx, dy = point.y - f.cy
            guard hypot(dx, dy) > 0.0001 else { return m }
            m.angle = normalized((atan2(dy, dx) - .pi / 2) * 180 / .pi)
        case .feather:
            let p = toMask(f, point)
            m.feather = max(0, start.kind == "band" ? p.x - f.w / 2 : p.x)
        case .edge where start.kind == "band":
            m.width = max(minimumSide, 2 * abs(toMask(f, point).x)) / size.width
        case .edge(let side):
            resize(&m, f, size, axisX: side == 1 || side == 3, axisY: side == 0 || side == 2,
                   signX: side == 1 ? 1 : (side == 3 ? -1 : 0), signY: side == 2 ? 1 : (side == 0 ? -1 : 0),
                   point: point, keep: keepProportions, fromCenter: fromCenter)
        case .corner(let corner):
            resize(&m, f, size, axisX: true, axisY: true, signX: (corner == 1 || corner == 2) ? 1 : -1,
                   signY: (corner == 2 || corner == 3) ? 1 : -1, point: point, keep: keepProportions, fromCenter: fromCenter)
        }
        return m
    }

    private static func resize(_ m: inout NativeClipMask, _ f: (cx: Double, cy: Double, w: Double, h: Double, cos: Double, sin: Double),
                               _ size: CanvasSize, axisX: Bool, axisY: Bool, signX: Double, signY: Double,
                               point: CanvasPoint, keep: Bool, fromCenter: Bool) {
        let p = toMask(f, point)
        // The edge or corner follows the pointer; the opposite side stays (or, from the centre, mirrors it).
        var newW = f.w, newH = f.h, shiftX = 0.0, shiftY = 0.0
        if axisX {
            let moved = p.x * signX
            newW = fromCenter ? 2 * moved : moved + f.w / 2
            if !fromCenter { shiftX = (newW - f.w) / 2 * signX }
        }
        if axisY {
            let moved = p.y * signY
            newH = fromCenter ? 2 * moved : moved + f.h / 2
            if !fromCenter { shiftY = (newH - f.h) / 2 * signY }
        }
        newW = max(minimumSide, newW); newH = max(minimumSide, newH)
        if keep, f.w > 0, f.h > 0 {
            let ratio = f.w / f.h
            if axisX && axisY {
                // A corner takes whichever side grew more.
                if newW / f.w >= newH / f.h { newH = newW / ratio } else { newW = newH * ratio }
            } else if axisX { newH = newW / ratio } else { newW = newH * ratio }
            newW = max(minimumSide, newW); newH = max(minimumSide, newH)
            if !fromCenter {
                if axisX { shiftX = (newW - f.w) / 2 * (signX == 0 ? 0 : signX) }
                if axisY { shiftY = (newH - f.h) / 2 * (signY == 0 ? 0 : signY) }
                if !axisX { shiftX = 0 }
                if !axisY { shiftY = 0 }
            }
        }
        if !fromCenter {
            let c = toLayer(f, shiftX, shiftY)
            m.x = c.x / size.width; m.y = c.y / size.height
        }
        m.width = newW / size.width; m.height = newH / size.height
    }

    /// Degrees in -180…180.
    private static func normalized(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    // MARK: Nudging

    /// `mask` with `handle` moved by (dx, dy) layer pixels: an arrow key's 1 px, or 10 px with ⇧.
    public static func nudged(_ mask: NativeClipMask, handle: MaskHandle, dx: Double, dy: Double, layerSize size: CanvasSize,
                              keepProportions: Bool = false, fromCenter: Bool = false) -> NativeClipMask {
        guard let at = handles(of: mask, layerSize: size).first(where: { $0.handle == handle })?.point
            ?? (handle == .body ? CanvasPoint((mask.x ?? 0.5) * size.width, (mask.y ?? 0.5) * size.height) : nil) else { return mask }
        return dragged(mask, handle: handle, to: CanvasPoint(at.x + dx, at.y + dy), from: at, layerSize: size,
                       keepProportions: keepProportions, fromCenter: fromCenter)
    }
}
