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
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared

/// A clip's fit (`clip.fit`: Fit, Fill, Stretch) in the preview painter and in the export frames it paints: a 16:9
/// picture in a 9:16 project, drawn at a tenth of its size (108×192 view px for the 1080×1920 canvas).
final class MediaFitTests: XCTestCase {
    static let view = CanvasRect(x: 0, y: 0, width: 108, height: 192)
    static let scale = 0.1
    static let background: [UInt8] = [0x10, 0x20, 0x30, 255]

    /// A 1080×1920 project at 10 fps holding one 1920×1080 still `W` (frames 0…9); `extra` adds keys to the clip.
    static func document(_ extra: String = "", canvas: (Int, Int) = (1080, 1920)) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"project:fit","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":\#(canvas.0),"height":\#(canvas.1),"background":"#102030"},
         "assets":[{"id":"w","kind":"image","name":"w.png","source":"w.png","durationFrames":100,"width":1920,"height":1080}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"t1","kind":"video","clips":[
           {"id":"W","assetId":"w","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]\#(extra)}]}]}}
        """#), engine: nil)
    }

    static func composition(_ extra: String = "", canvas: (Int, Int) = (1080, 1920)) throws -> PreviewComposition {
        PreviewComposition(document: try document(extra, canvas: canvas), projectDir: URL(fileURLWithPath: "/proj"),
                           engine: nil, fileExists: { _ in true })
    }

    /// A 16:9 solid picture, as the decoder returns the still.
    static func picture(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CanvasImage { PreviewCompositorTests.solid(r, g, b, w: 16, h: 9) }

    /// The recorded drawing of the clip's layer at frame 0.
    func recorded(_ extra: String = "") throws -> PreviewRecordingCanvas {
        let layer = try XCTUnwrap(try Self.composition(extra).layers(at: 0).first)
        let c = PreviewRecordingCanvas()
        PreviewPainter.draw(layer, image: Self.picture(9, 0, 0), on: c, frame: Self.view, scale: Self.scale)
        return c
    }

    func exported(_ extra: String = "", image: CanvasImage) throws -> (frame: CanvasImage, asked: [(Int, Int)]) {
        let p = try ExportFramePainter(composition: try Self.composition(extra), width: 108, height: 192, pad: .transparent)
        var asked: [(Int, Int)] = []
        let frame = try p.paint(time: 0) { _, _, w, h in asked.append((w, h)); return image }
        return (frame, asked)
    }

    func pixel(_ img: CanvasImage, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * img.width + x) * 4
        return Array(img.rgba[i..<i + 4])
    }

    func assertRect(_ a: CanvasRect?, _ b: CanvasRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nothing drawn", file: file, line: line) }
        for (x, y) in [(a.x, b.x), (a.y, b.y), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: 1e-9, "\(a) is not \(b)", file: file, line: line)
        }
    }

    // Acceptance: without `fit`, a clip renders exactly as today.
    func testWithoutFitTheClipIsLetterboxedInItsNaturalBoxAsBefore() throws {
        let layer = try XCTUnwrap(try Self.composition().layers(at: 0).first)
        XCTAssertNil(layer.fit)
        XCTAssertEqual(layer.box, CanvasRect(x: 0, y: 656, width: 1080, height: 608), "the fit of the natural size, centred")
        let c = try recorded()
        assertRect(c.images.first?.rect, CanvasRect(x: 0, y: 65.6, width: 108, height: 60.8))
        XCTAssertFalse(c.ops.contains { if case .clip = $0 { return true }; return false }, "nothing clips an uncropped Fit picture")
        XCTAssertEqual(try recorded(#","fit":"fit""#).ops, c.ops, "a written-out Fit draws the same")
        let out = try exported(image: Self.picture(255, 0, 0))
        XCTAssertEqual(pixel(out.frame, 54, 10), Self.background, "background above the letterboxed picture")
        XCTAssertEqual(pixel(out.frame, 54, 96), [255, 0, 0, 255])
    }

    // Acceptance: Fill on a 1920×1080 picture in a 1080×1920 box covers the whole box, keeping the picture's aspect.
    func testFillCoversTheWholeBoxWithNoTransparentPixelsAndKeepsTheAspect() throws {
        let layer = try XCTUnwrap(try Self.composition(#","fit":"fill""#).layers(at: 0).first)
        XCTAssertEqual(layer.fit, .fill)
        XCTAssertEqual(layer.box, CanvasRect(x: 0, y: 0, width: 1080, height: 1920), "an untouched Fill clip's box is the frame")
        let c = try recorded(#","fit":"fill""#)
        let r = try XCTUnwrap(c.images.first?.rect)
        XCTAssertEqual(r.width / r.height, 16.0 / 9.0, accuracy: 1e-9, "the picture keeps its aspect")
        XCTAssertEqual(r.height, 192, accuracy: 1e-9); XCTAssertEqual(r.midX, 54, accuracy: 1e-9)
        XCTAssertTrue(r.x <= 0 && r.maxX >= 108 && r.y <= 0 && r.maxY >= 192, "covers the box: \(r)")
        let clip = try XCTUnwrap(c.ops.firstIndex(of: .clip(.rect(Self.view))), "the overflow is clipped to the box")
        let image = try XCTUnwrap(c.ops.firstIndex { if case .image = $0 { return true }; return false })
        XCTAssertLessThan(clip, image)
        let out = try exported(#","fit":"fill""#, image: Self.picture(255, 0, 0))
        let off = stride(from: 0, to: out.frame.rgba.count, by: 4).filter { i in
            out.frame.rgba[i] < 250 || out.frame.rgba[i + 1] > 5 || out.frame.rgba[i + 2] > 5 || out.frame.rgba[i + 3] != 255
        }
        XCTAssertEqual(off.count, 0, "every pixel of the frame is the picture (first miss at byte \(off.first ?? -1))")
        XCTAssertEqual(out.asked.first?.0, 342, "decoded as wide as it is drawn, not scaled up from a contained frame")
        XCTAssertEqual(out.asked.first?.1, 192)
    }

    // Acceptance: Stretch maps the picture onto the box exactly.
    func testStretchMapsThePictureOntoTheBoxExactly() throws {
        let placed = #","fit":"stretch","staticParameters":{"layout.left":0,"layout.top":0,"layout.width":1080,"layout.height":960}"#
        let c = try recorded(placed)
        assertRect(c.images.first?.rect, CanvasRect(x: 0, y: 0, width: 108, height: 96))
        XCTAssertFalse(c.ops.contains { if case .clip = $0 { return true }; return false }, "a stretched picture is the box")
        let out = try exported(placed, image: Self.picture(0, 255, 0))
        XCTAssertEqual(pixel(out.frame, 2, 2), [0, 255, 0, 255], "the box's corner")
        XCTAssertEqual(pixel(out.frame, 54, 90), [0, 255, 0, 255], "the box's bottom edge, where Fit would leave a bar")
        XCTAssertEqual(pixel(out.frame, 54, 150), Self.background, "below the box")
        // An untouched Stretch clip is stretched over the whole frame.
        let whole = try exported(#","fit":"stretch""#, image: Self.picture(0, 255, 0))
        XCTAssertEqual(pixel(whole.frame, 54, 2), [0, 255, 0, 255]); XCTAssertEqual(pixel(whole.frame, 54, 189), [0, 255, 0, 255])
    }

    // Acceptance: preview and export use the same rect, since export reuses the preview painter.
    func testPreviewAndExportDrawTheSameFrameForEveryFit() throws {
        for extra in ["", #","fit":"fit""#, #","fit":"fill""#, #","fit":"stretch""#,
                      #","fit":"fill","staticParameters":{"layout.left":100,"layout.top":200,"layout.width":600,"layout.height":900}"#] {
            let comp = try Self.composition(extra)
            let layer = try XCTUnwrap(comp.layers(at: 0).first)
            let image = Self.picture(200, 40, 90)
            // The stage: the compositor drawing the cached still, as PlayerView asks it to.
            let cx = PreviewCompositor(decodesMedia: false)
            cx.composition = comp
            cx.cache.store(image, lane: layer.laneKey, frame: PreviewDecodeLane.stillFrame)
            let stage = try RasterCanvas(width: 108, height: 192)
            cx.draw(stage, in: Self.view, time: 0, elements: [], context: FrameDrawContext())
            XCTAssertEqual(cx.lastShown.map(\.clipId), ["W"], extra)
            let export = try exported(extra, image: image)
            XCTAssertEqual(stage.image().rgba, export.frame.rgba, "preview and export frames differ for \(extra)")
        }
    }

    /// Codex review on #133: a 16:9 picture stretched or filled onto the largest square canvas (16384 x 16384) is
    /// decoded within the engine's 16384 px picture bound, aspect kept, so export does not ask its reader for about
    /// 29128 x 16384 and fail.
    func testAWidePictureOnTheLargestSquareCanvasIsDecodedWithinTheEngineBound() throws {
        for fit in ["stretch", "fill"] {
            let comp = try Self.composition(#","fit":"\#(fit)""#, canvas: (16384, 16384))
            let layer = try XCTUnwrap(comp.layers(at: 0).first)
            XCTAssertEqual(layer.box, CanvasRect(x: 0, y: 0, width: 16384, height: 16384))
            let px = PreviewPainter.screenPixels(layer, viewScale: 1, backingScale: 1)
            XCTAssertEqual(px.width, 16384, accuracy: 1e-9, fit); XCTAssertEqual(px.height, 9216, accuracy: 1e-9, fit)
            XCTAssertLessThanOrEqual(Int(px.width.rounded(.up)), 16384, "export's reader size, \(fit)")
            // At a box below the bound the cover is not capped.
            let half = PreviewPainter.screenPixels(layer, viewScale: 0.25, backingScale: 1)
            XCTAssertEqual(half.width, 4096 * 16 / 9, accuracy: 1e-6, fit); XCTAssertEqual(half.height, 4096, accuracy: 1e-9, fit)
        }
    }

    func testAStretchedWidePictureOnALargeSquareCanvasExportsAsThePreviewDrawsIt() throws {
        for fit in ["stretch", "fill"] {
            let extra = #","fit":"\#(fit)""#
            let comp = try Self.composition(extra, canvas: (16384, 16384))
            let layer = try XCTUnwrap(comp.layers(at: 0).first)
            let view = CanvasRect(x: 0, y: 0, width: 128, height: 128)
            let image = Self.picture(200, 40, 90)
            let cx = PreviewCompositor(decodesMedia: false)
            cx.composition = comp
            cx.cache.store(image, lane: layer.laneKey, frame: PreviewDecodeLane.stillFrame)
            let stage = try RasterCanvas(width: 128, height: 128)
            cx.draw(stage, in: view, time: 0, elements: [], context: FrameDrawContext())
            let p = try ExportFramePainter(composition: comp, width: 128, height: 128, pad: .transparent)
            var asked: [(Int, Int)] = []
            let frame = try p.paint(time: 0) { _, _, w, h in asked.append((w, h)); return image }
            XCTAssertEqual(stage.image().rgba, frame.rgba, "preview and export frames differ for \(fit)")
            XCTAssertEqual(asked.first?.0, 228, fit); XCTAssertEqual(asked.first?.1, 128, fit)
            XCTAssertEqual(PreviewPainter.mediaRect(imageWidth: 16, imageHeight: 9, in: layer.box, fit: layer.fit).width,
                           fit == "stretch" ? 16384 : 16384 * 16 / 9.0, accuracy: 1e-6)
        }
    }
}
