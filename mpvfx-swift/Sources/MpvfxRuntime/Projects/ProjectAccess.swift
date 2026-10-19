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
// Project access: one queue per project root; operations on the same root run
// strictly one after another (a failure does not block later ones), different roots run independently.
// Async callers use `run`; synchronous callers (the UI thread, the autosave queue) use `runBlocking`, in one order.
import Foundation

public final class ProjectAccessQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: Turn] = [:]
    private var submitted = 0

    public init() {}

    /// Takes the next place on `projectRoot`: returns the turn to wait for (nil when the root is idle) and this one.
    private func enqueue(_ projectRoot: String) -> (previous: Turn?, own: Turn) {
        lock.withLock {
            submitted += 1
            let own = Turn()
            defer { pending[projectRoot] = own }
            return (pending[projectRoot], own)
        }
    }

    private func finish(_ projectRoot: String, _ own: Turn) {
        lock.withLock { if pending[projectRoot] === own { pending[projectRoot] = nil } }
        own.finish()
    }

    /// Runs `operation` after every earlier one on the same root.
    public func run<T: Sendable>(_ projectRoot: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let (previous, own) = enqueue(projectRoot)
        let task = Task<T, Error> {
            defer { self.finish(projectRoot, own) }
            await previous?.wait()
            return try await operation()
        }
        return try await task.value
    }

    /// Runs `operation` on the calling thread after every earlier one on the same root, blocking until then; later
    /// operations wait for it. Call it from a thread outside Swift concurrency, and never from inside an operation
    /// on the same root (that waits for itself).
    public func runBlocking<T>(_ projectRoot: String, _ operation: () throws -> T) rethrows -> T {
        let (previous, own) = enqueue(projectRoot)
        defer { finish(projectRoot, own) }
        previous?.block()
        return try operation()
    }

    /// Waits until no operation is pending.
    public func drain() async {
        while true {
            let all = lock.withLock { Array(pending.values) }
            if all.isEmpty { return }
            for t in all { await t.wait() }
            await Task.yield()
        }
    }

    var pendingCount: Int { lock.withLock { pending.count } }
    /// Operations queued so far; tests wait on it instead of sleeping to order their submissions.
    var submittedCount: Int { lock.withLock { submitted } }
}

/// The end of one queued operation: `wait()` suspends a task until then, `block()` parks a thread.
private final class Turn: @unchecked Sendable {
    private let condition = NSCondition()
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        condition.lock()
        done = true
        let resumed = waiters
        waiters = []
        condition.broadcast()
        condition.unlock()
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            condition.lock()
            if done { condition.unlock(); c.resume(); return }
            waiters.append(c)
            condition.unlock()
        }
    }

    func block() {
        condition.lock()
        while !done { condition.wait() }
        condition.unlock()
    }
}
