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

/// Synthetic frames land exactly where `docs/SCOPES.md` says on every scope.
final class ScopeEngineAccuracyTests: XCTestCase {
    typealias F = ScopeFixtures

    func testGreyRampPutsColumnCAtLevelCOnEveryPlane() throws {
        let a = ScopeEngine.analyze(try F.greyRamp(height: 3))
        XCTAssertEqual(a.columns, 256)
        XCTAssertEqual(a.samples, 256 * 3)
        for c in 0..<256 {
            for ch in ScopeChannel.allCases {
                XCTAssertEqual(a.waveform(ch, column: c, level: c), 3, "\(ch) column \(c)")
            }
        }
        XCTAssertEqual(a.waveform.reduce(0) { $0 + Int($1) }, 4 * 256 * 3, "nothing outside the diagonal")
    }

    func testGreyRampHistogramIsFlatAndVectorscopeSitsAtTheCentre() throws {
        let a = ScopeEngine.analyze(try F.greyRamp(height: 2))
        for ch in ScopeChannel.allCases {
            XCTAssertEqual((0..<256).map { a.histogram(ch, level: $0) }, [UInt32](repeating: 2, count: 256), "\(ch)")
        }
        XCTAssertEqual(a.vectorSide, 257)
        XCTAssertEqual(a.vector(row: 128, col: 128), 512, "every grey is achromatic")
        XCTAssertEqual(a.vectorOutside, 0)
    }

    func testBT471BarsLandOnTheirLumaLevelsAndVectorscopeTargets() throws {
        for amplitude in ScopeTargets.barAmplitudes {
            let a = ScopeEngine.analyze(try F.bars(amplitude: amplitude, barWidth: 4, height: 2))
            let targets = ScopeTargets.bars(.rec709, amplitude: amplitude)
            for (i, bar) in F.barColours(amplitude: amplitude).enumerated() {
                let level = F.lumaLevel(.rec709, bar.r, bar.g, bar.b)
                for c in i * 4..<(i + 1) * 4 { XCTAssertEqual(a.waveform(.luma, column: c, level: level), 2, "\(bar.name) \(amplitude)") }
                let bin = try XCTUnwrap(F.vectorBin(.rec709, bar.r, bar.g, bar.b))
                let neutral = bar.name == "White" || bar.name == "Black"
                XCTAssertEqual(a.vector(row: bin.row, col: bin.col), neutral ? 16 : 8, "\(bar.name) \(amplitude)")
                guard let t = targets.first(where: { $0.name == bar.name }) else { continue }
                let target = try XCTUnwrap(a.vectorBin(cb: t.cb, cr: t.cr))
                XCTAssertEqual(target.row, bin.row, "\(bar.name) \(amplitude): trace on its target")
                XCTAssertEqual(target.col, bin.col, "\(bar.name) \(amplitude): trace on its target")
            }
        }
    }

    func testPureBlackIsCountedAtLevelZero() throws {
        let a = ScopeEngine.analyze(try F.solid(8, 8, 0, 0, 0))
        for ch in ScopeChannel.allCases {
            XCTAssertEqual(a.waveform(ch, column: 0, level: 0), 8, "\(ch)")
            XCTAssertEqual(a.clipped(ch).low, 64)
        }
    }

    func testPureBlueAndRedLandOnTheVectorscopeEdgeNotOffIt() throws {
        let blue = ScopeEngine.analyze(try F.solid(4, 4, 0, 0, 255))
        XCTAssertEqual(blue.vector(row: 128 + 12, col: 256), 16, "Cb +0.5 is the right edge; Cr -0.0458 x 256 = 11.7 bins down")
        let red = ScopeEngine.analyze(try F.solid(4, 4, 255, 0, 0))
        XCTAssertEqual(red.vector(row: 0, col: 128 - 29), 16, "Cr +0.5 is the top edge; Cb -0.1146 x 256 = 29.3 bins left")
        XCTAssertEqual(blue.vectorOutside + red.vectorOutside, 0)
    }

