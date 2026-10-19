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
// Media import policy: formats and MIME types.
import XCTest
@testable import MpvfxShared

private let EXPECTED_FORMATS: KeyValuePairs<MediaImportKind, [String]> = [
    .video: ["mp4", "m4v", "mov", "webm"],
    .audio: ["mp3", "wav", "ogg", "m4a", "aac"],
    .image: ["jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "ico"],
    .font: ["woff", "woff2", "ttf", "ttc", "otf", "eot"],
    .lut: ["cube"],
]
private func expected(_ k: MediaImportKind) -> [String] { EXPECTED_FORMATS.first { $0.key == k }!.value }

final class MediaImportPolicyFormatsTests: XCTestCase {
    func testListsEverySupportedVideoContainer() { XCTAssertEqual(supportedMediaImportExtensions(.video), expected(.video)) }
    func testListsEverySupportedAudioContainer() { XCTAssertEqual(supportedMediaImportExtensions(.audio), expected(.audio)) }
    func testListsEverySupportedStillImageFormat() { XCTAssertEqual(supportedMediaImportExtensions(.image), expected(.image)) }

    func testKeepsFontAndLutExplicitWithoutTreatingThemAsTimelineMedia() {
        XCTAssertEqual(supportedMediaImportExtensions(.font), expected(.font))
        XCTAssertEqual(supportedMediaImportExtensions(.lut), expected(.lut))
        XCTAssertFalse(isImportableMediaPath("assets/fonts/title.woff2"))
        XCTAssertFalse(isImportableMediaPath("assets/luts/cinema.cube"))
    }

    /// it.each over every (kind, extension) pair.
    func testClassifiesEachExtensionCaseInsensitivelyInNestedPaths() {
        var cases = 0
        for (kind, extensions) in EXPECTED_FORMATS {
            for ext in extensions {
                XCTAssertEqual(classifyMediaImportPath("nested/My Asset.\(ext.uppercased())"), kind, "\(kind)/\(ext)")
                cases += 1
            }
        }
        XCTAssertEqual(cases, 24)
    }

    func testClassifiesLiteralFilenamesByFinalExtensionWithoutStrippingQueryOrHash() {
        XCTAssertEqual(classifyMediaImportPath("assets/clip?v=2#preview.M4V"), .video)
        XCTAssertEqual(classifyMediaImportPath("assets/voice#take-2.AAC"), .audio)
        XCTAssertEqual(classifyMediaImportPath("assets/poster?rev=3.AVIF"), .image)
        XCTAssertNil(classifyMediaImportPath("assets/clip.M4V?v=2#preview"))
        XCTAssertNil(classifyMediaImportPath("assets/voice.AAC#take-2"))
        XCTAssertNil(classifyMediaImportPath("assets/poster.AVIF?rev=3"))
    }

    func testDoesNotTurnProjectCodeArchiveFilesIntoMediaImports() {
        for path in ["index.html", "script.js", "styles.css", "project.json", "notes.md", "archive.zip", "installer.exe", "no-extension"] {
            XCTAssertNil(classifyMediaImportPath(path), path)
            XCTAssertFalse(isImportableMediaPath(path), path)
        }
    }
}
