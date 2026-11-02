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
import MpvfxCanvas
import MpvfxShared
import MpvfxTheme
import MpvfxTimeline
import OneTakeKeyframes
import XCTest

@testable import MpvfxPanels

/// Issue #281: the Look section of the Text group.
internal final class TextLookRowsTests: XCTestCase {
    private let width = "textLook:outline0:width"
    private let shadowX = "textLook:shadow:x"

    private func make() throws -> (TimelineEditor, String, InspectorPanel) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        let id = try XCTUnwrap(editor.addTextClip(at: 0, content: "Title", seconds: 10))
        let panel = InspectorPanel()
        panel.editor = editor
        panel.selection = [id]
        panel.openGroupId = "text"
        redraw(panel)
        return (editor, id, panel)
    }
    private func redraw(_ panel: InspectorPanel, height: Double = 2400) {
        panel.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 360, height: height))
    }
    private func look(_ editor: TimelineEditor, _ id: String) -> NativeTextLook? { editor.clipText(clipId: id)?.look }
    private func addAll(_ panel: InspectorPanel) {
        panel.button("textLook:outline:add")?.action(); redraw(panel)
        panel.button("textLook:shadow:add")?.action(); redraw(panel)
    }
    private func focus(_ panel: InspectorPanel, _ key: String) {
        panel.focus.current = .slider(key); panel.focus.visible = true
    }

    internal func testASectionWithoutALookOffersOnlyTheAddButtons() throws {
        let (editor, id, panel) = try make()
        XCTAssertNil(panel.slider(width))
        XCTAssertNotNil(panel.button("textLook:outline:add"))
        XCTAssertNotNil(panel.button("textLook:shadow:add"))
        XCTAssertNil(panel.button("textLook:outline:remove"))
        XCTAssertNil(look(editor, id))
    }

    internal func testAddingAndRemovingPartsAreSingleUndoStepsAndLeaveNoLookBehind() throws {
        let (editor, id, panel) = try make()
        let original = editor.document
        let count = editor.undoStack.count
        addAll(panel)
        XCTAssertEqual(editor.undoStack.count, count + 2)
        XCTAssertEqual(look(editor, id)?.outlines?.count, 1)
        XCTAssertEqual(look(editor, id)?.shadow, TimelineEditor.defaultShadow)
        XCTAssertNotNil(panel.slider(width)); XCTAssertNotNil(panel.slider(shadowX))
        XCTAssertNotNil(panel.button("textLook:outline:add"), "a second outline is offered")
        panel.button("textLook:outline:add")?.action(); redraw(panel)
        XCTAssertEqual(look(editor, id)?.outlines?.count, 2)
        XCTAssertNil(panel.button("textLook:outline:add"), "two outlines is the most")
        XCTAssertNotNil(panel.slider("textLook:outline1:width"))
        panel.button("textLook:outline:remove")?.action(); redraw(panel)
        panel.button("textLook:outline:remove")?.action(); redraw(panel)
        panel.button("textLook:shadow:remove")?.action(); redraw(panel)
        XCTAssertNil(look(editor, id), "an emptied look is not stored")
        XCTAssertEqual(editor.undoStack.count, count + 6)
        for _ in 0..<6 { XCTAssertTrue(editor.undo()) }
        XCTAssertEqual(editor.document, original)
    }

    internal func testA1EveryRowIsReachedByTabNudgedByArrowsAndTypedInto() throws {
        let (editor, id, panel) = try make()
        addAll(panel)
        let keys = [width, shadowX, "textLook:shadow:y", "textLook:shadow:blur"]
        let order = PanelFocus<InspectorPanel.Hit>.order(panel.hits, panel.isFocusable)
        for key in keys { XCTAssertTrue(order.contains(.slider(key)), "Tab reaches \(key)") }
        for key in ["textLook:outline0:color", "textLook:shadow:color"] {
            XCTAssertTrue(order.contains(.field(key)), "Tab reaches \(key)")
        }
        focus(panel, width)
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        XCTAssertEqual(look(editor, id)?.outlines?[0].width, TimelineEditor.defaultOutlineWidth + 1)
        redraw(panel)
        XCTAssertTrue(panel.keyDown(EditorKey(.left, shift: true)))
        XCTAssertEqual(look(editor, id)?.outlines?[0].width, 0, "shift steps ten and the width stops at zero")
        redraw(panel)
        focus(panel, "textLook:shadow:blur")
        XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
        for _ in 0..<4 { _ = panel.keyDown(EditorKey(.backspace)) }
        for c in "30" { XCTAssertTrue(panel.keyDown(EditorKey(.char(c)))) }
        XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
        XCTAssertEqual(look(editor, id)?.shadow?.blur, 30)
        redraw(panel)
        panel.number("textLook:outline0:color")?.commit("#00ff00")
        XCTAssertEqual(look(editor, id)?.outlines?[0].color, "#00ff00")
        panel.number("textLook:shadow:color")?.commit("#11223344")
        XCTAssertEqual(look(editor, id)?.shadow?.color, "#11223344")
        panel.number("textLook:shadow:color")?.commit("not a colour")
        XCTAssertEqual(look(editor, id)?.shadow?.color, "#11223344", "a bad colour changes nothing")
    }

    internal func testPositionAndResetWriteTheLook() throws {
        let (editor, id, panel) = try make()
        panel.button("textLook:outline:add")?.action(); redraw(panel)
        panel.segmented("textLook:outline0:position")?.select("center"); redraw(panel)
        XCTAssertEqual(look(editor, id)?.outlines?[0].position, "center")
        panel.segmented("textLook:outline0:position")?.select("outside"); redraw(panel)
        XCTAssertNil(look(editor, id)?.outlines?[0].position, "the default position is an absent key")
        XCTAssertTrue(editor.setTextLookValue(clipId: id, NativeTextLookParameter.outlineWidthIds[0], 40, time: 0)); redraw(panel)
        panel.slider(width)?.reset?(); redraw(panel)
        XCTAssertEqual(look(editor, id)?.outlines?[0].width, TimelineEditor.defaultOutlineWidth)
    }

    internal func testA2KeyframesOnEveryListedValueFollowTheTimeAndStopWithOneStep() throws {
        let (editor, id, panel) = try make()
        addAll(panel)
        let pids = [NativeTextLookParameter.outlineWidthIds[0], NativeTextLookParameter.shadowXId,
                    NativeTextLookParameter.shadowYId, NativeTextLookParameter.shadowBlurId]
        for pid in pids {
            XCTAssertTrue(editor.setAnimated(clipId: id, [(pid, .number(editor.textLookValue(clipId: id, pid, time: 0) ?? 0))], true, time: 0))
            XCTAssertTrue(editor.isAnimated(clipId: id, pid), pid)
            XCTAssertTrue(editor.setTextLookValue(clipId: id, pid, 20, time: 2), pid)
            XCTAssertTrue(editor.setTextLookValue(clipId: id, pid, 40, time: 4), pid)
            XCTAssertEqual(try XCTUnwrap(editor.textLookValue(clipId: id, pid, time: 2)), 20, accuracy: 1e-6, pid)
            XCTAssertEqual(try XCTUnwrap(editor.textLookValue(clipId: id, pid, time: 4)), 40, accuracy: 1e-6, pid)
        }
        panel.time = 2
        redraw(panel)
        XCTAssertEqual(panel.slider(width)?.position ?? -1, 20, accuracy: 1e-6, "the row reads the value at the playhead")
        XCTAssertEqual(panel.slider(width)?.keyframe?.state, .onKey)
        let before = editor.undoStack.count
        XCTAssertTrue(editor.stopAnimatingTextLook(clipId: id, pids[0], time: 4))
        XCTAssertEqual(editor.undoStack.count, before + 1)
        XCTAssertFalse(editor.isAnimated(clipId: id, pids[0]))
        XCTAssertEqual(look(editor, id)?.outlines?[0].width, 40, "the value at the playhead stays")
        XCTAssertNil(editor.clip(id)?.clip.staticParameters?[pids[0]], "no static parameter is left behind")
        XCTAssertTrue(editor.undo())
        XCTAssertTrue(editor.isAnimated(clipId: id, pids[0]))
    }

    internal func testRemovingAPartDropsItsKeys() throws {
        let (editor, id, panel) = try make()
        addAll(panel)
        let pid = NativeTextLookParameter.shadowBlurId
        XCTAssertTrue(editor.setAnimated(clipId: id, [(pid, .number(4))], true, time: 0))
        XCTAssertTrue(editor.removeTextLookShadow(clipId: id))
        XCTAssertFalse(editor.isAnimated(clipId: id, pid))
        XCTAssertFalse(editor.clip(id)?.clip.parameterTracks.contains { NativeTextLookParameter.isTextLookParameter($0.parameterId) } ?? true)
    }

    internal func testALinkedStyleKeepsItsLinkAndOverridesOnlyTheLook() throws {
        let (editor, id, panel) = try make()
        XCTAssertTrue(editor.createTextStyle(clipId: id, styleId: "style:t", name: "T"))
        redraw(panel)
        panel.button("textLook:outline:add")?.action()
        XCTAssertEqual(editor.clip(id)?.1.textStyle?.styleId, "style:t")
        XCTAssertEqual(editor.clip(id)?.1.textStyle?.overrides, ["look"])
        XCTAssertEqual(look(editor, id)?.outlines?.count, 1)
    }

    internal func testALockedTrackRefusesEveryLookEdit() throws {
        let (editor, id, _) = try make()
        XCTAssertTrue(editor.addTextLookOutline(clipId: id))
        let trackId = try XCTUnwrap(editor.document.sequence.tracks.first { $0.clips.contains { $0.id == id } }?.id)
        XCTAssertTrue(editor.setTrackLocked(trackId, true))
        let locked = editor.document
        XCTAssertFalse(editor.addTextLookShadow(clipId: id))
        XCTAssertFalse(editor.setTextLookValue(clipId: id, NativeTextLookParameter.outlineWidthIds[0], 9, time: 0))
        XCTAssertFalse(editor.removeLastTextLookOutline(clipId: id))
        XCTAssertEqual(editor.document, locked)
    }

    internal func testTheSectionAtBothWindowSizesInBothAppearances() throws {
        let previous = Theme.mode
        defer { Theme.setMode(previous) }
        for mode in ThemeMode.allCases {
            Theme.setMode(mode)
            for (windowWidth, windowHeight) in [(1_440.0, 900.0), (1_280.0, 800.0)] {
                let (_, _, panel) = try make()
                addAll(panel)
                panel.button("textLook:outline:add")?.action()
                let width = PanelFit.fit(windowWidth, PanelFit.defaults(windowWidth)).right
                panel.bodyScroll = 300
                let canvas = PanelMeasureCanvas()
                panel.draw(canvas, in: CanvasRect(x: 0, y: 0, width: width, height: windowHeight))
                XCTAssertTrue(canvas.texts.contains { $0.0.contains("Outline 2 width") || $0.0.contains("Shadow blur") }, "\(mode) \(windowWidth)")
                for (text, _, font, _) in canvas.texts { XCTAssertGreaterThanOrEqual(font.size, 11, text) }
            }
        }
    }
}
