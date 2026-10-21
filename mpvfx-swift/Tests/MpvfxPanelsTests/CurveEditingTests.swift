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
import MpvfxShared
@testable import MpvfxPanels

/// The curve editor's point rules (`CurveEditing`): what the graph shows, and what each edit stores.
final class CurveEditingTests: XCTestCase {
    let rgb = CurveEditing(hue: false, limit: 0...1)
    let hueSat = CurveEditing(hue: true, limit: -1...1)

    /// The graph shows the points the renderer reads: end points added, values clamped, too few hue points flat.
    func testDisplayedIsWhatRenders() {
        XCTAssertEqual(rgb.displayed([[0.2, 0.9], [0.8, 0.1]]), [[0, 0], [0.2, 0.9], [0.8, 0.1], [1, 1]])
        XCTAssertEqual(rgb.displayed([[-0.3, 1.4], [0.5, -0.2], [1.4, 0.5]]), [[0, 1], [0.5, 0], [1, 0.5]])
        XCTAssertEqual(rgb.displayed([[0, 0], [0.5, 0.2], [0.5, 0.8], [1, 1]]), GradeCurve.identity, "a shared input renders the identity")
        XCTAssertEqual(hueSat.displayed([[90, 1]]), [])
        XCTAssertEqual(hueSat.displayed([[400, 2], [0, 0], [200, -0.5]]), [[0, 0], [40, 1], [200, -0.5]])
    }

    func testStoredDropsTheDefaultCurve() {
        XCTAssertNil(rgb.stored(GradeCurve.identity))
        XCTAssertEqual(rgb.stored([[0, 0.1], [1, 1]]), [[0, 0.1], [1, 1]])
        XCTAssertNil(hueSat.stored([]))
        XCTAssertNil(hueSat.stored([[0, 0.2], [100, 0]]), "two hue points render nothing")
    }

    func testEndPointsArePinned() {
        let pts: [[Double]] = [[0, 0], [0.5, 0.5], [1, 1]]
        XCTAssertEqual(rgb.moving(0, to: [0.3, 0.4], in: pts)[0], [0, 0.4])
        XCTAssertEqual(rgb.moving(2, to: [0.7, 0.6], in: pts)[2], [1, 0.6])
        XCTAssertEqual(rgb.moving(1, to: [1.2, 1.5], in: pts)[1], [0.99, 1], "inside the white point, output clamped")
        XCTAssertNil(rgb.removing(0, from: pts)); XCTAssertNil(rgb.removing(2, from: pts))
        XCTAssertEqual(rgb.removing(1, from: pts), GradeCurve.identity)
        XCTAssertEqual(rgb.moving(7, to: [0.5, 0.5], in: pts), pts, "an index past the end changes nothing")
        XCTAssertEqual(rgb.moving(1, to: [0.4, .nan], in: pts), pts, "a non-finite output changes nothing")
        XCTAssertEqual(rgb.moving(1, to: [.infinity, 0.4], in: pts), pts, "a non-finite input changes nothing")
    }

    func testHuePointsMoveInsideTheirNeighboursAndTheCircle() {
        let pts: [[Double]] = [[10, 0], [90, 0.5], [180, 0]]
        XCTAssertEqual(hueSat.moving(0, to: [-30, 0.2], in: pts)[0], [0, 0.2])
        XCTAssertEqual(hueSat.moving(2, to: [400, 0.2], in: pts)[2], [359.9, 0.2])
        XCTAssertEqual(hueSat.moving(1, to: [200, 0.2], in: pts)[1], [179, 0.2])
    }

