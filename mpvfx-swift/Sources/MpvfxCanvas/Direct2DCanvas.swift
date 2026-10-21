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
#if os(Windows)
// Direct2D + DirectWrite backend. The COM calls (path geometries, the solid brush, clip layers, DirectWrite text
// layouts, bitmaps, WIC readback) are in Sources/CMpvfxWin32/d2d.cpp behind a flat C interface, because
// DirectWrite has no C interface Swift could import; this class keeps the canvas state (transform stack, clip
// layers per save) and turns CanvasPath into the C path arrays.
import CMpvfxWin32
import Foundation

/// A failed Direct2D / DirectWrite / WIC call (HRESULT).
public struct Direct2DError: Error, Equatable, CustomStringConvertible {
    public let call: String
    public let hresult: Int32
    public init(_ call: String, _ hresult: Int32) { self.call = call; self.hresult = hresult }
    public var description: String { "\(call) failed (HRESULT 0x\(String(UInt32(bitPattern: hresult), radix: 16, uppercase: true)))" }
}

@inline(__always) func check(_ call: String, _ hr: Int32) throws { if hr < 0 { throw Direct2DError(call, hr) } }

/// Row-vector affine matrix in D2D1_MATRIX_3X2_F order: p' = (x m11 + y m21 + dx, x m12 + y m22 + dy).
struct D2DMatrix: Equatable {
    var m11: Double = 1, m12: Double = 0, m21: Double = 0, m22: Double = 1, dx: Double = 0, dy: Double = 0
    /// `m` applied first, then self (a user-space operation on the current transform).
    func prepending(_ m: D2DMatrix) -> D2DMatrix {
        D2DMatrix(m11: m.m11 * m11 + m.m12 * m21, m12: m.m11 * m12 + m.m12 * m22,
                  m21: m.m21 * m11 + m.m22 * m21, m22: m.m21 * m12 + m.m22 * m22,
                  dx: m.dx * m11 + m.dy * m21 + dx, dy: m.dx * m12 + m.dy * m22 + dy)
    }
    var floats: [Float] { [Float(m11), Float(m12), Float(m21), Float(m22), Float(dx), Float(dy)] }
}

/// CanvasPath as the C path arrays (kinds + x, y float pairs).
struct D2DPathArrays {
    var kinds: [UInt8] = []
    var points: [Float] = []
    init(_ path: CanvasPath) {
        for e in path.elements {
            switch e {
            case .move(let p): kinds.append(UInt8(MPVFX_PATH_MOVE)); points += [Float(p.x), Float(p.y)]
            case .line(let p): kinds.append(UInt8(MPVFX_PATH_LINE)); points += [Float(p.x), Float(p.y)]
            case let .curve(c1, c2, p):
                kinds.append(UInt8(MPVFX_PATH_CUBIC))
                points += [Float(c1.x), Float(c1.y), Float(c2.x), Float(c2.y), Float(p.x), Float(p.y)]
            case .close: kinds.append(UInt8(MPVFX_PATH_CLOSE))
            }
        }
    }
    /// The arrays as an MpvfxPath, valid inside `body`.
    func with<R>(_ body: (UnsafePointer<MpvfxPath>) -> R) -> R {
        kinds.withUnsafeBufferPointer { k in
            points.withUnsafeBufferPointer { p in
                var path = MpvfxPath(kinds: k.baseAddress, count: Int32(k.count), points: p.baseAddress)
                return body(&path)
            }
        }
    }
}

extension CanvasColor {
    var d2d: MpvfxColor { MpvfxColor(r: Float(r), g: Float(g), b: Float(b), a: Float(a)) }
}

