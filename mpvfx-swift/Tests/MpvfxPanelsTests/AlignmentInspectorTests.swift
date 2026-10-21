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
import OneTakeKeyframes
@testable import MpvfxPanels

final class AlignmentInspectorTests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"id":"alignment","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1000,"height":600,"background":"#000000"},
     "assets":[{"id":"image","kind":"image","name":"image.png","source":"image.png","durationFrames":300},
               {"id":"audio","kind":"audio","name":"audio.wav","source":"audio.wav","durationFrames":300}],
     "sequence":{"id":"sequence","name":"Sequence","tracks":[
      {"id":"v1","kind":"video","clips":[{"id":"a","assetId":"image","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"staticParameters":{"layout.left":30,"layout.top":50,"layout.width":100,"layout.height":80}}]},
      {"id":"v2","kind":"video","clips":[{"id":"b","assetId":"image","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"staticParameters":{"layout.left":350,"layout.top":170,"layout.width":200,"layout.height":100}}]},
      {"id":"v3","kind":"video","clips":[{"id":"c","assetId":"image","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"staticParameters":{"layout.left":800,"layout.top":400,"layout.width":150,"layout.height":120}}]},
      {"id":"sound","kind":"audio","clips":[{"id":"sound","assetId":"audio","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """#

    func panel(_ ids: [String]) throws -> (InspectorPanel, TimelineEditor, PanelMeasureCanvas) {
        let editor = try TimelineEditor(json: Self.json, engine: KeyframeRuntime())
        let panel = InspectorPanel(); panel.editor = editor; panel.selection = ids; panel.time = 1
        let canvas = PanelMeasureCanvas()
        panel.draw(canvas, in: CanvasRect(x: 0, y: 0, width: 364, height: 1600))
        return (panel, editor, canvas)
    }

    func testASingleVisualClipOffersAllSixButtonsAndKeyboardActivation() throws {
        let (p, e, _) = try panel(["a"])
        for value in TimelineAlignment.allCases {
            XCTAssertNotNil(p.hits.rect { $0 == .button("align:\(value.rawValue)") })
        }
        p.focus.current = .button("align:left"); p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(e.alignmentBounds(clipId: "a", time: 1)?.x, 0)
        XCTAssertEqual(e.undoStack.count, 1)
    }

    func testMultiSelectionShowsActionsAndSelectionReferenceIsKeyboardOperable() throws {
        let (p, e, c) = try panel(["a", "b", "c"])
        XCTAssertTrue(c.drawnStrings.contains("3 clips selected"))
        XCTAssertNotNil(p.hits.rect { $0 == .button("align:right") })
        p.focus.current = .segment("align:reference", "selection"); p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(p.alignmentReference, .selection)
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 364, height: 1600))
        p.focus.current = .button("align:right")
        XCTAssertTrue(p.keyDown(EditorKey(.space)))
        for id in ["a", "b", "c"] { XCTAssertEqual(e.alignmentBounds(clipId: id, time: 1)?.maxX, 950) }
        XCTAssertEqual(e.undoStack.count, 1)
    }

    func testDistributionRequiresThreeAndAudioOrLockedSelectionsCannotEdit() throws {
        let (p, e, _) = try panel(["a", "b"])
        let rows = p.groups.flatMap(\.rows)
        let buttons = rows.flatMap { row -> [InspectorRow.Button] in if case .buttons(let b) = row.kind { return b }; return [] }
        XCTAssertEqual(buttons.filter { $0.key.hasPrefix("distribute:") }.map(\.disabled), [true, true])
        let (mixed, mixedEditor, _) = try panel(["a", "sound"])
        mixed.focus.current = .button("align:left"); mixed.focus.visible = true
        _ = mixed.keyDown(EditorKey(.enter))
        XCTAssertTrue(mixedEditor.undoStack.isEmpty)
        XCTAssertTrue(e.undoStack.isEmpty)
    }
}
