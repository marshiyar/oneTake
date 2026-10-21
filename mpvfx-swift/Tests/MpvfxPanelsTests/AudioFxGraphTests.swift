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
import MpvfxTheme
import MpvfxAudioGraph
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The rack's pictures and their handles: a filter module and the Tone EQ draw the response the DSP makes and drag it;
/// a compressor, limiter or gate draws its static curve; numbers read with their precision, sign and unit.
final class AudioFxGraphTests: XCTestCase {
    func chain(_ e: TimelineEditor) -> FxChain {
        (e.clip("clip:music")?.clip.audioFxChain).flatMap { try? AudioFx.parseChain($0) } ?? FxChain()
    }
    func single(_ type: String, _ values: [String: Double]) -> FxChain {
        var p = FxParams(); for (k, v) in values { p[k] = .number(v) }
        return FxChain(nodes: [FxNode(type: type, id: "n1", params: AudioFx.normalize(type, p))])
    }
    @discardableResult
    func draw(_ p: InspectorPanel) -> PanelMeasureCanvas {
        let c = PanelMeasureCanvas()
        p.draw(c, in: CanvasRect(x: 0, y: 0, width: AudioFxRackTests.width, height: AudioFxRackTests.height))
        return c
    }
    /// Drags handle `handle` of graph `row` to the point the graph maps `frequency` / `gain` to, and releases.
    func drag(_ p: InspectorPanel, row: String, handle: Int, to frequency: Double, _ gain: Double) throws {
        draw(p)
        let h = try XCTUnwrap(p.hits.rect { $0 == .custom(row, handle) }, "no handle \(handle) on \(row)")
        let g = try XCTUnwrap(p.audioFxUI.graphBoxes[row])
        XCTAssertTrue(p.pointerDown(CanvasPoint(h.midX, h.midY)))
        let to = CanvasPoint(AfxGraphScale.x(frequency, in: g.box), AfxGraphScale.y(gain, range: g.range, in: g.box))
        _ = p.pointerMove(to)
        XCTAssertNotNil(p.audioFxUI.graphDrag, "the drag is in flight")
        draw(p)   // the curve follows the pointer before the commit
        p.pointerUp(to)
        XCTAssertNil(p.audioFxUI.graphDrag)
    }

    func testBellModuleDrawsItsResponseAndTheHandleSetsFrequencyAndGain() throws {
        let (editor, p) = try AudioFxRackTests.makeFixture(single("peaking", ["frequency": 1000, "gain": 0, "q": 1]))
        draw(p)   // the rack seeds its UI state for this clip on its first draw
        p.audioFxUI.openNode = 0
        try drag(p, row: "afx:node:0", handle: 1, to: 2500, 6)
        let params = try XCTUnwrap(chain(editor).nodes.first?.params)
        XCTAssertEqual(params.num("frequency"), 2500, accuracy: 1)
        XCTAssertEqual(params.num("gain"), 6, accuracy: 0.11)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(chain(editor).nodes.first?.params?.num("frequency"), 1000, "one drag, one undo step")
    }

    func testCutFilterHandleMovesOnlyItsCorner() throws {
        let (editor, p) = try AudioFxRackTests.makeFixture(single("highpass", ["frequency": 300]))
        draw(p)   // the rack seeds its UI state for this clip on its first draw
        p.audioFxUI.openNode = 0
        try drag(p, row: "afx:node:0", handle: 1, to: 120, 9)
        let params = try XCTUnwrap(chain(editor).nodes.first?.params)
        XCTAssertEqual(params.num("frequency"), 120, accuracy: 1)
        XCTAssertNil(params["gain"], "a cut filter has no gain to drag")
    }

