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
// Issue #322 A1: the Layout menu's rows, keys and clicks, through the menu model and the stage controller.
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import XCTest

@testable import MpvfxPlayer

internal final class StageLayoutMenuTests: XCTestCase {
    private func rig(clips: Int = 2) -> (PlayerView, PlayerController, () -> [(NativeGridLayout, NativeGridOptions)]) {
        let view = PlayerView(playback: PlaybackState(duration: 10))
        view.canvasSize = CanvasSize(1000, 500)
        let controller = PlayerController(view: view)
        controller.size = CanvasSize(1016, 36 + 516 + 40)
        var applied: [(NativeGridLayout, NativeGridOptions)] = []
        controller.onApplyLayout = { layout, options in
            applied.append((layout, options))
            return true
        }
        controller.openLayoutMenu(at: CanvasPoint(300, 200), clipCount: clips)
        return (view, controller, { applied })
    }

    internal func testRowsTakeOnlyAsManyClipsAsTheyHaveCells() {
        let menu = StageLayoutMenu(origin: CanvasPoint(0, 0), clipCount: 3)
        XCTAssertFalse(menu.isEnabled(.sideBySide), "two cells cannot take three clips")
        XCTAssertFalse(menu.isEnabled(.pictureInPicture))
        XCTAssertTrue(menu.isEnabled(.threeUp))
        XCTAssertTrue(menu.isEnabled(.largeLeft))
        XCTAssertTrue(menu.isEnabled(.grid2x2), "a spare cell is fine")
        XCTAssertEqual(StageLayoutMenu.layouts.map(StageLayoutMenu.label).count, 6)
    }

    internal func testOpeningSelectsTheFirstRowThatFitsAndArrowsSkipTheOthers() throws {
        let (view, controller, _) = rig(clips: 3)
        XCTAssertEqual(view.layoutMenu?.layout, .threeUp)
        XCTAssertEqual(controller.keyDown(EditorKey(.down)), true)
        XCTAssertEqual(view.layoutMenu?.layout, .grid2x2)
        XCTAssertEqual(controller.keyDown(EditorKey(.down)), true)
        XCTAssertEqual(view.layoutMenu?.layout, .largeLeft)
        _ = controller.keyDown(EditorKey(.down))
        XCTAssertEqual(view.layoutMenu?.layout, .threeUp, "it wraps past the rows that do not fit")
        _ = controller.keyDown(EditorKey(.up))
        XCTAssertEqual(view.layoutMenu?.layout, .largeLeft)
    }

    internal func testReturnAppliesTheRowWithTheFooterSpacingAndClosesTheMenu() {
        let (view, controller, applied) = rig()
        XCTAssertEqual(view.layoutMenu?.layout, .sideBySide)
        _ = controller.keyDown(EditorKey(.right))
        _ = controller.keyDown(EditorKey(.right))
        _ = controller.keyDown(EditorKey(.right, shift: true))
        _ = controller.keyDown(EditorKey(.left, shift: true))
        _ = controller.keyDown(EditorKey(.left, shift: true))
        _ = controller.keyDown(EditorKey(.down))
        XCTAssertEqual(view.layoutMenu?.layout, .stacked)
        XCTAssertTrue(controller.keyDown(EditorKey(.enter)))
        XCTAssertNil(view.layoutMenu)
        XCTAssertEqual(applied().count, 1)
        XCTAssertEqual(applied().first?.0, .stacked)
        XCTAssertEqual(applied().first?.1.gutter, 8)
        XCTAssertEqual(applied().first?.1.margin, 0, "the margin cannot go below zero")
    }

    internal func testNumbersPickARowAndEscClosesWithoutApplying() {
        let (view, controller, applied) = rig()
        XCTAssertTrue(controller.keyDown(EditorKey(.char("6"))))
        XCTAssertEqual(view.layoutMenu?.layout, .pictureInPicture)
        XCTAssertTrue(controller.keyDown(EditorKey(.escape)))
        XCTAssertNil(view.layoutMenu)
        XCTAssertTrue(applied().isEmpty)
    }