    /// An added point never lands on another point's input; with no room left it is refused.
    func testInsertNeverSharesAnInput() throws {
        let pts: [[Double]] = [[0, 0], [0.5, 0.5], [1, 1]]
        let left = try XCTUnwrap(rgb.inserting([0, 0.8], into: pts))
        XCTAssertEqual(left.points[left.index], [0.01, 0.8])
        let right = try XCTUnwrap(rgb.inserting([1, 0.2], into: pts))
        XCTAssertEqual(right.points[right.index], [0.99, 0.2])
        let above = try XCTUnwrap(rgb.inserting([0.5, 0.9], into: pts))
        XCTAssertEqual(above.points[above.index], [0.51, 0.9])
        XCTAssertNil(rgb.inserting([0.01, 0.2], into: [[0, 0], [0.015, 0.5], [1, 1]]), "no room between 0 and 0.015")
        let full = (0..<16).map { [Double($0) / 15, Double($0) / 15] }
        XCTAssertNil(rgb.inserting([0.52, 0.1], into: full), "16 points is the most the renderer takes")
        XCTAssertNil(rgb.inserting([Double.nan, 0.1], into: pts))
    }

    /// The first hue point brings a flat anchor 60° either side, wrapped around the circle.
    func testEmptyHueCurveSeedsThreePoints() throws {
        let a = try XCTUnwrap(hueSat.inserting([100, 0.5], into: []))
        XCTAssertEqual(a.points, [[40, 0], [100, 0.5], [160, 0]]); XCTAssertEqual(a.index, 1)
        let b = try XCTUnwrap(hueSat.inserting([20, 0.5], into: []))
        XCTAssertEqual(b.points, [[20, 0.5], [80, 0], [320, 0]]); XCTAssertEqual(b.index, 0)
        let c = try XCTUnwrap(hueSat.inserting([359.9999, -2], into: []))
        XCTAssertEqual(c.points, [[0, -1], [60, 0], [300, 0]], "359.9999 rounds onto 0, the output is clamped")
        XCTAssertEqual(hueSat.displayed(c.points), c.points)
    }

    func testRemovingAHuePointBelowThreeClearsTheCurve() {
        XCTAssertEqual(hueSat.removing(1, from: [[0, 0.2], [120, 0.4], [240, 0.2]]), [])
        XCTAssertEqual(hueSat.removing(1, from: [[0, 0.2], [120, 0.4], [240, 0.2], [300, 0]]), [[0, 0.2], [240, 0.2], [300, 0]])
    }

    /// Enter's point: the middle of the widest gap (across 360° on a hue curve), on the curve.
    func testInsertionPointIsTheMiddleOfTheWidestGap() {
        XCTAssertEqual(rgb.insertionPoint([[0, 0], [0.2, 0.1], [1, 1]])[0], 0.6)
        XCTAssertEqual(rgb.insertionPoint(GradeCurve.identity), [0.5, 0.5])
        XCTAssertEqual(hueSat.insertionPoint([[0, 0], [90, 0], [180, 0]]), [270, 0])
        XCTAssertEqual(hueSat.insertionPoint([[20, 0], [100, 0], [350, 0]])[0], 225)
        XCTAssertEqual(hueSat.insertionPoint([]), [180, 0])
    }

    /// Random edits on every kind of curve: every result is one the renderer reads as it is (normalization is a
    /// no-op), so nothing the editor stores can make the renderer drop a curve.
    func testRandomEditsAlwaysGiveARenderableCurve() {
        var seed: UInt64 = 42
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for edit in [rgb, hueSat, CurveEditing(hue: true, limit: -180...180)] {
            var pts = edit.displayed([])
            let span = edit.limit.upperBound - edit.limit.lowerBound, xMax = edit.hue ? 400.0 : 1.2
            for step in 0..<2000 {
                let p = [next() * xMax - 0.1 * xMax, edit.limit.lowerBound - 0.2 * span + next() * 1.4 * span]
                switch next() {
                case ..<0.4: if let a = edit.inserting(p, into: pts) { pts = a.points }
                case ..<0.8: if !pts.isEmpty { pts = edit.moving(Int(next() * Double(pts.count)), to: p, in: pts) }
                default: if !pts.isEmpty, let r = edit.removing(Int(next() * Double(pts.count)), from: pts) { pts = r }
                }
                XCTAssertEqual(edit.displayed(pts), pts, "step \(step): \(pts)")
                XCTAssertLessThanOrEqual(pts.count, GradeCurve.maxPoints)
                if pts != edit.displayed(pts) { return }
            }
        }
    }
}
