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
@testable import MpvfxRuntime

/// Export refuses template placeholders that have no media, naming their numbers (#332 A4).
final class ExportPlaceholderTests: XCTestCase {
    func project(_ placeholders: [Int?]) throws -> NativeProjectDocument {
        let clips = placeholders.enumerated().map { i, n in
            let marker = n.map { #","placeholder":{"v":1,"index":\#($0)}"# } ?? ""
            return #"{"id":"c\#(i)","assetId":"a","startFrame":\#(i * 10),"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]\#(marker)}"#
        }.joined(separator: ",")
        return try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":64,"background":"#000000"},
         "assets":[{"id":"a","kind":"image","name":"a","source":"a.bmp","durationFrames":100}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"v","kind":"video","clips":[\#(clips)]}]}}
        """#))
    }

    func testUnfilledPlaceholdersAreRefusedByNumber() throws {
        let plan = planExport(try project([3, nil, 1]), settings: ExportSettings())
        XCTAssertFalse(plan.canStart)
        XCTAssertEqual(plan.issues, ["Placeholders 1, 3 have no media yet. Fill them with media, or unmark them, before exporting."])
    }

    func testOnePlaceholderReadsInTheSingular() throws {
        let plan = planExport(try project([nil, 2]), settings: ExportSettings())
        XCTAssertEqual(plan.issues, ["Placeholder 2 has no media yet. Fill it with media, or unmark it, before exporting."])
    }

    func testAProjectWithoutPlaceholdersPlansAsBefore() throws {
        XCTAssertTrue(planExport(try project([nil, nil]), settings: ExportSettings()).canStart)
    }

    func testStartExportRefusesBeforeAnythingIsWritten() throws {
        let dir = NSTemporaryDirectory() + "placeholder-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertThrowsError(try startExport(project: try project([1]), projectDir: dir, outputPath: "\(dir)/out.mp4", settings: ExportSettings())) {
            XCTAssertEqual(($0 as? ExportStartError)?.issues.first?.hasPrefix("Placeholder 1 has no media yet"), true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/out.mp4"))
    }
}
