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
// Media import policy: file validation.
// MediaImportFile stands for a picked file, with size = UTF-8 byte length of
// contents and the type string as given (all test types are lowercase printable ASCII,
// left unchanged).
import XCTest
@testable import MpvfxShared

private func file(_ name: String, _ type: String = "", _ contents: String = "x") -> MediaImportFile {
    MediaImportFile(name: name, type: type, size: Double(contents.utf8.count))
}
/// vitest toMatchObject({ accepted: true, kind }).
private func assertAccepted(_ i: MediaImportInspection, _ kind: MediaImportKind, file: StaticString = #filePath, line: UInt = #line) {
    guard case .accepted(let k, _, _) = i else { return XCTFail("expected accepted, got \(i)", file: file, line: line) }
    XCTAssertEqual(k, kind, file: file, line: line)
}

final class MediaImportPolicyValidationTests: XCTestCase {
    func testAcceptsEachSupportedFileAsItsKind() {
        let cases: [(String, String, MediaImportKind)] = [
            ("clip.mp4", "video/mp4", .video), ("camera.M4V", "video/mp4", .video), ("voice.aac", "audio/aac", .audio),
            ("logo.avif", "image/avif", .image), ("display.woff2", "font/woff2", .font), ("grade.cube", "text/plain", .lut),
        ]
        for (name, type, kind) in cases { assertAccepted(inspectMediaImportFile(file(name, type)), kind) }
    }

    func testAcceptsEmptyOrGenericOsMimeTypeWhenExtensionIsSupported() {
        assertAccepted(inspectMediaImportFile(file("camera.mov")), .video)
        assertAccepted(inspectMediaImportFile(file("voice.aac", "application/octet-stream")), .audio)
    }

    func testRejectsEmptyFilesBeforeUpload() {
        XCTAssertEqual(inspectMediaImportFile(file("empty.png", "image/png", "")), .rejected(reason: .emptyFile))
    }

    func testRejectsUnsupportedAndExtensionlessFiles() {
        XCTAssertEqual(inspectMediaImportFile(file("notes.pdf", "application/pdf")), .rejected(reason: .unsupportedExtension))
        XCTAssertEqual(inspectMediaImportFile(file("camera", "video/mp4")), .rejected(reason: .unsupportedExtension))
    }

    func testRejectsExplicitCrossKindMimeMismatchButToleratesAliases() {
        XCTAssertEqual(inspectMediaImportFile(file("poster.png", "video/mp4")), .rejected(reason: .mimeTypeMismatch))
        assertAccepted(inspectMediaImportFile(file("voice.wav", "audio/x-wav")), .audio)
        assertAccepted(inspectMediaImportFile(file("movie.m4v", "video/x-m4v")), .video)
    }

    func testPartitionsMixedDropWithoutChangingAcceptedOrder() {
        let files = [
            file("one.mov", "video/quicktime"), file("readme.txt", "text/plain"), file("two.aac", "audio/aac"),
            file("empty.jpg", "image/jpeg", ""), file("three.webp", "image/webp"),
        ]
        let result = partitionMediaImportFiles(files)
        XCTAssertEqual(result.accepted.map(\.file.name), ["one.mov", "two.aac", "three.webp"])
        XCTAssertEqual(result.rejected.count, 2)
        XCTAssertEqual(result.rejected.map(\.file), [files[1], files[3]])
        XCTAssertEqual(result.rejected.map(\.reason), [.unsupportedExtension, .emptyFile])
    }

    func testAcceptsCommonLegacyFontMimeAliases() {
        for (name, type) in [("display.ttf", "application/x-font-ttf"), ("display.otf", "application/x-font-opentype"),
                             ("display.woff", "application/x-font-woff")] {
            assertAccepted(inspectMediaImportFile(file(name, type)), .font)
        }
    }
}
