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
// Issue #26, acceptance 1: one starter document, written through the transaction store by every path that creates
// a project (the standalone project, a library project, `ProjectDocumentStore.create`).
import Foundation
import XCTest
@testable import MpvfxRuntime
import MpvfxShared

/// Records every path the transaction store writes durably, then writes like `TestDurableWrite`.
final class RecordingDurableWrite: DurableWrite, @unchecked Sendable {
    private let base = TestDurableWrite()
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.withLock { _paths } }
    func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        lock.withLock { _paths.append(path) }
        try base.write(data, to: path, tempName: tempName, preserveMode: preserveMode, beforeRename: beforeRename)
    }
    func syncDirectory(_ path: String) throws { try base.syncDirectory(path) }
}

final class StarterDocumentTests: XCTestCase {
    private var root = ""
    private var realRoot = ""
    override func setUpWithError() throws {
        // The root is reached through a symlink, as macOS's temporary folder /var is /private/var: the store writes
        // to realpath(3) paths, so a test double that compares paths without it misses its target on every Mac.
        realRoot = try makeMediaTempDir("mpvfx-starter-")
        root = realRoot + "-link"
        try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: realRoot)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: realRoot)
        super.tearDown()
    }

    private func documentText(_ projectDir: String) throws -> String {
        try String(contentsOfFile: PosixPath.join(projectDir, NATIVE_PROJECT_DOCUMENT_PATH), encoding: .utf8)
    }

    /// Creates the standalone project and a library project named "Main"; returns both documents and the library project id.
    private func createBoth(_ durableWrite: DurableWrite) async throws -> (standalone: String, library: String, projectId: String) {
        _ = try ensureStandaloneProject(PosixPath.join(root, "projects"), durableWrite: durableWrite)
        let library = LibraryService(userData: PosixPath.join(root, "settings"), durableWrite: durableWrite)
        let libraryId = try await library.create(PosixPath.join(root, "Film.mpvfxlibrary"))
        let views = await library.views()
        let eventId = try XCTUnwrap(views.first?.events.first?.id)
        let projectId = try await library.createProject(libraryId, eventId, "Main")
        let entry = try XCTUnwrap(library.resolveProject(projectId))
        let libraryDocument = try documentText(entry.dir)
        await library.close()
        return (try documentText(PosixPath.join(root, "projects", STANDALONE_PROJECT_ID)), libraryDocument, projectId)
    }

    func testStandaloneAndLibraryProjectsStartFromTheSameDocumentBytes() async throws {
        let created = try await createBoth(TestDurableWrite())
        XCTAssertEqual(created.standalone, try ProjectDocuments.starterDocument(id: STANDALONE_PROJECT_ID, name: "Main"))
        XCTAssertEqual(created.library, try ProjectDocuments.starterDocument(id: created.projectId, name: "Main"))
        // Both projects are named "Main", so the two files differ in the project id and nowhere else.
        XCTAssertEqual(created.standalone.replacingOccurrences(of: "\"\(STANDALONE_PROJECT_ID)\"", with: "\"<id>\""),
                       created.library.replacingOccurrences(of: "\"\(created.projectId)\"", with: "\"<id>\""))
        let standalone = try ProjectDocuments.validate(created.standalone), library = try ProjectDocuments.validate(created.library)
        XCTAssertEqual([standalone.canvas.background, library.canvas.background], ["#000000", "#000000"])
        XCTAssertEqual([standalone.sequence.id, library.sequence.id], ["sequence:main", "sequence:main"])
    }

    func testTheStoreCreatesTheSameStarterDocument() throws {
        let store = try ProjectDocumentStore.create(at: PosixPath.join(root, "p"), name: "Main", id: "project-1", durableWrite: TestDurableWrite())
        XCTAssertEqual(try documentText(store.directory), try ProjectDocuments.starterDocument(id: "project-1", name: "Main"))
    }

    func testStarterDocumentsAreWrittenThroughTheDurableTransactionStore() async throws {
        let recorder = RecordingDurableWrite()
        let created = try await createBoth(recorder)
        let standaloneDir = PosixPath.join(root, "projects", STANDALONE_PROJECT_ID)
        let libraryDir = PosixPath.join(root, "Film.mpvfxlibrary/Projects", created.projectId)
        let documents = recorder.paths.filter { $0.hasSuffix("/" + NATIVE_PROJECT_DOCUMENT_PATH) }
        XCTAssertEqual(documents.map(PosixPath.dirname).map(PosixPath.dirname).map(PosixPath.basename),
                       [STANDALONE_PROJECT_ID, created.projectId], "one durable write of each starter document")
        // The create transactions are acknowledged: no journal is left in either project.
        XCTAssertEqual(try journals(standaloneDir), [])
        XCTAssertEqual(try journals(libraryDir), [])
    }

    private func journals(_ projectDir: String) throws -> [String] {
        let dir = PosixPath.join(projectDir, JOURNAL_PARENT + "/studio-transactions")
        guard FileManager.default.fileExists(atPath: dir) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }
    }

    func testAStandaloneDocumentCreatedMeanwhileIsKept() throws {
        // Another process created the document between the existence check and the commit: the commit's
        // "absent before" check refuses, and the existing document stays as it is.
        let projects = PosixPath.join(root, "projects"), dir = PosixPath.join(projects, STANDALONE_PROJECT_ID)
        let racing = RacingDurableWrite(document: PosixPath.join(dir, NATIVE_PROJECT_DOCUMENT_PATH), text: "{\"theirs\":true}")
        XCTAssertEqual(try ensureStandaloneProject(projects, durableWrite: racing), EnsureStandaloneProjectResult(created: false, id: STANDALONE_PROJECT_ID))
        XCTAssertTrue(racing.raced, "the other creator's write happened during the commit")
        XCTAssertEqual(try documentText(dir), "{\"theirs\":true}")
    }

    func testAnIdenticalStandaloneDocumentCreatedMeanwhileIsKept() throws {
        // Another creator wrote the same starter bytes during the commit: rolling back this refused create must not
        // remove them (recovery cannot tell identical bytes from its own write).
        let projects = PosixPath.join(root, "projects"), dir = PosixPath.join(projects, STANDALONE_PROJECT_ID)
        let starter = try createStandaloneProjectDocument()
        let racing = RacingDurableWrite(document: PosixPath.join(dir, NATIVE_PROJECT_DOCUMENT_PATH), text: starter)
        _ = try ensureStandaloneProject(projects, durableWrite: racing)
        XCTAssertTrue(racing.raced, "the other creator's write happened during the commit")
        XCTAssertEqual(try documentText(dir), starter)
        XCTAssertEqual(try ProjectDocumentStore.open(dir, durableWrite: TestDurableWrite()).savedContent, starter)
    }

    func testAStandaloneCreationInterruptedByACrashIsRedoneAndOpens() throws {
        // Power is lost after the document was renamed into place but before its journal says COMMITTED.
        let projects = PosixPath.join(root, "projects"), dir = PosixPath.join(projects, STANDALONE_PROJECT_ID)
        XCTAssertThrowsError(try ensureStandaloneProject(projects, durableWrite: CrashBeforeCommitted()))
        XCTAssertEqual(try documentText(dir), try createStandaloneProjectDocument(), "the crash left the document in place")
        // The next launch rolls the interrupted creation back and creates the project again, so opening it does
        // not roll the document away.
        XCTAssertEqual(try ensureStandaloneProject(projects, durableWrite: TestDurableWrite()),
                       EnsureStandaloneProjectResult(created: true, id: STANDALONE_PROJECT_ID))
        let opened = try ProjectDocumentStore.open(dir, durableWrite: TestDurableWrite())
        XCTAssertEqual(opened.savedContent, try createStandaloneProjectDocument())
        XCTAssertEqual(try documentText(dir), try createStandaloneProjectDocument())
    }
}

