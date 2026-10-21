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
        let img = ScopeTraces.waveform(a, planes: [(.luma, .init(0xFFFFFF))], gain: 1)
        XCTAssertEqual(img.width, 64); XCTAssertEqual(img.height, 256)
        XCTAssertGreaterThan(Self.red(img, 0, 255), 200, "column 0 (black) lit on the bottom row")
        XCTAssertGreaterThan(Self.red(img, 63, 0), 200, "column 63 (white) lit on the top row")
        XCTAssertEqual(Self.red(img, 0, 0), 0, "nothing where nothing landed")
        XCTAssertEqual(img.rgba[3], 255, "opaque")
    }

    func testParadeLanesCarryOneChannelEach() throws {
        let a = ScopeEngine.analyze(try ScopeFrame(width: 16, height: 9, rgba: Self.solid(255, 0, 128).rgba))
        let img = ScopeTraces.parade(a, colours: [.init(0xFF0000), .init(0x00FF00), .init(0x0000FF)], gain: 1)
        let lane = a.columns, gap = max(2, lane / 32)
        XCTAssertEqual(img.width, 3 * lane + 2 * gap)
        XCTAssertGreaterThan(Self.red(img, 0, 0), 200, "R lane: 255 at the top")
        XCTAssertGreaterThan(img.rgba[((255) * img.width + lane + gap) * 4 + 1], 200, "G lane: 0 at the bottom")
        XCTAssertGreaterThan(img.rgba[((255 - 128) * img.width + 2 * (lane + gap)) * 4 + 2], 200, "B lane: 128 mid-height")
    }

    func testVectorscopeTraceShowsPureBlueOnTheRightEdge() throws {
        let a = ScopeEngine.analyze(try ScopeFrame(width: 16, height: 9, rgba: Self.solid(0, 0, 255).rgba))
        let img = ScopeTraces.vectorscope(a, colour: .init(0xFFFFFF), gain: 1)
        XCTAssertEqual(img.width, 257)
        XCTAssertGreaterThan(Self.red(img, 256, 140), 200, "Cb +0.5, Cr -0.0458: the right edge, 12 bins below centre")
    }

    func testTheWorkerAnalysesOffTheDrawThreadAndKeepsOnlyTheNewestFrame() throws {
        let worker = ScopeWorker(), settings = ScopeSettings()
        worker.queue.suspend()
        let frames = [Self.solid(10, 10, 10), Self.solid(128, 128, 128), Self.solid(250, 250, 250)]
        for f in frames {
            let r = worker.result(for: f, settings: settings)
            XCTAssertNil(r.result); XCTAssertFalse(r.current, "a draw never waits for the analysis")
        }
        XCTAssertEqual(worker.analysed, 0)
        worker.queue.resume(); worker.wait()
        XCTAssertEqual(worker.analysed, 1, "only the newest request was analysed")
        let done = try XCTUnwrap(worker.result(for: frames[2], settings: settings).result)
        XCTAssertEqual(done.analysis.histogram(.luma, level: 250), 16 * 9)
        XCTAssertNotNil(done.traces[.waveform]); XCTAssertNotNil(done.traces[.vectorscope])
        XCTAssertTrue(worker.result(for: frames[2], settings: settings).current)
    }

    func testChangingASettingReanalysesAndResetDropsTheResult() throws {
        let worker = ScopeWorker(), frame = Self.ramp()
        var settings = ScopeSettings()
        _ = worker.result(for: frame, settings: settings); worker.wait()
        settings.toggle(.falseColor)
        let stale = worker.result(for: frame, settings: settings)
        XCTAssertNotNil(stale.result, "the last result stays up while the new one is made")
        XCTAssertFalse(stale.current)
        worker.wait()
        let fresh = try XCTUnwrap(worker.result(for: frame, settings: settings).result)
        XCTAssertNotNil(fresh.traces[.falseColor])
        worker.reset()
        XCTAssertNil(worker.result(for: frame, settings: settings).result)
        worker.wait()
    }

    static func red(_ img: CanvasImage, _ x: Int, _ y: Int) -> UInt8 { img.rgba[(y * img.width + x) * 4] }
}
