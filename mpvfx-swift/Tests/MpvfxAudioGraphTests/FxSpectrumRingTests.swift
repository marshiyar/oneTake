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
@testable import MpvfxAudioGraph

/// The ring the feeder publishes spectra into, and the UI reads them from.
final class FxSpectrumRingTests: XCTestCase {
    func publish(_ ring: FxSpectrumRing, frame: Int, level: Float) {
        let bands = [Float](repeating: level, count: ring.bandCount)
        bands.withUnsafeBufferPointer { ring.publish(frame: frame, bands: $0) }
    }

    func testReadsTheNewestSpectrumAtOrBeforeAFrame() {
        let ring = FxSpectrumRing(bandCount: 6)
        XCTAssertNil(ring.reading(atOrBefore: 100))
        for k in 0..<5 { publish(ring, frame: k * 2048, level: Float(-k)) }
        let reading = ring.reading(atOrBefore: 2048 * 2 + 10)
        XCTAssertEqual(reading?.frame, 4096)
        XCTAssertEqual(reading?.bands, [Float](repeating: -2, count: 6))
        XCTAssertEqual(ring.reading(atOrBefore: 1_000_000)?.frame, 4 * 2048)
        XCTAssertNil(ring.reading(atOrBefore: -1))
    }

    func testOnlyTheLatestSpectraAreKept() {
        let ring = FxSpectrumRing(bandCount: 4)
        for k in 0..<(FxSpectrumRing.capacity * 3) { publish(ring, frame: k, level: -10) }
        XCTAssertEqual(ring.count, FxSpectrumRing.capacity * 3)
        XCTAssertEqual(ring.reading(atOrBefore: Int.max)?.frame, FxSpectrumRing.capacity * 3 - 1)
        XCTAssertNil(ring.reading(atOrBefore: 3), "a frame long gone is not answered with a newer spectrum")
    }

    func testTheChainMetersHoldTheWatchedModulesRings() {
        let meters = FxChainMeters(nodeIds: ["a", "b"])
        XCTAssertEqual(meters.watchedNode.load(ordering: .relaxed), -1)
        XCTAssertEqual(meters.spectrumInput.bandCount, SpectrumAnalyzer.bandCount)
        XCTAssertEqual(meters.spectrumOutput.bandCount, SpectrumAnalyzer.bandCount)
        XCTAssertNil(meters.spectrumOutput.reading(atOrBefore: 0))
    }
}
