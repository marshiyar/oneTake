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
@testable import MpvfxColor

final class ComputeErrorMessageTests: XCTestCase {
    func testStopsAtFirstNULAndIgnoresBufferPadding() {
        var buffer = [CChar](repeating: 88, count: 512)
        let message = "device unavailable".utf8.map { CChar(bitPattern: $0) }
        buffer.replaceSubrange(0..<message.count, with: message)
        buffer[message.count] = 0
        XCTAssertEqual(computeErrorMessage(buffer), "device unavailable")
        buffer[0] = 0
        XCTAssertEqual(computeErrorMessage(buffer), "")
    }

    func testDecodesNonASCIIAndRepairsInvalidUTF8LikeCString() {
        let messages: [[UInt8]] = [Array("GPU: périphérique 日本語".utf8), [0xC3, 0x28], [0xFF]]
        for message in messages {
            let buffer = (message + [0, 88, 89]).map { CChar(bitPattern: $0) }
            let expected = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            XCTAssertEqual(computeErrorMessage(buffer), expected)
        }
        XCTAssertEqual(computeErrorMessage([CChar(bitPattern: 0xC3), 0x28, 0]), "\u{FFFD}(")
    }

    func testMaximumLengthTerminatedDiagnosticAndZeroFilledBuffer() {
        let buffer = [CChar](repeating: 65, count: 511) + [0]
        XCTAssertEqual(computeErrorMessage(buffer), String(repeating: "A", count: 511))
        XCTAssertEqual(computeErrorMessage([CChar](repeating: 0, count: 512)), "")
    }
}
