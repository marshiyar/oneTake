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
// Durable file transactions: commits, conflicts, journals and recovery.
import Foundation
import XCTest
import MpvfxShared
@testable import MpvfxRuntime

final class FileTransactionTests: XCTestCase {
    let roots = TempRoots()
    override func tearDown() { roots.cleanup() }

    func projectRoot() throws -> String {
        let root = try roots.make("studio-file-transaction-")
        try mkdirP(join(root, "src"))
        try writeText(join(root, "src/index.html"), "before-html")
        try writeText(join(root, "project.json"), "before-project")
        return root
    }

    func transaction(_ id: String = "tx-1") -> DurableFileTransactionInput {
        DurableFileTransactionInput(id: id, files: [
            .init(path: "src/index.html", expectedBefore: "before-html", after: "after-html"),
            .init(path: "project.json", expectedBefore: "before-project", after: "after-project"),
        ])
    }
    func crash(_ m: String) -> PowerLoss { PowerLoss(m) }

    func testValidatesEveryExpectedBeforeValueBeforeMutatingAnyTarget() throws {
        let root = try projectRoot()
        try writeText(join(root, "project.json"), "external-change")
        let s = store(root)
        assertThrows(try s.commit(transaction()), #"project\.json.*changed"#, caseInsensitive: true)
        XCTAssertEqual(try readText(join(root, "src/index.html")), "before-html")
        XCTAssertEqual(try readText(join(root, "project.json")), "external-change")
        XCTAssertEqual(try s.listReceipts(), [])
    }

    /// Rejected target paths; "/absolute/outside" stands for any absolute path
    /// (no-outside-path rule; rejected before any filesystem access).
    func testRejectsUnsafeTransactionTargetsWithoutTouchingProjectFiles() throws {
        for path in ["../outside", "/absolute/outside", ".hyperframes/recovery.json"] {
            let root = try projectRoot()
            let s = store(root)
            var input = transaction()
            input.files[0].path = path
            assertThrows(try s.commit(input), "unsafe|reserved|relative", caseInsensitive: true)
            XCTAssertEqual(try readText(join(root, "src/index.html")), "before-html")
            XCTAssertEqual(try s.listReceipts(), [])
        }
    }

    func testWritesAPreparedJournalBeforeTheFirstTargetReplacement() throws {
        let root = try projectRoot()
        var calls = 0
        var s: DurableFileTransactionStore!
        s = store(root, afterPrepared: { receipt in
            calls += 1
            XCTAssertEqual(receipt.state, .prepared)
            XCTAssertEqual(try readText(join(root, "src/index.html")), "before-html")
            XCTAssertEqual(try s.status("tx-1")?.stateName, "PREPARED")
        })
        try s.commit(transaction())
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try s.status("tx-1")?.stateName, "COMMITTED")
        XCTAssertEqual(try readText(join(root, "src/index.html")), "after-html")
        XCTAssertEqual(try readText(join(root, "project.json")), "after-project")
    }

    func testRecoversAPartiallyAppliedPreparedTransactionToExactBeforeBytes() throws {
        let root = try projectRoot()
        let s = store(root, afterTargetWrite: { i, _ in if i == 0 { throw PowerLoss("simulated crash") } })
        assertThrows(try s.commit(transaction()), "simulated crash")
        // Files are sorted with localeCompare: project.json is index 0.
        XCTAssertEqual(try readText(join(root, "src/index.html")), "before-html")
        XCTAssertEqual(try readText(join(root, "project.json")), "after-project")
        let recovery = try store(root).recover()
        XCTAssertEqual(recovery.map { [$0.status.id, $0.action.rawValue, $0.status.stateName] }, [["tx-1", "rolled-back", "ROLLED_BACK"]])
        XCTAssertEqual(try readText(join(root, "src/index.html")), "before-html")
        XCTAssertEqual(try readText(join(root, "project.json")), "before-project")
    }

