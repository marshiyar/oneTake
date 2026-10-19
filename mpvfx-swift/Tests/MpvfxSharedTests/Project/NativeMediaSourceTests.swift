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
// Native media sources.
import XCTest
@testable import MpvfxShared

final class NativeMediaSourceTests: XCTestCase {
    func testRemovesEditorTransportWithoutProjectIdOrURLEncoding() {
        XCTAssertEqual(nativeMediaSource("mpvfx://editor/api/projects/demo/preview/assets/clip%20one.mov?revision=3", projectId: "demo"), "assets/clip one.mov")
    }
    func testRetainsPlainFilenamesIncludingLiteralPercentSigns() {
        XCTAssertEqual(nativeMediaSource("./assets/100% final.mov", projectId: "demo"), "assets/100% final.mov")
    }
    func testNormalizesPathAliasesWithoutFoldingCaseOrDecoding() {
        XCTAssertEqual(nativeMediaSource("./assets//./camera.mov", projectId: "demo"), "assets/camera.mov")
        XCTAssertEqual(nativeMediaSource("assets\\camera.mov", projectId: "demo"), "assets/camera.mov")
        XCTAssertEqual(nativeMediaSource("assets/Camera%20A.mov", projectId: "demo"), "assets/Camera%20A.mov")
        XCTAssertEqual(nativeMediaSource("assets/Camera A.mov", projectId: "demo"), "assets/Camera A.mov")
    }
    func testRejectsNonFilePaths() {
        for source in [".", "././", "assets/", "assets/.", "./../clip.mov"] {
            XCTAssertNil(nativeMediaSource(source, projectId: "demo"), source)
        }
    }
    func testRejectsSourcesOutsideOwningProject() {
        for source in ["../outside.mov", "/outside.mov", "C:\\outside.mov", "https://example.com/clip.mov",
                       "mpvfx://editor/api/projects/other/preview/clip.mov",
                       "mpvfx://editor/api/projects/demo/preview/%2e%2e/outside.mov"] {
            XCTAssertNil(nativeMediaSource(source, projectId: "demo"), source)
        }
    }
}
