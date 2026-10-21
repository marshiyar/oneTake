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
@testable import MpvfxPlayer
import MpvfxCanvas

/// The transform box maths in view px: edge stretch per side, free and aspect-locked corners, ⌥ from the anchor,
/// rotation about the anchor, 15° snapping, the minimum side, and crop riding along with a resize.
final class TransformBoxGeometryTests: XCTestCase {
    let box = StageElement(id: "a", name: "A", rect: CanvasRect(x: 100, y: 100, width: 200, height: 100), kind: .element)

    func close(_ a: CanvasPoint, _ b: CanvasPoint, _ msg: String = "", line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6, "x \(msg)", line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-6, "y \(msg)", line: line)
    }

    /// The handle's local point pushed `d` px outward along its own axes.
    func outward(_ e: StageElement, _ h: TransformHandle, _ d: Double) -> CanvasPoint {
        let p = TransformBox.localPoint(e, unit: h.unit)
        return CanvasPoint(p.x + (h.unit.x - 0.5) * 2 * d, p.y + (h.unit.y - 0.5) * 2 * d)
    }

    func testEachEdgeStretchesOnlyItsOwnAxisAndKeepsTheOppositeEdge() {
        let opposite: [TransformHandle: TransformHandle] = [.n: .s, .s: .n, .e: .w, .w: .e]
        for rot in [0.0, 30.0, -120.0] { for h in TransformHandle.edges {
            var e = box; e.rotation = rot
            let fixedBefore = TransformBox.screenPoint(e, unit: opposite[h]!.unit)
            let out = TransformBox.resized(e, TransformResize(handle: h, pointer: outward(e, h, 40)))
            let tag = "\(h) rot \(rot)"
            if h.movesX {
                XCTAssertEqual(out.rect.width, 240, accuracy: 1e-6, tag); XCTAssertEqual(out.rect.height, 100, accuracy: 1e-6, tag)
            } else {
                XCTAssertEqual(out.rect.height, 140, accuracy: 1e-6, tag); XCTAssertEqual(out.rect.width, 200, accuracy: 1e-6, tag)
            }
            close(TransformBox.screenPoint(out, unit: opposite[h]!.unit), fixedBefore, "opposite edge fixed \(tag)")
            close(TransformBox.screenPoint(out, unit: h.unit), PlayerView.rotate(outward(e, h, 40), about: e.centre, rot), "handle under the pointer \(tag)")
            XCTAssertEqual(out.rotation, rot)
        } }
    }

    func testCornersScaleFreelyAndShiftKeepsTheAspectRatio() {
        let p = CanvasPoint(400, 150)   // se pulled 100 right, 50 up
        let free = TransformBox.resized(box, TransformResize(handle: .se, pointer: p))
        XCTAssertEqual(free.rect, CanvasRect(x: 100, y: 100, width: 300, height: 50))
        let locked = TransformBox.resized(box, TransformResize(handle: .se, pointer: p, keepAspect: true))
        XCTAssertEqual(locked.rect.width / locked.rect.height, 2, accuracy: 1e-9, "aspect 2:1 kept")
        XCTAssertEqual(locked.rect.width, 300, accuracy: 1e-9, "the larger change wins")
        close(CanvasPoint(locked.rect.x, locked.rect.y), CanvasPoint(100, 100), "nw corner fixed")
        // An edge with the aspect kept carries the other side, centred on the fixed side.
        let edge = TransformBox.resized(box, TransformResize(handle: .e, pointer: CanvasPoint(400, 150), keepAspect: true))
        XCTAssertEqual(edge.rect, CanvasRect(x: 100, y: 75, width: 300, height: 150))
    }

    func testFromTheCentreGrowsBothSidesAndKeepsTheCentre() {
        for rot in [0.0, 45.0] {
            var e = box; e.rotation = rot
            let c = e.centre
            let out = TransformBox.resized(e, TransformResize(handle: .e, pointer: outward(e, .e, 30), fromAnchor: true))
            XCTAssertEqual(out.rect.width, 260, accuracy: 1e-6, "30 px each side (rot \(rot))")
            close(out.centre, c, "centre fixed (rot \(rot))")
            let corner = TransformBox.resized(e, TransformResize(handle: .nw, pointer: outward(e, .nw, 10), fromAnchor: true))
            XCTAssertEqual(corner.rect.width, 220, accuracy: 1e-6); XCTAssertEqual(corner.rect.height, 120, accuracy: 1e-6)
            close(corner.centre, c)
        }
    }

    func testFromAnAnchorOffTheCentreKeepsTheAnchorUnderRotation() {
        var e = box; e.rotation = 37
        let anchor = CanvasPoint(0.25, 0.8)
        let pinned = TransformBox.screenPoint(e, unit: anchor)
        var req = TransformResize(handle: .se, pointer: outward(e, .se, 25), fromAnchor: true)
        req.anchor = anchor
        let out = TransformBox.resized(e, req)
        close(TransformBox.screenPoint(out, unit: anchor), pinned, "anchor fixed on screen")
        XCTAssertGreaterThan(out.rect.width, e.rect.width)
    }

    func testRotationTurnsAboutTheAnchor() {
        let centre = TransformBox.rotated(box, by: 90, anchor: TransformBox.centreAnchor)
        XCTAssertEqual(centre.rect, box.rect, "about the centre the box stays put")
        XCTAssertEqual(centre.rotation, 90)
        let corner = CanvasPoint(0, 0)
        var e = box; e.rotation = 20
        let pivot = TransformBox.screenPoint(e, unit: corner)
        let out = TransformBox.rotated(e, by: 70, anchor: corner)
        close(TransformBox.screenPoint(out, unit: corner), pivot, "top-left anchor fixed")
        XCTAssertEqual(out.rotation, 90)
        XCTAssertEqual(out.rect.width, 200); XCTAssertEqual(out.rect.height, 100)
        close(out.centre, PlayerView.rotate(e.centre, about: pivot, 70), "centre travels around the anchor")
    }

    func testRotationSnapsToFifteenDegreesAndWrapsTheTurn() {
        XCTAssertEqual(TransformBox.rotation(start: 0, from: 0, to: 37, snap: 15), 30)
        XCTAssertEqual(TransformBox.rotation(start: 0, from: 0, to: 38, snap: 15), 45)
        XCTAssertEqual(TransformBox.rotation(start: 10, from: 170, to: -170, snap: nil), 30, "crossing ±180 turns 20°, not -340°")
        XCTAssertEqual(TransformBox.rotation(start: 0, from: 0, to: 12.3456, snap: nil), 12.35)
    }

    func testDraggingPastTheOppositeSideStopsAtTheMinimumAndNeverFlips() {
        let out = TransformBox.resized(box, TransformResize(handle: .e, pointer: CanvasPoint(-500, 150)))
        XCTAssertEqual(out.rect.width, TransformBox.minimumSide)
        XCTAssertEqual(out.rect.x, 100, "left edge stays")
    }

    func testCropScalesWithTheBoxAndTheVisibleEdgeFollowsThePointer() {
        var e = box; e.crop = CropInsets(top: 10, right: 20, bottom: 10, left: 20)
        let v = e.visibleRect   // 120…280 × 110…190
        let out = TransformBox.resized(e, TransformResize(handle: .e, pointer: CanvasPoint(v.maxX + 80, 150)))
        XCTAssertEqual(out.visibleRect.width, v.width + 80, accuracy: 1e-9)
        XCTAssertEqual(out.visibleRect.x, v.x, accuracy: 1e-9, "visible left edge fixed")
        XCTAssertEqual(out.crop.left, 20 * 240 / 160, accuracy: 1e-9, "crop scales with its axis")
        XCTAssertEqual(out.crop.top, 10, accuracy: 1e-9)
    }

    func testUnitIsTheInverseOfScreenPoint() {
        var e = box; e.rotation = -63; e.crop = CropInsets(top: 5, right: 0, bottom: 15, left: 30)
        let u = CanvasPoint(0.3, 0.9)
        close(TransformBox.unit(e, of: TransformBox.screenPoint(e, unit: u)), u)
    }
}
