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
import CMediaEngine

/// One step of a vector path drawn on a `RasterSurface`.
public enum RasterPathElement: Equatable, Sendable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    /// Cubic curve to (x, y) with control points (c1x, c1y) and (c2x, c2y).
    case curve(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double)
    case close
}

/// Straight-alpha colour, components 0 ... 1.
public struct RasterColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// Affine map p -> (a x + c y + tx, b x + d y + ty).
public struct RasterTransform: Equatable, Sendable {
    public var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
    public init() {}
    public static let identity = RasterTransform()
    public static func translation(_ x: Double, _ y: Double) -> RasterTransform {
        var t = RasterTransform()
        t.tx = x
        t.ty = y
        return t
    }
}

public struct RasterRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Straight-alpha RGBA8 pixels, rows tightly packed.
public struct RasterImage: Sendable {
    public var rgba: [UInt8]
    public var width: Int, height: Int
    public init(rgba: [UInt8], width: Int, height: Int) {
        self.rgba = rgba
        self.width = width
        self.height = height
    }
}

public struct RasterStroke: Equatable, Sendable {
    public var width: Double, dash: [Double]
    public init(width: Double, dash: [Double] = []) {
        self.width = width
        self.dash = dash
    }
}

/// An offscreen RGBA canvas painted by the media engine (export frames are drawn on it).
public final class RasterSurface {
    /// Largest side the surface accepts.
    static let maxSide = 16_384

    private let canvas: OpaquePointer
    public let width: Int, height: Int

    public init(width: Int, height: Int) throws {
        guard (1...Self.maxSide).contains(width), (1...Self.maxSide).contains(height),
              let created = mpvfx_canvas_new(u32(width), u32(height)) else {
            throw MediaError(kind: .argument, message: "invalid canvas size \(width)x\(height)")
        }
        canvas = created
        self.width = width
        self.height = height
    }

    deinit { mpvfx_canvas_free(canvas) }

    /// Fills the surface with `color` and resets the transform, the clip and the saved states.
    public func clear(_ color: RasterColor) {
        mpvfx_canvas_clear(canvas, Float(color.r), Float(color.g), Float(color.b), Float(color.a))
    }

    public func save() { mpvfx_canvas_save(canvas) }
    public func restore() { mpvfx_canvas_restore(canvas) }

    /// Pre-multiplies the current transform by `t`.
    public func concat(_ t: RasterTransform) {
        mpvfx_canvas_concat(canvas, t.a, t.b, t.c, t.d, t.tx, t.ty)
    }

    public func setTransform(_ t: RasterTransform) {
        mpvfx_canvas_set_transform(canvas, t.a, t.b, t.c, t.d, t.tx, t.ty)
    }

    public func clip(_ path: [RasterPathElement]) {
        Self.withElements(path) { mpvfx_canvas_clip(canvas, $0.baseAddress, $0.count) }
    }

    public func fill(_ path: [RasterPathElement], _ color: RasterColor) {
        Self.withElements(path) {
            mpvfx_canvas_fill(canvas, $0.baseAddress, $0.count, Float(color.r), Float(color.g), Float(color.b), Float(color.a))
        }
    }

    public func stroke(_ path: [RasterPathElement], _ style: RasterStroke, _ color: RasterColor) {
        Self.withElements(path) { elements in
            style.dash.withUnsafeBufferPointer { dash in
                mpvfx_canvas_stroke(canvas, elements.baseAddress, elements.count, style.width, dash.baseAddress, dash.count,
                                    Float(color.r), Float(color.g), Float(color.b), Float(color.a))
            }
        }
    }

    /// Draws `image` scaled into `rect` (user coordinates) at `opacity`. An empty image draws nothing.
    public func drawImage(_ image: RasterImage, in rect: RasterRect, opacity: Double = 1) throws {
        guard image.width > 0, image.height > 0 else { return }
        let status = image.rgba.withUnsafeBufferPointer {
            mpvfx_canvas_draw_image(canvas, $0.baseAddress, $0.count, u32(image.width), u32(image.height),
                                    rect.x, rect.y, rect.width, rect.height, Float(opacity))
        }
        try MediaError.check(status)
    }

    /// The surface as straight-alpha RGBA8 (width x height x 4 bytes); empty if the engine refuses the read.
    public func rgba() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let status = pixels.withUnsafeMutableBufferPointer { mpvfx_canvas_read_rgba(canvas, $0.baseAddress, $0.count) }
        return status == MPVFX_OK ? pixels : []
    }

    private static func withElements<R>(_ path: [RasterPathElement], _ body: (UnsafeBufferPointer<MpvfxPathElement>) -> R) -> R {
        path.map(cElement).withUnsafeBufferPointer(body)
    }

    /// Path kinds of the C interface: 0 move, 1 line, 2 cubic (controls in x0/y0 and x1/y1, end in x2/y2), 3 close.
    static func cElement(_ element: RasterPathElement) -> MpvfxPathElement {
        var e = MpvfxPathElement()
        switch element {
        case let .move(x, y):
            e.kind = 0; e.x0 = x; e.y0 = y
        case let .line(x, y):
            e.kind = 1; e.x0 = x; e.y0 = y
        case let .curve(c1x, c1y, c2x, c2y, x, y):
            e.kind = 2; e.x0 = c1x; e.y0 = c1y; e.x1 = c2x; e.y1 = c2y; e.x2 = x; e.y2 = y
        case .close:
            e.kind = 3
        }
        return e
    }
}
