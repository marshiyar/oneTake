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
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
@testable import MpvfxPanels

/// Issue #170 A4: the Effects catalog grid reserves the height its tiles take at the width the body draws at, so on
/// a narrow (280 pt minimum) or wide (40% of a 1440 pt window) right panel the last tile row ends where the group's
/// next row would start, as at the default width. Before the fix the height was computed for a fixed 375 pt body.
final class EffectGridWidthTests: XCTestCase {
    /// Distance from the last catalog tile's bottom to the next group header's top, at panel width `w`.
    func gapBelowTheGrid(width w: Double) throws -> Double {
        let p = InspectorPanel()
        p.editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        p.selection = ["clip:a"]; p.time = 1
        if p.openGroupId != "effects" { p.toggleGroup("effects") }
        p.effectsUI = EffectsUIState(clipId: "clip:a", catalogOpen: true, catalogFamily: "Retro & Glitch")
        let c = PanelMeasureCanvas()
        for _ in 0..<2 { c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: w, height: 3000)) }   // the 2nd draw knows its width
        var last = try XCTUnwrap(p.hits.rect { $0 == .custom("fx:tiles", 0) })
        var i = 1
        while let r = p.hits.rect(where: { $0 == .custom("fx:tiles", i) }) { last = r; i += 1 }
        let next = try XCTUnwrap(p.hits.rect { $0 == .group("audio-fx") }, "the group after Effects")
        return next.y - last.maxY
    }

    func testTheGridEndsWhereTheNextRowStartsAtTheMinimumWidth() throws {
        XCTAssertEqual(try gapBelowTheGrid(width: PanelFit.minRight), try gapBelowTheGrid(width: 409), accuracy: 0.5,
                       "at the 280 pt minimum the grid leaves a gap below it")
    }

    func testTheGridEndsWhereTheNextRowStartsAtTheMaximumWidth() throws {
        XCTAssertEqual(try gapBelowTheGrid(width: (1440 * PanelFit.maxRatio).rounded(.down)), try gapBelowTheGrid(width: 409), accuracy: 0.5,
                       "at the widest panel the grid overlaps the next row")
    }
}
