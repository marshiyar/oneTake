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
import MpvfxTimeline
import XCTest

@testable import MpvfxPlayer

internal final class ShapeToolTests: XCTestCase {
    private func stage() -> (PlayerView, PlayerController, () -> [(StageShapeDraft, Double)]) {
        let view = PlayerView(playback: PlaybackState(duration: 10))
        view.canvasSize = CanvasSize(1000, 500)
        let controller = PlayerController(view: view)
        controller.size = CanvasSize(1016, 36 + 516 + 40)
        var made: [(StageShapeDraft, Double)] = []
        controller.onCreateShape = { draft, time in
            made.append((draft, time))
            return "shape-\(made.count)"
        }
        return (view, controller, { made })
    }

    private func key(_ ch: Character, shift: Bool = false) -> EditorKey { EditorKey(.char(ch), shift: shift) }

    internal func testShiftSTurnsTheToolOnAndOffAndEscLeavesIt() {
        let (view, controller, _) = stage()
        XCTAssertNil(view.shapeTool)
        XCTAssertTrue(controller.keyDown(key("S", shift: true)))
        XCTAssertEqual(view.shapeTool, "rectangle")
        XCTAssertTrue(controller.keyDown(key("S", shift: true)))
        XCTAssertNil(view.shapeTool)
        XCTAssertTrue(controller.keyDown(key("S", shift: true)))
        XCTAssertTrue(controller.keyDown(EditorKey(.escape)))
        XCTAssertNil(view.shapeTool)
        XCTAssertFalse(controller.keyDown(key("s")), "bare S stays Split, which the timeline owns")
    }

    internal func testWithoutAHostThatAddsShapesTheKeyIsNotTaken() {
        let view = PlayerView(playback: PlaybackState(duration: 10))
        let controller = PlayerController(view: view)
        XCTAssertFalse(controller.keyDown(key("S", shift: true)))
        XCTAssertNil(view.shapeTool)
    }

    internal func testDigitsAndTheChipsPickTheKindAndTheKindIsRemembered() throws {
        let (view, controller, _) = stage()
        _ = controller.keyDown(key("S", shift: true))
        for (digit, kind) in [("2", "ellipse"), ("3", "line"), ("4", "arrow"), ("1", "rectangle")] {
            XCTAssertTrue(controller.keyDown(key(Character(digit))))
            XCTAssertEqual(view.shapeTool, kind)
        }
        XCTAssertFalse(controller.keyDown(key("5")))
        let chips = StageShapePicker.rects(in: view.viewportRect(in: controller.size))
        let ellipse = try XCTUnwrap(chips.first { $0.kind == "ellipse" }).rect
        controller.pointerDown(x: ellipse.midX, y: ellipse.midY)
        XCTAssertEqual(view.shapeTool, "ellipse")
        controller.pointerUp(x: ellipse.midX, y: ellipse.midY)
        _ = controller.keyDown(key("S", shift: true))
        _ = controller.keyDown(key("S", shift: true))
        XCTAssertEqual(view.shapeTool, "ellipse", "the tool comes back with the kind drawn last")
    }

    internal func testADragAddsTheShapeAtThePlayheadAndSelectsItAndTheToolGoesOff() throws {
        let (view, controller, made) = stage()
        view.playback.seek(2)
        let frame = view.frameRect(in: controller.size), s = view.scale(in: controller.size)
        _ = controller.keyDown(key("S", shift: true))
        controller.pointerDown(x: frame.x + 100 * s, y: frame.y + 100 * s)
        controller.pointerMove(x: frame.x + 300 * s, y: frame.y + 250 * s)
        let draft = try XCTUnwrap(view.shapeDraft, "the shape shows while dragging")
        XCTAssertEqual(draft.box.width, 200, accuracy: 1)
        XCTAssertTrue(made().isEmpty, "nothing is added until the button is released")
        controller.pointerUp(x: frame.x + 300 * s, y: frame.y + 250 * s)
        XCTAssertEqual(made().count, 1)
        let (shape, time) = try XCTUnwrap(made().first)
        XCTAssertEqual(shape.shape.kind, "rectangle")
        XCTAssertEqual(shape.box.x, 100, accuracy: 1); XCTAssertEqual(shape.box.y, 100, accuracy: 1)
        XCTAssertEqual(shape.box.width, 200, accuracy: 1); XCTAssertEqual(shape.box.height, 150, accuracy: 1)
        XCTAssertEqual(time, 2, accuracy: 1e-9)
        XCTAssertNil(view.shapeDraft); XCTAssertNil(view.shapeTool)
        XCTAssertEqual(view.selectedIds, ["shape-1"])
    }

    internal func testShiftAndOptionOnTheDragAreRead() throws {
        let (view, controller, made) = stage()
        let frame = view.frameRect(in: controller.size), s = view.scale(in: controller.size)
        _ = controller.keyDown(key("S", shift: true))
        controller.modifiers = [.alt]
        controller.pointerDown(x: frame.x + 500 * s, y: frame.y + 250 * s)
        controller.pointerMove(x: frame.x + 560 * s, y: frame.y + 280 * s, shift: true)
        controller.pointerUp(x: frame.x + 560 * s, y: frame.y + 280 * s)
        let box = try XCTUnwrap(made().first).0.box
        XCTAssertEqual(box.width, 120, accuracy: 2); XCTAssertEqual(box.height, 120, accuracy: 2, "Shift: square")
        XCTAssertEqual(box.x, 440, accuracy: 2); XCTAssertEqual(box.y, 190, accuracy: 2, "Option: from the centre")
    }

    internal func testAClickMakesTheDefaultSizeAtThePoint() throws {
        let (view, controller, made) = stage()
        let frame = view.frameRect(in: controller.size), s = view.scale(in: controller.size)
        _ = controller.keyDown(key("S", shift: true))
        controller.pointerDown(x: frame.x + 500 * s, y: frame.y + 250 * s)
        controller.pointerUp(x: frame.x + 500 * s, y: frame.y + 250 * s)
        let box = try XCTUnwrap(made().first).0.box
        XCTAssertEqual(box.width, 200); XCTAssertEqual(box.height, 120)
        XCTAssertEqual(box.x, 400, accuracy: 1); XCTAssertEqual(box.y, 190, accuracy: 1)
    }

    internal func testEscDuringADragDropsTheShape() {
        let (view, controller, made) = stage()
        let frame = view.frameRect(in: controller.size)
        _ = controller.keyDown(key("S", shift: true))
        controller.pointerDown(x: frame.x + 50, y: frame.y + 50)
        controller.pointerMove(x: frame.x + 200, y: frame.y + 150)
        XCTAssertNotNil(view.shapeDraft)
        XCTAssertTrue(controller.keyDown(EditorKey(.escape)))
        XCTAssertNil(view.shapeDraft)
        controller.pointerUp(x: frame.x + 200, y: frame.y + 150)
        XCTAssertTrue(made().isEmpty)
        XCTAssertEqual(view.shapeTool, "rectangle", "the first Esc only cancels the drag")
    }
}
