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
#if os(Linux)
import CGtk3
import Foundation

/// Cairo + Pango backend. Wraps a caller-owned cairo_t (e.g. GtkDrawingArea "draw").
public final class CairoCanvas: CanvasContext {
    public let cr: OpaquePointer
    public init(cr: OpaquePointer) { self.cr = cr }

    public var deviceScale: Double {
        var sx = 1.0, sy = 1.0
        if let target = cairo_get_target(cr) { cairo_surface_get_device_scale(target, &sx, &sy) }
        var m = cairo_matrix_t()
        cairo_get_matrix(cr, &m)
        return max(1, sx * (m.xx * m.xx + m.yx * m.yx).squareRoot())
    }

    public func save() { cairo_save(cr) }
    public func restore() { cairo_restore(cr) }
    public func translate(_ dx: Double, _ dy: Double) { cairo_translate(cr, dx, dy) }
    public func scale(_ sx: Double, _ sy: Double) { cairo_scale(cr, sx, sy) }
    public func rotate(_ radians: Double) { cairo_rotate(cr, radians) }

    private func apply(_ path: CanvasPath) {
        cairo_new_path(cr)
        for e in path.elements {
            switch e {
            case .move(let p): cairo_move_to(cr, p.x, p.y)
            case .line(let p): cairo_line_to(cr, p.x, p.y)
            case .curve(let a, let b, let p): cairo_curve_to(cr, a.x, a.y, b.x, b.y, p.x, p.y)
            case .close: cairo_close_path(cr)
            }
        }
    }
    private func setColor(_ c: CanvasColor) { cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a) }

    public func clip(_ path: CanvasPath) { apply(path); cairo_clip(cr) }
    public func fill(_ path: CanvasPath, _ color: CanvasColor) { apply(path); setColor(color); cairo_fill(cr) }
    public func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {
        apply(path); setColor(color)
        cairo_set_line_width(cr, style.width)
        style.dash.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, Int32($0.count), 0) }
        cairo_stroke(cr)
        cairo_set_dash(cr, nil, 0, 0)
    }

    private func layout(_ text: String, _ font: CanvasFont) -> OpaquePointer {
        let layout = pango_cairo_create_layout(cr)!
        let desc = pango_font_description_new()!
        pango_font_description_set_family(desc, font.family)
        // CSS px == Cairo user units; Pango absolute size is in device units * PANGO_SCALE.
        pango_font_description_set_absolute_size(desc, font.size * Double(PANGO_SCALE))
        let w: PangoWeight
        switch font.weight { case .regular: w = PANGO_WEIGHT_NORMAL; case .medium: w = PANGO_WEIGHT_MEDIUM; case .semibold: w = PANGO_WEIGHT_SEMIBOLD; case .bold: w = PANGO_WEIGHT_BOLD }
        pango_font_description_set_weight(desc, font.numericWeight.map { PangoWeight(UInt32(max(100, min(1000, $0)))) } ?? w)
        if font.italic { pango_font_description_set_style(desc, PANGO_STYLE_ITALIC) }
        pango_layout_set_font_description(layout, desc)
        pango_font_description_free(desc)
        pango_layout_set_text(layout, text, -1)
        return layout
    }

    public func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {
        let l = layout(text, font)
        defer { g_object_unref(UnsafeMutableRawPointer(l)) }
        // line-height: 1 -> place the ink box like CSS: top of the em box at origin.y.
        let baseline = Double(pango_layout_get_baseline(l)) / Double(PANGO_SCALE)
        var ink = PangoRectangle(), logical = PangoRectangle()
        pango_layout_get_pixel_extents(l, &ink, &logical)
        let ascentInEm = font.size * 0.8   // typical ascent share of a 1.0 line box
        setColor(color)
        cairo_move_to(cr, origin.x, origin.y + ascentInEm - baseline)
        pango_cairo_show_layout(cr, l)
    }

    public func textUnits(_ text: String, font: CanvasFont) -> [TextUnit] {
        let l = layout(text, font)
        defer { g_object_unref(UnsafeMutableRawPointer(l)) }
        return TextUnits.graphemes(text).map { range in
            let value = String(decoding: Array(text.utf16)[range], as: UTF16.self)
            let prefix = String(decoding: Array(text.utf16)[..<range.lowerBound], as: UTF16.self)
            var byte = prefix.utf8.count, boxes: [CanvasRect] = []
            for scalar in value.unicodeScalars {
                var r = PangoRectangle()
                pango_layout_index_to_pos(l, Int32(byte), &r)
                let x = Double(r.x) / Double(PANGO_SCALE), width = Double(r.width) / Double(PANGO_SCALE)
                boxes.append(CanvasRect(x: min(x, x + width), y: 0, width: abs(width), height: font.size))
                byte += scalar.utf8.count
            }
            return TextUnit(range: range, rect: TextUnits.union(boxes))
        }
    }
    public func textWordRanges(_ text: String) -> [Range<Int>] {
        let l = layout(text, CanvasFont(size: 12))
        defer { g_object_unref(UnsafeMutableRawPointer(l)) }
        var offset = 0, start: Int?, result: [Range<Int>] = []
        let scalars = Array(text.unicodeScalars)
        for index in 0...scalars.count {
            let flags = mpvfx_pango_word_boundary(l, Int32(index))
            if flags & 2 != 0, let s = start { result.append(s..<offset); start = nil }
            if flags & 1 != 0 { start = offset }
            if index < scalars.count { offset += scalars[index].utf16.count }
        }
        return result
    }
    public func measureText(_ text: String, font: CanvasFont) -> CanvasSize {
        let l = layout(text, font)
        defer { g_object_unref(UnsafeMutableRawPointer(l)) }
        var ink = PangoRectangle(), logical = PangoRectangle()
        pango_layout_get_pixel_extents(l, &ink, &logical)
        return CanvasSize(Double(logical.width), Double(logical.height))
    }

    public func drawImage(_ image: CanvasImage, in rect: CanvasRect) { drawImage(image, in: rect, opacity: 1) }

    public func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double) {
        guard image.width > 0, image.height > 0, opacity > 0,
              let converted = image.drawable(CairoImageSurface.self, make: { CairoImageSurface(image) }) else { return }
        let surface = converted.surface
        cairo_save(cr)
        cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height)
        cairo_clip(cr)
        cairo_translate(cr, rect.x, rect.y)
        cairo_scale(cr, rect.width / Double(image.width), rect.height / Double(image.height))
        cairo_set_source_surface(cr, surface, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD)
        // Edge pixels extend instead of fading to transparent at the image border when scaled.
        cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD)
        if opacity >= 1 { cairo_paint(cr) } else { cairo_paint_with_alpha(cr, opacity) }
        cairo_restore(cr)
    }
}