/// `text` in `font` as an MpvfxText, valid inside `body`.
func withDirectWriteText<R>(_ text: String, _ font: CanvasFont, _ body: (UnsafePointer<MpvfxText>) -> R) -> R {
    let units = Array(text.utf16)
    return units.withUnsafeBufferPointer { t in
        font.family.withCString(encodedAs: UTF16.self) { family in
            var spec = MpvfxText(text: t.baseAddress, length: Int32(t.count), family: family, size: Float(font.size),
                                 weight: directWriteWeight(font), italic: font.italic ? 1 : 0)
            return body(&spec)
        }
    }
}

/// DirectWrite font parameters of a CanvasFont: numeric weight (a text layer's) or the named weight.
func directWriteWeight(_ font: CanvasFont) -> Int32 {
    if let n = font.numericWeight { return Int32(max(1, min(999, n))) }
    switch font.weight { case .regular: return 400; case .medium: return 500; case .semibold: return 600; case .bold: return 700 }
}

/// Draws on a Direct2D render target (a window's or an offscreen bitmap's) between the host's begin and end draw.
public final class Direct2DCanvas: CanvasContext {
    public let target: OpaquePointer
    /// Device pixels per DIP (the target's DPI / 96).
    public let dpiScale: Double
    /// The first drawing failure since the canvas was made (the protocol's draw calls cannot throw); hosts check it
    /// after a frame so a failed draw is reported instead of silently missing.
    public private(set) var drawError: Direct2DError?
    private var current = D2DMatrix()
    private var transforms: [D2DMatrix] = []
    /// Clip layers pushed since each save(); restore() pops that many.
    private var layers: [Int] = [0]

    /// Starts from the identity transform (a render target keeps its last transform across drawing passes).
    public init(target: OpaquePointer, dpiScale: Double = 1) {
        self.target = target; self.dpiScale = dpiScale
        setTransform()
    }

    /// The target ended its drawing pass, which popped every clip layer: the saves no longer own any.
    func layersPopped() { layers = layers.map { _ in 0 } }

    private func record(_ call: String, _ hr: Int32) {
        if hr < 0, drawError == nil { drawError = Direct2DError(call, hr) }
    }
    private func setTransform() { current.floats.withUnsafeBufferPointer { mpvfx_d2d_set_transform(target, $0.baseAddress) } }
    private func multiply(_ m: D2DMatrix) { current = current.prepending(m); setTransform() }

    public var deviceScale: Double { dpiScale * max(1e-6, abs(current.m11 * current.m22 - current.m12 * current.m21).squareRoot()) }

    public func save() { transforms.append(current); layers.append(0) }
    public func restore() {
        guard let pushed = layers.popLast(), let t = transforms.popLast() else { return }
        for _ in 0..<pushed { mpvfx_d2d_pop_clip(target) }
        if layers.isEmpty { layers = [0] }
        current = t; setTransform()
    }
    public func translate(_ dx: Double, _ dy: Double) { multiply(D2DMatrix(dx: dx, dy: dy)) }
    public func scale(_ sx: Double, _ sy: Double) { multiply(D2DMatrix(m11: sx, m22: sy)) }
    public func rotate(_ r: Double) { multiply(D2DMatrix(m11: cos(r), m12: sin(r), m21: -sin(r), m22: cos(r))) }

    public func clip(_ path: CanvasPath) {
        let hr = D2DPathArrays(path).with { mpvfx_d2d_push_clip(target, $0) }
        record("PushLayer", hr)
        if hr >= 0 { layers[layers.count - 1] += 1 }
    }

    public func fill(_ path: CanvasPath, _ c: CanvasColor) {
        record("FillGeometry", D2DPathArrays(path).with { mpvfx_d2d_fill_path(target, $0, c.d2d) })
    }

    public func stroke(_ path: CanvasPath, _ c: CanvasColor, _ style: StrokeStyle) {
        let dashes = style.dash.map(Float.init)
        record("DrawGeometry", D2DPathArrays(path).with { p in
            dashes.withUnsafeBufferPointer { d in
                var stroke = MpvfxStroke(width: Float(style.width), dashes: d.baseAddress, dash_count: Int32(d.count))
                return mpvfx_d2d_stroke_path(target, p, &stroke, c.d2d)
            }
        })
    }

