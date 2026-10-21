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
@testable import MpvfxScopes

/// Hostile frames and settings give typed errors or clamped values, never a crash or an unbounded allocation.
final class ScopeEngineInputTests: XCTestCase {
    func testInvalidSizesThrowInvalidSize() {
        for (w, h) in [(0, 1), (1, 0), (-4, 4), (ScopeFrame.maxSide + 1, 1), (Int.max, Int.max)] {
            XCTAssertThrowsError(try ScopeFrame(width: w, height: h, rgba: [])) { error in
                XCTAssertEqual(error as? ScopeError, .invalidSize(width: w, height: h))
            }
        }
    }

    func testShortAndLongBuffersThrowByteCount() {
        XCTAssertThrowsError(try ScopeFrame(width: 2, height: 2, rgba: [UInt8](repeating: 0, count: 15))) { error in
            XCTAssertEqual(error as? ScopeError, .byteCount(expected: 16, actual: 15))
        }
        XCTAssertThrowsError(try ScopeFrame(width: 2, height: 2, rgba: [UInt8](repeating: 0, count: 17))) { error in
            XCTAssertEqual(error as? ScopeError, .byteCount(expected: 16, actual: 17))
        }
    }

    func testOutOfRangeOptionsAreClamped() {
        let o = ScopeOptions.with {
            $0.columns = -5; $0.vectorRadius = 1 << 40; $0.vectorZoom = .nan; $0.maxSamples = -1; $0.workers = 10_000
        }.resolved
        XCTAssertEqual(o.columns, 1)
        XCTAssertEqual(o.vectorRadius, 512)
        XCTAssertEqual(o.vectorZoom, 1)
        XCTAssertEqual(o.maxSamples, 1)
        XCTAssertEqual(o.workers, 64)
        XCTAssertEqual(ScopeOptions.with { $0.vectorRadius = 0 }.resolved.vectorRadius, 16)
        XCTAssertEqual(ScopeOptions(vectorZoom: 100).resolved.vectorZoom, 8)
        XCTAssertEqual(ScopeOptions(vectorZoom: -.infinity).resolved.vectorZoom, 1)
    }

    func testExtremeOptionsStillAnalyse() throws {
        let f = try ScopeFixtures.busy(17, 9)
        let a = ScopeEngine.analyze(f, options: .with {
            $0.columns = 100_000; $0.vectorRadius = -3; $0.vectorZoom = .infinity; $0.maxSamples = 0; $0.workers = -2
        })
        XCTAssertEqual(a.step, 17, "one sample per frame at maxSamples 1")
        XCTAssertEqual(a.samples, 1)
        XCTAssertEqual(a.columns, 1)
        XCTAssertEqual(a.vectorSide, 33)
    }

    func testOneByOneFrameAndFullyTransparentFrame() throws {
        let one = ScopeEngine.analyze(try ScopeFixtures.solid(1, 1, 10, 20, 30))
        XCTAssertEqual(one.samples, 1)
        let clear = ScopeEngine.analyze(try ScopeFixtures.solid(16, 16, 255, 255, 255, alpha: 0))
        XCTAssertEqual(clear.samples, 0)
        XCTAssertEqual(clear.histogram.reduce(0, +), 0)
    }
}
