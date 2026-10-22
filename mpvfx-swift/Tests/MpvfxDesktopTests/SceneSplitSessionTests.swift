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
import MpvfxTimeline
import MpvfxPlayer
import MpvfxShared
import MpvfxCanvas
@testable import MpvfxDesktop

final class SceneSplitSessionTests: XCTestCase {
    func testKeyboardStartsAdjustsThresholdAndCancelsThroughTheToolbar() throws {
        let session = try EditorSession(projectPath: nil, demo: true)
        defer { session.audio?.stop() }
        session.timelineRegion = TimelineRegion(controller: session.timeline)
        session.installSceneSplitHook()
        let toolbar = try XCTUnwrap(session.timelineRegion?.toolbar)
        var calls = 0
        toolbar.onSplitScenes = { calls += 1 }
        session.timeline.view.selection = ["clip:a"]
        XCTAssertTrue(session.sceneSplitKey(EditorKey(.char("s"), ctrl: true, alt: true)))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(session.sceneSplitKey(EditorKey(.char("]"), ctrl: true, alt: true)))
        XCTAssertEqual(toolbar.sceneThreshold, 0.4)
        XCTAssertTrue(session.sceneSplitKey(EditorKey(.char("["), alt: true, meta: true)))
        XCTAssertEqual(toolbar.sceneThreshold, 0.3)
        toolbar.sceneProgress = 0.2
        XCTAssertTrue(session.sceneSplitKey(EditorKey(.escape)))
        XCTAssertEqual(calls, 2)
        toolbar.sceneProgress = nil
        XCTAssertFalse(session.sceneSplitKey(EditorKey(.escape)))
        XCTAssertFalse(session.sceneSplitKey(EditorKey(.char("s"), ctrl: true)))
    }

    func testSplitsKeepEverySourcePictureAndPreviewMatchesExportPainterAtCutEdges() throws {
        let json = #"""
        {"schemaVersion":1,"id":"scene","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"Movie","source":"movie.mov","durationFrames":40}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
         {"id":"c","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":5,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
        """#
        let editor = try TimelineEditor(json: json, engine: KeyframeRuntime())
        func composition(_ document: NativeProjectDocument) -> PreviewComposition {
            PreviewComposition(document: document, projectDir: URL(fileURLWithPath: "/fixture"), engine: editor.engine,
                naturalSize: { _ in NativeMediaNaturalSize(width: 64, height: 32) }, fileExists: { _ in true })
        }
        let before = composition(editor.document)
        XCTAssertTrue(editor.splitScenes(clipId: "c", sourceTimes: [1.5, 2.5]))
        let after = composition(editor.document)
        let baseline = try ExportFramePainter(composition: before, width: 64, height: 32, pad: .transparent)
        let exported = try ExportFramePainter(composition: after, width: 64, height: 32, pad: .transparent)
        func image(_ time: Double) -> CanvasImage {
            let level = UInt8(min(255, max(0, (time * 50).rounded())))
            return CanvasImage(width: 1, height: 1, rgba: [level, 0, 255 - level, 255])
        }
        for frame in 0..<30 {
            let time = (Double(frame) + 0.5) / 10
            let expected = try baseline.paint(time: time) { _, source, _, _ in image(source) }
            let got = try exported.paint(time: time) { _, source, _, _ in image(source) }
            XCTAssertEqual(got.rgba, expected.rgba, "source continuity at frame \(frame)")
            let canvas = try RasterCanvas(width: 64, height: 32)
            canvas.clear(after.background)
            let layers = after.layers(at: time)
            XCTAssertEqual(layers.count, 1)
            for layer in layers {
                PreviewPainter.draw(layer, image: image(layer.sourceTime(at: time)), on: canvas,
                    frame: CanvasRect(x: 0, y: 0, width: 64, height: 32), scale: 1)
            }
            XCTAssertEqual(canvas.image().rgba, got.rgba, "preview/export at frame \(frame)")
        }
    }
}
