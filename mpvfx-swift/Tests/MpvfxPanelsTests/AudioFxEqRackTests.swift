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
import MpvfxAudioGraph
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The parametric EQ in the rack: every band is a point on the graph, dragged for frequency and gain (one undo
/// step), Alt-dragged or wheeled for Q, added by a double-click, removed by Delete, and reachable without a pointer.
final class AudioFxEqRackTests: XCTestCase {
    let row = "afx:node:0"

    func chain(_ e: TimelineEditor) -> FxChain {
        (e.clip("clip:music")?.clip.audioFxChain).flatMap { try? AudioFx.parseChain($0) } ?? FxChain()
    }
    /// Settings as written in a test: numbers and strings by key.
    func eqChain(_ values: [String: Any] = [:]) -> FxChain {
        let json = values.mapValues { v in (v as? String).map(JSONValue.string) ?? .number((v as? Double) ?? Double((v as? Int) ?? 0)) }
        return FxChain(nodes: [FxNode(type: "eq", version: 2, id: "n1", params: AudioFx.normalize("eq", json, version: 2))])
    }
    func normalized(_ values: [String: Any]) -> FxParams { eqChain(values).nodes[0].params ?? FxParams() }
    func params(_ e: TimelineEditor) throws -> FxParams { try XCTUnwrap(chain(e).nodes.first?.params) }

    @discardableResult
    func draw(_ p: InspectorPanel) -> PanelMeasureCanvas {
        let c = PanelMeasureCanvas()
        p.draw(c, in: CanvasRect(x: 0, y: 0, width: AudioFxRackTests.width, height: AudioFxRackTests.height))
        return c
    }
    func open(_ chain: FxChain) throws -> (TimelineEditor, InspectorPanel) {
        let (editor, p) = try AudioFxRackTests.makeFixture(chain)
        draw(p)
        p.audioFxUI.openNode = 0
        draw(p)
        return (editor, p)
    }
    func plotPoint(_ p: InspectorPanel, frequency: Double, gain: Double) throws -> CanvasPoint {
        let g = try XCTUnwrap(p.audioFxUI.graphBoxes[row])
        return CanvasPoint(AfxGraphScale.x(frequency, in: g.box), AfxGraphScale.y(gain, range: g.range, in: g.box))
    }
    /// Presses band handle `part`, moves to `to`, releases.
    func drag(_ p: InspectorPanel, part: Int, to: CanvasPoint, alt: Bool = false) throws {
        let h = try XCTUnwrap(p.hits.rect { $0 == .custom(row, part) }, "no handle \(part)")
        p.pointerModifiers = alt ? [.alt] : []
        XCTAssertTrue(p.pointerDown(CanvasPoint(h.midX, h.midY)))
        _ = p.pointerMove(to)
        draw(p)
        p.pointerUp(to)
        p.pointerModifiers = []
        draw(p)
    }

    /// A key on focused point `part`, on the rack as it draws now (the handlers read the chain they were built from).
    func key(_ p: InspectorPanel, part: Int, _ k: EditorKey) throws -> Bool {
        draw(p)
        return try XCTUnwrap(p.customRow(row)?.keyPress)(part, k)
    }

    func testEveryActiveBandIsAPointAndABypassedOneIsNot() throws {
        let (_, p) = try open(eqChain(["bands": 4, "band2.bypass": "on"]))
        XCTAssertNotNil(p.hits.rect { $0 == .custom(self.row, 1) })
        XCTAssertNotNil(p.hits.rect { $0 == .custom(self.row, 2) }, "three active bands: points 1 to 3")
        XCTAssertNotNil(p.hits.rect { $0 == .custom(self.row, 3) })
        XCTAssertNil(p.hits.rect { $0 == .custom(self.row, 4) })
        XCTAssertEqual(InspectorPanel.afxEqHandles(eqChain(["bands": 4, "band2.bypass": "on"]).nodes[0], 0).map(\.bandNumber), [1, 3, 4])
    }

    func testDraggingABandSetsFrequencyAndGainInOneUndoStep() throws {
        let (editor, p) = try open(eqChain(["bands": 3, "band2.freq": 400, "band2.gain": 0]))
        let before = editor.undoStack.count
        try drag(p, part: 2, to: try plotPoint(p, frequency: 1800, gain: 7))
        let q = try params(editor)
        XCTAssertEqual(q.num("band2.freq"), 1800, accuracy: 1)
        XCTAssertEqual(q.num("band2.gain"), 7, accuracy: 0.11)
        XCTAssertEqual(q.num("band1.freq"), 100, "the other bands stay put")
        XCTAssertEqual(editor.undoStack.count, before + 1, "one drag, one undo step")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(try params(editor).num("band2.freq"), 400)
        XCTAssertEqual(p.audioFxUI.selectedBand, 2, "the dragged band is the one whose settings show")
    }

    func testCutBandMovesOnlyItsFrequency() throws {
        let (editor, p) = try open(eqChain(["bands": 1, "band1.type": "lowcut", "band1.freq": 80]))
        try drag(p, part: 1, to: try plotPoint(p, frequency: 150, gain: 9))
        let q = try params(editor)
        XCTAssertEqual(q.num("band1.freq"), 150, accuracy: 1)
        XCTAssertEqual(q.num("band1.gain"), 0, "a cut has no gain to drag")
    }

    func testAltDragSetsQAndLeavesFrequencyAndGain() throws {
        let (editor, p) = try open(eqChain(["bands": 2, "band2.freq": 1000, "band2.gain": 5, "band2.q": 1]))
        let before = editor.undoStack.count
        let h = try XCTUnwrap(p.hits.rect { $0 == .custom(self.row, 2) })
        try drag(p, part: 2, to: CanvasPoint(h.midX + 30, h.midY - 40), alt: true)   // up: narrower
        let q = try params(editor)
        XCTAssertEqual(q.num("band2.q"), 2, accuracy: 0.05, "40 points up doubles Q")
        XCTAssertEqual(q.num("band2.freq"), 1000)
        XCTAssertEqual(q.num("band2.gain"), 5)
        XCTAssertEqual(editor.undoStack.count, before + 1)
        try drag(p, part: 2, to: CanvasPoint(h.midX, h.midY + 400), alt: true)
        XCTAssertEqual(try params(editor).num("band2.q"), 0.1, "Q stops at the registry's floor")
    }

    func testShelfHasNoQ() throws {
        let node = eqChain(["bands": 1, "band1.type": "lowshelf", "band1.freq": 200, "band1.gain": 4]).nodes[0]
        let handle = try XCTUnwrap(InspectorPanel.afxEqHandles(node, 0).first)
        XCTAssertNil(handle.q)
        XCTAssertNil(handle.qKey)
        let (editor, p) = try open(eqChain(["bands": 1, "band1.type": "lowshelf", "band1.freq": 200, "band1.gain": 4]))
        XCTAssertTrue(try key(p, part: 1, EditorKey(.up, alt: true)), "Alt+Up has nothing to change on a shelf and is absorbed")
        XCTAssertEqual(try params(editor).num("band1.q"), 0.707, accuracy: 0.001)
        XCTAssertEqual(try params(editor).num("band1.gain"), 4, accuracy: 0.001)
    }

    func testDoubleClickOnThePlotAddsABandAndDeleteRemovesIt() throws {
        let (editor, p) = try open(eqChain(["bands": 3]))
        var now = 100.0
        p.fxGestureNow = { now }
        let at = try plotPoint(p, frequency: 1500, gain: 8)
        let before = editor.undoStack.count
        for _ in 0..<2 {
            XCTAssertTrue(p.pointerDown(at)); p.pointerUp(at); now += 0.1
        }
        let q = try params(editor)
        XCTAssertEqual(q.num("bands"), 4)
        XCTAssertEqual(q.num("band4.freq"), 1500, accuracy: 20)
        XCTAssertEqual(q.num("band4.gain"), 8, accuracy: 0.5)
        XCTAssertEqual(q["band4.type"]?.string, "bell")
        XCTAssertEqual(editor.undoStack.count, before + 1, "adding a band is one undo step")
        XCTAssertEqual(p.audioFxUI.selectedBand, 4)
        // Delete on the focused point removes that band; the ones after move up.
        XCTAssertTrue(try key(p, part: 2, EditorKey(.delete)))
        let r = try params(editor)
        XCTAssertEqual(r.num("bands"), 3)
        XCTAssertEqual(r.num("band2.freq"), 2500, "band 3 moved up into place 2")
        XCTAssertEqual(r.num("band3.freq"), 1500, accuracy: 20, "and the new band after it")
        XCTAssertEqual(r.num("band4.gain"), 0, "the freed band returns to its defaults")
    }

    func testTwoSlowClicksOrTwoFarApartDoNotAddABand() throws {
        let (editor, p) = try open(eqChain(["bands": 3]))
        var now = 100.0
        p.fxGestureNow = { now }
        let at = try plotPoint(p, frequency: 1500, gain: 8)
        _ = p.pointerDown(at); p.pointerUp(at); now += 1
        _ = p.pointerDown(at); p.pointerUp(at)
        let far = try plotPoint(p, frequency: 5000, gain: 8)
        now += 0.1
        _ = p.pointerDown(far); p.pointerUp(far)
        XCTAssertEqual(try params(editor).num("bands"), 3)
    }

    func testBandCountStopsAtEightAndAtOne() throws {
        XCTAssertNil(InspectorPanel.afxEqAddingBand(normalized(["bands": 8]), frequency: 1000, gain: 0))
        XCTAssertNil(InspectorPanel.afxEqRemovingBand(normalized(["bands": 1]), band: 1))
        let seven = normalized(["bands": 7])
        XCTAssertEqual(InspectorPanel.afxEqAddingBand(seven, frequency: 1000, gain: 0)?.num("bands"), 8)
    }

    func testBandStripPicksAddsAndRemovesBands() throws {
        let (editor, p) = try open(eqChain(["bands": 3]))
        XCTAssertTrue(p.press(.button("fx:0:band:2")))
        XCTAssertEqual(p.audioFxUI.selectedBand, 2)
        let t = draw(p).texts.map(\.0)
        XCTAssertTrue(t.contains("[2]"), "the picked band is bracketed: \(t)")
        XCTAssertTrue(p.press(.button("fx:0:band-add")))
        XCTAssertEqual(try params(editor).num("bands"), 4)
        XCTAssertEqual(p.audioFxUI.selectedBand, 4)
        draw(p)
        XCTAssertTrue(p.press(.button("fx:0:band-remove")))
        XCTAssertEqual(try params(editor).num("bands"), 3)
    }

    func testOnlyThePickedBandsSettingsAreListed() throws {
        let (_, p) = try open(eqChain(["bands": 3, "band2.type": "lowcut"]))
        p.audioFxUI.selectedBand = 2
        draw(p)
        XCTAssertNotNil(p.hits.rect { $0 == .slider("fx:0:band2.freq") })
        XCTAssertNotNil(p.hits.rect { $0 == .slider("fx:0:band2.q") })
        XCTAssertNil(p.hits.rect { $0 == .slider("fx:0:band2.gain") }, "a cut has no gain")
        XCTAssertNil(p.hits.rect { $0 == .slider("fx:0:band3.freq") }, "other bands stay out of the list")
        XCTAssertEqual(InspectorPanel.afxEqShownKeys(normalized(["bands": 2, "band2.type": "lowcut"]), selected: 2),
                       ["bands", "band2.type", "band2.freq", "band2.bypass", "band2.q", "band2.slope"])
    }

    func testEveryBandIsReachableAndMovableFromTheKeyboard() throws {
        let (editor, p) = try open(eqChain(["bands": 4, "band3.freq": 2000, "band3.gain": 0, "band3.q": 1]))
        for part in 1...4 { XCTAssertNotNil(p.hits.rect { $0 == .custom(self.row, part) }, "band \(part) has a focusable point") }
        XCTAssertTrue(try key(p, part: 3, EditorKey(.up)))
        XCTAssertEqual(try params(editor).num("band3.gain"), 0.5, accuracy: 0.001)
        XCTAssertTrue(try key(p, part: 3, EditorKey(.down, shift: true)))
        XCTAssertEqual(try params(editor).num("band3.gain"), -2.5, accuracy: 0.001)
        XCTAssertTrue(try key(p, part: 3, EditorKey(.right)))
        XCTAssertEqual(try params(editor).num("band3.freq"), 2000 * pow(2, 1.0 / 12), accuracy: 1)
        XCTAssertTrue(try key(p, part: 3, EditorKey(.up, alt: true)))
        XCTAssertEqual(try params(editor).num("band3.q"), pow(2, 0.25), accuracy: 0.01)
        XCTAssertEqual(p.audioFxUI.selectedBand, 3)
        XCTAssertFalse(try key(p, part: 3, EditorKey(.char("x"))))
    }

    func testWheelNotchChangesTheNearestBandsQ() throws {
        let (editor, p) = try open(eqChain(["bands": 3, "band2.freq": 400, "band2.q": 1, "band3.freq": 2500]))
        let at = try plotPoint(p, frequency: 450, gain: 3)
        XCTAssertEqual(p.fxGraphWheel.count, 1, "the open EQ graph registers its wheel step")
        XCTAssertTrue(p.fxGraphWheel.values.first?.box.contains(at) ?? false, "and the pointer is over its plot")
        XCTAssertTrue(p.scroll(at, dy: -53))
        let q = try params(editor)
        XCTAssertEqual(q.num("band2.q"), pow(2, 53.0 * 40 / 212 / 40), accuracy: 0.02, "a notch up narrows the nearest band")
        XCTAssertEqual(q.num("band3.q"), 1)
        let narrowed = q.num("band2.q")
        _ = p.scroll(at, dy: -3, precise: true)
        XCTAssertEqual(try params(editor).num("band2.q"), narrowed, "trackpad deltas scroll the panel instead")
    }

    func testTheOpenEqModuleAsksForItsSpectrumAndClosedOnesDoNot() throws {
        let (_, p) = try AudioFxRackTests.makeFixture(eqChain())
        var asked: [String] = []
        p.audioFxSpectrumProvider = { owner, node in
            asked.append("\(owner)/\(node)")
            return (0..<60).map { _ in Float(-40) }
        }
        draw(p)   // seeds the rack's state
        p.audioFxUI.openNode = nil
        asked = []
        draw(p)
        XCTAssertTrue(asked.isEmpty, "a closed module draws no graph: \(asked)")
        p.audioFxUI.openNode = 0
        draw(p)
        XCTAssertTrue(asked.contains("clip:clip:music/0"), "\(asked)")
    }
}
