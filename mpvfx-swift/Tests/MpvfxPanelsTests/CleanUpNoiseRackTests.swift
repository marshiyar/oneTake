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
import XCTest
import MpvfxCanvas
import MpvfxAudioGraph
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// Clean up noise in the Audio FX rack (issue #312, A4): every control can be reached and used from the keyboard.
final class CleanUpNoiseRackTests: XCTestCase {
    func chain(_ e: TimelineEditor) -> FxChain {
        (e.clip("clip:music")?.clip.audioFxChain).flatMap { try? AudioFx.parseChain($0) } ?? FxChain()
    }

    func testA4LearnFromListenAndLearnAreEachOperableWithoutAPointer() throws {
        let node = FxNode(type: "denoise", id: "n1", params: AudioFx.defaultParams("denoise"))
        let (editor, p) = try AudioFxRackTests.makeFixture(FxChain(nodes: [node]))
        var asked: [String] = []
        p.onLearnNoise = { clip, index, source in asked.append("\(clip) \(index) \(source)") }
        func draw() { p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 4000)) }
        draw()
        let open = try XCTUnwrap(p.hits.rect { $0 == .button("fx:0:open") })
        XCTAssertTrue(p.pointerDown(CanvasPoint(open.midX, open.midY))); p.pointerUp(CanvasPoint(open.midX, open.midY))
        draw()
        func press(_ key: String) throws {
            draw()
            XCTAssertNotNil(p.hits.rect { $0 == .button(key) }, "\(key) is on screen")
            p.focus.current = .button(key); p.focus.visible = true
            XCTAssertTrue(p.keyDown(EditorKey(.space)), key)
        }
        XCTAssertEqual(chain(editor).nodes[0].params?["learn_source"]?.string, "quietest")
        try press("fx:0:learn_source")
        XCTAssertEqual(chain(editor).nodes[0].params?["learn_source"]?.string, "range")
        try press("fx:0:listen")
        XCTAssertEqual(chain(editor).nodes[0].params?["listen"]?.string, "on")
        try press("fx:0:learn")
        XCTAssertEqual(asked, ["clip:music 0 range"])
    }

    func testLearnIsOfferedOnlyWhereTheHostCanLearn() throws {
        let node = FxNode(type: "denoise", id: "n1", params: AudioFx.defaultParams("denoise"))
        let (_, p) = try AudioFxRackTests.makeFixture(FxChain(nodes: [node]))
        let open = { () throws -> Void in
            p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 4000))
            let r = try XCTUnwrap(p.hits.rect { $0 == .button("fx:0:open") })
            _ = p.pointerDown(CanvasPoint(r.midX, r.midY)); p.pointerUp(CanvasPoint(r.midX, r.midY))
            p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 4000))
        }
        try open()
        XCTAssertNil(p.hits.rect { $0 == .button("fx:0:learn") }, "no host, no Learn")
        var learned = node
        learned.noiseProfile = [Double](repeating: -50, count: NoiseProfile.bins)
        let (_, q) = try AudioFxRackTests.makeFixture(FxChain(nodes: [learned]))
        q.onLearnNoise = { _, _, _ in }
        let canvas = PanelMeasureCanvas()
        q.draw(canvas, in: CanvasRect(x: 0, y: 0, width: 409, height: 4000))
        let r = try XCTUnwrap(q.hits.rect { $0 == .button("fx:0:open") })
        _ = q.pointerDown(CanvasPoint(r.midX, r.midY)); q.pointerUp(CanvasPoint(r.midX, r.midY))
        let shown = PanelMeasureCanvas()
        q.draw(shown, in: CanvasRect(x: 0, y: 0, width: 409, height: 4000))
        XCTAssertTrue(shown.texts.map(\.0).contains("Learn again"))
        XCTAssertNotNil(q.hits.rect { $0 == .button("fx:0:learn") })
    }
}
