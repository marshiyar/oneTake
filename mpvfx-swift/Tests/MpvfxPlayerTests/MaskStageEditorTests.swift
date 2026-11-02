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
// Issue #297 A2/A3: what dragging and nudging each kind of mask handle makes of the mask, with ⇧ and ⌥.
import MpvfxCanvas
import MpvfxShared
import XCTest

@testable import MpvfxPlayer

internal final class MaskStageEditorTests: XCTestCase {
    private let size = CanvasSize(400, 200)
    private func mask(_ kind: String, x: Double = 0.5, y: Double = 0.5, width: Double? = 0.5, height: Double? = 0.5,
                      angle: Double? = nil, feather: Double? = nil) -> NativeClipMask {
        NativeClipMask(id: "m", kind: kind, configuration: .init(x: x, y: y, width: width, height: height, angle: angle, feather: feather))
    }
    private func point(_ m: NativeClipMask, _ h: MaskHandle) -> CanvasPoint {
        MaskStageEditor.handles(of: m, layerSize: size).first { $0.handle == h }!.point
    }
    private func assertClose(_ a: Double?, _ b: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try XCTUnwrap(a, what, file: file, line: line), b, accuracy: 1e-9, what, file: file, line: line)
    }

    internal func testARectangleHasEightHandlesOnItsOutline() {
        let handles = MaskStageEditor.handles(of: mask("rectangle"), layerSize: size)
        XCTAssertEqual(handles.count, 8)
        XCTAssertEqual(point(mask("rectangle"), .corner(0)), CanvasPoint(100, 50))
        XCTAssertEqual(point(mask("rectangle"), .corner(2)), CanvasPoint(300, 150))
        XCTAssertEqual(point(mask("rectangle"), .edge(1)), CanvasPoint(300, 100))
        XCTAssertEqual(point(mask("ellipse"), .edge(0)), CanvasPoint(200, 50))
    }

    internal func testHandlesTurnWithTheMaskAngle() {
        let m = mask("rectangle", angle: 90)   // clockwise: the right edge now points down
        let right = point(m, .edge(1))
        XCTAssertEqual(right.x, 200, accuracy: 1e-9); XCTAssertEqual(right.y, 100 + 100, accuracy: 1e-9)
    }

    internal func testDraggingAnEdgeMovesOnlyThatSideAndKeepsTheOppositeOne() {
        let m = mask("rectangle")
        let out = MaskStageEditor.dragged(m, handle: .edge(1), to: CanvasPoint(340, 120), from: point(m, .edge(1)), layerSize: size)
        assertClose(out.width, 240.0 / 400, "right edge to x 340: left edge stays at 100")
        assertClose(out.x, 220.0 / 400, "centre between 100 and 340")
        assertClose(out.height, 0.5, "height untouched"); assertClose(out.y, 0.5, "y untouched")
    }

    internal func testShiftKeepsTheProportionsOfACornerDrag() {
        let m = mask("rectangle")   // 200 x 100, ratio 2
        let out = MaskStageEditor.dragged(m, handle: .corner(2), to: CanvasPoint(400, 160), from: point(m, .corner(2)), layerSize: size,
                                          keepProportions: true)
        // The bottom-right corner moves from (300,150); top-left (100,50) stays; the side that grew more wins: width 300.
        assertClose(out.width, 300.0 / 400, "width follows the pointer")
        assertClose(out.height, 150.0 / 200, "height keeps the 2:1 ratio")
        assertClose(out.x, 250.0 / 400, "top-left corner stays at 100"); assertClose(out.y, 125.0 / 200, "top-left corner stays at 50")
    }

    internal func testOptionResizesAboutTheCentre() {
        let m = mask("ellipse")
        let out = MaskStageEditor.dragged(m, handle: .corner(1), to: CanvasPoint(340, 20), from: point(m, .corner(1)), layerSize: size,
                                          fromCenter: true)
        assertClose(out.width, 280.0 / 400, "the centre stays at 200: half width 140")
        assertClose(out.height, 160.0 / 200, "half height 80")
        assertClose(out.x, 0.5, "centre x"); assertClose(out.y, 0.5, "centre y")
    }

    internal func testASideDraggedPastTheOtherLeavesTheMinimumAndNeverFlips() {
        let m = mask("rectangle")
        let out = MaskStageEditor.dragged(m, handle: .edge(1), to: CanvasPoint(10, 100), from: point(m, .edge(1)), layerSize: size)
        assertClose(out.width, MaskStageEditor.minimumSide / 400, "minimum width")
        XCTAssertGreaterThan(try XCTUnwrap(out.width), 0)
    }

    internal func testDraggingTheBodyMovesTheMask() {
        let m = mask("rectangle")
        let out = MaskStageEditor.dragged(m, handle: .body, to: CanvasPoint(240, 130), from: CanvasPoint(200, 100), layerSize: size)
        assertClose(out.x, 0.6, "40 px right of 400"); assertClose(out.y, 0.65, "30 px down of 200")
        XCTAssertTrue(MaskStageEditor.contains(m, CanvasPoint(200, 100), layerSize: size))
        XCTAssertFalse(MaskStageEditor.contains(m, CanvasPoint(20, 20), layerSize: size))
        XCTAssertFalse(MaskStageEditor.contains(mask("ellipse"), CanvasPoint(101, 51), layerSize: size), "the ellipse's corner is outside it")
        XCTAssertFalse(MaskStageEditor.contains(mask("linear"), CanvasPoint(200, 100), layerSize: size), "a line has no body")
    }

    internal func testALinearMaskHasCentreTurnAndFeatherHandles() {
        let m = mask("linear", width: nil, height: nil, angle: 0, feather: 30)
        XCTAssertEqual(MaskStageEditor.handles(of: m, layerSize: size).map(\.handle), [.center, .rotate, .feather])
        XCTAssertEqual(point(m, .center), CanvasPoint(200, 100))
        XCTAssertEqual(point(m, .rotate), CanvasPoint(200, 100 + MaskStageEditor.rotateReach))
        XCTAssertEqual(point(m, .feather).x, 230, "the feather handle sits feather px off the line, on the soft side")
        let turned = MaskStageEditor.dragged(m, handle: .rotate, to: CanvasPoint(100, 100), from: point(m, .rotate), layerSize: size)
        assertClose(turned.angle, 90, "pointer straight left: the line turns a quarter clockwise")
        let soft = MaskStageEditor.dragged(m, handle: .feather, to: CanvasPoint(250, 160), from: point(m, .feather), layerSize: size)
        assertClose(soft.feather, 50, "50 px right of the line through x 200")
        let behind = MaskStageEditor.dragged(m, handle: .feather, to: CanvasPoint(120, 160), from: point(m, .feather), layerSize: size)
        assertClose(behind.feather, 0, "never negative")
        let moved = MaskStageEditor.dragged(m, handle: .center, to: CanvasPoint(240, 100), from: point(m, .center), layerSize: size)
        assertClose(moved.x, 0.6, "the line moves")
    }

    internal func testABandResizesFromBothEdgesSymmetrically() {
        let m = mask("band", width: 0.25, height: nil, angle: 0)   // 100 px wide
        XCTAssertEqual(point(m, .edge(1)), CanvasPoint(250, 100)); XCTAssertEqual(point(m, .edge(3)), CanvasPoint(150, 100))
        let wider = MaskStageEditor.dragged(m, handle: .edge(1), to: CanvasPoint(280, 100), from: point(m, .edge(1)), layerSize: size)
        assertClose(wider.width, 160.0 / 400, "centre stays: half width 80")
        assertClose(wider.x, 0.5, "centre x")
        let other = MaskStageEditor.dragged(m, handle: .edge(3), to: CanvasPoint(120, 100), from: point(m, .edge(3)), layerSize: size)
        assertClose(other.width, 160.0 / 400, "the left edge widens it the same way")
    }

    internal func testNudgingMovesTheHandleByOneOrTenPixelsOfTheLayer() {
        let m = mask("rectangle")
        let one = MaskStageEditor.nudged(m, handle: .edge(1), dx: 1, dy: 0, layerSize: size)
        assertClose(one.width, 201.0 / 400, "edge right by 1 px"); assertClose(one.x, 200.5 / 400, "centre follows by half")
        let ten = MaskStageEditor.nudged(m, handle: .body, dx: 0, dy: -10, layerSize: size)
        assertClose(ten.y, 90.0 / 200, "body up 10 px"); assertClose(ten.width, 0.5, "size unchanged")
        let corner = MaskStageEditor.nudged(m, handle: .corner(0), dx: -10, dy: -10, layerSize: size)
        assertClose(corner.width, 210.0 / 400, "top-left out by 10"); assertClose(corner.height, 110.0 / 200, "")
    }

    internal func testDraggingNeverChangesAnythingButWhatTheHandleOwns() {
        var m = mask("rectangle"); m.feather = 12; m.opacity = 0.5; m.invert = true; m.mode = "subtract"
        let out = MaskStageEditor.dragged(m, handle: .edge(2), to: CanvasPoint(200, 190), from: point(m, .edge(2)), layerSize: size)
        XCTAssertEqual(out.feather, 12); XCTAssertEqual(out.opacity, 0.5); XCTAssertEqual(out.invert, true); XCTAssertEqual(out.mode, "subtract")
        XCTAssertEqual(out.id, "m"); XCTAssertEqual(out.kind, "rectangle")
    }
}
