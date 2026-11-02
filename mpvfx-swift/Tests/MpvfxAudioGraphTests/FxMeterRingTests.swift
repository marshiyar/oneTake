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

/// The fixed-size ring the feeder publishes meter readings into.
final class FxMeterRingTests: XCTestCase {
    func reading(_ frame: Int) -> FxMeterReading {
        FxMeterReading(frame: frame, inputPeak: Float(frame), inputRMS: Float(frame) + 1, outputPeak: Float(frame) + 2, outputRMS: Float(frame) + 3)
    }

    func testReadsTheNewestReadingAtOrBeforeAFrame() {
        let ring = FxMeterRing()
        XCTAssertNil(ring.reading(atOrBefore: 100))
        for k in 0..<10 { ring.publish(reading(k * 128)) }
        XCTAssertEqual(ring.reading(atOrBefore: 128 * 4 + 5)?.frame, 128 * 4)
        XCTAssertEqual(ring.reading(atOrBefore: 128 * 4)?.frame, 128 * 4)
        XCTAssertEqual(ring.reading(atOrBefore: 1_000_000)?.frame, 128 * 9)
        XCTAssertNil(ring.reading(atOrBefore: -1))
    }

    func testOnlyTheLatestReadingsAreKept() {
        let ring = FxMeterRing()
        for k in 0..<(FxMeterRing.capacity * 3) { ring.publish(reading(k)) }
        XCTAssertEqual(ring.count, FxMeterRing.capacity * 3)
        XCTAssertEqual(ring.reading(atOrBefore: Int.max)?.frame, FxMeterRing.capacity * 3 - 1)
        XCTAssertNil(ring.reading(atOrBefore: 10), "a frame long gone is not answered with a newer one")
    }

    func testLevelsOfABlock() {
        let level = FxLevel([[0.5, -0.5, 0.5, -0.5], [0, 0, 0, 1]])
        XCTAssertEqual(level.peak, 1)
        XCTAssertEqual(Double(level.rms), (4 * 0.25 + 1) / 8, accuracy: 1e-6, "RMS of all samples is the root of the mean square")
        XCTAssertEqual(FxLevel([]).rms, 0)
        XCTAssertEqual(FxMeterReading.decibels(1), 0, accuracy: 1e-9)
        XCTAssertEqual(FxMeterReading.decibels(0), -120)
        XCTAssertEqual(FxMeterReading(frame: 0, lowestGain: 0.5).gainReductionDb, 6.0206, accuracy: 1e-3)
    }

    /// A reader running against the feeder never sees a half-written reading.
    func testAReaderNeverSeesATornReading() {
        let ring = FxMeterRing()
        let done = Atomic(false)
        let writer = Thread {
            var k = 0
            while !done.value { ring.publish(self.reading(k & 0xFFFFF)); k += 1 }
        }
        writer.start()
        var checked = 0
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let r = ring.reading(atOrBefore: Int.max) {
                XCTAssertEqual(r.inputRMS, r.inputPeak + 1)
                XCTAssertEqual(r.outputPeak, r.inputPeak + 2)
                XCTAssertEqual(r.outputRMS, r.inputPeak + 3)
                XCTAssertEqual(Int(r.inputPeak), r.frame)
                checked += 1
            }
        }
        done.value = true
        XCTAssertGreaterThan(checked, 1000)
    }
}

private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ flag: Bool) { self.flag = flag }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}
