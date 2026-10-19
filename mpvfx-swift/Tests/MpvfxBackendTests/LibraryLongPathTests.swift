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
// Library projects live deep in the library folder: a project's transaction journal
// (<library>/Projects/<uuid>/.hyperframes/studio-transactions/<sha256>.json) passes Windows' MAX_PATH from a parent
// folder of about 100 characters. Creating, opening and saving such a project goes through NativeDurableWrite.
import Foundation
import XCTest
import MpvfxBackend
import MpvfxDesktopCore
@testable import MpvfxRuntime
import MpvfxShared

final class LibraryLongPathTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws { root = try makeTemporaryDirectory(NSTemporaryDirectory() + "mpvfx-longpath-") }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    func testALibraryProjectWhoseJournalPathPassesMaxPathIsCreatedOpenedAndSaved() async throws {
        let b = RuntimeDesktopBackend(userData: root + "/userData", durableWrite: NativeDurableWrite())
        let libraries = try XCTUnwrap(b.libraries)
        // The journal path is the folder plus 166 characters; a 110-character folder puts it past 260 on every runner.
        let folder = root + String(repeating: "/Footage of the shoot", count: max(1, (110 - root.utf16.count) / 21 + 1))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let libraryId = try await libraries.create(root: folder + "/Lib.mpvfxlibrary")
        let views = try await b.libraryViews()
        let eventId = try XCTUnwrap(views.first { $0.id == libraryId }?.events.first?.id)
        let projectId = try await libraries.createProject(libraryId: libraryId, eventId: eventId, name: "Cut")
        let after = try await b.libraryViews()
        let directory = try XCTUnwrap(after.first?.projects.first { $0.id == projectId }?.directory)
        let journal = directory + "/.hyperframes/studio-transactions/" + String(repeating: "0", count: 64) + ".json"
        XCTAssertGreaterThan(journal.utf16.count, 260, "the journal path passes MAX_PATH")

        let project = try b.openProject(path: directory)
        let first = try withDuration(project.content, 240), second = try withDuration(project.content, 360)
        try b.saveProject(id: project.id, content: first)
        XCTAssertEqual(try String(contentsOfFile: directory + "/" + NATIVE_PROJECT_DOCUMENT_PATH, encoding: .utf8), first)
        try b.saveProject(id: project.id, content: second)
        XCTAssertEqual(try String(contentsOfFile: directory + "/" + NATIVE_PROJECT_DOCUMENT_PATH, encoding: .utf8), second)
        try await b.close()
    }

    private func withDuration(_ content: String, _ frames: Double) throws -> String {
        var document = try parseNativeProjectDocument(try NativeJSONValue.parse(content))
        document.sequence.durationFrames = frames
        return try serializeNativeProjectDocument(document)
    }
}