    func testToneEqGraphHandlesSetTheBandGains() throws {
        let (eqChain, eqId) = AudioEq.add(FxChain())
        let (editor, p) = try AudioFxRackTests.makeFixture(eqChain)
        draw(p)
        p.audioFxUI.openEq = eqId
        try drag(p, row: "afx:eq:\(eqId)", handle: 1, to: 200, 6)
        let bass = try XCTUnwrap(AudioEq.readBands(chain(editor), eqId: eqId).first { $0.name == "Bass" })
        XCTAssertEqual(bass.gain, 6, accuracy: 0.26, "a band moves in the faders' 0.5 dB steps")
        XCTAssertEqual(bass.frequency, 200, "the Tone bands keep their frequencies")
    }

    func testDynamicsModulesDrawTheirStaticCurve() throws {
        for (type, values, mark) in [("compressor", ["threshold": -24.0, "ratio": 4], "-24"), ("limiter", ["limit": -3.0], "-3"),
                                     ("gate", ["threshold": -40.0], "-40")] {
            let (_, p) = try AudioFxRackTests.makeFixture(single(type, values))
            draw(p)   // the rack seeds its UI state for this clip on its first draw
            p.audioFxUI.openNode = 0
            p.audioFxUI.details.insert("n1")
            let t = draw(p).texts.map(\.0)
            XCTAssertTrue(t.contains("in") && t.contains("out") && t.contains(mark), "\(type): \(t)")
        }
    }

    /// Every parameter row of a module lines up: the field and the slider's end sit at the same x whether the knob has
    /// a unit (dB, ms, :1) or none (knee, mix).
    func testControlsLineUpWhateverTheirUnit() throws {
        let (_, p) = try AudioFxRackTests.makeFixture(single("compressor", [:]))
        draw(p)
        p.audioFxUI.openNode = 0
        p.audioFxUI.details.insert("n1")
        draw(p)
        let keys = ["threshold", "ratio", "attack", "release", "knee", "makeup", "mix"]
        let fields = try keys.map { k in try XCTUnwrap(p.hits.rect { $0 == .field("fx:0:\(k)") }, k) }
        let sliders = try keys.map { k in try XCTUnwrap(p.hits.rect { $0 == .slider("fx:0:\(k)") }, k) }
        XCTAssertEqual(Set(fields.map(\.x)).count, 1, "fields at \(fields.map(\.x))")
        XCTAssertEqual(Set(sliders.map(\.maxX)).count, 1, "slider ends at \(sliders.map(\.maxX))")
    }

    func testBypassedModuleGraphIsNotAControl() throws {
        var c = single("peaking", ["frequency": 1000, "gain": 3, "q": 1])
        c.nodes[0].enabled = false
        let (_, p) = try AudioFxRackTests.makeFixture(c)
        draw(p)   // the rack seeds its UI state for this clip on its first draw
        p.audioFxUI.openNode = 0
        draw(p)
        XCTAssertNil(p.hits.rect { $0 == .custom("afx:node:0", 1) })
    }

    func testValuesReadWithTheirPrecisionSignAndUnit() {
        XCTAssertEqual(AfxValueFormat.text(0.05, key: "attack", step: 0.1), "0.05")
        XCTAssertEqual(AfxValueFormat.text(0.5, key: "release", step: 1), "0.50")
        XCTAssertEqual(AfxValueFormat.text(250, key: "release", step: 1), "250")
        XCTAssertEqual(AfxValueFormat.text(3, key: "gain", step: 0.1), "+3.0")
        XCTAssertEqual(AfxValueFormat.text(-24, key: "threshold", step: 0.5), "-24.0")
        XCTAssertEqual(AfxValueFormat.text(0, key: "gain", step: 0.1), "0.0")
        let typed: [(String, Double?)] = [("1.2k", 1200), ("1.2 kHz", 1200), ("250 Hz", 250), ("-3 dB", -3), ("−3dB", -3),
                                          ("12 ms", 12), ("4:1", 4), ("+5 st", 5), ("8 bit", 8), ("4x", 4), ("0.6", 0.6),
                                          ("", nil), ("abc", nil), ("1e999", nil)]
        for (s, v) in typed { XCTAssertEqual(AfxValueFormat.parse(s), v, s) }
    }

