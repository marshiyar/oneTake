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
// Template placeholders in the preview (#332): an unfilled placeholder is a neutral card with its number in the clip's
// box, never decoded, and a placeholder whose media file is on disk plays as usual.
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxShared
@testable import MpvfxPlayer

final class PlaceholderPreviewTests: XCTestCase {
    func document(source: String) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse("""
        {"schemaVersion":1,"id":"project:t","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":200,"height":100,"background":"#102030"},
         "assets":[{"id":"slot","kind":"video","name":"Intro",\(source)"durationFrames":100}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"t1","kind":"video","clips":[
           {"id":"P","assetId":"slot","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],
            "placeholder":{"v":1,"index":4}}]}]}}
        """), engine: nil)
    }

    func composition(_ doc: NativeProjectDocument, present: Bool = false) -> PreviewComposition {
        PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil, fileExists: { _ in present })
    }

    func testAPlaceholderWithoutMediaIsANumberedCardInTheClipBox() throws {
        let comp = composition(try document(source: ""))
        let layer = try XCTUnwrap(comp.layers(at: 1).first)
        XCTAssertEqual(layer.kind, .offline)
        XCTAssertEqual(layer.placeholderNumber, 4)
        XCTAssertNil(layer.offlineFileName)

        let cx = PreviewCompositor(decodesMedia: true)
        cx.composition = comp
        let canvas = OfflineMediaTests.TextCanvas()
        let frame = CanvasRect(x: 10, y: 20, width: 400, height: 200)
        cx.draw(canvas, in: frame, time: 1, elements: [])
        XCTAssertTrue(canvas.texts.contains("Placeholder 4"), "\(canvas.texts)")
        XCTAssertFalse(canvas.texts.contains("Media offline"), "\(canvas.texts)")
        XCTAssertTrue(canvas.fills.contains(.rect(PreviewPainter.toView(layer.box, frame: frame, scale: 2))))
        XCTAssertTrue(cx.lanes.isEmpty, "a placeholder opens no decoder")
        XCTAssertEqual(comp.offlineAssetIds, [], "it references no file, so the timeline does not call it offline")
    }

    func testAPlaceholderWhoseFileIsMissingKeepsItsNumberOnTheSlate() throws {
        let comp = composition(try document(source: #""source":"intro.mov","#))
        let layer = try XCTUnwrap(comp.layers(at: 1).first)
        XCTAssertEqual(layer.kind, .offline)
        XCTAssertEqual(layer.placeholderNumber, 4)
        XCTAssertEqual(layer.offlineFileName, "intro.mov")
    }

    func testAPlaceholderWithItsFileOnDiskPlaysAsUsual() throws {
        let comp = composition(try document(source: #""source":"intro.mov","#), present: true)
        let layer = try XCTUnwrap(comp.layers(at: 1).first)
        XCTAssertEqual(layer.kind, .video)
        XCTAssertNil(layer.placeholderNumber)
    }
}