    func testPreservesAnExternalEditWhenRecoveringAnInterruptedTransaction() throws {
        let root = try projectRoot()
        let s = store(root, afterTargetWrite: { _, _ in throw PowerLoss("interrupted") })
        assertThrows(try s.commit(transaction()), "interrupted")
        try writeText(join(root, "src/index.html"), "external work")
        let first = try s.recover()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].status.id, "tx-1"); XCTAssertEqual(first[0].action, .conflict)
        XCTAssertEqual(first[0].status.stateName, "ROLLED_BACK"); XCTAssertEqual(first[0].conflicts, ["src/index.html"])
        XCTAssertEqual(try readText(join(root, "src/index.html")), "external work")
        XCTAssertEqual(try readText(join(root, "project.json")), "before-project")
        let second = try s.recover()
        XCTAssertEqual(second.map { [$0.status.id, $0.action.rawValue] }, [["tx-1", "already-rolled-back"]])
        XCTAssertEqual(try s.listPending(), [])
    }

    func testTreatsCaseVariantsAsTheReservedJournalFolder() throws {
        for path in [".HyperFrames/studio-transactions/x.json", ".HYPERFRAMES/notes.txt"] {
            let root = try projectRoot()
            assertThrows(try store(root).commit(DurableFileTransactionInput(id: "forge", files: [.init(path: path, expectedBefore: nil, after: "{}")])),
                         "Reserved transaction target")
        }
    }

    func testRemovesTemporaryFilesACrashLeftBehindDuringRecovery() throws {
        let root = try projectRoot()
        let s = store(root, afterTargetWrite: { _, _ in throw PowerLoss("interrupted") })
        assertThrows(try s.commit(transaction()), "interrupted")
        let strayTarget = join(root, "src", ".0f6a3c1e-1d2b-4c3d-8e9f-0a1b2c3d4e5f.studio-transaction.tmp")
        let strayJournal = join(root, ".hyperframes/studio-transactions", ".1f6a3c1e-1d2b-4c3d-8e9f-0a1b2c3d4e5f.studio-transaction.tmp")
        let unrelated = join(root, "src", "notes.tmp")
        try writeText(strayTarget, "half"); try writeText(strayJournal, "half"); try writeText(unrelated, "keep")
        _ = try s.recover()
        XCTAssertTrue(isENOENT { try readBytes(strayTarget) })
        XCTAssertTrue(isENOENT { try readBytes(strayJournal) })
        XCTAssertEqual(try readText(unrelated), "keep")
    }

    func testPrunesSettledJournalsOnceTheyAreOldEnoughToBeUseless() throws {
        let root = try projectRoot()
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: jsDateParseISO("2026-01-01T00:00:00.000Z") / 1000) }
        let clock = Clock()
        let now = { clock.now }
        try store(root, now: now).commit(transaction("committed"))
        let crashing = store(root, afterTargetWrite: { _, _ in throw PowerLoss("interrupted") }, now: now)
        assertThrows(try crashing.commit(DurableFileTransactionInput(id: "rolled", files: [.init(path: "src/index.html", expectedBefore: "after-html", after: "x")])),
                     "interrupted")
        let s = store(root, now: now)
        _ = try s.recover()
        XCTAssertEqual(try s.listReceipts().map(\.stateName).sorted(), ["COMMITTED", "ROLLED_BACK"])
        clock.now = Date(timeIntervalSince1970: jsDateParseISO("2026-01-09T00:00:00.000Z") / 1000)
        _ = try s.recover()
        XCTAssertEqual(try s.listReceipts().map(\.id), ["committed"])
        clock.now = Date(timeIntervalSince1970: jsDateParseISO("2026-02-01T00:00:00.000Z") / 1000)
        _ = try s.recover()
        XCTAssertEqual(try s.listReceipts(), [])
    }

    func testPreservesLaterEditsAndDeletionsWhenRecoveringACommittedReceipt() throws {
        let root = try projectRoot()
        let s = store(root)
        try s.commit(transaction())
        try writeText(join(root, "src/index.html"), "later edit")
        try rmrf(join(root, "project.json"))
        let recovery = try s.recover()
        XCTAssertEqual(recovery.map { [$0.status.id, $0.action.rawValue, $0.status.stateName] }, [["tx-1", "already-committed", "COMMITTED"]])
        XCTAssertEqual(try readText(join(root, "src/index.html")), "later edit")
        XCTAssertTrue(isENOENT { try readBytes(join(root, "project.json")) })
    }

    func testSupportsExactCreationAndDeletionDuringCommitAndRecovery() throws {
        let root = try projectRoot()
        try writeText(join(root, "delete-me.txt"), "old")
        let s = store(root)
        try s.commit(DurableFileTransactionInput(id: "create-delete", files: [
            .init(path: "created.txt", expectedBefore: nil, after: "new"), .init(path: "delete-me.txt", expectedBefore: "old", after: nil)]))
        XCTAssertEqual(try readText(join(root, "created.txt")), "new")
        XCTAssertTrue(isENOENT { try readBytes(join(root, "delete-me.txt")) })
        try writeText(join(root, "delete-me.txt"), "partial")
        try rmrf(join(root, "created.txt"))
        _ = try s.recover()
        XCTAssertTrue(isENOENT { try readBytes(join(root, "created.txt")) })
        XCTAssertEqual(try readText(join(root, "delete-me.txt")), "partial")
    }

    func testCreatesMissingParentFoldersForANewFileInsideTheProject() throws {
        let root = try projectRoot()
        try store(root).commit(DurableFileTransactionInput(id: "tx-first-sidecar", files: [.init(path: ".studio/project.json", expectedBefore: nil, after: "{}")]))
        XCTAssertEqual(try readText(join(root, ".studio/project.json")), "{}")
    }

    func testNeverCreatesParentFoldersThroughASymlinkThatLeavesTheProject() throws {
        let root = try projectRoot()
        let outside = try roots.make("studio-file-transaction-outside-")
        try makeSymlink(outside, at: join(root, "linked"))
        assertThrows(try store(root).commit(DurableFileTransactionInput(id: "tx-escape", files: [.init(path: "linked/nested/file.json", expectedBefore: nil, after: "x")])),
                     "unsafe", caseInsensitive: true)
        XCTAssertThrowsError(try readText(join(outside, "nested/file.json")))
    }

    func testMakesCommittedRetriesIdempotentAndRejectsTransactionIdPayloadReuse() throws {
        let root = try projectRoot()
        var writes = 0
        let s = store(root, afterTargetWrite: { _, _ in writes += 1 })
        let first = try s.commit(transaction())
        try writeText(join(root, "src/index.html"), "newer edit")
        let retry = try s.commit(transaction())
        XCTAssertEqual(retry, first)
        XCTAssertEqual(try readText(join(root, "src/index.html")), "newer edit")
        XCTAssertEqual(writes, 2)
        var changed = transaction()
        changed.files[0].after = "different-after"
        assertThrows(try s.commit(changed), "already belongs to a different payload", caseInsensitive: true)
    }

    func testResumesTheSamePreparedTransactionByRollingBackBeforeRetrying() throws {
        let root = try projectRoot()
        assertThrows(try store(root, afterTargetWrite: { _, _ in throw PowerLoss("crash") }).commit(transaction()), "crash")
        let retry = try store(root).commit(transaction())
        XCTAssertEqual(retry.state, .committed)
        XCTAssertEqual(try readText(join(root, "src/index.html")), "after-html")
        XCTAssertEqual(try readText(join(root, "project.json")), "after-project")
    }

    func testListsUnacknowledgedReceiptsAndOnlyCleansTerminalReceiptsOnAck() throws {
        let root = try projectRoot()
        let s = store(root)
        try s.commit(transaction())
        XCTAssertEqual(try s.listPending(), [])
        XCTAssertEqual(try s.listReceipts().map { [$0.id, $0.stateName] }, [["tx-1", "COMMITTED"]])
        XCTAssertTrue(try s.acknowledge("tx-1"))
        XCTAssertNil(try s.status("tx-1"))
        XCTAssertFalse(try s.acknowledge("tx-1"))
    }

    func testRefusesAckForAnUnresolvedPreparedReceipt() throws {
        let root = try projectRoot()
        let crashing = store(root, afterPrepared: { _ in throw PowerLoss("crash") })
        assertThrows(try crashing.commit(transaction()), "crash")
        assertThrows(try crashing.acknowledge("tx-1"), "prepared", caseInsensitive: true)
        XCTAssertEqual(try crashing.status("tx-1")?.stateName, "PREPARED")
        XCTAssertEqual(try crashing.listPending().map { [$0.id, $0.state.rawValue] }, [["tx-1", "PREPARED"]])
    }

    func testReportsCorruptJournalsDeterministicallyAndNeverMutatesTargetsFromThem() throws {
        let root = try projectRoot()
        let journalDir = join(root, ".hyperframes/studio-transactions")
        try mkdirP(journalDir)
        try writeText(join(journalDir, "corrupt.json"), "{not-json")
        let s = store(root)
        let first = try s.recover(), second = try s.recover()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map { [$0.action.rawValue, $0.status.journal] }, [["corrupt", "corrupt.json"]])
        XCTAssertEqual(try readText(join(root, "src/index.html")), "before-html")
        XCTAssertEqual(try readText(join(root, "project.json")), "before-project")
    }

    func testDetectsAParseableButChecksumCorruptedJournalWithoutTrustingItsPaths() throws {
        let root = try projectRoot()
        let s = store(root, afterPrepared: { _ in throw PowerLoss("crash") })
        assertThrows(try s.commit(transaction()), "crash")
        let receipt = try XCTUnwrap(s.status("tx-1"))
        XCTAssertTrue(receipt.journal.hasSuffix(".json"))
        let journalPath = join(root, ".hyperframes/studio-transactions", receipt.journal)
        guard case .object(var parsed) = try NativeJSONValue.parse(readText(journalPath)),
              case .array(var files)? = parsed["files"], case .object(var f0) = files[0] else { return XCTFail("journal shape") }
        f0["path"] = .string("../outside"); files[0] = .object(f0); parsed["files"] = .array(files)
        try writeText(journalPath, jsJSONStringify(.object(parsed)))
        let result = try s.recover()
        XCTAssertEqual(result.map { [$0.action.rawValue, $0.status.journal] }, [["corrupt", receipt.journal]])
        XCTAssertEqual(try readText(join(root, "src/index.html")), "before-html")
    }

    func testRejectsDuplicateTargetsBeforeCreatingAJournal() throws {
        let root = try projectRoot()
        let s = store(root)
        var input = transaction()
        input.files.append(.init(path: "src/index.html", expectedBefore: "before-html", after: "duplicate"))
        assertThrows(try s.commit(input), "duplicate", caseInsensitive: true)
        XCTAssertEqual(try s.listReceipts(), [])
    }

    func testPreservesNewerBytesWhileReconcilingOverlappingCommittedReceipts() throws {
        let root = try projectRoot()
        let candidates = jsStableSorted(["sequence-a", "sequence-b"]) { jsLocaleCompare(sha256Hex($0), sha256Hex($1)) }
        let newerId = candidates[0], olderId = candidates[1]
        let s = store(root)
        try s.commit(DurableFileTransactionInput(id: olderId, files: [.init(path: "src/index.html", expectedBefore: "before-html", after: "middle")]))
        try s.commit(DurableFileTransactionInput(id: newerId, files: [.init(path: "src/index.html", expectedBefore: "middle", after: "final")]))
        try writeText(join(root, "src/index.html"), "damaged")
        _ = try store(root).recover()
        XCTAssertEqual(try readText(join(root, "src/index.html")), "damaged")
    }

    func testSerializesCommitsAcrossStoreInstancesForTheSameProject() throws {
        let root = try projectRoot()
        let preparedGate = DispatchSemaphore(value: 0), prepared = DispatchSemaphore(value: 0)
        let firstStore = store(root, afterPrepared: { _ in prepared.signal(); preparedGate.wait() })
        let secondStore = store(root)
        let first = Spawned { try firstStore.commit(DurableFileTransactionInput(id: "concurrent-first", files: [.init(path: "src/index.html", expectedBefore: "before-html", after: "middle")])) }
        prepared.wait()
        let second = Spawned { try secondStore.commit(DurableFileTransactionInput(id: "concurrent-second", files: [.init(path: "src/index.html", expectedBefore: "middle", after: "final")])) }
        Thread.sleep(forTimeInterval: 0.05)   // let the second commit reach the per-root lock
        preparedGate.signal()
        XCTAssertEqual(try first.join().get().state, .committed)
        XCTAssertEqual(try second.join().get().state, .committed)
        XCTAssertEqual(try readText(join(root, "src/index.html")), "final")
    }

    func testValidatesEveryRecoveryTargetBeforeRestoringAnyFile() throws {
        let root = try projectRoot()
        let outside = try roots.make("studio-file-transaction-outside-")
        try writeText(join(outside, "index.html"), "outside")
        assertThrows(try store(root, afterPrepared: { _ in throw PowerLoss("crash") }).commit(transaction()), "crash")
        try rmrf(join(root, "src"))
        try makeSymlink(outside, at: join(root, "src"))
        try writeText(join(root, "project.json"), "external")
        let result = try store(root).recover()
        XCTAssertEqual(result.map { [$0.action.rawValue, $0.status.id] }, [["corrupt", "tx-1"]])
        XCTAssertEqual(try readText(join(root, "project.json")), "external")
        XCTAssertEqual(try readText(join(outside, "index.html")), "outside")
    }

    func testTreatsJournalSymlinksAsCorruptInsteadOfFollowingThem() throws {
        let root = try projectRoot()
        let s = store(root)
        let receipt = try s.commit(transaction())
        let journalDir = join(root, ".hyperframes/studio-transactions")
        let valid = try readText(join(journalDir, receipt.journal))
        try rmrf(join(journalDir, receipt.journal))
        let outside = try roots.make("studio-journal-outside-")
        let external = join(outside, "receipt.json")
        try writeText(external, valid)
        try makeSymlink(external, at: join(journalDir, receipt.journal))
        XCTAssertEqual(try s.listReceipts().map { [$0.stateName, $0.journal] }, [["CORRUPT", receipt.journal]])
    }

    func testPersistsValidatedEditHistoryMetadataThroughStatusAndRestartRecovery() throws {
        let root = try projectRoot()
        let history = DurableFileTransactionHistory(label: "Move timeline clips", kind: .timeline, coalesceKey: "timeline-move:clip:a,clip:b", coalesceMs: 5_000)
        var input = transaction("history-tx"); input.history = history
        let committed = try store(root).commit(input)
        let restarted = store(root)
        let status = try restarted.status("history-tx")
        let recovery = try restarted.recover()
        XCTAssertEqual(committed.history, history)
        XCTAssertEqual(status?.stateName, "COMMITTED"); XCTAssertEqual(status?.receipt?.history, history)
        XCTAssertEqual(recovery.map { [$0.status.id, $0.action.rawValue] }, [["history-tx", "already-committed"]])
        XCTAssertEqual(recovery[0].status.receipt?.history, history)
        XCTAssertEqual(try restarted.listCommittedPendingHistory().map { [$0.id, $0.state.rawValue] }, [["history-tx", "COMMITTED"]])
        XCTAssertEqual(try restarted.listCommittedPendingHistory()[0].history, history)
    }

    func testRejectsMalformedHistoryMetadataBeforeJournalCreation() throws {
        let cases: [NativeJSONObject] = [
            ["label": .string(""), "kind": .string("timeline")],
            ["label": .string("Move"), "kind": .string("agent")],
            ["label": .string("Move"), "kind": .string("timeline"), "coalesceKey": .string("")],
            ["label": .string("Move"), "kind": .string("timeline"), "coalesceMs": .number(-1)],
            ["label": .string("Move"), "kind": .string("timeline"), "coalesceMs": .number(.nan)],
            ["label": .string("Move"), "kind": .string("timeline"), "unexpected": .bool(true)],
        ]
        for history in cases {
            let root = try projectRoot()
            let s = store(root)
            guard case .object(var input) = transaction("malformed-history").jsonValue else { return XCTFail() }
            input["history"] = .object(history)
            assertThrows(try s.commit(NativeJSONValue.object(input)), "history", caseInsensitive: true)
            XCTAssertEqual(try s.listReceipts(), [])
            XCTAssertEqual(try readText(join(root, "src/index.html")), "before-html")
        }
    }

    func testIncludesHistoryMetadataInTransactionIdIdempotency() throws {
        let root = try projectRoot()
        let s = store(root)
        var input = transaction("history-idempotency"); input.history = .init(label: "Move clip", kind: .timeline)
        try s.commit(input)
        input.history = .init(label: "Trim clip", kind: .timeline)
        assertThrows(try s.commit(input), "different payload", caseInsensitive: true)
    }

    func testListsOnlyUnacknowledgedCommittedReceiptsAsPendingHistory() throws {
        let root = try projectRoot()
        let s = store(root)
        var input = transaction("committed-history"); input.history = .init(label: "Edit clip", kind: .manual)
        try s.commit(input)
        let preparedStore = store(root, afterPrepared: { _ in throw PowerLoss("crash") })
        assertThrows(try preparedStore.commit(DurableFileTransactionInput(id: "prepared-history",
            files: [.init(path: "src/index.html", expectedBefore: "after-html", after: "later")], history: .init(label: "Later edit", kind: .motion))), "crash")
        XCTAssertEqual(try s.listCommittedPendingHistory().map { [$0.id, $0.state.rawValue] }, [["committed-history", "COMMITTED"]])
        _ = try s.acknowledge("committed-history")
        XCTAssertEqual(try s.listCommittedPendingHistory(), [])
    }
}
