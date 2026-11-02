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

/// Issue #281, A2: keyframed outline width and shadow values reach the drawn text in preview and export.
final class TextLookAnimationRenderingTests: XCTestCase {
    private func editor() throws -> TimelineEditor {
        let engine = try KeyframeRuntime()
        let base = try TimelineEditor(json: TimelineEditor.demoJSON, engine: engine)
        var document = base.document
        document.assets = []; document.sequence.tracks = []
        document.canvas.width = 320; document.canvas.height = 180; document.canvas.background = "#000000"
        return try TimelineEditor(json: serializeNativeProjectDocument(document, engine: engine), engine: engine)
    }

    private func animatedTitle() throws -> (TimelineEditor, String) {
        let e = try editor()
        let id = try XCTUnwrap(e.addTextClip(at: 0, content: "HI", seconds: 5))
        XCTAssertTrue(e.setTextLook(clipId: id, NativeTextLook(outlines: [.init(width: 2, color: "#ff0000")],
                                                               shadow: .init(x: 1, y: 1, blur: 2, color: "#0000ff"))))
        let pids = [NativeTextLookParameter.outlineWidthIds[0], NativeTextLookParameter.shadowXId,
                    NativeTextLookParameter.shadowYId, NativeTextLookParameter.shadowBlurId]
        for pid in pids {
            let start = try XCTUnwrap(e.textLookValue(clipId: id, pid, time: 0))
            XCTAssertTrue(e.setAnimated(clipId: id, [(pid, .number(start))], true, time: 0))
            XCTAssertTrue(e.setTextLookValue(clipId: id, pid, start * 3 + 4, time: 1))
            XCTAssertTrue(e.setTextLookValue(clipId: id, pid, start * 6 + 8, time: 2))
        }
        return (e, id)
    }

    func testTheDrawnLookFollowsTheKeysAtThreeTimesInPreviewAndExport() throws {
        let (e, id) = try animatedTitle()
        let reopened = try TimelineEditor(json: serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
        let composition = PreviewComposition(document: reopened.document, projectDir: nil, engine: reopened.engine)
        let painter = try ExportFramePainter(composition: composition, width: 320, height: 180, pad: CanvasColor(r: 0, g: 0, b: 0))
        let expected: [(time: Double, width: Double, x: Double, blur: Double)] = [(0, 2, 1, 2), (1, 10, 7, 10), (2, 20, 14, 20)]
        for want in expected {
            let preview = try XCTUnwrap(composition.layers(at: want.time).first { $0.clipId == id }?.text?.look)
            XCTAssertEqual(try XCTUnwrap(preview.outlines?.first).width, want.width, accuracy: 1e-6, "outline at \(want.time)s")
            XCTAssertEqual(preview.shadow?.resolvedX ?? -1, want.x, accuracy: 1e-6, "shadow x at \(want.time)s")
            XCTAssertEqual(preview.shadow?.resolvedBlur ?? -1, want.blur, accuracy: 1e-6, "shadow blur at \(want.time)s")
            let exported = try XCTUnwrap(painter.layers(at: want.time).first { $0.layer.clipId == id }?.layer.text?.look)
            XCTAssertEqual(exported, preview, "export draws the look preview draws at \(want.time)s")
        }
        let between = try XCTUnwrap(composition.layers(at: 0.5).first { $0.clipId == id }?.text?.look?.outlines?.first?.width)
        XCTAssertGreaterThanOrEqual(between, 2); XCTAssertLessThanOrEqual(between, 10)
    }

    func testTheStoredLookIsUntouchedWhileKeysDrawTheAnimatedOne() throws {
        let (e, id) = try animatedTitle()
        XCTAssertEqual(e.clipText(clipId: id)?.look?.outlines?[0].width, 2, "the document keeps the value it had before animating")
        let composition = PreviewComposition(document: e.document, projectDir: nil, engine: e.engine)
        XCTAssertEqual(composition.layers(at: 2).first { $0.clipId == id }?.text?.look?.outlines?[0].width, 20)
    }

    func testAnUnanimatedLookDrawsExactlyWhatIsStored() throws {
        let e = try editor()
        let id = try XCTUnwrap(e.addTextClip(at: 0, content: "HI", seconds: 5))
        let look = NativeTextLook(outlines: [.init(width: 6, color: "#ff0000")])
        XCTAssertTrue(e.setTextLook(clipId: id, look))
        let composition = PreviewComposition(document: e.document, projectDir: nil, engine: e.engine)
        for t in [0.0, 1, 2] { XCTAssertEqual(composition.layers(at: t).first { $0.clipId == id }?.text?.look, look) }
    }

    func testTheOutlineGrowsOnScreenAsItsWidthIsKeyed() throws {
        let (e, _) = try animatedTitle()
        let composition = PreviewComposition(document: e.document, projectDir: nil, engine: e.engine)
        let painter = try ExportFramePainter(composition: composition, width: 320, height: 180, pad: CanvasColor(r: 0, g: 0, b: 0))
        var reds: [Int] = []
        for t in [0.0, 1, 2] {
            let image = try painter.paint(time: t) { _, _, _, _ in nil }
            reds.append(stride(from: 0, to: image.rgba.count, by: 4).filter { image.rgba[$0] > 150 && image.rgba[$0 + 1] < 80 && image.rgba[$0 + 2] < 80 }.count)
        }
        XCTAssertGreaterThan(reds[0], 0, "a 2px red outline shows")
        XCTAssertGreaterThan(reds[1], reds[0], "\(reds)")
        XCTAssertGreaterThan(reds[2], reds[1], "\(reds)")
    }
}
