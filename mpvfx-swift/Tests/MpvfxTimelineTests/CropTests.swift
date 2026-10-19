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
import MpvfxShared
@testable import MpvfxTimeline

final class CropTests: XCTestCase {
    func testCropIsStoredOnTheClipAndUndoes() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        XCTAssertNil(e.crop(clipId: "clip:a"))
        XCTAssertTrue(e.setCrop(clipId: "clip:a", NativeClipCrop(top: 10, right: 0, bottom: 5, left: 2)))
        XCTAssertEqual(e.crop(clipId: "clip:a"), NativeClipCrop(top: 10, right: 0, bottom: 5, left: 2))
        XCTAssertFalse(e.setCrop(clipId: "clip:a", NativeClipCrop(top: 10, right: 0, bottom: 5, left: 2)))   // no change, no undo step
        XCTAssertTrue(e.undo())
        XCTAssertNil(e.crop(clipId: "clip:a"))
        XCTAssertTrue(e.redo())
        XCTAssertTrue(e.setCrop(clipId: "clip:a", NativeClipCrop()))   // all-zero clears
        XCTAssertNil(e.crop(clipId: "clip:a"))
    }
}