    internal func testReturnOnARowThatDoesNotFitAppliesNothing() {
        let (view, controller, applied) = rig(clips: 4)
        view.layoutMenu?.selected = 0
        XCTAssertTrue(controller.keyDown(EditorKey(.enter)))
        XCTAssertNotNil(view.layoutMenu, "the menu stays open")
        XCTAssertTrue(applied().isEmpty)
    }

    internal func testAClickOnARowAppliesItAndAClickOutsideCloses() throws {
        let (view, controller, applied) = rig(clips: 4)
        let bounds = CanvasRect(x: 0, y: 0, width: controller.size.width, height: controller.size.height)
        let menu = try XCTUnwrap(view.layoutMenu)
        let frame = menu.frame(in: bounds)
        let threeUp = menu.rowRect(2, in: frame)
        XCTAssertEqual(menu.hit(at: CanvasPoint(threeUp.midX, threeUp.midY), bounds: bounds), .row(2))
        controller.pointerDown(x: threeUp.midX, y: threeUp.midY)
        XCTAssertTrue(applied().isEmpty, "three up has no cell for a fourth clip")
        XCTAssertNotNil(view.layoutMenu, "a row that does not fit leaves the menu open")
        let grid = menu.rowRect(3, in: frame)
        controller.pointerDown(x: grid.midX, y: grid.midY)
        XCTAssertEqual(applied().map(\.0), [.grid2x2])
        XCTAssertNil(view.layoutMenu)
        controller.openLayoutMenu(at: CanvasPoint(300, 200), clipCount: 2)
        controller.pointerDown(x: 5, y: 5)
        XCTAssertNil(view.layoutMenu, "a click outside closes it")
        XCTAssertEqual(applied().count, 1)
    }

    internal func testTheMenuStaysInsideTheStage() {
        let menu = StageLayoutMenu(origin: CanvasPoint(1000, 600), clipCount: 2)
        let bounds = CanvasRect(x: 0, y: 0, width: 1016, height: 592)
        let frame = menu.frame(in: bounds)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX); XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY)
        XCTAssertGreaterThanOrEqual(frame.x, 0); XCTAssertGreaterThanOrEqual(frame.y, 0)
    }

    internal func testDiagramsHaveTheLayoutsCells() {
        let menu = StageLayoutMenu(origin: CanvasPoint(0, 0), clipCount: 1)
        for layout in StageLayoutMenu.layouts {
            XCTAssertEqual(menu.diagram(layout, size: CanvasSize(56, 32)).count, StageLayoutMenu.cells(layout), "\(layout)")
        }
    }

    internal func testPictureInPictureCornersFollowTheArrowAndSwapsRotateTheCells() {
        XCTAssertEqual(StageLayoutMenu.corner(.bottomRight, moving: .left), .bottomLeft)
        XCTAssertEqual(StageLayoutMenu.corner(.bottomRight, moving: .up), .topRight)
        XCTAssertEqual(StageLayoutMenu.corner(.topLeft, moving: .right), .topRight)
        XCTAssertEqual(StageLayoutMenu.corner(.topLeft, moving: .down), .bottomLeft)
        XCTAssertEqual(StageLayoutMenu.corner(.topLeft, moving: .left), .topLeft, "already on that side")
        XCTAssertEqual(StageLayoutMenu.rotated(["a", "b"], forward: true), ["b", "a"])
        XCTAssertEqual(StageLayoutMenu.rotated(["a", "b"], forward: false), ["b", "a"])
        XCTAssertEqual(StageLayoutMenu.rotated(["a", "b", "c"], forward: true), ["c", "a", "b"])
        XCTAssertEqual(StageLayoutMenu.rotated(["a", "b", "c"], forward: false), ["b", "c", "a"])
        XCTAssertEqual(StageLayoutMenu.rotated(["a"], forward: true), ["a"])
    }
}
