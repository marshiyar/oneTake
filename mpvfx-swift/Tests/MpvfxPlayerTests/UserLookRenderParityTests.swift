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
import MpvfxTimeline
@testable import MpvfxPlayer

final class UserLookRenderParityTests: XCTestCase {
    func testApplyingASavedLookChangesPreviewAndExportToTheSamePixels() throws {
        let dir = try TestMedia.scratch("saved-look")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try TestMedia.PatternVideo(width: 96, height: 54).write(to: dir.appendingPathComponent("media.mov").path)
        let editor = try TimelineEditor(json: #"""
        {"schemaVersion":1,"id":"project:look","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":96,"height":54,"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"video","name":"media.mov","source":"media.mov","durationFrames":30}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
           {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#)
        func preview() throws -> CanvasImage {
            let comp = PreviewComposition(document: editor.document, projectDir: dir, engine: nil)
            let cx = PreviewCompositor(); cx.composition = comp
            defer { cx.stopAll() }
            return try XCTUnwrap(cx.decodeNow(try XCTUnwrap(comp.layers(at: 0.5).first), time: 0.5, fps: 30,
                                              size: PreviewDecodeSize(width: 96, height: 54)))
        }
        let baseline = try preview()
        var grade = ColorGrading(); grade.adjust["exposure"] = 0.6; grade.adjust["temperature"] = 0.3
        let store = try UserLookStore(path: dir.appendingPathComponent("looks.json").path) { data, path in
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        let look = try store.save(name: "Warm interview", effects: [.init(id: "grade", effectId: ColorGrading.effectId, enabled: true, parameters: grade.json)])
        XCTAssertEqual(try editor.applyUserLook(look, to: ["clip:a"], lutExists: { _ in true }), 1)
        let shown = try preview()
        XCTAssertNotEqual(shown.rgba, baseline.rgba)
        let comp = PreviewComposition(document: editor.document, projectDir: dir, engine: nil)
        let painter = try ExportFramePainter(composition: comp, width: 96, height: 54, pad: CanvasColor(r: 0, g: 0, b: 0))
        let exported = try painter.paint(time: 0.5) { _, _, _, _ in baseline }
        XCTAssertEqual(shown.rgba, exported.rgba)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(try preview().rgba, baseline.rgba)
    }
}
