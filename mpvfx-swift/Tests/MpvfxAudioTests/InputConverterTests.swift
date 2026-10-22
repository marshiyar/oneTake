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
// The capture converter: channel mixing and resampling from a device's own format to the recording format, the same
// samples however the stream is cut into blocks.
import XCTest
@testable import MpvfxAudio

final class InputConverterTests: XCTestCase {
    func sine(_ f: Double, rate: Int, seconds: Double) -> [Float] { WavFixtures.sine(f, seconds: seconds, amp: 0.5, sampleRate: rate) }

    func testSameFormatPassesThroughUntouched() {
        var c = InputConverter(sourceRate: 48_000, sourceChannels: 1, targetRate: 48_000, targetChannels: 1)
        let block: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(c.process(block), block)
    }

    func testStereoToMonoAveragesAndMonoToStereoRepeats() {
        var down = InputConverter(sourceRate: 48_000, sourceChannels: 2, targetRate: 48_000, targetChannels: 1)
        XCTAssertEqual(down.process([0.25, 0.75, -0.25, 0.25]), [0.5, 0])
        var up = InputConverter(sourceRate: 48_000, sourceChannels: 1, targetRate: 48_000, targetChannels: 2)
        XCTAssertEqual(up.process([0.5, -0.5]), [0.5, 0.5, -0.5, -0.5])
    }

    func testFourChannelsKeepTheFirstTwoForStereo() {
        var c = InputConverter(sourceRate: 48_000, sourceChannels: 4, targetRate: 48_000, targetChannels: 2)
        XCTAssertEqual(Array(c.process([1, 2, 3, 4, 5, 6, 7, 8]).prefix(2)), [1, 2])
    }

    /// 44.1 kHz in, 48 kHz out: the length scales by 48/44.1 and a 440 Hz sine keeps its pitch.
    func testResamplingKeepsDurationAndPitch() {
        var c = InputConverter(sourceRate: 44_100, sourceChannels: 1, targetRate: 48_000, targetChannels: 1)
        let out = c.process(sine(440, rate: 44_100, seconds: 1))
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 3)
        XCTAssertEqual(crossingsPerSecond(out, sampleRate: 48_000), 880, accuracy: 6)
        XCTAssertLessThanOrEqual(out.map(abs).max() ?? 9, 0.5001, "linear interpolation never overshoots")
    }

    func testTheSamplesDoNotDependOnHowTheStreamIsCutIntoBlocks() {
        let source = sine(300, rate: 96_000, seconds: 0.5)
        var whole = InputConverter(sourceRate: 96_000, sourceChannels: 1, targetRate: 48_000, targetChannels: 1)
        let reference = whole.process(source)
        for cut in [1, 7, 480, 1001] {
            var c = InputConverter(sourceRate: 96_000, sourceChannels: 1, targetRate: 48_000, targetChannels: 1)
            var pieces: [Float] = []
            var i = 0
            while i < source.count { pieces += c.process(Array(source[i..<min(source.count, i + cut)])); i += cut }
            XCTAssertEqual(pieces.count, reference.count, "cut \(cut)")
            XCTAssertEqual(zip(pieces, reference).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 1e-6, "cut \(cut)")
        }
    }

    func testDownsamplingStereoDeviceToMonoRecordingEndsWithTheRightLength() {
        var c = InputConverter(sourceRate: 96_000, sourceChannels: 2, targetRate: 48_000, targetChannels: 1)
        let tone = sine(500, rate: 96_000, seconds: 0.25)
        let out = c.process(tone.flatMap { [$0, $0] })
        XCTAssertEqual(Double(out.count), 12_000, accuracy: 3)
    }
}
