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
import MpvfxPanels
import MpvfxShared

/// The colour-key preview views (issue #300): one keyed image clip over the project background, drawn through
/// `PreviewCompositor.draw` with `FrameDrawContext(colorKeyClipId:colorKeyView:)`. Result keys the green out to the
/// background, Matte shows the key's matte (black keyed out, white kept) and Source shows the raw frame; holding the
/// Option shortcut shows Source until the release restores Result, and export always paints Result.
final class ColorKeyViewTests: XCTestCase {
    static let background: [UInt8] = [0x10, 0x20, 0x30, 255]

    /// One stretched image clip ("KEY") filling the 100×50 canvas, with the default green chroma key enabled.
    static func composition() throws -> PreviewComposition {
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse("""
        {"schemaVersion":1,"id":"project:key","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":100,"height":50,"background":"#102030"},
         "assets":[{"id":"w","kind":"image","name":"w.png","source":"w.png","durationFrames":100,"width":100,"height":50}],
         "sequence":{"id":"s","name":"Main","tracks":[
          {"id":"t1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
           {"id":"KEY","assetId":"w","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,
            "effects":[{"id":"e1","effectId":"color-key","enabled":true,"parameters":{"v":1,"kind":"chroma"}}],
            "parameterTracks":[],"fit":"stretch"}]}]}}
        """), engine: nil)
        return PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil, fileExists: { _ in true })
    }

    /// Left half green (keyed out), right half red (kept): one picture exercises both sides of the key.
    static func halfGreenHalfRed(w: Int = 100, h: Int = 50) -> CanvasImage {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if x < w / 2 { rgba[o] = 0; rgba[o + 1] = 255; rgba[o + 2] = 0 } else { rgba[o] = 255; rgba[o + 1] = 0; rgba[o + 2] = 0 }
            }
        }
        return CanvasImage(width: w, height: h, rgba: rgba)
    }

    func pixel(_ img: CanvasImage, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * img.width + x) * 4
        return Array(img.rgba[i..<i + 4])
    }

    func context(_ view: ColorKeyViewMode) -> FrameDrawContext {
        FrameDrawContext(colorKeyClipId: "KEY", colorKeyView: view)
    }

    /// Draws the keyed clip in `view`, waiting for the async grade so Result (and a grade-derived Matte) is final.
    func drawn(_ view: ColorKeyViewMode, picture: CanvasImage? = nil) throws -> CanvasImage {
        let comp = try Self.composition()
        let cx = PreviewCompositor(decodesMedia: false)
        defer { cx.stopAll() }
        cx.composition = comp
        let layer = try XCTUnwrap(comp.layers(at: 0).first)
        XCTAssertEqual(layer.grade?.params.colorKey?.color, SIMD3(0, 1, 0), "the default key is green")
        cx.cache.store(picture ?? Self.halfGreenHalfRed(), lane: layer.laneKey, frame: PreviewDecodeLane.stillFrame)
        let frame = CanvasRect(x: 0, y: 0, width: 100, height: 50)
        cx.draw(PreviewRecordingCanvas(), in: frame, time: 0, elements: [], context: context(view))
        cx.grader.waitUntilIdle()
        let canvas = try RasterCanvas(width: 100, height: 50)
        cx.draw(canvas, in: frame, time: 0, elements: [], context: context(view))
        return canvas.image()
    }

    func testResultKeysGreenOutToTheBackgroundAndKeepsRed() throws {
        let img = try drawn(.result)
        XCTAssertEqual(pixel(img, 25, 25), Self.background, "green is keyed out: the background shows through")
        XCTAssertEqual(pixel(img, 75, 25), [255, 0, 0, 255], "red is kept")
    }

    func testMatteIsBlackForGreenAndWhiteForRed() throws {
        let img = try drawn(.matte)
        XCTAssertEqual(pixel(img, 25, 25), [0, 0, 0, 255], "keyed-out green reads black")
        XCTAssertEqual(pixel(img, 75, 25), [255, 255, 255, 255], "kept red reads white")
    }

    func testSourceShowsTheRawGreenFrame() throws {
        let img = try drawn(.source)
        XCTAssertEqual(pixel(img, 25, 25), [0, 255, 0, 255], "the source is unkeyed")
        XCTAssertEqual(pixel(img, 75, 25), [255, 0, 0, 255])
    }

    /// The Option hold (`PlayerView.colorKeyHold`) wins over the chosen view while down; releasing it at pointer-up
    /// restores Result. The contexts below are built the way `PlayerView.draw` builds them
    /// (`colorKeyHold ?? colorKeyView`).
    func testOptionHoldShowsSourceWhileDownAndResultAfterPointerUp() throws {
        let view = PlayerView(playback: PlaybackState(duration: 10))
        view.colorKeyView = .result
        let controller = PlayerController(view: view)
        controller.size = CanvasSize(1280, 800)
        controller.pointerDown(x: 10, y: 10, option: true)
        XCTAssertEqual(view.colorKeyHold, .source, "Option-press holds the source preview; no gesture starts")
        var img = try drawn(view.colorKeyHold ?? view.colorKeyView)
        XCTAssertEqual(pixel(img, 25, 25), [0, 255, 0, 255], "held: the raw source while Option is down")
        controller.pointerUp(x: 10, y: 10)
        XCTAssertNil(view.colorKeyHold, "release restores the chosen view")
        XCTAssertEqual(view.colorKeyHold ?? view.colorKeyView, .result)
        img = try drawn(view.colorKeyHold ?? view.colorKeyView)
        XCTAssertEqual(pixel(img, 25, 25), Self.background, "released: back to the keyed result")
        XCTAssertEqual(pixel(img, 75, 25), [255, 0, 0, 255])
    }

    /// Export never reads the preview's view mode: every view paints the same keyed Result bytes.
    func testExportPaintsTheSameKeyedResultRegardlessOfViewMode() throws {
        let comp = try Self.composition()
        func exported() throws -> CanvasImage {
            try ExportFramePainter(composition: comp, width: 100, height: 50, pad: .transparent).paint(time: 0) { _, _, _, _ in
                Self.halfGreenHalfRed()
            }
        }
        let first = try exported(), second = try exported()
        XCTAssertEqual(first.rgba, second.rgba, "export is stable: no view mode leaks into it")
        XCTAssertEqual(pixel(first, 25, 25), Self.background, "export keys the green out (Result)")
        XCTAssertEqual(pixel(first, 75, 25), [255, 0, 0, 255], "export keeps the red")
    }
}