    func testANumberFieldTakesAValueWithItsUnit() throws {
        let (editor, p) = try AudioFxRackTests.makeFixture(single("peaking", ["frequency": 1000, "gain": 0, "q": 1]))
        draw(p)   // the rack seeds its UI state for this clip on its first draw
        p.audioFxUI.openNode = 0
        p.audioFxUI.details.insert("n1")
        draw(p)
        let field = try XCTUnwrap(p.hits.rect { $0 == .field("fx:0:frequency") })
        XCTAssertTrue(p.pointerDown(CanvasPoint(field.midX, field.midY))); p.pointerUp(CanvasPoint(field.midX, field.midY))
        for _ in 0..<8 { _ = p.keyDown(EditorKey(.backspace)) }
        for ch in "2.5k" { _ = p.keyDown(EditorKey(.char(ch))) }
        _ = p.keyDown(EditorKey(.enter))
        XCTAssertEqual(chain(editor).nodes.first?.params?.num("frequency") ?? 0, 2500, accuracy: 1e-9)
    }
}

#if os(Linux)   // Cairo pixels
final class AudioFxGraphSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func render(_ p: InspectorPanel, _ name: String, scale: Double) -> CairoImageTarget {
        let w = AudioFxRackTests.width, h = 900.0
        let t = CairoImageTarget(width: Int(w * scale), height: Int(h * scale))
        t.canvas.scale(scale, scale)
        p.draw(t.canvas, in: CanvasRect(x: 0, y: 0, width: w, height: h))
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name)-\(Int(scale))x.png"), 0)
        }
        return t
    }
    func color(_ t: CairoImageTarget, _ x: Double, _ y: Double, _ scale: Double) -> CanvasColor {
        let p = t.pixel(Int(x * scale), Int(y * scale))
        return CanvasColor(r: Double(p.r) / 255, g: Double(p.g) / 255, b: Double(p.b) / 255)
    }
    func near(_ a: CanvasColor, _ b: CanvasColor, tol: Double) -> Bool {
        abs(a.r - b.r) * 255 <= tol && abs(a.g - b.g) * 255 <= tol && abs(a.b - b.b) * 255 <= tol
    }

    /// A +6 dB bell at 1 kHz and a compressor, each open in turn, in both appearances at 1x and 2x: the bell's point
    /// sits on its frequency and gain in the accent.
    func testGraphsInDarkAndLight() throws {
        let bell = AudioFx.normalize("peaking", FxParams([("frequency", .number(1000)), ("gain", .number(6)), ("q", .number(1))]))
        let chain = FxChain(nodes: [FxNode(type: "peaking", id: "n1", params: bell),
                                    FxNode(type: "compressor", id: "n2", params: AudioFx.defaultParams("compressor"))])
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            for scale in [1.0, 2.0] {
                let (_, p) = try AudioFxRackTests.makeFixture(chain)
                _ = render(p, "audiofx-graph-seed", scale: 1)   // the rack seeds its UI state for this clip on its first draw
                p.audioFxUI.openNode = 0
                let t = render(p, "audiofx-graph-\(mode.rawValue)", scale: scale)
                let g = try XCTUnwrap(p.audioFxUI.graphBoxes["afx:node:0"])
                let x = AfxGraphScale.x(1000, in: g.box), y = AfxGraphScale.y(6, range: g.range, in: g.box)
                XCTAssertTrue(near(color(t, x, y, scale), PanelTheme.accent, tol: 24), "\(mode) \(scale)x: the point is the accent")
                p.audioFxUI.openNode = 1
                p.audioFxUI.details.insert("n2")
                _ = render(p, "audiofx-transfer-\(mode.rawValue)", scale: scale)
            }
        }
    }
}
#endif
