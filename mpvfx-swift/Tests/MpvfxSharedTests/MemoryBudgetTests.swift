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
@testable import MpvfxShared

/// Cache budgets sized from physical memory, the footprint reader, memory-pressure observers and the pipe reader the
/// decoders use instead of a `Data` per chunk.
final class MemoryBudgetTests: XCTestCase {
    func testBudgetsScaleWithRAMWithinTheirBounds() {
        let gb = 1 << 30
        XCTAssertEqual(MemoryBudget.previewFrames(physical: 16 * gb, env: [:]), Int(Double(16 * gb) * 0.10), "10% of a 16 GB Mac")
        XCTAssertEqual(MemoryBudget.previewFrames(physical: 64 * gb, env: [:]), 2 * gb, "capped at 2 GB")
        XCTAssertEqual(MemoryBudget.previewFrames(physical: 1 * gb, env: [:]), 256 << 20, "at least 256 MB")
        XCTAssertEqual(MemoryBudget.previewFrames(physical: 16 * gb, env: ["MPVFX_PREVIEW_CACHE_MB": "64"]), 64 << 20, "env override")
        XCTAssertEqual(MemoryBudget.mediaThumbnails(physical: 128 * gb), 256 << 20)
        XCTAssertEqual(MemoryBudget.gradedFrames(physical: 1 * gb), 64 << 20)
        XCTAssertGreaterThan(MemoryBudget.physicalMemory, 0)
        XCTAssertLessThanOrEqual(MemoryBudget.previewFrames(), 2 * gb)
    }

    /// The preview benchmark's `budget_sum_mib`: raw frames plus graded pictures, each within its own bounds.
    func testPreviewTotalIsTheSumOfThePreviewBudgets() {
        let gb = 1 << 30
        let ram = Int(15.6 * Double(gb))   // the Linux hosted runner of the issue #97 baseline
        XCTAssertEqual(MemoryBudget.previewTotal(physical: ram, env: [:]),
                       MemoryBudget.previewFrames(physical: ram, env: [:]) + MemoryBudget.gradedFrames(physical: ram))
        XCTAssertEqual(MemoryBudget.previewTotal(physical: ram, env: [:]), Int(Double(ram) * 0.10) + (256 << 20))
        let overridden = MemoryBudget.previewTotal(physical: 16 * gb, env: ["MPVFX_PREVIEW_CACHE_MB": "64"])
        XCTAssertEqual(overridden, (64 << 20) + (256 << 20), "the override replaces the frame budget in the sum too")
        XCTAssertEqual(MemoryBudget.previewTotal(physical: 1 * gb, env: [:]), (256 << 20) + (64 << 20), "both floors")
    }

    func testFootprintIsReadable() throws {
        #if os(Linux) || os(macOS)
        let a = try XCTUnwrap(ResidentMemory.footprintBytes())
        XCTAssertGreaterThan(a, 1 << 20)
        #endif
        XCTAssertEqual(ResidentMemory.parseVmRSS("Name:\tx\nVmPeak:\t  900 kB\nVmRSS:\t   12345 kB\nVmData: 1 kB\n"), 12345 * 1024)
        XCTAssertNil(ResidentMemory.parseVmRSS("Name:\tx\n"))
    }

    func testPressureObserversRunAndEndWithTheirToken() {
        let monitor = MemoryPressureMonitor()
        var seen: [MemoryPressureMonitor.Level] = []
        var token: MemoryPressureMonitor.Token? = monitor.observe { seen.append($0) }
        XCTAssertEqual(monitor.observerCount, 1)
        monitor.simulate(.warning); monitor.simulate(.critical)
        XCTAssertEqual(seen, [.warning, .critical])
        XCTAssertNotNil(token)
        token = nil
        XCTAssertEqual(monitor.observerCount, 0, "releasing the token removes the observer (no retained caches)")
        monitor.simulate(.warning)
        XCTAssertEqual(seen.count, 2)
    }

    func testAutoreleasePoolWrapperReturnsAndRethrows() {
        XCTAssertEqual(withAutoreleasePool { 41 + 1 }, 42)
        struct Boom: Error {}
        XCTAssertThrowsError(try withAutoreleasePool { () throws -> Int in throw Boom() })
    }
}
