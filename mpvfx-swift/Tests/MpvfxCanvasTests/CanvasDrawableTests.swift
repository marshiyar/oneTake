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
import XCTest
@testable import MpvfxCanvas
#if os(Linux)
import CGtk3
#endif
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#endif

/// Issue #95: an image is converted to its backend's drawable once, not on every draw.
enum DrawableFixtures {
    /// A fresh 4x3 image every call (a shared one would carry its drawable from test to test): opaque pixels in the
    /// top row, translucent ones below, a fully transparent one in the corner.
    static var mixed: CanvasImage {
        CanvasImage(width: 4, height: 3, rgba: [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 200, 120, 40, 255,
            255, 0, 0, 128, 10, 200, 90, 64, 250, 250, 250, 200, 30, 60, 90, 1,
            0, 0, 0, 0, 255, 255, 255, 255, 128, 64, 32, 160, 90, 180, 45, 33,
        ])
    }
    static var opaque: CanvasImage {
        CanvasImage(width: 4, height: 3, rgba: (0..<12).flatMap { i -> [UInt8] in [UInt8(i * 20), UInt8(255 - i * 20), 77, 255] })
    }
    /// The rect the pixel tests draw into: scaled (4x3 into 7x5) and off the pixel grid.
    static let rect = CanvasRect(x: 0.5, y: 1, width: 7, height: 5)
    static let opacities = [1.0, 0.35, 0.6]
}

/// A drawable that counts how often it is made and freed.
final class CountingDrawable: CanvasDrawable {
    nonisolated(unsafe) static var made = 0
    let byteCount: Int
    let owner: Int
    init(bytes: Int, owner: Int = 0) { byteCount = bytes; self.owner = owner; Self.made += 1 }
}

final class CanvasDrawableModelTests: XCTestCase {
    func make(_ image: CanvasImage, owner: Int = 0) -> CountingDrawable? {
        image.drawable(CountingDrawable.self, reuse: { $0.owner == owner }, make: { CountingDrawable(bytes: image.rgba.count, owner: owner) })
    }
    func makeRepeatedly(_ image: CanvasImage, times: Int) -> Set<ObjectIdentifier> {
        Set((0..<times).compactMap { _ in make(image).map(ObjectIdentifier.init) })
    }

    func testOneImageDrawnAHundredTimesIsConvertedOnce() {
        let image = DrawableFixtures.mixed
        let before = CountingDrawable.made
        XCTAssertEqual(makeRepeatedly(image, times: 100).count, 1, "every draw gets the same drawable")
        XCTAssertEqual(CountingDrawable.made - before, 1)
        XCTAssertEqual(image.drawableConversions, 1)
    }

    func testCopiesShareTheConversionAndChangedPixelsDropIt() {
        let image = DrawableFixtures.mixed
        let first = make(image)
        let copy = image
        XCTAssertTrue(make(copy) === first, "a copy of the image draws the same drawable")
        var edited = image
        edited.rgba[0] = 1
        XCTAssertFalse(make(edited) === first, "changed pixels are converted again")
        XCTAssertEqual(image.drawableConversions, 1, "the original keeps its drawable")
        XCTAssertEqual(edited.drawableConversions, 1)
    }

    func testTheDrawableIsFreedWithTheLastCopyOfTheImage() {
        let live = CanvasImage.liveDrawableBytes
        weak var drawable: CountingDrawable?
        var image: CanvasImage? = DrawableFixtures.mixed
        drawable = image.flatMap { make($0) }
        let copy = image
        image = nil
        XCTAssertNotNil(drawable, "a copy still holds it")
        XCTAssertEqual(copy?.heldBytes, 48 * 2, "pixels plus drawable")
        XCTAssertEqual(CanvasImage.liveDrawableBytes - live, 48)
        withExtendedLifetime(copy) {}
        _ = consume copy
        XCTAssertNil(drawable, "freed with the last copy")
        XCTAssertEqual(CanvasImage.liveDrawableBytes, live, "and the ledger is back where it was")
    }

