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

/// Per-channel difference of two RGBA8 frames (GPU output vs the CPU reference).
struct GradeDiff: CustomStringConvertible {
    var max = 0, over1 = 0, over2 = 0, count = 0, sum = 0
    var mean: Double { count > 0 ? Double(sum) / Double(count) : 0 }
    var description: String { "max \(max), >1: \(over1), >2: \(over2) of \(count), mean \(String(format: "%.4f", mean))" }

    init(_ a: [UInt8], _ b: [UInt8]) {
        count = a.count
        for i in 0..<min(a.count, b.count) {
            let x = abs(Int(a[i]) - Int(b[i]))
            sum += x; max = Swift.max(max, x)
            if x > 1 { over1 += 1 }
            if x > 2 { over2 += 1 }
        }
    }

    /// The Metal parity tolerance (MetalColorRendererTests.testEveryControlAndEffectMatchesTheCPUReference).
    func assertWithinParityTolerance(noisy: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        if noisy {
            XCTAssertLessThanOrEqual(over2, count / 50, "\(what): \(self)", file: file, line: line)
            XCTAssertLessThan(mean, 0.5, "\(what): \(self)", file: file, line: line)
        } else {
            XCTAssertLessThanOrEqual(over1, count / 1000, "\(what): \(self)", file: file, line: line)
            XCTAssertLessThanOrEqual(over2, count / 2000, "\(what): \(self)", file: file, line: line)
            XCTAssertLessThan(mean, 0.02, "\(what): \(self)", file: file, line: line)
        }
    }
}
