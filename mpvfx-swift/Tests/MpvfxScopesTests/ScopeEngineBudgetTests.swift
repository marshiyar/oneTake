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
@testable import MpvfxScopes

/// Frame-time budget of the analysis (docs/SCOPES.md "Speed"). MpvfxScopes is built with -O in every configuration
/// (Package.swift), so this measures the code the app runs. Measured on a shared 4-vCPU Intel Xeon @ 2.10 GHz
/// Linux machine with other builds running: 1080p full density 12.7 ms median (date and load in docs/SCOPES.md).
/// Budget: 25 ms with four or more processors, so the scopes keep up with 40 updates a second with 2x headroom for
/// slower or busier runners. With fewer processors the work cannot be split as far, so the budget grows in
/// proportion (100 ms on one; one worker measured 21 to 41 ms on the machine above, depending on its load).
final class ScopeEngineBudgetTests: XCTestCase {
    static var budget1080pMilliseconds: Double {
        25 * 4 / Double(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
    }

    func testFullDensity1080pFitsTheFrameBudget() throws {
        let frame = try ScopeFixtures.busy(1920, 1080)
        let ms = Self.medianMilliseconds(runs: 5) { _ = ScopeEngine.analyze(frame) }
        print("scope budget: 1080p full density median \(String(format: "%.2f", ms)) ms (budget \(Self.budget1080pMilliseconds) ms)")
        XCTAssertLessThanOrEqual(ms, Self.budget1080pMilliseconds)
    }

    func testUHDIsSampledToTheSameCostAs1080p() throws {
        let frame = try ScopeFixtures.busy(3840, 2160)
        var analysis: ScopeAnalysis?
        let ms = Self.medianMilliseconds(runs: 3) { analysis = ScopeEngine.analyze(frame) }
        print("scope budget: 2160p (step 2) median \(String(format: "%.2f", ms)) ms")
        XCTAssertEqual(analysis?.step, 2)
        XCTAssertEqual(analysis?.samples, 1920 * 1080)
        XCTAssertLessThanOrEqual(ms, Self.budget1080pMilliseconds * 1.5, "same samples as 1080p, plus a strided read")
    }

    static func medianMilliseconds(runs: Int, _ body: () -> Void) -> Double {
        body()   // warm the allocator and the thread pool
        let times = (0..<runs).map { _ -> Double in
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }.sorted()
        return times[times.count / 2]
    }
}
