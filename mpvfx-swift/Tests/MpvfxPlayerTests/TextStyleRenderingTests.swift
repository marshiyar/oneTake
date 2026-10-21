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
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxPlayer

internal final class TextStyleRenderingTests: XCTestCase {
    private func document() throws -> NativeProjectDocument {
        let raw = try NativeJSONValue.parse(
            """
            {"schemaVersion":1,"mediaEngine":"native","id":"project:text","revision":0,
             "frameRate":{"numerator":30,"denominator":1},"canvas":{"width":320,"height":180,"background":"#000000"},
             "assets":[{"id":"asset:title","kind":"element","name":"Title","durationFrames":60}],
             "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:1","kind":"video","clips":[
             {"id":"clip:title","assetId":"asset:title","startFrame":0,"durationFrames":60,"sourceInFrame":0,
              "staticParameters":{"layout.left":10,"layout.top":10,"layout.width":300,"layout.height":160},
              "text":{"content":"Title","fontSize":40,"color":"#ffffff"},"effects":[],"parameterTracks":[]}]}]}}
            """)
        return try parseNativeProjectDocument(raw, engine: try KeyframeRuntime())
    }
    internal func testDetachRendersIdenticalPixelsThroughPreviewAndExportComposition() throws {
        let engine = try KeyframeRuntime()
        var document = try document()
        document = try planNativeTextStyle(
            document, .save(clipId: "clip:title", styleId: "style:title", name: "Title"), engine: engine)
        document = try planNativeTextStyle(
            document, .apply(styleId: "style:title", clipIds: ["clip:title"]), engine: engine)
        document.textStyles?[0].text?.color = "#ff0000"
        let composition = PreviewComposition(document: document, projectDir: nil, engine: engine)
        XCTAssertEqual(composition.layers(at: 0)[0].text?.color, "#ff0000")
        let painter = try ExportFramePainter(composition: composition, width: 320, height: 180, pad: .transparent)
        let linked = try painter.paint(time: 0) { _, _, _, _ in nil }
        let detached = try planNativeTextStyle(document, .detach(clipIds: ["clip:title"]), engine: engine)
        let other = PreviewComposition(document: detached, projectDir: nil, engine: engine)
        let plainPainter = try ExportFramePainter(composition: other, width: 320, height: 180, pad: .transparent)
        XCTAssertEqual(try plainPainter.paint(time: 0) { _, _, _, _ in nil }, linked)
        XCTAssertTrue(linked.rgba.enumerated().contains { $0.offset.isMultiple(of: 4) && $0.element > 100 })
    }
}
