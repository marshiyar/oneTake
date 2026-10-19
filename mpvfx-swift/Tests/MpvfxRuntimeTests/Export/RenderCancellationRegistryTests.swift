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
import MpvfxShared
@testable import MpvfxRuntime

final class RenderCancellationRegistryTests: XCTestCase {
    final class Clock: @unchecked Sendable { var now = 1_000.0 }

    func testAbortsTheSignalExactlyOnceOnAnExplicitCancel() throws {
        let registry = RenderCancellationRegistry(sweepIntervalMs: 0)
        let render = try registry.register("render-1")
        var aborts = 0
        render.cancellation.onCancel { aborts += 1 }
        XCTAssertTrue(registry.cancel("render-1"))
        XCTAssertTrue(render.cancellation.isCancelled)
        XCTAssertEqual(aborts, 1)
        XCTAssertFalse(registry.cancel("render-1"))
        XCTAssertEqual(aborts, 1)
    }
    func testCancelsEveryActiveRenderWhenTheLocalServerCloses() throws {
        let registry = RenderCancellationRegistry(sweepIntervalMs: 0)
        let first = try registry.register("render-1"), second = try registry.register("render-2")
        registry.dispose()
        XCTAssertTrue(first.cancellation.isCancelled)
        XCTAssertTrue(second.cancellation.isCancelled)
        XCTAssertEqual(registry.activeCount(), 0)
    }
    func testExpiresAnOrphanedRenderAfterHeartbeatsStop() throws {
        let clock = Clock()
        let registry = RenderCancellationRegistry(now: { clock.now }, leaseTimeoutMs: 15_000, sweepIntervalMs: 0)
        let render = try registry.register("orphan")
        clock.now += 14_999
        XCTAssertEqual(registry.sweepExpired(), 0)
        XCTAssertFalse(render.cancellation.isCancelled)
        clock.now += 1
        XCTAssertEqual(registry.sweepExpired(), 1)
        XCTAssertTrue(render.cancellation.isCancelled)
    }
    func testKeepsALiveRenderLeasedWhileTheEditorContinuesHeartbeating() throws {
        let clock = Clock()
        let registry = RenderCancellationRegistry(now: { clock.now }, leaseTimeoutMs: 15_000, sweepIntervalMs: 0)
        let render = try registry.register("render-1")
        clock.now += 10_000
        XCTAssertTrue(registry.heartbeat("render-1"))
        clock.now += 10_000
        XCTAssertEqual(registry.sweepExpired(), 0)
        XCTAssertFalse(render.cancellation.isCancelled)
    }
    func testUnregistersCompletedWorkSoALaterCloseOrLeaseSweepCannotCancelIt() throws {
        let clock = Clock()
        let registry = RenderCancellationRegistry(now: { clock.now }, leaseTimeoutMs: 15_000, sweepIntervalMs: 0)
        let render = try registry.register("complete")
        render.finish()
        clock.now += 60_000
        _ = registry.sweepExpired()
        registry.dispose()
        XCTAssertFalse(render.cancellation.isCancelled)
        XCTAssertEqual(registry.activeCount(), 0)
    }
    func testRefusesADuplicateJobIdWithoutCancellingTheRenderThatAlreadyOwnsIt() throws {
        let registry = RenderCancellationRegistry(sweepIntervalMs: 0)
        let stale = try registry.register("same-id")
        XCTAssertThrowsError(try registry.register("same-id")) { XCTAssertTrue("\($0)".lowercased().contains("already active")) }
        XCTAssertFalse(stale.cancellation.isCancelled)
        stale.finish()
        XCTAssertEqual(registry.activeCount(), 0)
    }
}
