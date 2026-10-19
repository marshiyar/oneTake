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

/// Export formats.
final class ExportFormatsTests: XCTestCase {
    func testDefinesEveryFormatTheStandaloneRenderRouteCanProduce() {
        XCTAssertEqual(SUPPORTED_EXPORT_FORMATS.map(\.rawValue), ["mp4", "webm", "mov"])
    }
    func testMapsEachFormatToItsExactExtensionAndMimeType() {
        for (format, ext, mime) in [("mp4", ".mp4", "video/mp4"), ("webm", ".webm", "video/webm"), ("mov", ".mov", "video/quicktime")] {
            let cap = exportFormatCapability(ExportFormat(rawValue: format)!)
            XCTAssertEqual(cap.extension, ext); XCTAssertEqual(cap.mimeType, mime)
            XCTAssertTrue(isExportFormat(.string(format)))
        }
    }
    func testDoesNotAdvertiseUnsupportedStandaloneOutputs() {
        for f in ["gif", "png-sequence", "avi", "mkv", "mxf", "mp3", "wav"] { XCTAssertFalse(isExportFormat(.string(f)), f) }
    }
    func testDocumentsProducerFormatsTheStandaloneRouteDoesNotExpose() {
        XCTAssertEqual(UNSUPPORTED_STANDALONE_EXPORT_FORMATS.map(\.0), ["gif", "png-sequence"])
        XCTAssertEqual(UNSUPPORTED_STANDALONE_EXPORT_FORMATS.map(\.1),
                       Array(repeating: "not exposed by the standalone Studio render route", count: 2))
    }
}
