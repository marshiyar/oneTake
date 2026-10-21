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
import MpvfxPanels
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
        XCTAssertEqual(Set(statted), ["/proj/a.mp4", "/proj/b.mp4", "/proj/i.jpg", "/proj/gone.mp4", "/proj/m.wav"],
                       "every resolved media source is statted, sound included")
        XCTAssertEqual(statted.count, Set(statted).count, "each file once")
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

    func testOfflineLayersAreLeftOutOfExportPaintingAndPresetPreviews() throws {
        let comp = PreviewCompositorTests.composition(try PreviewCompositorTests.document())
        let painter = try ExportFramePainter(composition: comp, width: 200, height: 100, pad: CanvasColor(r: 0, g: 0, b: 0))
        XCTAssertEqual(painter.layers(at: 3.2).map(\.layer.clipId), [], "export never paints an offline layer")
        var asked: [String] = []
        _ = try painter.paint(time: 3.2) { layer, _, _, _ in asked.append(layer.clipId); return nil }
        XCTAssertEqual(asked, [], "no frame is asked for the missing file")

        let cx = PreviewCompositor(decodesMedia: true)
        cx.composition = comp
        let presets = PresetPreviewRenderer(compositor: cx)
        XCTAssertFalse(presets.isAvailable(clipId: "G"))
        guard case .unavailable = presets.gradedFrame(clipId: "G", time: 3.2, pixelWidth: 32, pixelHeight: 16) else {
            return XCTFail("an offline clip has no graded frame")
        }
        XCTAssertTrue(presets.isAvailable(clipId: "A"), "a clip with its file still previews")
        let tile = EffectPreviewRequest(key: "fx:blur", grade: [:], clipId: "G", pixelWidth: 32, pixelHeight: 16)
        guard case .unavailable = presets.effectPreview(tile, time: 3.2) else { return XCTFail("an offline clip has no effect tile") }
        XCTAssertTrue(presets.decodeGaveUp(clipId: "G"), "the tile host shows the sample picture, not Rendering")
    }

    func testAMissingSoundFileIsMarkedOfflineButNotDrawn() throws {
        let doc = try PreviewCompositorTests.document()
        let missing: (String) -> Bool = { !$0.hasSuffix("gone.mp4") && !$0.hasSuffix("m.wav") }
        let comp = PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil, fileExists: missing)
        XCTAssertEqual(comp.offlineAssetIds, ["gone", "m"], "the timeline marks the audio clip too")
        XCTAssertFalse(comp.entries.contains { $0.clip.id == "M" }, "sound is never a stage layer")
        XCTAssertEqual(PreviewComposition.offlineAssetIds(document: doc, projectDir: URL(fileURLWithPath: "/proj"), fileExists: missing),
                       comp.offlineAssetIds, "the session's re-check agrees with a rebuild")
    }

    func testAnOfflineSlateTakesTheClips3DTransform() {
        // A tilted clip under a lens: the slate goes through the same projection (mesh cells and their transforms) as
        // the decoded picture would.
        var picture = PreviewLayer(clipId: "c", source: "/p/c.mp4", kind: .video, start: 0, end: 1, sourceIn: 0,
                                   box: CanvasRect(x: 20, y: 10, width: 160, height: 80))
        picture.transform3D = NativeTransform3D(rotationX: 0, rotationY: 35, z: 0, perspective: 600)
        var slate = picture
        slate.kind = .offline; slate.offlineFileName = "c.mp4"
        let frame = CanvasRect(x: 0, y: 0, width: 400, height: 200)
        func transforms(_ draw: (CanvasContext) -> Void) -> [PreviewRecordingCanvas.Op] {
            let c = PreviewRecordingCanvas()
            draw(c)
            return c.ops.filter { if case .translate = $0 { return true }; if case .scale = $0 { return true }; if case .rotate = $0 { return true }; return false }
        }
        let projected = transforms { PreviewPainter.draw(picture, image: PreviewCompositorTests.solid(9, 9, 9), on: $0, frame: frame, scale: 2) }
        XCTAssertFalse(projected.isEmpty)
        XCTAssertEqual(transforms { PreviewPainter.drawOffline(slate, on: $0, frame: frame, scale: 2) }, projected)
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
