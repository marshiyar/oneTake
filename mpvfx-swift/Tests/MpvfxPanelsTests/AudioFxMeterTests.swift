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
#if os(macOS)
import AppKit
#endif
import XCTest
import MpvfxCanvas
import MpvfxTheme
import MpvfxAudioGraph
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Audio FX rack's meters: a gain-reduction bar beside the curve of a compressor, limiter, gate or de-esser, and
/// input and output bars with a number in dB on every module card.
final class AudioFxMeterTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    static func db(_ amplitude: Double) -> Float { Float(pow(10, amplitude / 20)) }

    /// -12 dBFS peak in, -6 dBFS peak out, 13.5 dB of reduction.
    static let reading = FxMeterReading(frame: 0, inputPeak: db(-12), inputRMS: db(-18), outputPeak: db(-6), outputRMS: db(-12),
                                        lowestGain: db(-13.5))

    static func fixture(meters: Bool, type: String = "compressor") throws -> InspectorPanel {
        let node = FxNode(type: type, version: 2, id: "n1", params: AudioFx.defaultParams(type, version: 2))
        let (_, panel) = try AudioFxRackTests.makeFixture(FxChain(nodes: [node]))
        if meters { panel.fxMeterProvider = { owner in owner == "clip:clip:music" || owner == "clip:music" ? FxMeterSnapshot(chain: reading, nodes: [reading]) : nil } }
        return panel
    }

    func drawn(_ panel: InspectorPanel) -> PanelMeasureCanvas {
        let canvas = PanelMeasureCanvas()
        panel.draw(canvas, in: CanvasRect(x: 0, y: 0, width: AudioFxRackTests.width, height: AudioFxRackTests.height))
        return canvas
    }

    func testBarMappingAndPeakHold() {
        XCTAssertEqual(AudioFxMeterBar.level(-60), 0)
        XCTAssertEqual(AudioFxMeterBar.level(-30), 0.5)
        XCTAssertEqual(AudioFxMeterBar.level(0), 1)
        XCTAssertEqual(AudioFxMeterBar.level(6), 1)
        XCTAssertEqual(AudioFxMeterBar.reduction(0), 0)
        XCTAssertEqual(AudioFxMeterBar.reduction(12), 0.5)
        XCTAssertEqual(AudioFxMeterBar.reduction(40), 1)
        XCTAssertEqual(AudioFxMeterBar.readout(-12.04), "-12.0")
        XCTAssertEqual(AudioFxMeterBar.readout(-120), "-inf")
        XCTAssertEqual(AudioFxMeterBar.reductionReadout(13.5), "-13.5")
        XCTAssertEqual(AudioFxMeterBar.reductionReadout(0), "0.0")

        var hold = AudioFxMeterBar.held(nil, value: 6, now: 10)
        XCTAssertEqual(hold, AfxPeakHold(value: 6, at: 10))
        hold = AudioFxMeterBar.held(hold, value: 2, now: 10.5)
        XCTAssertEqual(hold.value, 6, "a smaller reading does not lower the held peak within a second")
        hold = AudioFxMeterBar.held(hold, value: 9, now: 10.6)
        XCTAssertEqual(hold, AfxPeakHold(value: 9, at: 10.6), "a deeper one replaces it at once")
        hold = AudioFxMeterBar.held(hold, value: 2, now: 11.7)
        XCTAssertEqual(hold, AfxPeakHold(value: 2, at: 11.7), "after a second it falls back to the live reading")
    }

    func testRackWithoutMetersIsUnchangedAndMetersAddAStripToEveryCard() throws {
        let plain = try Self.fixture(meters: false)
        let metered = try Self.fixture(meters: true)
        let plainRows = drawn(plain).drawnStrings
        XCTAssertFalse(plainRows.contains("GR"))
        XCTAssertFalse(plainRows.contains("In"))
        let texts = drawn(metered).drawnStrings
        for expected in ["In", "Out", "-12.0", "-6.0", "GR", "-13.5"] { XCTAssertTrue(texts.contains(expected), "\(expected) in \(texts)") }
    }

    func testEveryDynamicsModuleShowsAGainReductionBarAndAFilterDoesNot() throws {
        for type in ["compressor", "limiter", "gate", "deesser"] {
            let texts = drawn(try Self.fixture(meters: true, type: type)).drawnStrings
            XCTAssertTrue(texts.contains("GR"), "\(type) has a gain-reduction bar")
            XCTAssertTrue(texts.contains("-13.5"), "\(type) reads the reduction")
        }
        for type in ["peaking", "gain", "delay"] {
            let texts = drawn(try Self.fixture(meters: true, type: type)).drawnStrings
            XCTAssertFalse(texts.contains("GR"), "\(type) has no gain-reduction bar")
            XCTAssertTrue(texts.contains("In") && texts.contains("Out"), "\(type) still shows its input and output")
        }
    }

    func testBypassedAndStoppedModulesShowNoReading() throws {
        let panel = try Self.fixture(meters: true)
        panel.fxMeterProvider = { _ in nil }
        let texts = drawn(panel).drawnStrings
        XCTAssertTrue(texts.contains("In"))
        XCTAssertFalse(texts.contains("-12.0"), "stopped playback leaves the bars empty")
        XCTAssertEqual(InspectorPanel.afxMeterIndex(FxChain(nodes: [FxNode(type: "gain", enabled: false), FxNode(type: "delay")]), 1), 0,
                       "meters count enabled modules only")
        XCTAssertNil(InspectorPanel.afxMeterIndex(FxChain(nodes: [FxNode(type: "gain", enabled: false)]), 0))
    }

    /// The bars in both palettes: filled in the accent, and in the danger colour when a peak is within 1 dB of full scale.
    func testBarsAreDrawnInDarkAndLightAtOneAndTwoTimes() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            let hot = FxMeterReading(frame: 0, inputPeak: Self.db(-0.5), inputRMS: Self.db(-6), outputPeak: Self.db(-12), outputRMS: Self.db(-18),
                                     lowestGain: Self.db(-6))
            let panel = try Self.fixture(meters: true)
            panel.fxMeterProvider = { _ in FxMeterSnapshot(chain: hot, nodes: [hot]) }
            let canvas = drawn(panel)
            XCTAssertTrue(canvas.fills.contains { $0.1 == PanelTheme.danger.withAlpha(0.6) }, "\(mode) hot input bar")
            XCTAssertTrue(canvas.fills.contains { $0.1 == PanelTheme.accent.withAlpha(0.6) }, "\(mode) output bar")
            XCTAssertTrue(canvas.fills.contains { $0.1 == PanelTheme.accent }, "\(mode) gain-reduction bar")
            #if os(macOS)
            for scale in [1.0, 2.0] {
                let w = Int(AudioFxRackTests.width * scale), h = Int(700 * scale)
                let target = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: w, height: h))
                target.scale(scale, scale)
                target.fillRect(CanvasRect(x: 0, y: 0, width: AudioFxRackTests.width, height: 700), PanelTheme.studioBg)
                panel.draw(target, in: CanvasRect(x: 0, y: 0, width: AudioFxRackTests.width, height: 700))
                let image = try XCTUnwrap(target.ctx.makeImage())
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                if let output = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("audio-fx-meters-\(mode.rawValue)-\(Int(scale))x.png"))
                }
            }
            #endif
        }
    }
}
