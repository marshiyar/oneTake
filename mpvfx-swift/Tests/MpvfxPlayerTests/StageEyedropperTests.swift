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
import MpvfxCanvas
import MpvfxShared
import XCTest

@testable import MpvfxPlayer

/// Issue #300: the stage eyedropper waits for one press on the selected layer; Esc and a press elsewhere end it
/// with nothing picked, and no press under it moves or selects anything.
final class StageEyedropperTests: XCTestCase {
    private func makeController() -> PlayerController {
        let view = PlayerView(playback: PlaybackState(duration: 4, fps: 10))
        view.canvasSize = CanvasSize(200, 100)
        let c = PlayerController(view: view)
        c.size = CanvasSize(216, PreviewToolbar.height + PlayerView.controlsHeight + 116)
        view.elements = [StageElement(id: "A", name: "A", rect: CanvasRect(x: 0, y: 0, width: 200, height: 100), kind: .video),
                         StageElement(id: "B", name: "B", rect: CanvasRect(x: 50, y: 25, width: 40, height: 20), kind: .video)]
        view.selectedIds = ["B"]
        return c
    }

    private func screen(_ c: PlayerController, unit: CanvasPoint) -> CanvasPoint {
        let b = c.view.elements[1]
        return TransformBox.screenPoint(c.view.chromeElement(b, in: c.size), unit: unit)
    }

    func testAPressInsideThePicksOnceWithTheUnitPointAndEndsTheMode() throws {
        let c = makeController()
        var picks: [(String, CanvasPoint)] = [], ended = 0
        XCTAssertTrue(c.startEyedropper(onEnd: { ended += 1 }) { picks.append(($0, $1)) })
        XCTAssertTrue(c.eyedropperActive)
        let p = screen(c, unit: CanvasPoint(0.25, 0.75))
        let before = c.view.elements
        c.pointerDown(x: p.x, y: p.y); c.pointerMove(x: p.x + 20, y: p.y + 9); c.pointerUp(x: p.x + 20, y: p.y + 9)
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks.first?.0, "B")
        XCTAssertEqual(try XCTUnwrap(picks.first).1.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(picks.first).1.y, 0.75, accuracy: 1e-6)
        XCTAssertFalse(c.eyedropperActive); XCTAssertEqual(ended, 1)
        XCTAssertEqual(c.view.elements, before, "the press moved nothing")
        XCTAssertEqual(c.view.selectedIds, ["B"])
    }

    func testAPressOutsideTheLayerEndsTheModeWithNothingPickedAndSelectsNothing() {
        let c = makeController()
        var picks = 0
        XCTAssertTrue(c.startEyedropper { _, _ in picks += 1 })
        let before = c.view.elements
        let f = c.view.frameRect(in: c.size), s = c.view.scale(in: c.size)
        c.pointerDown(x: f.x + 10 * s, y: f.y + 10 * s)   // on layer A, not on B
        c.pointerUp(x: f.x + 10 * s, y: f.y + 10 * s)
        XCTAssertEqual(picks, 0)
        XCTAssertFalse(c.eyedropperActive)
        XCTAssertEqual(c.view.selectedIds, ["B"], "the press selected nothing")
        XCTAssertEqual(c.view.elements, before)
    }

    func testEscapeEndsTheModeWithNothingPickedAndNoCommit() {
        let c = makeController()
        var picks = 0, commits = 0, ended = 0
        c.onCommit = { _ in commits += 1 }
        XCTAssertTrue(c.startEyedropper(onEnd: { ended += 1 }) { _, _ in picks += 1 })
        XCTAssertTrue(c.keyDown(EditorKey(.escape)))
        XCTAssertFalse(c.eyedropperActive)
        XCTAssertEqual(picks, 0); XCTAssertEqual(commits, 0); XCTAssertEqual(ended, 1)
    }

    func testCancelEndsTheMode() {
        let c = makeController()
        XCTAssertTrue(c.startEyedropper { _, _ in })
        c.cancelEyedropper()
        XCTAssertFalse(c.eyedropperActive)
    }

    func testItNeedsOneSelectedUnlockedLayer() {
        let c = makeController()
        c.view.selectedIds = ["A", "B"]
        XCTAssertFalse(c.startEyedropper { _, _ in }, "two layers")
        c.view.selectedIds = []
        XCTAssertFalse(c.startEyedropper { _, _ in }, "none")
        c.view.selectedIds = ["B"]
        c.view.elements[1].locked = true
        XCTAssertFalse(c.startEyedropper { _, _ in }, "locked")
        XCTAssertFalse(c.eyedropperActive)
    }
}
