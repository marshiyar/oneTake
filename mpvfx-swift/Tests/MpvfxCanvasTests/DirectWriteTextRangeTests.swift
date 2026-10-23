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
#if os(Windows)
import CMpvfxWin32
@testable import MpvfxCanvas
import XCTest

internal final class DirectWriteTextRangeTests: XCTestCase {
    internal func testEmptyRangesSucceedWithoutNativeLayoutOrBuffers() {
        var text: MpvfxText = MpvfxText(text: nil, length: 0, family: nil, size: 22, weight: 400, italic: 0)

        XCTAssertEqual(mpvfx_d2d_text_ranges(&text, nil, nil, nil, 0), 0)
    }

    internal func testMalformedRangesReturnInvalidArgumentBeforeNativeLayout() {
        let invalidArgument = Int32(bitPattern: 0x80070057)
        let inputs: [(Int32, Int32)] = [(-1, 1), (0, 0), (0, -1), (3, 1), (0, Int32.max)]

        for (start, length) in inputs {
            var offset = start
            var count = length
            var rect: MpvfxRect = MpvfxRect(x: 0, y: 0, w: 0, h: 0)
            let result = withDirectWriteText("ab", .mono(22)) { text in
                mpvfx_d2d_text_ranges(text, &offset, &count, &rect, 1)
            }

            XCTAssertEqual(result, invalidArgument)
        }
        XCTAssertEqual(mpvfx_d2d_text_ranges(nil, nil, nil, nil, 0), invalidArgument)
    }

    internal func testWordStopsRejectMissingInputAndOutputBuffers() {
        let invalidArgument = Int32(bitPattern: 0x80070057)
        var text: MpvfxText = MpvfxText(text: nil, length: 1, family: nil, size: 22, weight: 400, italic: 0)
        var stop = 0

        XCTAssertEqual(mpvfx_d2d_word_stops(&text, &stop), invalidArgument)
        XCTAssertEqual(mpvfx_d2d_word_stops(&text, nil), invalidArgument)
    }
}
#endif
