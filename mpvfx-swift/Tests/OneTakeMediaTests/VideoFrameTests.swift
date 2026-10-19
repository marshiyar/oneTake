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
@testable import OneTakeMedia

final class VideoFrameTests: XCTestCase {
    func testRGBA8RoundTripThroughLinearHalfFloat() throws {
        var ramp = [UInt8]()
        for value in 0 ... 255 {
            ramp.append(contentsOf: [UInt8(value), UInt8(255 - value), UInt8(value / 2), UInt8(value)])
        }
        let original = try VideoFrame(width: 256, height: 1, storage: .rgba8(ramp))
        let linear = try original.convertedToRGBA16F()
        let roundTrip = try linear.convertedToRGBA8()

        guard case let .rgba8(actual) = roundTrip.storage else {
            return XCTFail("expected RGBA8 storage")
        }
        for (expected, actual) in zip(ramp, actual) {
            XCTAssertLessThanOrEqual(abs(Int(expected) - Int(actual)), 1)
        }
    }

    func testByteCountsAt1080pAnd4K() throws {
        XCTAssertEqual(VideoPixelFormat.rgba8DisplayReferred.bytesPerPixel, 4)
        XCTAssertEqual(VideoPixelFormat.rgba16FLinear.bytesPerPixel, 8)

        for (width, height) in [(1_920, 1_080), (3_840, 2_160)] {
            let componentCount = width * height * 4
            let rgba8 = try VideoFrame(width: width, height: height,
                                       storage: .rgba8([UInt8](repeating: 0, count: componentCount)))
            let rgba16F = try VideoFrame(width: width, height: height,
                                         storage: .rgba16F([Float16](repeating: 0, count: componentCount)))
            XCTAssertEqual(rgba8.byteCount, width * height * 4)
            XCTAssertEqual(rgba16F.byteCount, width * height * 8)
            XCTAssertEqual(rgba8.bytesPerRow, width * 4)
            XCTAssertEqual(rgba16F.bytesPerRow, width * 8)
        }
    }

    func testAlphaIsLinearAndStraightAcrossConversions() throws {
        let frame = try VideoFrame(width: 2, height: 1, storage: .rgba8([
            255, 0, 0, 0,
            64, 128, 255, 128,
        ]))
        let linear = try frame.convertedToRGBA16F()
        guard case let .rgba16F(components) = linear.storage else {
            return XCTFail("expected RGBA16F storage")
        }
        XCTAssertEqual(Float(components[3]), 0, accuracy: 0.0001)
        XCTAssertEqual(Float(components[7]), 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(Float(components[4]), 0.05127, accuracy: 0.001)

        XCTAssertEqual(try linear.convertedToRGBA8(), frame)
    }

    func testRejectsStorageWithWrongComponentCount() {
        XCTAssertThrowsError(try VideoFrame(width: 2, height: 2, storage: .rgba8([UInt8](repeating: 0, count: 15)))) {
            XCTAssertEqual($0 as? VideoFrame.Error, .invalidComponentCount(expected: 16, actual: 15))
        }
    }
}