    func testAFailedConversionIsNotKeptAndAnotherOwnerMakesItsOwn() {
        let image = DrawableFixtures.opaque
        XCTAssertNil(image.drawable(CountingDrawable.self, make: { nil }))
        XCTAssertEqual(image.drawableConversions, 0)
        let a = make(image, owner: 1), b = make(image, owner: 2)
        XCTAssertFalse(a === b, "a drawable of another owner (render target) is made again")
        XCTAssertEqual(image.drawableConversions, 2)
        XCTAssertEqual(image.drawableBytes, 48, "only the current one is held")
        image.releaseDrawables()
        XCTAssertEqual(image.drawableBytes, 0)
        XCTAssertEqual(image, DrawableFixtures.opaque, "equality is the pixels only")
    }
}

/// Draws `image` into `rect` `times` times on `c`.
func drawRepeatedly(_ c: CanvasContext, _ image: CanvasImage, times: Int, opacity: Double = 1) {
    (0..<times).forEach { _ in c.drawImage(image, in: DrawableFixtures.rect, opacity: opacity) }
}

#if os(Linux)
/// The Cairo drawImage of before #95 (the same calls and per-pixel arithmetic): a new surface converted on every
/// draw. The pixel reference.
func legacyCairoDraw(_ cr: OpaquePointer, _ image: CanvasImage, in rect: CanvasRect, opacity: Double) {
    guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(image.width), Int32(image.height)),
          let data = cairo_image_surface_get_data(surface) else { return }
    defer { cairo_surface_destroy(surface) }
    cairo_surface_flush(surface)
    let stride = Int(cairo_image_surface_get_stride(surface))
    let w = image.width
    image.rgba.withUnsafeBytes { src in
        (0..<image.height).forEach { y in
            let row = UnsafeMutableRawPointer(data + y * stride).assumingMemoryBound(to: UInt32.self)
            (0..<w).forEach { x in
                let v = src.loadUnaligned(fromByteOffset: (y * w + x) * 4, as: UInt32.self)
                let a = v >> 24
                let r = (v & 0xFF) * a / 255, g = ((v >> 8) & 0xFF) * a / 255, b = ((v >> 16) & 0xFF) * a / 255
                row[x] = a == 255 ? (v & 0xFF00_FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF) : (a << 24) | (r << 16) | (g << 8) | b
            }
        }
    }
    cairo_surface_mark_dirty(surface)
    cairo_save(cr)
    cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height)
    cairo_clip(cr)
    cairo_translate(cr, rect.x, rect.y)
    cairo_scale(cr, rect.width / Double(image.width), rect.height / Double(image.height))
    cairo_set_source_surface(cr, surface, 0, 0)
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD)
    cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD)
    _ = opacity >= 1 ? cairo_paint(cr) : cairo_paint_with_alpha(cr, opacity)
    cairo_restore(cr)
}

final class CairoDrawableTests: XCTestCase {
    /// Pixels of `image` drawn twice (the second draw reuses the first one's surface) and by the legacy code.
    func newAndLegacy(_ image: CanvasImage, opacity: Double) -> (new: [UInt8], legacy: [UInt8]) {
        let t = CairoImageTarget(width: 8, height: 7), ref = CairoImageTarget(width: 8, height: 7)
        drawRepeatedly(t.canvas, image, times: 2, opacity: opacity)
        legacyCairoDraw(ref.canvas.cr, image, in: DrawableFixtures.rect, opacity: opacity)
        legacyCairoDraw(ref.canvas.cr, image, in: DrawableFixtures.rect, opacity: opacity)
        return (t.straightRGBA(), ref.straightRGBA())
    }
    func samePixels(_ image: CanvasImage) -> [Bool] {
        DrawableFixtures.opacities.map { newAndLegacy(image, opacity: $0).new == newAndLegacy(image, opacity: $0).legacy }
    }

