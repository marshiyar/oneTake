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
import MpvfxCanvas
import MpvfxScopes
import MpvfxTheme
@testable import MpvfxPanels

/// The Grade group's scopes as a tool: several at once, their layout, settings, the trace bitmaps and the
/// background analysis (docs/SCOPES.md).
final class ScopesPanelTests: XCTestCase {
    /// `w` columns, column x grey at code `x * 255 / (w - 1)`: black at the left edge, white at the right.
    static func ramp(_ w: Int = 64, _ h: Int = 36) -> CanvasImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let v = UInt8(x * 255 / (w - 1)), i = (y * w + x) * 4
            px[i] = v; px[i + 1] = v; px[i + 2] = v
        } }
        return CanvasImage(width: w, height: h, rgba: px)
    }

    /// BT.471 100/0/75/0 bars over a black-to-white ramp (the bottom third): every scope has something to show.
    static func barsOverRamp(_ w: Int = 160, _ h: Int = 90) -> CanvasImage {
        let bars: [[UInt8]] = [[255, 255, 255], [191, 191, 0], [0, 191, 191], [0, 191, 0], [191, 0, 191], [191, 0, 0], [0, 0, 191], [0, 0, 0]]
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, v = UInt8(x * 255 / (w - 1))
            let c = y < h * 2 / 3 ? bars[x * bars.count / w] : [v, v, v]
            px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]
        } }
        return CanvasImage(width: w, height: h, rgba: px)
    }

    static func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ w: Int = 16, _ h: Int = 9) -> CanvasImage {
        CanvasImage(width: w, height: h, rgba: (0..<(w * h)).flatMap { _ in [r, g, b, 255] })
    }

    func testSeveralScopesShowAtOnceUpToFourAndNeverNone() {
        var s = ScopeSettings()
        XCTAssertEqual(s.kinds, [.waveform, .vectorscope], "waveform beside the vectorscope by default")
        s.toggle(.parade); s.toggle(.histogram)
        XCTAssertEqual(s.kinds, [.waveform, .vectorscope, .parade, .histogram])
        s.toggle(.falseColor)
        XCTAssertEqual(s.kinds, [.vectorscope, .parade, .histogram, .falseColor], "a fifth replaces the oldest")
        for k in [ScopeKind.vectorscope, .parade, .histogram, .falseColor] { s.toggle(k) }
        XCTAssertEqual(s.kinds, [.falseColor], "the last one stays")
    }

    func testGainAndZoomStepThroughTheirValues() {
        var s = ScopeSettings()
        s.stepGain(1); XCTAssertEqual(s.gain, 2)
        s.stepGain(5); XCTAssertEqual(s.gain, 4, "clamped at the brightest")
        s.stepGain(-9); XCTAssertEqual(s.gain, 0.25, "clamped at the dimmest")
        s.cycleZoom(); XCTAssertEqual(s.zoom, 2)
        s.cycleZoom(); XCTAssertEqual(s.zoom, 4)
        s.cycleZoom(); XCTAssertEqual(s.zoom, 1)
    }

    func testOneFillsTheWidthAndMorePairUp() {
        let one = ScopeLayout.tiles([.waveform], x: 0, y: 0, width: 377)
        XCTAssertEqual(one.map(\.rect), [CanvasRect(x: 0, y: 0, width: 377, height: 212)])
        let two = ScopeLayout.tiles([.waveform, .vectorscope], x: 10, y: 5, width: 377)
        XCTAssertEqual(two[0].rect, CanvasRect(x: 10, y: 5, width: 185.5, height: 139), "a row is as tall as its tallest tile")
        XCTAssertEqual(two[1].rect, CanvasRect(x: 201.5, y: 5, width: 185.5, height: 139))
        let three = ScopeLayout.tiles([.waveform, .vectorscope, .histogram], x: 0, y: 0, width: 377)
        XCTAssertEqual(three[2].rect, CanvasRect(x: 0, y: 145, width: 377, height: 212), "a lone last tile spans the width")
        XCTAssertEqual(ScopeLayout.height([.waveform, .vectorscope, .parade, .histogram], width: 377), 139 + 6 + 104)
    }

    func testWaveformTraceDrawsBlackAtTheBottomAndWhiteAtTheTop() throws {
        let frame = try ScopeFrame(width: 64, height: 36, rgba: Self.ramp().rgba)
        let a = ScopeEngine.analyze(frame)
        let img = ScopeTraces.waveform(a, planes: [(.luma, ThemeColor(0xFFFFFF))], gain: 1, size: PixelSize(64, 256))
        XCTAssertEqual(img.width, 64); XCTAssertEqual(img.height, 256)
        XCTAssertGreaterThan(Self.red(img, 0, 255), 200, "column 0 (black) lit on the bottom row")
        XCTAssertGreaterThan(Self.red(img, 63, 0), 200, "column 63 (white) lit on the top row")
        XCTAssertEqual(Self.red(img, 0, 0), 0, "nothing where nothing landed")
        let small = ScopeTraces.waveform(a, planes: [(.luma, ThemeColor(0xFFFFFF))], gain: 1, size: PixelSize(16, 32))
        XCTAssertGreaterThan(Self.red(small, 0, 31), 200, "at a smaller size the cells under a pixel are summed, not dropped")
        XCTAssertGreaterThan(Self.red(small, 15, 0), 200)
        XCTAssertEqual(img.rgba[3], 255, "opaque")
    }

    func testParadeLanesCarryOneChannelEach() throws {
        let a = ScopeEngine.analyze(try ScopeFrame(width: 16, height: 9, rgba: Self.solid(255, 0, 128).rgba))
        let img = ScopeTraces.parade(a, colours: [ThemeColor(0xFF0000), ThemeColor(0x00FF00), ThemeColor(0x0000FF)], gain: 1, size: PixelSize(300, 256))
        let lanes = ScopeTraces.paradeLanes(width: 300)
        XCTAssertEqual(lanes.map(\.count), [98, 98, 98])
        XCTAssertGreaterThan(Self.red(img, lanes[0].lowerBound, 0), 200, "R lane: 255 at the top")
        XCTAssertGreaterThan(img.rgba[(255 * img.width + lanes[1].lowerBound) * 4 + 1], 200, "G lane: 0 at the bottom")
        XCTAssertGreaterThan(img.rgba[((255 - 128) * img.width + lanes[2].lowerBound) * 4 + 2], 200, "B lane: 128 mid-height")
        XCTAssertEqual(img.rgba[(255 * img.width + lanes[0].upperBound) * 4 + 1], 0, "the gap between lanes stays black")
    }

    func testVectorscopeTraceShowsPureBlueOnTheRightEdge() throws {
        let a = ScopeEngine.analyze(try ScopeFrame(width: 16, height: 9, rgba: Self.solid(0, 0, 255).rgba))
        let img = ScopeTraces.vectorscope(a, colour: ThemeColor(0xFFFFFF), gain: 1, size: PixelSize(257, 257))
        XCTAssertEqual(img.width, 257)
        XCTAssertGreaterThan(Self.red(img, 256, 140), 200, "Cb +0.5, Cr -0.0458: the right edge, 12 bins below centre")
        let grey = ScopeEngine.analyze(try ScopeFrame(width: 16, height: 9, rgba: Self.solid(90, 90, 90).rgba))
        let small = ScopeTraces.vectorscope(grey, colour: ThemeColor(0xFFFFFF), gain: 1, size: PixelSize(64, 64))
        XCTAssertGreaterThan(Self.red(small, 32, 32), 200, "a single centre bin stays lit at a smaller size")
    }

    func testTheWorkerAnalysesOffTheDrawThreadAndKeepsOnlyTheNewestFrame() throws {
        let worker = ScopeWorker(), settings = ScopeRequest(settings: ScopeSettings(), sizes: [.waveform: PixelSize(100, 60)])
        worker.queue.suspend()
        let frames = [Self.solid(10, 10, 10), Self.solid(128, 128, 128), Self.solid(250, 250, 250)]
        for f in frames {
            let r = worker.result(for: f, request: settings)
            XCTAssertNil(r.result); XCTAssertFalse(r.current, "a draw never waits for the analysis")
        }
        XCTAssertEqual(worker.analysed, 0)
        worker.queue.resume(); worker.wait()
        XCTAssertEqual(worker.analysed, 1, "only the newest request was analysed")
        let done = try XCTUnwrap(worker.result(for: frames[2], request: settings).result)
        XCTAssertEqual(done.analysis.histogram(.luma, level: 250), 16 * 9)
        XCTAssertEqual(done.traces[.waveform]?.width, 100, "traces are made at the size the row asked for")
        XCTAssertNotNil(done.traces[.vectorscope])
        XCTAssertTrue(worker.result(for: frames[2], request: settings).current)
    }

    func testChangingASettingReanalysesAndResetDropsTheResult() throws {
        let worker = ScopeWorker(), frame = Self.ramp()
        var settings = ScopeRequest(settings: ScopeSettings(), sizes: [:])
        _ = worker.result(for: frame, request: settings); worker.wait()
        settings.settings.toggle(.falseColor)
        let stale = worker.result(for: frame, request: settings)
        XCTAssertNotNil(stale.result, "the last result stays up while the new one is made")
        XCTAssertFalse(stale.current)
        worker.wait()
        let fresh = try XCTUnwrap(worker.result(for: frame, request: settings).result)
        XCTAssertNotNil(fresh.traces[.falseColor])
        worker.reset()
        XCTAssertNil(worker.result(for: frame, request: settings).result)
        worker.wait()
    }

    static func red(_ img: CanvasImage, _ x: Int, _ y: Int) -> UInt8 { img.rgba[(y * img.width + x) * 4] }
}
