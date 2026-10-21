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
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPlayer

final class AlignmentPainterTests: XCTestCase {
    func testAlignedParametersDriveThePreviewAndExportPainterToTheSamePixels() throws {
        let json = #"""
        {"schemaVersion":1,"id":"paint-align","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1000,"height":600,"background":"#000000"},
         "assets":[{"id":"image","kind":"image","name":"image.png","source":"image.png","durationFrames":300}],
         "sequence":{"id":"seq","name":"Sequence","tracks":[{"id":"v","kind":"video","clips":[
          {"id":"a","assetId":"image","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],
           "staticParameters":{"layout.left":30,"layout.top":50,"layout.width":100,"layout.height":80}}]}]}}
        """#
        let e = try TimelineEditor(json: json, engine: KeyframeRuntime())
        XCTAssertTrue(e.alignClips(["a"], to: .right, time: 1))
        XCTAssertTrue(e.alignClips(["a"], to: .bottom, time: 1))
        let composition = PreviewComposition(document: e.document, projectDir: nil, engine: e.engine, fileExists: { _ in true })
        let layer = try XCTUnwrap(composition.layers(at: 1).first)
        XCTAssertEqual(layer.box, CanvasRect(x: 900, y: 520, width: 100, height: 80))
        let image = CanvasImage(width: 100, height: 80, rgba: (0..<8000).flatMap { _ in [UInt8(255), 0, 0, 255] })
        let painter = try ExportFramePainter(composition: composition, width: 1000, height: 600, pad: .init(r: 0, g: 0, b: 0))
        let exported = try painter.paint(time: 1) { _, _, _, _ in image }
        func rgb(_ x: Int, _ y: Int) -> [UInt8] { Array(exported.rgba[((y * 1000 + x) * 4)..<((y * 1000 + x) * 4 + 3)]) }
        XCTAssertEqual(rgb(950, 560), [255, 0, 0]); XCTAssertEqual(rgb(899, 560), [0, 0, 0])
        XCTAssertEqual(rgb(950, 519), [0, 0, 0])
        #if os(Linux)
        let target = CairoImageTarget(width: 1000, height: 600)
        target.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 1000, height: 600), composition.background)
        PreviewPainter.draw(layer, image: image, on: target.canvas, frame: CanvasRect(x: 0, y: 0, width: 1000, height: 600), scale: 1)
        XCTAssertEqual(target.straightRGBA(), exported.rgba, "alignment writes the parameters both painters read")
        #endif
    }
}
