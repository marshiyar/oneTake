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
@testable import MpvfxTimeline
import MpvfxShared
import OneTakeKeyframes

/// Undo history survives a restart (usePersistentEditHistory): saved per project, taken back only against the
/// same document, and undo/redo then walk the same states with the same labels.
final class TimelineEditHistoryStoreTests: XCTestCase {
    func testHistoryRoundTripsThroughTheFileAndUndoesAfterReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTimelineHistoryStore(directory: dir)
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        var saves = 0
        e.onHistoryChange = { saves += 1; store.save(projectId: "project:demo/x", e.persistedHistory()) }
        let d0 = e.document
        XCTAssertTrue(e.apply(.move(address: e.address(clipId: "clip:b")!, destination: .init(trackId: "track:v1", startFrame: 240))))
        let d1 = e.document
        XCTAssertTrue(e.setTrackLocked("track:a1", true))
        let d2 = e.document
        XCTAssertTrue(e.undo())
        XCTAssertEqual(saves, 3)

        // "Restart": a fresh editor on the saved document.
        let e2 = TimelineEditor(document: e.document, engine: try KeyframeRuntime())
        let saved = try XCTUnwrap(store.load(projectId: "project:demo/x"))
        XCTAssertTrue(e2.restoreHistory(saved))
        XCTAssertEqual(e2.undoLabel, "Move clip"); XCTAssertEqual(e2.redoLabel, "Lock track")
        XCTAssertEqual(e2.document, d1)
        XCTAssertTrue(e2.redo()); XCTAssertEqual(e2.document, d2)
        XCTAssertTrue(e2.undo()); XCTAssertTrue(e2.undo()); XCTAssertEqual(e2.document, d0)
        XCTAssertFalse(e2.canUndo)

        // Saved against a different document: not taken back.
        let e3 = TimelineEditor(document: d0, engine: try KeyframeRuntime())
        XCTAssertFalse(e3.restoreHistory(saved)); XCTAssertFalse(e3.canUndo)
    }

    /// Persisting after every edit costs the UI thread only an O(1) snapshot, however deep the history is: the
    /// replay into documents (a document clone per entry) and the write run on the persister's worker, and a burst
    /// of edits collapses into the newest snapshot. What lands on disk is the final history.
    func testPersisterKeepsTheReplayOffTheEditingThreadAndWritesTheNewestHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTimelineHistoryStore(directory: dir)
        let persister = TimelineHistoryPersister(store: store, projectId: "p")
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        var submits = 0, maxCallback: UInt64 = 0
        e.onHistoryChange = {
            let t0 = DispatchTime.now().uptimeNanoseconds
            persister.submit(e.historySnapshot()); submits += 1
            maxCallback = max(maxCallback, DispatchTime.now().uptimeNanoseconds - t0)
        }
        for i in 0..<(e.maxHistoryEntries + 30) { XCTAssertTrue(e.setTrackLocked("track:a1", i % 2 == 0)) }
        XCTAssertTrue(e.undo()); XCTAssertTrue(e.undo())
        persister.waitUntilIdle()
        print(String(format: "HISTORY-PERSIST submits=%d writes=%d maxCallbackMs=%.3f", submits, persister.writes, Double(maxCallback) / 1e6))
        XCTAssertEqual(submits, e.maxHistoryEntries + 32)
        XCTAssertLessThan(persister.writes, submits, "a burst of edits collapses into fewer writes")
        XCTAssertGreaterThan(persister.writes, 0)
        XCTAssertLessThan(Double(maxCallback) / 1e6, 50, "the edit-time callback must not replay the history")
        let saved = try XCTUnwrap(store.load(projectId: "p"))
        XCTAssertEqual(saved, e.persistedHistory())
        XCTAssertEqual(saved.undo.count, e.maxHistoryEntries - 2); XCTAssertEqual(saved.redo.count, 2)
    }
    /// The quit path waits for the last history write, but only up to a bound: while the write is stuck the
    /// wait gives up and reports it (the app still quits); once the write lands the wait returns true at once.
    func testWaitUntilIdleWithTimeoutWaitsForTheWriteButGivesUpWhenItIsStuck() throws {
        let release = DispatchSemaphore(value: 0)
        var written: [TimelinePersistedHistory] = []
        let persister = TimelineHistoryPersister { h in release.wait(); written.append(h) }
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        e.onHistoryChange = { persister.submit(e.historySnapshot()) }
        XCTAssertTrue(e.setTrackLocked("track:a1", true))
        XCTAssertFalse(persister.waitUntilIdle(timeout: 0.05), "a stuck write does not hold the caller past the bound")
        XCTAssertEqual(persister.writes, 0)
        release.signal()
        XCTAssertTrue(persister.waitUntilIdle(timeout: 30))
        XCTAssertEqual(persister.writes, 1)
        XCTAssertEqual(written.last?.undo.last?.label, "Lock track")
        XCTAssertTrue(persister.waitUntilIdle(timeout: 0), "idle: no wait")
    }
}
