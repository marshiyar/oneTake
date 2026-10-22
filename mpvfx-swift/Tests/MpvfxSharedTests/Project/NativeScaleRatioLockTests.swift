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

final class NativeScaleRatioLockTests: XCTestCase {
    let engine = KeyframeEngineStandIn()

    func testAbsentLockLeavesOlderProjectsUnchanged() throws {
        let before = try serializeNativeProjectDocument(validNativeDocument(), engine: engine)
        let document = try parseNativeProjectDocument(J(before), engine: engine)
        XCTAssertNil(document.sequence.tracks[0].clips[0].scaleRatioLocked)
        XCTAssertFalse(before.contains("scaleRatioLocked"))
        XCTAssertEqual(try serializeNativeProjectDocument(document, engine: engine), before)
    }

    func testBooleanLockRoundTrips() throws {
        for on in [true, false] {
            var input = validNativeDocument()
            input["sequence"]?["tracks"]?[0]?["clips"]?[0]?["scaleRatioLocked"] = .bool(on)
            let saved = try serializeNativeProjectDocument(input, engine: engine)
            XCTAssertEqual(try parseNativeProjectDocument(J(saved), engine: engine).sequence.tracks[0].clips[0].scaleRatioLocked, on)
            XCTAssertEqual(try serializeNativeProjectDocument(J(saved), engine: engine), saved)
        }
    }

    func testMalformedLocksHaveATypedIssueAtTheClipField() {
        for bad in [J("1"), J("null"), J(#""true""#), J("{}"), J("[]")] {
            var input = validNativeDocument()
            input["sequence"]?["tracks"]?[0]?["clips"]?[0]?["scaleRatioLocked"] = bad
            XCTAssertThrowsError(try parseNativeProjectDocument(input, engine: engine)) { error in
                guard let error = error as? NativeProjectDocumentValidationError else { return XCTFail("\(error)") }
                XCTAssertEqual(error.issues.map(\.code), [.invalidClip])
                XCTAssertEqual(error.issues.map(\.path), ["sequence.tracks[0].clips[0].scaleRatioLocked"])
            }
        }
    }
}
