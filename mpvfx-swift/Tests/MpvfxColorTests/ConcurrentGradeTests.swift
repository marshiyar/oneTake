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
import Synchronization
@testable import MpvfxColor

final class ConcurrentGradeTests: XCTestCase {
    func testRowsVisitEveryRowOnceAndPublishInOrder() {
        // Both sides of the serial threshold, uneven chunks, and more rows than workers.
        let counts = [0, 1, 15, 16, 17, 33, ProcessInfo.processInfo.activeProcessorCount * 2 + 1]
        for count in counts {
            let visits = Mutex([Int](repeating: 0, count: count))
            var rows = [Int](repeating: -1, count: count)
            concurrentRows(count, elementsPerRow: 1, into: &rows) { chunk in
                visits.withLock { seen in
                    for row in chunk { seen[row] += 1 }
                }
                // Vary completion order; the result still has to follow row order.
                if chunk.lowerBound == 0 { Thread.sleep(forTimeInterval: 0.002) }
                return Array(chunk)
            }
            XCTAssertEqual(rows, Array(0..<count))
            XCTAssertEqual(visits.withLock { $0 }, [Int](repeating: 1, count: count))
        }
    }

    func testPublishingRowsPreservesSharedInputAndTrailingElements() {
        for count in [15, 17] {
            let original = Array(0..<(count * 3 + 5))
            var output = original
            concurrentRows(count, elementsPerRow: 3, into: &output) { rows in
                rows.flatMap { row in [row * 10, row * 10 + 1, row * 10 + 2] }
            }
            var expected: [Int] = []
            for row in 0..<count {
                for column in 0..<3 { expected.append(row * 10 + column) }
            }
            XCTAssertEqual(Array(output.prefix(count * 3)), expected)
            XCTAssertEqual(Array(output.suffix(5)), Array(original.suffix(5)))
            XCTAssertEqual(original, Array(0..<(count * 3 + 5)), "shared input must retain its value")
        }
    }

    func testParallelGradePreservesRowOrientationAlphaAndTrailingBytes() {
        let width = 7, height = 33
        let renderer = ColorGradeRenderer(params: GradeReferenceCases.params(#"{"adjust":{"temperature":0.4}}"#))
        var source: [UInt8] = []
        for i in 0..<(width * height) {
            source.append(UInt8(30 + i % 170))
            source.append(UInt8(40 + i / width))
            source.append(70)
            source.append(UInt8(50 + i % 200))
        }
        var expected: [UInt8] = []
        // A colour-only grade is independent of frame dimensions. Render each pixel through
        // the serial path as an oracle for the parallel path's row placement and alpha.
        for i in stride(from: 0, to: source.count, by: 4) {
            var pixel = Array(source[i..<i + 4])
            renderer.apply(&pixel, width: 1, height: 1, time: 0)
            expected += pixel
        }
        let trailing: [UInt8] = [19, 28, 37, 46, 55]
        var actual = source + trailing
        renderer.apply(&actual, width: width, height: height, time: 0)
        XCTAssertEqual(actual, expected + trailing)
        XCTAssertNotEqual(Array(actual.prefix(source.count)), source)
    }

    func testSharedRendererKeepsMultipassFramesIndependent() {
        let renderer = ColorGradeRenderer(params: GradeReferenceCases.params(
            #"{"adjust":{"exposure":0.2},"details":{"grain":0.3},"effects":{"blur":0.2,"bloom":0.3,"bloomRadius":0.4,"kuwahara":0.6,"kuwaharaRadius":0.2}}"#),
            seedKey: "concurrent-frames")
        let sizes = [(7, 15), (11, 17), (9, 33)]
        let sources = sizes.map { GradeReferenceCases.card(width: $0.0, height: $0.1) }
        let expected = sizes.indices.map { i -> [UInt8] in
            var frame = sources[i]
            renderer.apply(&frame, width: sizes[i].0, height: sizes[i].1, time: Double(i) / 3)
            return frame
        }
        let results = Mutex([[UInt8]](repeating: [], count: 12))
        DispatchQueue.concurrentPerform(iterations: 12) { iteration in
            let i = iteration % sizes.count
            var frame = sources[i]
            renderer.apply(&frame, width: sizes[i].0, height: sizes[i].1, time: Double(i) / 3)
            results.withLock { $0[iteration] = frame }
        }
        for (iteration, frame) in results.withLock({ $0 }).enumerated() {
            XCTAssertEqual(frame, expected[iteration % sizes.count], "frame \(iteration)")
        }
        for i in sizes.indices { XCTAssertNotEqual(expected[i], sources[i]) }
    }
}