/// A `CanvasImage` as a premultiplied native-endian ARGB32 cairo image surface, made once per image and painted by
/// every draw of it (and of its copies).
public final class CairoImageSurface: CanvasDrawable {
    public let surface: OpaquePointer
    public let byteCount: Int

    /// Nil when cairo cannot make the surface (out of memory, a size cairo refuses).
    init?(_ image: CanvasImage) {
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(image.width), Int32(image.height)) else { return nil }
        guard cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS, let data = cairo_image_surface_get_data(surface) else {
            cairo_surface_destroy(surface); return nil
        }
        self.surface = surface
        cairo_surface_flush(surface)
        let stride = Int(cairo_image_surface_get_stride(surface))
        byteCount = stride * image.height
        Self.premultiply(image, into: data, stride: stride)
        cairo_surface_mark_dirty(surface)
    }
    deinit { cairo_surface_destroy(surface) }

    /// Straight RGBA8 -> premultiplied ARGB32 rows (the conversion every draw did before #95, unchanged).
    static func premultiply(_ image: CanvasImage, into data: UnsafeMutablePointer<UInt8>, stride: Int) {
        let w = image.width
        image.rgba.withUnsafeBytes { src in
            for y in 0..<image.height {
                let row = UnsafeMutableRawPointer(data + y * stride).assumingMemoryBound(to: UInt32.self)
                let base = y * w * 4
                for x in 0..<w {
                    // One load per pixel: R | G << 8 | B << 16 | A << 24 on these little-endian targets.
                    let v = src.loadUnaligned(fromByteOffset: base + x * 4, as: UInt32.self)
                    let a = v >> 24
                    if a == 255 {
                        row[x] = (v & 0xFF00_FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF)   // swap R and B
                    } else {
                        let r = (v & 0xFF) * a / 255, g = ((v >> 8) & 0xFF) * a / 255, b = ((v >> 16) & 0xFF) * a / 255
                        row[x] = (a << 24) | (r << 16) | (g << 8) | b   // premultiplied native-endian ARGB
                    }
                }
            }
        }
    }
}

