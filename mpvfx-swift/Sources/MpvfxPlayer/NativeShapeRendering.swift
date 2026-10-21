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
    /// Builds geometry in the requested canvas box, with authored stroke dimensions scaled uniformly.
    public static func path(_ shape: NativeClipShape, box: CanvasRect, scale: Double) -> CanvasPath {
        var shapePath = CanvasPath()
        guard shape.isSupported else {
            return shapePath
        }
        let centerX = box.x + box.width / 2
        let centerY = box.y + box.height / 2
        switch shape.kind {
        case "rectangle": shapePath.addRoundedRect(box, radius: shape.number("radius") * scale)
        case "line", "arrow":
            let start = CanvasPoint(
                box.x + shape.number("startX") * box.width, box.y + shape.number("startY") * box.height)
            let end = CanvasPoint(
                box.x + shape.number("endX", default: 1) * box.width,
                box.y + shape.number("endY", default: 1) * box.height)
            shapePath.move(to: start)
            shapePath.line(to: end)
            if shape.kind == "arrow" {
                let length = hypot(end.x - start.x, end.y - start.y)
                if length > 0 {
                    let head = shape.number("headLength", default: 20) * scale
                    let unitX = (end.x - start.x) / length
                    let unitY = (end.y - start.y) / length
                    shapePath.move(
                        to: .init(end.x - head * unitX - head * unitY / 2, end.y - head * unitY + head * unitX / 2))
                    shapePath.line(to: end)
                    shapePath.line(
                        to: .init(end.x - head * unitX + head * unitY / 2, end.y - head * unitY - head * unitX / 2))
                }
            }
        case "ellipse":
            let radiusX = box.width / 2
            let radiusY = box.height / 2
            let arcFactor = 0.5522847498307936
            shapePath.move(to: .init(centerX + radiusX, centerY))
            shapePath.curve(
                to: .init(centerX, centerY + radiusY), c1: .init(centerX + radiusX, centerY + arcFactor * radiusY),
                c2: .init(centerX + arcFactor * radiusX, centerY + radiusY))
            shapePath.curve(
                to: .init(centerX - radiusX, centerY), c1: .init(centerX - arcFactor * radiusX, centerY + radiusY),
                c2: .init(centerX - radiusX, centerY + arcFactor * radiusY))
            shapePath.curve(
                to: .init(centerX, centerY - radiusY), c1: .init(centerX - radiusX, centerY - arcFactor * radiusY),
                c2: .init(centerX - arcFactor * radiusX, centerY - radiusY))
            shapePath.curve(
                to: .init(centerX + radiusX, centerY), c1: .init(centerX + arcFactor * radiusX, centerY - radiusY),
                c2: .init(centerX + radiusX, centerY - arcFactor * radiusY))
            shapePath.close()
        default:
            let authoredSides = shape.number("sides", default: 5)
            guard authoredSides.isFinite, (3...128).contains(authoredSides) else { return shapePath }
            let sides = shape.kind == "triangle" ? 3 : shape.kind == "diamond" ? 4 : Int(authoredSides)
            let star = shape.kind == "star"
            let count = star ? sides * 2 : sides
            for index in 0..<count {
                let angle = Double(index) * 2 * .pi / Double(count) - .pi / 2
                let radiusScale = star && index % 2 == 1 ? shape.number("innerRadius", default: 0.5) : 1
                let point = CanvasPoint(
                    centerX + cos(angle) * box.width / 2 * radiusScale,
                    centerY + sin(angle) * box.height / 2 * radiusScale)
                if index == 0 { shapePath.move(to: point) } else { shapePath.line(to: point) }
            }
            shapePath.close()
        }
        return shapePath
    }

    public static func draw(
        _ shape: NativeClipShape, box: CanvasRect, scale: Double, opacity: Double, on canvas: CanvasContext
    ) {
        guard shape.isSupported else { return }
        let shapePath = path(shape, box: box, scale: scale)
        if shape.kind != "line" && shape.kind != "arrow", let fill = CanvasColor(hex: shape.fill) {
            canvas.fill(shapePath, fill.withAlpha(fill.a * opacity))
        }
        let width = shape.number("strokeWidth") * scale
        if width > 0, let stroke = CanvasColor(hex: shape.stroke) {
            canvas.stroke(
                shapePath, stroke.withAlpha(stroke.a * opacity),
                StrokeStyle(width: width, dash: shape.dash.map { $0 * scale }))
        }
    }
}