    func testDrawingTheSameImageAHundredTimesConvertsItOnce() {
        let image = DrawableFixtures.mixed
        let t = CairoImageTarget(width: 8, height: 7)
        drawRepeatedly(t.canvas, image, times: 100)
        XCTAssertEqual(image.drawableConversions, 1)
        XCTAssertEqual(image.drawableBytes, Int(cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, 4)) * 3)
    }

    func testCachedDrawsMatchThePreviousCodePixelForPixel() {
        XCTAssertEqual(samePixels(DrawableFixtures.opaque), [true, true, true], "opaque at opacity 1, 0.35, 0.6")
        XCTAssertEqual(samePixels(DrawableFixtures.mixed), [true, true, true], "translucent at opacity 1, 0.35, 0.6")
    }
}
#endif

#if canImport(CoreGraphics) && canImport(CoreText)
final class CoreGraphicsDrawableTests: XCTestCase {
    /// The raw premultiplied bytes of an 8x7 y-down bitmap context after `draw`.
    func pixels(_ draw: (CoreGraphicsCanvas) -> Void) throws -> [UInt8] {
        let c = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: 8, height: 7))
        draw(c)
        let data = try XCTUnwrap(c.ctx.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: c.ctx.bytesPerRow * 7))
    }
    /// The Core Graphics drawImage of before #95, verbatim: a new CGImage over a new copy of the pixels on every draw.
    func legacyDraw(_ c: CoreGraphicsCanvas, _ image: CanvasImage, opacity: Double) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(image.rgba) as CFData),
              let cgImage = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        let rect = DrawableFixtures.rect
        c.ctx.saveGState()
        c.ctx.setAlpha(opacity < 1 ? opacity : 1)
        c.ctx.translateBy(x: rect.x, y: rect.maxY); c.ctx.scaleBy(x: 1, y: -1)
        c.ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        c.ctx.restoreGState()
    }
    func samePixels(_ image: CanvasImage) throws -> [Bool] {
        try DrawableFixtures.opacities.map { o in
            try pixels { drawRepeatedly($0, image, times: 2, opacity: o) } == pixels { legacyDraw($0, image, opacity: o); legacyDraw($0, image, opacity: o) }
        }
    }

    func testDrawingTheSameImageAHundredTimesConvertsItOnce() throws {
        let image = DrawableFixtures.mixed
        _ = try pixels { drawRepeatedly($0, image, times: 100) }
        XCTAssertEqual(image.drawableConversions, 1)
        XCTAssertEqual(image.drawableBytes, 48)
    }

    func testCachedDrawsMatchThePreviousCodePixelForPixel() throws {
        XCTAssertEqual(try samePixels(DrawableFixtures.opaque), [true, true, true], "opaque at opacity 1, 0.35, 0.6")
        XCTAssertEqual(try samePixels(DrawableFixtures.mixed), [true, true, true], "translucent at opacity 1, 0.35, 0.6")
    }
}
#endif

#if os(Windows)
final class Direct2DDrawableTests: XCTestCase {
    func testDrawingTheSameImageAHundredTimesConvertsItOncePerTarget() throws {
        let image = DrawableFixtures.mixed
        let t = try Direct2DImageTarget(width: 8, height: 7)
        drawRepeatedly(t.canvas, image, times: 100)
        let once = try t.straightRGBA()
        XCTAssertEqual(image.drawableConversions, 1)
        XCTAssertEqual(image.drawableBytes, 48)
        let other = try Direct2DImageTarget(width: 8, height: 7)
        drawRepeatedly(other.canvas, image, times: 100)
        XCTAssertEqual(image.drawableConversions, 2, "a second render target makes its own bitmap")
        XCTAssertEqual(try other.straightRGBA(), once, "and draws the same pixels")
        XCTAssertNil(other.canvas.drawError)
    }
}
#endif