/// Offscreen ARGB32 target: used by tests and snapshotting.
public final class CairoImageTarget {
    public let surface: OpaquePointer
    public let canvas: CairoCanvas
    public let width: Int, height: Int
    public init(width: Int, height: Int) {
        self.width = width; self.height = height
        surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height))!
        canvas = CairoCanvas(cr: cairo_create(surface)!)
    }
    deinit { cairo_destroy(canvas.cr); cairo_surface_destroy(surface) }

    /// Straight-alpha RGBA8 of pixel (x, y).
    public func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        cairo_surface_flush(surface)
        let stride = Int(cairo_image_surface_get_stride(surface))
        let p = cairo_image_surface_get_data(surface)! + y * stride + x * 4
        let v = p.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        let a = (v >> 24) & 0xFF
        func un(_ c: UInt32) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (c * 255 + a / 2) / a)) }
        return (un((v >> 16) & 0xFF), un((v >> 8) & 0xFF), un(v & 0xFF), UInt8(a))
    }
    /// The whole surface as straight-alpha RGBA8, row by row.
    public func straightRGBA() -> [UInt8] {
        cairo_surface_flush(surface)
        let stride = Int(cairo_image_surface_get_stride(surface))
        let base = cairo_image_surface_get_data(surface)!
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = UnsafeRawPointer(base + y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let v = row[x], a = (v >> 24) & 0xFF, i = (y * width + x) * 4
                guard a > 0 else { continue }
                func un(_ c: UInt32) -> UInt8 { UInt8(min(255, (c * 255 + a / 2) / a)) }
                out[i] = un((v >> 16) & 0xFF); out[i + 1] = un((v >> 8) & 0xFF); out[i + 2] = un(v & 0xFF); out[i + 3] = UInt8(a)
            }
        }
        return out
    }
    @discardableResult public func writePNG(_ path: String) -> Int32 { Int32(cairo_surface_write_to_png(surface, path).rawValue) }
}

/// PNG decoding through Cairo, for UI assets read off disk. Straight-alpha RGBA8.
public enum CairoPNG {
    public static func load(_ path: String) -> CanvasImage? {
        guard let surf = cairo_image_surface_create_from_png(path) else { return nil }
        defer { cairo_surface_destroy(surf) }
        guard cairo_surface_status(surf) == CAIRO_STATUS_SUCCESS else { return nil }
        let w = Int(cairo_image_surface_get_width(surf)), h = Int(cairo_image_surface_get_height(surf))
        // Normalise any format (RGB24, A8, …) to ARGB32 by painting it.
        let t = CairoImageTarget(width: w, height: h)
        cairo_set_source_surface(t.canvas.cr, surf, 0, 0); cairo_paint(t.canvas.cr)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let p = t.pixel(x, y), i = (y * w + x) * 4
            out[i] = p.r; out[i + 1] = p.g; out[i + 2] = p.b; out[i + 3] = p.a } }
        return CanvasImage(width: w, height: h, rgba: out)
    }
}
#endif