/// Throws on the second journal write (the COMMITTED one) of a transaction, as a power loss would.
final class CrashBeforeCommitted: DurableWrite, @unchecked Sendable {
    private let base = TestDurableWrite()
    private let lock = NSLock()
    private var journalWrites = 0
    func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        let crash = path.contains("/studio-transactions/") && lock.withLock { journalWrites += 1; return journalWrites == 2 }
        if crash { throw PowerLoss("before COMMITTED") }
        try base.write(data, to: path, tempName: tempName, preserveMode: preserveMode, beforeRename: beforeRename)
    }
    func syncDirectory(_ path: String) throws { try base.syncDirectory(path) }
}

/// Writes `text` to `document` just before the first durable write of that file reaches its rename, as a second
/// process creating the same project would. Paths are compared as realpath(3) of their folders: the store writes
/// resolved paths, which differ from the test's own on macOS (/var is /private/var).
final class RacingDurableWrite: DurableWrite, @unchecked Sendable {
    private let base = TestDurableWrite()
    private let document: String, text: String
    private let lock = NSLock()
    private var _raced = false
    /// Whether the racing write happened; a test that relies on the race asserts it.
    var raced: Bool { lock.withLock { _raced } }
    init(document: String, text: String) { self.document = document; self.text = text }
    private func isDocument(_ path: String) -> Bool {
        guard PosixPath.basename(path) == PosixPath.basename(document),
              let parent = try? ProjectFS.realpath(PosixPath.dirname(path)),
              let documentParent = try? ProjectFS.realpath(PosixPath.dirname(document)) else { return false }
        return parent == documentParent
    }
    func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        let race = isDocument(path) && lock.withLock { defer { _raced = true }; return !_raced }
        try base.write(data, to: path, tempName: tempName, preserveMode: preserveMode) {
            if race { try Data(text.utf8).write(to: URL(fileURLWithPath: document)) }
            try beforeRename()
        }
    }
    func syncDirectory(_ path: String) throws { try base.syncDirectory(path) }
}
