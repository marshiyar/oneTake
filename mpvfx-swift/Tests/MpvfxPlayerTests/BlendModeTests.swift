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
import MpvfxColor
import MpvfxShared

/// Clip blend modes (`clip.style.blend`) in the preview painter and the export frames it paints: a stretched still on
/// the bottom track and a second one on top, blended pixel by pixel with `BlendShader`.
final class BlendModeTests: XCTestCase {
    static let bottom: (UInt8, UInt8, UInt8) = (200, 100, 50)
    static let top: (UInt8, UInt8, UInt8) = (128, 64, 250)

    static func composition(blend: String?, opacity: Double? = nil) throws -> PreviewComposition {
        let style = blend.map { #","style":{"blend":"\#($0)"}"# } ?? ""
        let statics = opacity.map { #","staticParameters":{"transform.opacity":\#($0)}"# } ?? ""
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"project:blend","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":100,"height":50,"background":"#102030"},
         "assets":[{"id":"w","kind":"image","name":"w.png","source":"w.png","durationFrames":100,"width":16,"height":9}],
         "sequence":{"id":"s","name":"Main","tracks":[
          {"id":"t2","kind":"video","lane":{"authoredTrack":2,"displayTrack":0},"clips":[
           {"id":"TOP","assetId":"w","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"fit":"stretch"\#(style)\#(statics)}]},
          {"id":"t1","kind":"video","lane":{"authoredTrack":1,"displayTrack":1},"clips":[
           {"id":"BOTTOM","assetId":"w","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"fit":"stretch"}]}]}}
        """#), engine: nil)
        return PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil, fileExists: { _ in true })
    }

    static func picture(_ c: (UInt8, UInt8, UInt8)) -> CanvasImage { PreviewCompositorTests.solid(c.0, c.1, c.2, w: 16, h: 9) }
    static func image(for layer: PreviewLayer) -> CanvasImage { picture(layer.clipId == "TOP" ? top : bottom) }

    func pixel(_ img: CanvasImage, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * img.width + x) * 4
        return Array(img.rgba[i..<i + 4])
    }

    func exported(_ comp: PreviewComposition) throws -> CanvasImage {
        try ExportFramePainter(composition: comp, width: 100, height: 50, pad: .transparent).paint(time: 0) { layer, _, _, _ in Self.image(for: layer) }
    }

    func stage(_ comp: PreviewComposition) throws -> CanvasImage {
        let cx = PreviewCompositor(decodesMedia: false)
        cx.composition = comp
        for layer in comp.layers(at: 0) { cx.cache.store(Self.image(for: layer), lane: layer.laneKey, frame: PreviewDecodeLane.stillFrame) }
        let canvas = try RasterCanvas(width: 100, height: 50)
        cx.draw(canvas, in: CanvasRect(x: 0, y: 0, width: 100, height: 50), time: 0, elements: [], context: FrameDrawContext())
        return canvas.image()
    }

    func expected(_ mode: NativeBlendMode) -> [UInt8] {
        let b = SIMD4<Float>(200, 100, 50, 255) / 255, s = SIMD4<Float>(128, 64, 250, 255) / 255
        let c = BlendShader.composite(mode, backdrop: b, source: s)
        return (0..<4).map { UInt8((c[$0] * 255).rounded()) }
    }

    // Acceptance: every mode blends the top clip with the one under it, in export.
    func testEveryModeBlendsTheClipWithTheLayerUnderIt() throws {
        for mode in NativeBlendMode.allCases {
            let comp = try Self.composition(blend: mode == .normal ? nil : mode.rawValue)
            XCTAssertEqual(comp.layers(at: 0).last?.blend, mode)
            let got = pixel(try exported(comp), 50, 25), want = expected(mode)
            for k in 0..<4 { XCTAssertEqual(Int(got[k]), Int(want[k]), accuracy: 1, "\(mode) channel \(k)") }
        }
        XCTAssertEqual(expected(.multiply)[0], 100, "128/255 of 200")
        XCTAssertEqual(expected(.normal), [128, 64, 250, 255])
    }

    // Acceptance: preview and export use one formula, so the frames are the same bytes.
    func testPreviewAndExportDrawTheSameFrameForEveryMode() throws {
        for mode in NativeBlendMode.allCases {
            let comp = try Self.composition(blend: mode.rawValue)
            XCTAssertEqual(try stage(comp).rgba, try exported(comp).rgba, "\(mode)")
        }
    }

    func testOpacityScalesTheBlendedLayer() throws {
        let half = pixel(try exported(try Self.composition(blend: "multiply", opacity: 0.5)), 50, 25)
        let full = pixel(try exported(try Self.composition(blend: "multiply")), 50, 25)
        // Half of the blended result over the plain backdrop (200, 100, 50).
        XCTAssertEqual(Int(half[0]), (Int(full[0]) + 200) / 2, accuracy: 1)
        XCTAssertEqual(Int(half[2]), (Int(full[2]) + 50) / 2, accuracy: 1)
    }

    func testAClipWithoutABlendIsDrawnAsBefore() throws {
        let comp = try Self.composition(blend: nil)
        XCTAssertEqual(pixel(try exported(comp), 50, 25), [128, 64, 250, 255])
        XCTAssertEqual(try stage(comp).rgba, try exported(comp).rgba)
    }
}
