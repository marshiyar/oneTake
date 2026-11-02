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
import MpvfxPlayer
import MpvfxShared
import MpvfxTimeline
@testable import MpvfxDesktop

/// Issue #300: picking the colour key from the stage writes the colour under the click, from the ungraded frame, as
/// one undo step; Esc picks nothing and leaves the document alone.
final class ColorKeyPickTests: XCTestCase {
    func makeSession() throws -> EditorSession {
        let s = try EditorSession(projectPath: nil, demo: true)
        s.audio?.stop()
        s.player.size = CanvasSize(1440, 900)
        s.timeline.view.selection = ["clip:a"]
        s.syncStage()
        return s
    }

    /// A 20 x 10 frame: the left half red, the right half blue.
    func knownFrame() -> CanvasImage {
        var px = [UInt8](repeating: 255, count: 20 * 10 * 4)
        for y in 0..<10 { for x in 0..<20 {
            let i = (y * 20 + x) * 4
            px[i] = x < 10 ? 255 : 0; px[i + 1] = 0; px[i + 2] = x < 10 ? 0 : 255
        } }
        return CanvasImage(width: 20, height: 10, rgba: px)
    }

    func click(_ s: EditorSession, unit: CanvasPoint) throws {
        let e = try XCTUnwrap(s.player.view.elements.first { $0.id == "clip:a" })
        let p = TransformBox.screenPoint(s.player.view.chromeElement(e, in: s.player.size), unit: unit)
        s.player.pointerDown(x: p.x, y: p.y); s.player.pointerUp(x: p.x, y: p.y)
    }

    func testAClickWritesTheColourOfTheKnownFrameAsOneUndoStep() throws {
        let s = try makeSession()
        let frame = knownFrame()
        var asked: [String] = []
        s.rawFrameProvider = { id, _, w, h in asked.append("\(id) \(w)x\(h)"); return .ready(frame) }
        XCTAssertTrue(s.editor.setColorKey(clipId: "clip:a", { var k = ColorKeySettings(); k.similarity = 0.3; return k }()))
        let before = s.editor.document, entries = s.editor.undoStack.count
        s.pickKeyColorFromStage()
        XCTAssertTrue(s.player.eyedropperActive)
        try click(s, unit: CanvasPoint(0.9, 0.5))   // well inside the blue half
        XCTAssertFalse(s.player.eyedropperActive)
        let key = try XCTUnwrap(s.editor.colorKey(clipId: "clip:a"))
        XCTAssertEqual(key.color[0], 0, accuracy: 1e-6); XCTAssertEqual(key.color[1], 0, accuracy: 1e-6)
        XCTAssertEqual(key.color[2], 1, accuracy: 1e-6)
        XCTAssertEqual(key.similarity, 0.3, "the other settings stay")
        XCTAssertEqual(s.editor.undoStack.count, entries + 1)
        XCTAssertEqual(s.editor.undoLabel, EditorSession.pickKeyColorLabel)
        XCTAssertEqual(asked, ["clip:a 640x640"])
        XCTAssertTrue(s.editor.undo())
        XCTAssertEqual(s.editor.document, before)
    }

    func testAClickOnAClipWithoutAKeyCreatesOne() throws {
        let s = try makeSession()
        let frame = knownFrame()
        s.rawFrameProvider = { _, _, _, _ in .ready(frame) }
        XCTAssertNil(s.editor.colorKey(clipId: "clip:a"))
        s.pickKeyColorFromStage()
        try click(s, unit: CanvasPoint(0.1, 0.5))
        XCTAssertEqual(s.editor.colorKey(clipId: "clip:a")?.color, [1, 0, 0])
    }

    func testEscapePicksNothingAndLeavesTheDocumentAlone() throws {
        let s = try makeSession()
        s.rawFrameProvider = { _, _, _, _ in XCTFail("no frame is read"); return .unavailable }
        let before = s.editor.document, entries = s.editor.undoStack.count
        s.pickKeyColorFromStage()
        XCTAssertTrue(s.player.keyDown(EditorKey(.escape)))
        XCTAssertFalse(s.player.eyedropperActive)
        XCTAssertEqual(s.editor.document, before)
        XCTAssertEqual(s.editor.undoStack.count, entries)
    }
}