    public func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color c: CanvasColor) {
        guard !text.isEmpty else { return }
        let hr = withDirectWriteText(text, font) {
            mpvfx_d2d_draw_text(target, $0, MpvfxPoint(x: Float(origin.x), y: Float(origin.y)), c.d2d)
        }
        record("DrawTextLayout", hr)
    }

    public func textUnits(_ text: String, font: CanvasFont) -> [TextUnit] {
        let ranges = TextUnits.graphemes(text)
        let starts = ranges.map { Int32($0.lowerBound) }, lengths = ranges.map { Int32($0.count) }
        var rects = [MpvfxRect](repeating: MpvfxRect(x: 0, y: 0, w: 0, h: 0), count: ranges.count)
        let hr = withDirectWriteText(text, font) { spec in
            starts.withUnsafeBufferPointer { start in lengths.withUnsafeBufferPointer { length in
                rects.withUnsafeMutableBufferPointer { rect in
                    mpvfx_d2d_text_ranges(spec, start.baseAddress, length.baseAddress, rect.baseAddress, Int32(ranges.count))
                }
            } }
        }
        record("IDWriteTextLayout::HitTestTextRange", hr)
        guard hr >= 0 else { return [] }
        return zip(ranges, rects).map { range, r in
            TextUnit(range: range, rect: CanvasRect(x: Double(r.x), y: Double(r.y), width: Double(r.w), height: Double(r.h)))
        }
    }
    public func textWordRanges(_ text: String) -> [Range<Int>] {
        var stops = [UInt8](repeating: 0, count: text.utf16.count + 1)
        let hr = withDirectWriteText(text, CanvasFont(size: 12)) { spec in
            stops.withUnsafeMutableBufferPointer { mpvfx_d2d_word_stops(spec, $0.baseAddress) }
        }
        record("ScriptBreak", hr)
        guard hr >= 0 else { return [] }
        let boundaries = stops.indices.filter { stops[$0] != 0 }
        return zip(boundaries, boundaries.dropFirst()).map { $0..<$1 }
    }

    /// A failed measurement is recorded like a failed draw (reported after the frame); the text then measures
    /// zero wide and one em tall.
    public func measureText(_ text: String, font: CanvasFont) -> CanvasSize {
        let (size, hr) = Self.layoutSize(text, font: font)
        record("IDWriteTextLayout::GetMetrics", hr)
        return hr < 0 ? CanvasSize(0, font.size) : size
    }

    /// DirectWrite layout size of `text` (needs no render target).
    public static func measure(_ text: String, font: CanvasFont) throws -> CanvasSize {
        let (size, hr) = layoutSize(text, font: font)
        try check("IDWriteTextLayout::GetMetrics", hr)
        return size
    }

    static func layoutSize(_ text: String, font: CanvasFont) -> (CanvasSize, Int32) {
        var w: Float = 0, h: Float = 0
        let hr = withDirectWriteText(text, font) { mpvfx_d2d_measure_text($0, &w, &h) }
        return (CanvasSize(Double(w), Double(h)), hr)
    }

    public func drawImage(_ image: CanvasImage, in rect: CanvasRect) { drawImage(image, in: rect, opacity: 1) }

    public func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double) {
        guard image.width > 0, image.height > 0, opacity > 0 else { return }
        var created: Int32 = 0
        let target = self.target
        let made = image.drawable(Direct2DBitmap.self, reuse: { mpvfx_d2d_bitmap_belongs_to($0.bitmap, target) != 0 }, make: {
            let (bitmap, hr) = Direct2DBitmap.make(image, on: target)
            created = hr
            return bitmap
        })
        record("CreateBitmap", created)
        guard let made else { return }
        let destination = MpvfxRect(x: Float(rect.x), y: Float(rect.y), w: Float(rect.width), h: Float(rect.height))
        record("DrawBitmap", mpvfx_d2d_draw_bitmap(target, made.bitmap, destination, Float(min(1, opacity))))
    }
}

