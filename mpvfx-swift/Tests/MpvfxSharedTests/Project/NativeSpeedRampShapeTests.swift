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
@testable import MpvfxShared

final class NativeSpeedRampShapeTests: XCTestCase {
    let engine = KeyframeEngineStandIn()

    func testDocumentedShapes() throws {
        let expected: [(NativeSpeedRampShape, String, [Double], [Double])] = [
            (.slowMiddle, "Slow middle", [0, 0.3, 0.7, 1], [1, 0.25, 0.25, 1]),
            (.slowStart, "Slow start", [0, 0.5, 1], [0.25, 1, 1]),
            (.slowEnd, "Slow end", [0, 0.5, 1], [1, 1, 0.25]),
            (.speedUp, "Speed up", [0, 1], [1, 4]),
            (.slowDown, "Slow down", [0, 1], [1, 0.25]),
            (.twoHits, "Two hits", [0, 0.2, 0.25, 0.35, 0.6, 0.65, 0.75, 1], [1, 1, 0.2, 1, 1, 0.2, 1, 1])
        ]
        XCTAssertEqual(expected.map { $0.0 }, NativeSpeedRampShape.allCases)
        for (shape, title, fractions, speeds) in expected {
            XCTAssertEqual(shape.title, title)
            for duration in [100.0, 1000.0] {
                let points = shape.points(durationFrames: duration)
                XCTAssertEqual(points, zip(fractions, speeds).map { .init(t: $0.0 * duration, speed: $0.1) })
                XCTAssertEqual(points.last?.t, duration)
                XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0.t < $1.t })
                var doc = try parseNativeProjectDocument(J(clipCommandsFixtureJSON), engine: engine)
                for i in doc.assets.indices { doc.assets[i].durationFrames = 10000 }
                mutateClip(&doc, "clip:audio") { $0.durationFrames = duration; $0.speedRamp = NativeSpeedRamp(points: points) }
                XCTAssertNoThrow(try parseNativeProjectDocument(doc, engine: engine))
            }
        }
    }

    func testShortShapesDropCollisionsAndKeepTheExactEnd() {
        for shape in NativeSpeedRampShape.allCases {
            for duration in [0.0, 1, 2, 3, 4, 5, 0.25, 1.25] {
                let points = shape.points(durationFrames: duration)
                XCTAssertFalse(points.isEmpty)
                XCTAssertEqual(points.last?.t, duration)
                XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0.t < $1.t })
                XCTAssertTrue(points.allSatisfy { $0.t >= 0 && $0.t <= duration && $0.ease == .linear })
            }
        }
        XCTAssertEqual(NativeSpeedRampShape.twoHits.points(durationFrames: 1).map(\.t), [0, 1])
    }
}
