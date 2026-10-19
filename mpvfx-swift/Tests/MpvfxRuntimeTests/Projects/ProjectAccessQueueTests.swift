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
// The project access queue contract: one operation at a time per root, independent roots in parallel.
// Ordering is forced with gates and the queue's submission count, never with sleeps, so the tests do not depend on
// scheduler timing.
import XCTest
@testable import MpvfxRuntime

private actor Log { var items: [String] = []; func add(_ s: String) { items.append(s) } }

/// A one-shot latch: `wait()` suspends until `open()` has been called.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private struct QueueTimeout: Error { let expected: Int; let seen: Int }

final class ProjectAccessQueueTests: XCTestCase {
    private func waitUntilSubmitted(_ q: ProjectAccessQueue, _ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while q.submittedCount < count {
            guard Date() < deadline else { throw QueueTimeout(expected: count, seen: q.submittedCount) }
            await Task.yield()
        }
    }

    func testSameRootRunsInOrderAndFailuresDoNotBlock() async throws {
        let q = ProjectAccessQueue(), log = Log(), aStarted = Gate(), releaseA = Gate()
        let a = Task { try await q.run("/p") { await aStarted.open(); await releaseA.wait(); await log.add("a"); return 1 } }
        await aStarted.wait()
        let b = Task { try await q.run("/p") { () async throws -> Int in await log.add("b"); throw CancellationError() } }
        try await waitUntilSubmitted(q, 2)
        let c = Task { try await q.run("/p") { await log.add("c"); return 3 } }
        try await waitUntilSubmitted(q, 3)
        let whileAHolds = await log.items
        XCTAssertEqual(whileAHolds, [], "b and c must wait for a on the same root")
        await releaseA.open()
        let ra = try await a.value
        let rb = await b.result
        let rc = try await c.value
        XCTAssertEqual(ra, 1); XCTAssertEqual(rc, 3)
        XCTAssertThrowsError(try rb.get(), "b should fail")
        let items = await log.items
        XCTAssertEqual(items, ["a", "b", "c"])
        await q.drain()
        XCTAssertEqual(q.pendingCount, 0)
    }

    func testDifferentRootsRunIndependently() async throws {
        let q = ProjectAccessQueue(), log = Log(), slowStarted = Gate(), releaseSlow = Gate()
        let slow = Task { try await q.run("/one") { await slowStarted.open(); await releaseSlow.wait(); await log.add("slow") } }
        await slowStarted.wait()
        let fastDone = expectation(description: "/two finishes while /one is still running")
        let fast = Task { try await q.run("/two") { await log.add("fast") }; fastDone.fulfill() }
        await fulfillment(of: [fastDone], timeout: 5)
        await releaseSlow.open()
        _ = try await (slow.value, fast.value)
        let items = await log.items
        XCTAssertEqual(items, ["fast", "slow"])
    }

    func testBlockingRunWaitsForEarlierOperationsAndHoldsLaterOnes() async throws {
        let q = ProjectAccessQueue(), log = Log(), aStarted = Gate(), releaseA = Gate()
        let a = Task { try await q.run("/p") { await aStarted.open(); await releaseA.wait(); await log.add("a") } }
        await aStarted.wait()
        // A synchronous caller (the UI thread, an autosave queue) on its own thread.
        let blockingDone = expectation(description: "the blocking operation returns")
        let blockingStarted = LockedFlag()
        Thread {
            q.runBlocking("/p") { blockingStarted.set() }
            blockingDone.fulfill()
        }.start()
        try await waitUntilSubmitted(q, 2)
        let c = Task { try await q.run("/p") { await log.add("c (started blocking: \(blockingStarted.value))") } }
        try await waitUntilSubmitted(q, 3)
        XCTAssertFalse(blockingStarted.value, "the blocking operation must wait for a on the same root")
        await releaseA.open()
        await fulfillment(of: [blockingDone], timeout: 5)
        _ = try await (a.value, c.value)
        let items = await log.items
        XCTAssertEqual(items, ["a", "c (started blocking: true)"])
        await q.drain()
        XCTAssertEqual(q.pendingCount, 0)
    }

    func testBlockingRunPassesResultsAndErrorsThrough() {
        let q = ProjectAccessQueue()
        XCTAssertEqual(q.runBlocking("/p") { 7 }, 7)
        XCTAssertThrowsError(try q.runBlocking("/p") { () throws -> Int in throw CancellationError() })
        XCTAssertEqual(q.runBlocking("/p") { 8 }, 8, "a failure does not block later operations")
        XCTAssertEqual(q.pendingCount, 0)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
