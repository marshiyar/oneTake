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
// Offline media in the preview (issue #102): the composition stats each source once when it is rebuilt, a clip whose
// file is missing becomes an offline layer the stage draws as a slate naming the file, and a rebuild after the file
// comes back clears the mark. The document is PreviewCompositorTests.document(): clip G plays gone.mp4 at 3.0–4.0 s.
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxShared
@testable import MpvfxPlayer

final class OfflineMediaTests: XCTestCase {
    /// Records the text drawn and every filled path.
    final class TextCanvas: CanvasContext {
        var texts: [String] = []
        var fills: [CanvasPath] = []
        func save() {}; func restore() {}
        func translate(_ dx: Double, _ dy: Double) {}; func scale(_ sx: Double, _ sy: Double) {}; func rotate(_ radians: Double) {}
        func clip(_ path: CanvasPath) {}
        func fill(_ path: CanvasPath, _ color: CanvasColor) { fills.append(path) }
        func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {}
        func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) { texts.append(text) }
        func measureText(_ text: String, font: CanvasFont) -> CanvasSize { CanvasSize(Double(text.count) * 6, font.size) }
        func drawImage(_ image: CanvasImage, in rect: CanvasRect) {}
    }

    func testOfflineAssetIdsAreComputedWhenTheCompositionIsRebuiltByStattingEachSource() throws {
        let doc = try PreviewCompositorTests.document()
        var statted: [String] = []
        let comp = PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil,
                                      fileExists: { statted.append($0); return !$0.hasSuffix("gone.mp4") })
        XCTAssertEqual(comp.offlineAssetIds, ["gone"])
        XCTAssertEqual(Set(statted), ["/proj/a.mp4", "/proj/b.mp4", "/proj/i.jpg", "/proj/gone.mp4"],
                       "every resolved visual source is statted; audio is not drawn")
        let afterBuild = statted.count
        for t in stride(from: 0.0, to: 4.0, by: 0.1) { _ = comp.layers(at: t) }
        XCTAssertEqual(statted.count, afterBuild, "drawing frames never stats a file")
    }

    func testTheStageDrawsAnOfflineSlateWithTheFileNameInTheClipRect() throws {
        let comp = PreviewCompositorTests.composition(try PreviewCompositorTests.document())
        let g = try XCTUnwrap(comp.layers(at: 3.2).first)
        XCTAssertEqual(g.clipId, "G")
        XCTAssertEqual(g.kind, .offline)
        XCTAssertEqual(g.offlineFileName, "gone.mp4")

        let cx = PreviewCompositor(decodesMedia: true)
        cx.composition = comp
        let canvas = TextCanvas()
        let frame = CanvasRect(x: 10, y: 20, width: 400, height: 200)   // scale 2 over the 200×100 canvas
        cx.draw(canvas, in: frame, time: 3.2, elements: [])
        XCTAssertTrue(canvas.texts.contains("Media offline"), "\(canvas.texts)")
        XCTAssertTrue(canvas.texts.contains("gone.mp4"), "\(canvas.texts)")
        let clipRect = PreviewPainter.toView(g.box, frame: frame, scale: 2)
        XCTAssertTrue(canvas.fills.contains(.rect(clipRect)), "the slate fills the clip's rect: \(canvas.fills)")
        XCTAssertTrue(cx.lanes.isEmpty, "an offline clip opens no decoder")
    }

    func testMarksClearWhenTheFileReappearsAndTheCompositionIsRebuilt() throws {
        let doc = try PreviewCompositorTests.document()
        var present = false
        func rebuild() -> PreviewComposition {
            PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil,
                               fileExists: { !$0.hasSuffix("gone.mp4") || present })
        }
        let before = rebuild()
        XCTAssertEqual(before.offlineAssetIds, ["gone"])
        present = true
        XCTAssertEqual(before.offlineAssetIds, ["gone"], "the mark changes only on a rebuild")
        let after = rebuild()
        XCTAssertEqual(after.offlineAssetIds, [])
        let g = try XCTUnwrap(after.layers(at: 3.2).first)
        XCTAssertEqual(g.kind, .video)
        XCTAssertNil(g.offlineFileName)
    }
}
