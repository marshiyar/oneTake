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
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxTimeline

internal final class ShapeEditTests: XCTestCase {
    internal func testShapeEditIsOneUndoStepSurvivesRestartAndRefusesInvalidData() throws {
        let sourceEditor = try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime())
        // Reuse the existing element asset after removing its text through a fixture edit.
        var project = sourceEditor.document
        project.sequence.tracks[1].clips[0].text = nil
        let editor = try TimelineEditor(
            json: serializeNativeProjectDocument(project, engine: sourceEditor.engine),
            engine: sourceEditor.engine
        )
        let shape = NativeClipShape(kind: "rectangle", radius: 20, strokeWidth: 10)
        XCTAssertTrue(editor.setClipShape(clipId: "title", shape))
        XCTAssertFalse(editor.setClipShape(clipId: "title", shape))
        XCTAssertFalse(editor.setClipShape(clipId: "title", NativeClipShape(kind: "rectangle", radius: -1)))
        XCTAssertFalse(editor.setClipShape(clipId: "natural", shape), "media assets refuse shapes")
        let reopened = try TimelineEditor(
            json: serializeNativeProjectDocument(editor.document, engine: sourceEditor.engine),
            engine: sourceEditor.engine
        )
        XCTAssertEqual(reopened.clip("title")?.clip.shape, shape)
        _ = editor.undo()
        XCTAssertNil(editor.clip("title")?.clip.shape)
        _ = editor.redo()
        XCTAssertEqual(editor.clip("title")?.clip.shape, shape)
    }

    internal func testAddShapeClipIsOneUndoStepWithItsBoxAndSurvivesRestart() throws {
        let editor = try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime())
        let depth = editor.undoStack.count
        let shape = NativeClipShape(kind: "ellipse")
        let id = try XCTUnwrap(editor.addShapeClip(shape, left: 100, top: 50, width: 300, height: 200, at: 4))
        XCTAssertEqual(editor.undoStack.count, depth + 1, "one undo step")
        XCTAssertEqual(editor.undoLabel, "Add shape")
        let clip = try XCTUnwrap(editor.clip(id)?.clip)
        XCTAssertEqual(clip.shape, shape)
        XCTAssertEqual(clip.startFrame, 4 * editor.fps)
        XCTAssertEqual(clip.durationFrames, 5 * editor.fps, "five seconds")
        XCTAssertEqual(clip.staticParameters?["layout.left"], .number(100))
        XCTAssertEqual(clip.staticParameters?["layout.height"], .number(200))
        let reopened = try TimelineEditor(
            json: serializeNativeProjectDocument(editor.document, engine: editor.engine), engine: editor.engine)
        XCTAssertEqual(reopened.clip(id)?.clip.shape, shape)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clip(id), "one undo removes the clip")
        XCTAssertNil(editor.addShapeClip(NativeClipShape(kind: "rectangle", radius: -1), left: 0, top: 0, width: 10, height: 10, at: 0),
                     "the document refuses a bad shape")
    }
}
