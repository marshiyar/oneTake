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

/// Export file size labels and estimates.
final class ExportFileSizeTests: XCTestCase {
    func testFormatsBytes() {
        let cases: [(Double, String)] = [(0, "0 B"), (999, "999 B"), (1024, "1 KB"), (1536, "1.5 KB"),
                                         (pow(1024, 2), "1 MB"), (2.5 * pow(1024, 3), "2.5 GB")]
        for (b, s) in cases { XCTAssertEqual(formatExportFileSize(b), s, "\(b)") }
    }
    func testDoesNotDisplayInvalidByteCounts() {
        for b in [-1, Double.nan, .infinity] { XCTAssertEqual(formatExportFileSize(b), "Unknown size") }
    }
}
