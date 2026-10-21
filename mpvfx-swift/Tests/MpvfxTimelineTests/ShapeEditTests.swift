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
import MpvfxShared
import OneTakeKeyframes
@testable import MpvfxTimeline

final class ShapeEditTests: XCTestCase {
    func testShapeEditIsOneUndoStepSurvivesRestartAndRefusesInvalidData() throws {
        let e = try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime())
        // Reuse the existing element asset after removing its text through a fixture edit.
        var d = e.document
        d.sequence.tracks[1].clips[0].text = nil
        let editor = try TimelineEditor(json: serializeNativeProjectDocument(d, engine: e.engine), engine: e.engine)
        let shape = NativeClipShape(kind: "rectangle", radius: 20, strokeWidth: 10)
        XCTAssertTrue(editor.setClipShape(clipId: "title", shape))
        XCTAssertFalse(editor.setClipShape(clipId: "title", shape))
        XCTAssertFalse(editor.setClipShape(clipId: "title", NativeClipShape(kind: "rectangle", radius: -1)))
        XCTAssertFalse(editor.setClipShape(clipId: "natural", shape), "media assets refuse shapes")
        let reopened = try TimelineEditor(json: serializeNativeProjectDocument(editor.document, engine: e.engine), engine: e.engine)
        XCTAssertEqual(reopened.clip("title")?.clip.shape, shape)
        _ = editor.undo()
        XCTAssertNil(editor.clip("title")?.clip.shape)
        _ = editor.redo()
        XCTAssertEqual(editor.clip("title")?.clip.shape, shape)
    }
}
