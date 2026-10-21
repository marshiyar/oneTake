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
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxPanels
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPlayer

/// The matched look is an ordinary grade: the existing preview and export paths consume the same parameters.
final class LookMatchPainterTests: XCTestCase {
    func flat(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CanvasImage {
        .init(width: 16, height: 16, rgba: (0..<256).flatMap { _ in [r, g, b, 255] })
    }
    func editor() throws -> TimelineEditor {
        try TimelineEditor(json: #"""
        {"schemaVersion":1,"id":"match","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":16,"height":16,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"take.mov","source":"take.mov","durationFrames":30}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v","kind":"video","clips":[
         {"id":"take","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#, engine: KeyframeRuntime())
    }

    func testMatchedStatisticsImproveTheRenderedColourAndPreviewEqualsExport() throws {
        for (source, reference) in [(flat(60, 60, 60), flat(120, 120, 120)), (flat(110, 90, 70), flat(90, 100, 110))] {
            let e = try editor(), matched = try XCTUnwrap(LookMatch.matched(ColorGrading(), source: source, reference: reference))
            XCTAssertTrue(e.setColorGrading(clipId: "take", matched))
            let reopened = try TimelineEditor(json: serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
            let comp = PreviewComposition(document: reopened.document, projectDir: URL(fileURLWithPath: "/project"), engine: e.engine, fileExists: { _ in true })
            let layer = try XCTUnwrap(comp.layers(at: 0).first)
            let preview = PreviewCompositor(); defer { preview.stopAll() }
            let shown = preview.graded(layer, source, frame: 0, time: 0, fps: 30)
            let painter = try ExportFramePainter(composition: comp, width: 16, height: 16, pad: .init(r: 0, g: 0, b: 0))
            let exported = try painter.paint(time: 0) { _, _, _, _ in source }
            XCTAssertEqual(exported.rgba, shown.rgba, "saved values go through the same grade and painter contract")
            func error(_ image: CanvasImage) -> Double {
                zip(image.rgba.prefix(3), reference.rgba.prefix(3)).reduce(0) { $0 + abs(Double($1.0) - Double($1.1)) }
            }
            XCTAssertLessThan(error(shown), error(source) * 0.2, "the synthetic brightness/cast moves towards the reference")
        }
    }
}
