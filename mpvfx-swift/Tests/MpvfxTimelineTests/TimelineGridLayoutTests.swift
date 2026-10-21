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
@testable import MpvfxTimeline
import MpvfxShared
import OneTakeKeyframes

final class TimelineGridLayoutTests: XCTestCase {
    func testLayoutOfTwoLayersIsOneUndoStepAndAnExcessSelectionAddsNoHistory() throws {
        let editor = try TimelineEditor(json: """
        {"schemaVersion":1,"id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},"canvas":{"width":1920,"height":1080,"background":"#000000"},
         "assets":[{"id":"i","kind":"image","name":"i","source":"i.png","durationFrames":1}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"v","kind":"video","clips":[
         {"id":"a","assetId":"i","startFrame":0,"durationFrames":100,"sourceInFrame":0,"effects":[],"parameterTracks":[]},
         {"id":"b","assetId":"i","startFrame":0,"durationFrames":100,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
        """, engine: try KeyframeRuntime())
        let before = editor.document
        XCTAssertFalse(editor.applyGridLayout(.sideBySide, clipIds: ["a","b","c"], atFrame: 10))
        XCTAssertFalse(editor.canUndo); XCTAssertEqual(editor.document, before)
        XCTAssertTrue(editor.applyGridLayout(.sideBySide, clipIds: ["a","b"], atFrame: 10))
        let arranged = editor.document
        XCTAssertEqual(editor.undoLabel, "Arrange layout")
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.document, before); XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(editor.redo()); XCTAssertEqual(editor.document, arranged)
    }
}
