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
@testable import MpvfxPlayer

final class BackgroundGeneratorPainterTests: XCTestCase {
    func document(_ fill: NativeFill?, extra: Bool = false) throws -> NativeProjectDocument {
        let json = ##"{"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":10,"denominator":1},"canvas":{"width":80,"height":40,"background":"#000000"},"assets":[{"id":"a","kind":"element","name":"Background","durationFrames":100}],"sequence":{"id":"s","name":"Main","tracks":[{"id":"t","kind":"video","clips":[{"id":"c","assetId":"a","startFrame":0,"durationFrames":50,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}"##
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(json)); doc.sequence.tracks[0].clips[0].generator = fill
        return try parseNativeProjectDocument(doc)
    }
    func images(_ fill: NativeFill) throws -> (CanvasImage, CanvasImage) {
        let comp = PreviewComposition(document: try document(fill), projectDir: nil, engine: nil)
        let preview = PreviewCompositor(decodesMedia: false); preview.composition = comp
        let raster = try RasterCanvas(width: 80, height: 40)
        preview.draw(raster, in: CanvasRect(x: 0, y: 0, width: 80, height: 40), time: 0, elements: [])
        let export = try ExportFramePainter(composition: comp, width: 80, height: 40, pad: .opaqueBlack)
        let image = try export.paint(time: 0) { _, _, _, _ in XCTFail("Generators must never decode media"); return nil }
        return (raster.image(), image)
    }
    func px(_ image: CanvasImage, _ x: Int, _ y: Int) -> [UInt8] { Array(image.rgba[((y * image.width + x) * 4)..<((y * image.width + x) * 4 + 4)]) }
    func testSolidIsFullFrameAndPreviewEqualsExport() throws {
        let (preview, export) = try images(NativeFill(kind: "color", color: "#FF0000"))
        XCTAssertEqual(preview, export)
        XCTAssertEqual(px(export, 0, 0), [255, 0, 0, 255]); XCTAssertEqual(px(export, 79, 39), [255, 0, 0, 255])
    }
    func testLinearAngleAndRadialCentreHaveDistinctPixelsWithPreviewExportParity() throws {
        let stops: [NativeFill.Stop] = [.init(offset: 0, color: "#FF0000"), .init(offset: 1, color: "#0000FF")]
        for radial in [false, true] {
            let (preview, export) = try images(NativeFill(kind: "gradient", stops: stops, angle: 90,
                gradientType: radial ? "radial" : "linear", centerX: 0.25, centerY: 0.5))
            XCTAssertEqual(preview, export)
            XCTAssertGreaterThan(px(export, 20, 20)[0], px(export, 79, 20)[0])
            if radial { XCTAssertGreaterThan(px(export, 20, 20)[0], 240) }
        }
    }
    func testProceduralLayersNeverCreateDecodeLanesDuringPreroll() throws {
        let comp = PreviewComposition(document: try document(NativeGeneratorKind.radial.fill), projectDir: nil, engine: nil)
        let layer = try XCTUnwrap(comp.layers(at: 0).first)
        let preview = PreviewCompositor(decodesMedia: true)
        XCTAssertNil(preview.lane(for: layer, fps: comp.fps))
    }
    func testUnrelatedAndUnknownElementLayersStayUndrawn() throws {
        let future = NativeFill(raw: try NativeJSONValue.parse(#"{"v":2,"kind":"noise","seed":42}"#))
        for fill in [nil, future] {
            let comp = PreviewComposition(document: try document(fill), projectDir: nil, engine: nil)
            XCTAssertTrue(comp.entries.isEmpty)
        }
    }
}
