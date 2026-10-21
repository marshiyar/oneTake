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
import Foundation
import XCTest
import MpvfxBackend
import MpvfxDesktopCore
import MpvfxRuntime
import MpvfxShared

/// Caption import and export through the production backend and its durable write (issue #81).
final class CaptionBackendTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "mpvfx-captions-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    func testImportSavesTheTrackExportWritesItAndABadFileChangesNothing() async throws {
        let b = RuntimeDesktopBackend(userData: root + "/userData", durableWrite: NativeDurableWrite())
        let project = try b.createProject(name: "Captions", directory: root + "/Captions")
        let srt = root + "/in.srt"
        try Data("\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\nworld\r\n\r\n2\r\n00:00:03.000 --> 00:00:04.000\r\nBye".utf8)
            .write(to: URL(fileURLWithPath: srt))
        let imported = try b.importCaptions(projectId: project.id, path: srt, content: project.content)
        XCTAssertEqual(imported.cueCount, 2)
        XCTAssertEqual(try b.reloadProject(id: project.id).content, imported.content, "the import is saved")

        let out = root + "/out.srt"
        XCTAssertEqual(try b.exportCaptions(projectId: project.id, path: out, content: imported.content), 2)
        let written = try String(contentsOfFile: out, encoding: .utf8)
        XCTAssertEqual(written, "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\nworld\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nBye\r\n\r\n")

        try Data("1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:01,500 --> 00:00:03,000\nB\n".utf8).write(to: URL(fileURLWithPath: srt))
        XCTAssertThrowsError(try b.importCaptions(projectId: project.id, path: srt, content: imported.content)) { error in
            XCTAssertTrue("\(error)".hasPrefix("Line 6: Caption cue overlaps the previous cue"), "\(error)")
        }
        XCTAssertEqual(try b.reloadProject(id: project.id).content, imported.content, "a refused file saves nothing")
        XCTAssertThrowsError(try NotImplementedBackend().importCaptions(projectId: project.id, path: srt, content: imported.content))
        try await b.close()
    }
}
