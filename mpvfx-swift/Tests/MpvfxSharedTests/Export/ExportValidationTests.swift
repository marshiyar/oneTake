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

/// Export settings validation.
final class ExportValidationTests: XCTestCase {
    private func input(format: String = "mp4", quality: String = "standard", fps: Double = 30, scale: String = "auto",
                       w: Double = 1920, h: Double = 1080) -> ExportSettingsInput {
        .init(format: .string(format), quality: .string(quality), fps: .number(fps), scale: .string(scale), dimensions: dimsJSON(w, h))
    }
    func testAcceptsEveryCanonicalStandaloneFormat() {
        for f in ["mp4", "webm", "mov"] { XCTAssertEqual(validateExportSettings(input(format: f)), .init(ok: true, issues: [])) }
    }
    func testRejectsUnsupportedFields() {
        for i in [input(format: "gif"), input(quality: "lossless"), input(fps: 25), input(scale: "8k")] {
            let r = validateExportSettings(i)
            XCTAssertFalse(r.ok); XCTAssertGreaterThan(r.issues.count, 0)
        }
    }
    func testRejectsAlphaOutputWithASupersampledResolution() {
        XCTAssertFalse(validateExportSettings(input(format: "webm", scale: "4k")).ok)
    }
    func testRejectsAPresetThatIsNotAnIntegerUpscale() {
        XCTAssertFalse(validateExportSettings(input(scale: "1080p", w: 1280, h: 720)).ok)
    }
    func testRejectsOddWebMDimensions() {
        XCTAssertFalse(validateExportSettings(input(format: "webm", w: 1919, h: 1079)).ok)
    }
}
