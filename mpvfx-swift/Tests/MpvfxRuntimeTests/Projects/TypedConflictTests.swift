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
// Issue #26, acceptance 3: the transaction store throws a typed conflict, and ProjectDocumentStore recognises a
// conflict by that type, never by the wording of a message.
import Foundation
import XCTest
@testable import MpvfxRuntime
import MpvfxShared

/// Fails every durable write of `.studio/project.json` with an ordinary error whose message reads like a conflict.
private final class ConflictWordedFailure: DurableWrite, @unchecked Sendable {
    private let base = TestDurableWrite()
    private let lock = NSLock()
    private var _armed = false
    var armed: Bool { get { lock.withLock { _armed } } set { lock.withLock { _armed = newValue } } }
    func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        if armed && path.hasSuffix("/" + NATIVE_PROJECT_DOCUMENT_PATH) {
            throw ProjectsError("Disk refused: target changed before commit")
        }
        try base.write(data, to: path, tempName: tempName, preserveMode: preserveMode, beforeRename: beforeRename)
    }
    func syncDirectory(_ path: String) throws { try base.syncDirectory(path) }
}

final class TypedConflictTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws { root = try makeMediaTempDir("mpvfx-conflict-") }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    private func kind(_ body: () throws -> Void) -> ProjectsError.Kind? {
        do { try body(); return nil } catch { return (error as? ProjectsError)?.kind }
    }

    func testAStaleTargetThrowsATypedConflict() throws {
        try Data("disk".utf8).write(to: URL(fileURLWithPath: PosixPath.join(root, "a.txt")))
        let s = store(root)
        let stale = DurableFileTransactionInput(id: "stale-target", files: [DurableFileTransactionChange(path: "a.txt", expectedBefore: "mine", after: "new")])
        XCTAssertEqual(kind { try s.commit(stale) }, .conflict)
        let absent = DurableFileTransactionInput(id: "expected-absent", files: [DurableFileTransactionChange(path: "a.txt", expectedBefore: nil, after: "new")])
        XCTAssertEqual(kind { try s.commit(absent) }, .conflict)
        XCTAssertEqual(try String(contentsOfFile: PosixPath.join(root, "a.txt"), encoding: .utf8), "disk")
    }

    func testAChangedMediaFileThrowsATypedConflict() throws {
        try Data("clip".utf8).write(to: URL(fileURLWithPath: PosixPath.join(root, "clip.png")))
        let wrongVersion = String(repeating: "0", count: 64)
        let input = DurableFileTransactionInput(id: "stale-move", files: [],
                                                moves: [ProjectFileMove(from: "clip.png", to: "moved.png", expectedVersion: wrongVersion)])
        XCTAssertEqual(kind { try store(root).commit(input) }, .conflict)
        XCTAssertTrue(FileManager.default.fileExists(atPath: PosixPath.join(root, "clip.png")))
    }

    func testOtherTransactionFailuresAreNotConflicts() {
        let escaping = DurableFileTransactionInput(id: "escaping", files: [DurableFileTransactionChange(path: "../x.txt", expectedBefore: nil, after: "x")])
        XCTAssertEqual(kind { try store(root).commit(escaping) }, .failure)
    }

    func testTheDocumentStoreMatchesConflictsByTypeNotByMessage() throws {
        let durableWrite = ConflictWordedFailure()
        let project = try ProjectDocumentStore.create(at: PosixPath.join(root, "p"), name: "P", durableWrite: durableWrite)
        var document = try ProjectDocuments.validate(project.savedContent)
        document.sequence.durationFrames = 300
        let edited = try serializeNativeProjectDocument(document)
        durableWrite.armed = true
        XCTAssertThrowsError(try project.save(edited)) { error in
            XCTAssertNil(error as? ProjectDocumentError, "a disk failure is not a save conflict: \(error)")
            XCTAssertEqual((error as? ProjectsError)?.message, "Disk refused: target changed before commit")
        }
    }
}
