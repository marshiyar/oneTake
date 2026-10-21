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

/// Pure vector plans shared by preview and export. No device rounding: dashes and radii scale with the canvas.
public enum NativeShapeRendering {
    public static func path(_ shape: NativeClipShape, box: CanvasRect, scale: Double) -> CanvasPath {
        var p = CanvasPath()
        guard shape.isSupported else { return p }
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2
        switch shape.kind {
        case "rectangle": p.addRoundedRect(box, radius: shape.number("radius") * scale)
        case "line", "arrow":
            let a = CanvasPoint(box.x + shape.number("startX") * box.width, box.y + shape.number("startY") * box.height)
            let b = CanvasPoint(box.x + shape.number("endX", default: 1) * box.width, box.y + shape.number("endY", default: 1) * box.height)
            p.move(to: a); p.line(to: b)
            if shape.kind == "arrow" {
                let length = hypot(b.x - a.x, b.y - a.y)
                if length > 0 {
                    let head = shape.number("headLength", default: 20) * scale
                    let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
                    p.move(to: .init(b.x - head * ux - head * uy / 2, b.y - head * uy + head * ux / 2))
                    p.line(to: b)
                    p.line(to: .init(b.x - head * ux + head * uy / 2, b.y - head * uy - head * ux / 2))
                }
            }
        case "ellipse":
            let rx = box.width / 2, ry = box.height / 2, k = 0.5522847498307936
            p.move(to: .init(cx + rx, cy))
            p.curve(to: .init(cx, cy + ry), c1: .init(cx + rx, cy + k * ry), c2: .init(cx + k * rx, cy + ry))
            p.curve(to: .init(cx - rx, cy), c1: .init(cx - k * rx, cy + ry), c2: .init(cx - rx, cy + k * ry))
            p.curve(to: .init(cx, cy - ry), c1: .init(cx - rx, cy - k * ry), c2: .init(cx - k * rx, cy - ry))
            p.curve(to: .init(cx + rx, cy), c1: .init(cx + k * rx, cy - ry), c2: .init(cx + rx, cy - k * ry)); p.close()
        default:
            let authoredSides = shape.number("sides", default: 5)
            guard authoredSides.isFinite, (3...128).contains(authoredSides) else { return p }
            let sides = shape.kind == "triangle" ? 3 : shape.kind == "diamond" ? 4 : Int(authoredSides)
            let star = shape.kind == "star", count = star ? sides * 2 : sides
            for i in 0..<count {
                let angle = Double(i) * 2 * .pi / Double(count) - .pi / 2
                let r = star && i % 2 == 1 ? shape.number("innerRadius", default: 0.5) : 1
                let point = CanvasPoint(cx + cos(angle) * box.width / 2 * r, cy + sin(angle) * box.height / 2 * r)
                if i == 0 { p.move(to: point) } else { p.line(to: point) }
            }
            p.close()
        }
        return p
    }

    public static func draw(_ shape: NativeClipShape, box: CanvasRect, scale: Double, opacity: Double, on canvas: CanvasContext) {
        guard shape.isSupported else { return }
        let p = path(shape, box: box, scale: scale)
        if shape.kind != "line" && shape.kind != "arrow", let fill = CanvasColor(hex: shape.fill) {
            canvas.fill(p, fill.withAlpha(fill.a * opacity))
        }
        let width = shape.number("strokeWidth") * scale
        if width > 0, let stroke = CanvasColor(hex: shape.stroke) {
            canvas.stroke(p, stroke.withAlpha(stroke.a * opacity), StrokeStyle(width: width, dash: shape.dash.map { $0 * scale }))
        }
    }
}
