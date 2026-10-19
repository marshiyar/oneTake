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
// File moves inside a project: validation, version checks, recovery folder moves.
import Foundation
import XCTest
import MpvfxShared
@testable import MpvfxRuntime

final class FileMovesTests: XCTestCase {
    let roots = TempRoots()
    let bytes = Data([0, 255, 192, 128, 10, 13, 240])
    override func tearDown() { roots.cleanup() }

    func fixture() throws -> (root: String, input: DurableFileTransactionInput) {
        let root = try roots.make("media-moves-")
        try mkdirP(join(root, "media"))
        try writeBytes(join(root, "media/a.mp4"), bytes)
        try writeText(join(root, "index.html"), #"<video src="media/a.mp4">"#)
        return (root, DurableFileTransactionInput(
            id: "move-1",
            files: [.init(path: "index.html", expectedBefore: #"<video src="media/a.mp4">"#, after: #"<video src="media/b.mp4">"#)],
            history: .init(label: "Rename media", kind: .manual),
            moves: [.init(from: "media/a.mp4", to: "media/b.mp4", expectedVersion: try binaryFileVersion(root, "media/a.mp4")!)]))
    }

    func testKeepsBinaryBytesExactAcrossRenameRestartAndAtomicUndo() throws {
        let (root, input) = try fixture()
        let s = store(root)
        XCTAssertEqual(try s.commit(input).moves, input.moves)
        XCTAssertEqual(try readBytes(join(root, "media/b.mp4")), bytes)
        XCTAssertNil(try binaryFileVersion(root, "media/a.mp4"))
        let restarted = store(root)
        XCTAssertEqual(try restarted.recover()[0].action, .alreadyCommitted)
        let undone = try restarted.commit(DurableFileTransactionInput(
            id: "undo-1",
            files: input.files.map { .init(path: $0.path, expectedBefore: $0.after, after: $0.expectedBefore) },
            moves: input.moves!.map { .init(from: $0.to, to: $0.from, expectedVersion: $0.expectedVersion) },
            historyReplay: .init(entryId: "entry-1", direction: .undo)))
        XCTAssertEqual(undone.historyReplay, .init(entryId: "entry-1", direction: .undo))
        XCTAssertEqual(try readBytes(join(root, "media/a.mp4")), bytes)
        XCTAssertEqual(try readText(join(root, "index.html")), input.files[0].expectedBefore)
        XCTAssertEqual(try restarted.status("undo-1")?.receipt?.historyReplay, undone.historyReplay)
    }

    /// it.each(["afterPrepared", "afterMoveLink", "afterMove", "afterTargetWrite"])
    func testRecoversBothSourceNamesAndReferencesAfterInterruptionAtEachBoundary() throws {
        for boundary in ["afterPrepared", "afterMoveLink", "afterMove", "afterTargetWrite"] {
            let (root, input) = try fixture()
            let fail = { throw PowerLoss("power loss") }
            let interrupted = store(root,
                afterPrepared: boundary == "afterPrepared" ? { _ in try fail() } : nil,
                afterTargetWrite: boundary == "afterTargetWrite" ? { _, _ in try fail() } : nil,
                afterMoveLink: boundary == "afterMoveLink" ? { _, _ in try fail() } : nil,
                afterMove: boundary == "afterMove" ? { _, _ in try fail() } : nil)
            assertThrows(try interrupted.commit(input), "power loss")
            let restarted = store(root)
            XCTAssertEqual(try restarted.recover()[0].action, .rolledBack, boundary)
            XCTAssertEqual(try readBytes(join(root, "media/a.mp4")), bytes, boundary)
            XCTAssertNil(try binaryFileVersion(root, "media/b.mp4"), boundary)
            XCTAssertEqual(try readText(join(root, "index.html")), input.files[0].expectedBefore, boundary)
            XCTAssertEqual(try restarted.recover()[0].action, .alreadyRolledBack, boundary)
        }
    }

    func testRefusesADestinationCollisionWithoutWritingReferencesOrReplacingBytes() throws {
        let (root, input) = try fixture()
        try writeBytes(join(root, "media/b.mp4"), bytes)
        let s = store(root)
        assertThrows(try s.commit(input), "changed before commit")
        XCTAssertEqual(try readBytes(join(root, "media/b.mp4")), bytes)
        XCTAssertEqual(try s.listReceipts(), [])
    }

    func testDetectsDestinationCreationBetweenPreparationAndMoveWithoutClobberingIt() throws {
        let (root, input) = try fixture()
        let s = store(root, afterPrepared: { _ in try writeText(join(root, "media/b.mp4"), "external") })
        assertThrows(try s.commit(input), "changed before commit")
        XCTAssertEqual(try s.recover()[0].action, .corrupt)
        XCTAssertEqual(try readBytes(join(root, "media/a.mp4")), bytes)
        XCTAssertEqual(try readText(join(root, "media/b.mp4")), "external")
        XCTAssertEqual(try readText(join(root, "index.html")), input.files[0].expectedBefore)
    }

    func testValidatesAllRecoveryTargetsBeforeRollingBackAnyReference() throws {
        let (root, input) = try fixture()
        let s = store(root, afterTargetWrite: { _, _ in throw PowerLoss("power loss") })
        assertThrows(try s.commit(input), "power loss")
        try writeText(join(root, "media/b.mp4"), "outside edit")
        XCTAssertEqual(try s.recover()[0].action, .corrupt)
        XCTAssertEqual(try readText(join(root, "media/b.mp4")), "outside edit")
        XCTAssertEqual(try readText(join(root, "index.html")), input.files[0].after)
    }

    /// it.each(["afterPrepared", "afterMove"])
    func testDoesNotOverwriteReferenceEditsArrivingAtEachBoundary() throws {
        for boundary in ["afterPrepared", "afterMove"] {
            let (root, input) = try fixture()
            let edit = { try writeText(join(root, "index.html"), "external edit") }
            let s = store(root, afterPrepared: boundary == "afterPrepared" ? { _ in try edit() } : nil,
                          afterMove: boundary == "afterMove" ? { _, _ in try edit() } : nil)
            assertThrows(try s.commit(input), "changed before commit")
            XCTAssertEqual(try readText(join(root, "index.html")), "external edit", boundary)
            let rec = try s.recover()
            XCTAssertEqual(rec.count, 1)
            XCTAssertEqual(rec[0].action, .conflict, boundary)
            XCTAssertEqual(rec[0].conflicts, ["index.html"])
            XCTAssertEqual(rec[0].status.stateName, "ROLLED_BACK")
            XCTAssertEqual(try readText(join(root, "index.html")), "external edit", boundary)
            XCTAssertEqual(try readBytes(join(root, "media/a.mp4")), bytes, boundary)
            XCTAssertNil(try binaryFileVersion(root, "media/b.mp4"), boundary)
        }
    }

    func testArchivesAnUnreferencedFileWithoutRequiringATextTarget() throws {
        let (root, input) = try fixture()
        let s = store(root)
        var move = input.moves![0]
        move.to = ".hyperframes/deleted-media/delete-1/a.mp4"
        var archive = input
        archive.files = []; archive.moves = [move]
        XCTAssertEqual(try s.commit(archive).state, .committed)
        XCTAssertEqual(try readBytes(join(root, move.to)), bytes)
        XCTAssertEqual(try s.commit(archive).state, .committed)
    }

    /// it.each over unsafe targets. "/tmp/outside.mp4" is replaced by another absolute path
    /// ("/absolute/outside.mp4") under the no-outside-path rule; it is rejected before any filesystem access.
    func testRejectsUnsafeMoveTargets() throws {
        for to in ["../outside.mp4", ".hyperframes/studio-transactions/file.mp4", "/absolute/outside.mp4",
                   ".HyperFrames/studio-transactions/file.mp4", ".HYPERFRAMES/deleted-media/delete-1/a.mp4"] {
            let (root, input) = try fixture()
            var bad = input
            bad.moves![0].to = to
            assertThrows(try store(root).commit(bad), "Unsafe|Reserved")
        }
    }

    func testRefusesLinkedParentsOverlappingPathsAndChangedSourceBytes() throws {
        let (root, input) = try fixture()
        let s = store(root)
        try makeSymlink(join(root, "media"), at: join(root, "linked"))
        var linked = input; linked.moves![0].to = "linked/b.mp4"
        assertThrows(try s.commit(linked), "Unsafe")
        var overlap = input; overlap.moves![0].to = "index.html"
        assertThrows(try s.commit(overlap), "Duplicate")
        try writeBytes(join(root, "media/a.mp4"), Data([0, 255, 193, 128, 10, 13, 240]))
        assertThrows(try s.commit(input), "changed before commit")
        XCTAssertEqual(try s.listReceipts(), [])
    }
}
