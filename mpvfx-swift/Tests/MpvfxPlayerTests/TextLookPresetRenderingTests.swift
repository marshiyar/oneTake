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
import OneTakeKeyframes
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import MpvfxPanels
@testable import MpvfxPlayer

final class TextLookPresetRenderingTests: XCTestCase {
    func editor() throws -> TimelineEditor {
        let engine = try KeyframeRuntime()
        let base = try TimelineEditor(json: TimelineEditor.demoJSON, engine: engine)
        var document = base.document
        document.assets = []; document.sequence.tracks = []
        document.canvas.width = 320; document.canvas.height = 180; document.canvas.background = "#000000"
        return try TimelineEditor(json: serializeNativeProjectDocument(document, engine: engine), engine: engine)
    }

    func testEveryLookUsesTheTextPainterAndItsAnimationSurvivesProjectReopening() throws {
        for look in TextLookPreset.all {
            let e = try editor()
            let id = try XCTUnwrap(e.addTextLook(look, at: 0))
            let round = try TimelineEditor(json: serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
            let composition = PreviewComposition(document: round.document, projectDir: nil, engine: round.engine)
            let middle = look.seconds / 2
            let layer = try XCTUnwrap(composition.layers(at: middle).first { $0.clipId == id })
            XCTAssertEqual(layer.kind, .text)
            XCTAssertEqual(layer.text?.content, look.text.content)
            let painter = try ExportFramePainter(composition: composition, width: 320, height: 180, pad: CanvasColor(r: 0, g: 0, b: 0))
            let output = try painter.paint(time: middle) { _, _, _, _ in nil }
            XCTAssertTrue(stride(from: 0, to: output.rgba.count, by: 4).contains { output.rgba[$0] > 100 }, "\(look.id) draws its text")
            if look.motion == .fade {
                XCTAssertEqual(composition.layers(at: 0).first { $0.clipId == id }?.opacity, 0)
                XCTAssertEqual(layer.opacity, 1)
            }
            if look.motion == .roll {
                let first = try XCTUnwrap(composition.layers(at: 0).first { $0.clipId == id })
                let last = try XCTUnwrap(composition.layers(at: look.seconds - 1 / e.fps).first { $0.clipId == id })
                XCTAssertGreaterThan(first.box.y, layer.box.y)
                XCTAssertGreaterThan(layer.box.y, last.box.y)
            }
            #if os(Linux)
            let preview = CairoImageTarget(width: 320, height: 180)
            let frame = CanvasRect(x: 0, y: 0, width: 320, height: 180)
            preview.canvas.fillRect(frame, composition.background)
            PreviewPainter.drawText(layer, on: preview.canvas, frame: frame, scale: 1)
            let pixels = preview.straightRGBA()
            let total = zip(pixels, output.rgba).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            XCTAssertLessThan(Double(total) / Double(pixels.count), 1, "\(look.id): preview/export text pixels agree within average one level")
            #endif
        }
    }
}