/// A `CanvasImage` as a premultiplied BGRA Direct2D bitmap of one render target, made once per image and target and
/// drawn by every draw of it (and of its copies) there. Drawn on another target it is made again for that target.
public final class Direct2DBitmap: CanvasDrawable {
    let bitmap: OpaquePointer
    public let byteCount: Int
    init(_ bitmap: OpaquePointer) { self.bitmap = bitmap; byteCount = Int(mpvfx_d2d_bitmap_bytes(bitmap)) }
    deinit { mpvfx_d2d_bitmap_release(bitmap) }

    /// The bitmap, or nil with the failing HRESULT.
    static func make(_ image: CanvasImage, on target: OpaquePointer) -> (Direct2DBitmap?, Int32) {
        var out: OpaquePointer?
        let hr = image.rgba.withUnsafeBufferPointer {
            var pixels = MpvfxPixels(rgba: $0.baseAddress, width: UInt32(image.width), height: UInt32(image.height))
            return mpvfx_d2d_bitmap_create(target, &pixels, &out)
        }
        guard hr >= 0, let out else { return (nil, hr < 0 ? hr : -1) }
        return (Direct2DBitmap(out), hr)
    }
}

/// Offscreen Direct2D target (a WIC premultiplied BGRA bitmap): tests, export text and window snapshots.
public final class Direct2DImageTarget {
    public let width: Int, height: Int
    let target: OpaquePointer
    public let canvas: Direct2DCanvas
    private var drawing = false

    public init(width: Int, height: Int) throws {
        try check("D2D1CreateFactory/DWriteCreateFactory/WIC", mpvfx_d2d_init())
        var t: OpaquePointer?
        try check("CreateWicBitmapRenderTarget", mpvfx_d2d_target_create_bitmap(UInt32(width), UInt32(height), &t))
        guard let t else { throw Direct2DError("CreateWicBitmapRenderTarget", -1) }
        self.width = width; self.height = height; target = t
        canvas = Direct2DCanvas(target: t)
        mpvfx_d2d_begin_draw(t); drawing = true
    }
    deinit {
        if drawing { _ = mpvfx_d2d_end_draw(target) }
        mpvfx_d2d_target_release(target)
    }

    /// Ends the drawing pass (the pixels reach the bitmap; clips still pushed are popped) and reports the first
    /// failed draw call of the canvas.
    private func endPass() throws {
        if drawing {
            drawing = false
            let hr = mpvfx_d2d_end_draw(target)
            canvas.layersPopped()
            try check("EndDraw", hr)
        }
        if let e = canvas.drawError { throw e }
    }
    private func resume() { mpvfx_d2d_begin_draw(target); drawing = true }

    /// The whole bitmap as straight-alpha RGBA8, row by row. Drawing can continue after it (with no clip).
    public func straightRGBA() throws -> [UInt8] {
        try endPass()
        defer { resume() }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let hr = out.withUnsafeMutableBufferPointer { mpvfx_d2d_read_rgba(target, $0.baseAddress, UInt32($0.count)) }
        try check("IWICBitmap::Lock", hr)
        return out
    }

    /// Straight-alpha RGBA8 of pixel (x, y).
    public func pixel(_ x: Int, _ y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let px = try straightRGBA(), i = (y * width + x) * 4
        return (px[i], px[i + 1], px[i + 2], px[i + 3])
    }

    /// The bitmap as a PNG file.
    public func writePNG(_ path: String) throws {
        try endPass()
        defer { resume() }
        let hr = path.withCString(encodedAs: UTF16.self) { mpvfx_d2d_write_png(target, $0) }
        try check("WIC PNG encode", hr)
    }
}
#endif