    func testPrimariesOnEachMatrixLandWhereThePublishedFormulasPutThem() throws {
        let primaries: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255), (255, 0, 255)]
        for m in ScopeMatrix.allCases {
            for p in primaries {
                let a = ScopeEngine.analyze(try F.solid(2, 2, p.0, p.1, p.2), options: ScopeOptions(matrix: m))
                XCTAssertEqual(a.histogram(.luma, level: F.lumaLevel(m, p.0, p.1, p.2)), 4, "\(m) \(p)")
                let bin = try XCTUnwrap(F.vectorBin(m, p.0, p.1, p.2))
                XCTAssertEqual(a.vector(row: bin.row, col: bin.col), 4, "\(m) \(p)")
            }
        }
    }

    func testTransparentPixelsAreSkippedAndEveryOtherPixelCountsOnce() throws {
        let f = try F.frame(4, 1) { x, _ in (200, 200, 200, [0, 1, 128, 255][x]) }
        let a = ScopeEngine.analyze(f)
        XCTAssertEqual(a.samples, 3)
        XCTAssertEqual(a.histogram(.luma, level: 200), 3)
    }

    func testZoomTwoDoublesTheDistanceAndCountsOffScaleSamples() throws {
        let opts = ScopeOptions(vectorZoom: 2)
        let pastel = ScopeEngine.analyze(try F.solid(2, 2, 160, 120, 110), options: opts)
        let bin = try XCTUnwrap(F.vectorBin(.rec709, 160, 120, 110, zoom: 2))
        let unzoomed = try XCTUnwrap(F.vectorBin(.rec709, 160, 120, 110))
        XCTAssertEqual(pastel.vector(row: bin.row, col: bin.col), 4)
        XCTAssertLessThanOrEqual(abs((bin.col - 128) - 2 * (unzoomed.col - 128)), 1, "twice as far from the centre")
        XCTAssertLessThanOrEqual(abs((bin.row - 128) - 2 * (unzoomed.row - 128)), 1, "twice as far from the centre")
        XCTAssertGreaterThan(abs(bin.col - 128) + abs(bin.row - 128), 8, "a real distance, not the centre")
        let blue = ScopeEngine.analyze(try F.solid(2, 2, 0, 0, 255), options: opts)
        XCTAssertEqual(blue.vectorOutside, 4, "100 % blue is off a 2x scope and counted, not piled on the edge")
        XCTAssertEqual(blue.vectorscope.reduce(0, +), 0)
    }

    func testClippingCountsAndColumnMarks() throws {
        let f = try F.frame(4, 2) { x, _ in x == 0 ? (255, 10, 0, 255) : (100, 100, 100, 255) }
        let a = ScopeEngine.analyze(f)
        XCTAssertEqual(a.clipped(.red).high, 2)
        XCTAssertEqual(a.clipped(.blue).low, 2)
        XCTAssertTrue(a.columnClips(.red, column: 0).high)
        XCTAssertFalse(a.columnClips(.red, column: 1).high)
        XCTAssertEqual(a.clipped(.luma).high, 0)
    }

    func testTheNumberOfWorkersDoesNotChangeTheResult() throws {
        let f = try F.busy(1001, 531)   // enough samples for 4 workers (ScopeEngine.samplesPerWorker)
        let one = ScopeEngine.analyze(f, options: ScopeOptions(workers: 1))
        let many = ScopeEngine.analyze(f, options: ScopeOptions(workers: 7))
        XCTAssertEqual(one.waveform, many.waveform)
        XCTAssertEqual(one.histogram, many.histogram)
        XCTAssertEqual(one.vectorscope, many.vectorscope)
        XCTAssertEqual(one.samples, 1001 * 531)
        XCTAssertEqual(many.samples, 1001 * 531)
    }

    func testLargeFramesArePointSampledOnAUniformGrid() throws {
        XCTAssertEqual(ScopeEngine.samplingStep(width: 3840, height: 2160, maxSamples: 1920 * 1080), 2)
        XCTAssertEqual(ScopeEngine.samplingStep(width: 1920, height: 1080, maxSamples: 1920 * 1080), 1)
        let big = try F.busy(64, 36)
        let picked = try F.frame(32, 18) { x, y in
            let o = ((y * 2) * 64 + x * 2) * 4
            return (big.rgba[o], big.rgba[o + 1], big.rgba[o + 2], big.rgba[o + 3])
        }
        let a = ScopeEngine.analyze(big, options: ScopeOptions(columns: 32, maxSamples: 32 * 18))
        let b = ScopeEngine.analyze(picked, options: ScopeOptions(columns: 32))
        XCTAssertEqual(a.step, 2)
        XCTAssertEqual(a.samples, 32 * 18)
        XCTAssertEqual(a.waveform, b.waveform)
        XCTAssertEqual(a.histogram, b.histogram)
        XCTAssertEqual(a.vectorscope, b.vectorscope)
    }

    func testColumnsSpreadTheFrameEvenly() throws {
        let a = ScopeEngine.analyze(try F.greyRamp(height: 1), options: ScopeOptions(columns: 64))
        XCTAssertEqual(a.columns, 64)
        for c in 0..<64 {
            XCTAssertEqual((0..<256).reduce(0) { $0 + Int(a.waveform(.luma, column: c, level: $1)) }, 4, "column \(c)")
            XCTAssertEqual(a.waveform(.luma, column: c, level: c * 4), 1)
        }
    }
}
