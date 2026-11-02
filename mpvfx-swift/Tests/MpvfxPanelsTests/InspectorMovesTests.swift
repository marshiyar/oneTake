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
// Issue #274 A1: the Moves group's rows by kind, one undo step per edit, typed lengths, and Tab and Return access to
// every control.
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxPanels
@testable import MpvfxTimeline

internal final class InspectorMovesTests: XCTestCase {
    private static let frame = CanvasRect(x: 0, y: 0, width: 360, height: 9000)

    private func panel(select id: String = "clip:a") throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: InspectorMediaFitTests.json, engine: KeyframeRuntime())
        let p = InspectorPanel()
        p.editor = editor
        p.selection = [id]
        p.openGroupId = InspectorPanel.movesGroupId
        redraw(p)
        return (p, editor)
    }

    private func redraw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: Self.frame) }
    private func rows(_ p: InspectorPanel) -> [InspectorRow] { p.groups.first { $0.id == InspectorPanel.movesGroupId }?.addressableRows ?? [] }
    private func number(_ p: InspectorPanel, _ key: String) -> InspectorRow.Number? {
        for row in rows(p) { if case .number(let n) = row.kind, n.key == key { return n } }
        return nil
    }
    private func button(_ p: InspectorPanel, _ key: String) -> InspectorRow.Button? {
        for row in rows(p) { if case .buttons(let bs) = row.kind, let b = bs.first(where: { $0.key == key }) { return b } }
        return nil
    }
    private func segmented(_ p: InspectorPanel, _ key: String) -> InspectorRow.Segmented? {
        for row in rows(p) { if case .segmented(let s) = row.kind, s.key == key { return s } }
        return nil
    }

    internal func testTheGroupSitsAfterTransformForVisualClipsOnly() throws {
        let (p, _) = try panel()
        let ids = p.groups.map(\.id)
        let moves = try XCTUnwrap(ids.firstIndex(of: InspectorPanel.movesGroupId))
        XCTAssertEqual(ids[moves - 1], "layout", "after Transform")
        let (audio, _) = try panel(select: "clip:m")
        XCTAssertFalse(audio.groups.contains { $0.id == InspectorPanel.movesGroupId }, "a sound has no layer to move")
    }

    internal func testPickingAKindMakesOneMoveWithItsRowsAndNoneRemovesIt() throws {
        let (p, editor) = try panel()
        let depth = editor.undoStack.count
        XCTAssertEqual(button(p, "moves.in.kind.none")?.style, .chipActive)
        XCTAssertNil(number(p, "moves.in.frames"), "no move, no length")
        try XCTUnwrap(button(p, "moves.in.kind.slide")).action()
        redraw(p)
        XCTAssertEqual(editor.clipMoves(clipId: "clip:a")?.inMove?.kind, .slide)
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertEqual(editor.undoLabel, "Edit moves")
        XCTAssertEqual(button(p, "moves.in.kind.slide")?.style, .chipActive)
        XCTAssertEqual(number(p, "moves.in.frames")?.text, "15")
        XCTAssertNotNil(segmented(p, "moves.in.direction"), "a slide has a direction")
        XCTAssertEqual(number(p, "moves.in.amount")?.text, "100")
        XCTAssertEqual(number(p, "moves.in.amount")?.tier, .default)
        XCTAssertNil(number(p, "moves.in.amount")?.reset)
        try XCTUnwrap(button(p, "moves.in.kind.rise")).action()
        redraw(p)
        XCTAssertNil(segmented(p, "moves.in.direction"), "only a slide has one")
        XCTAssertEqual(editor.clipMoves(clipId: "clip:a")?.inMove?.frames, 15, "the length stays")
        try XCTUnwrap(button(p, "moves.in.kind.none")).action()
        XCTAssertNil(editor.clipMoves(clipId: "clip:a"))
        XCTAssertEqual(editor.undoStack.count, depth + 3)
    }

    internal func testLengthAmountDirectionAndEaseAreEditedInUndoSteps() throws {
        let (p, editor) = try panel()
        try XCTUnwrap(button(p, "moves.in.kind.slide")).action()
        redraw(p)
        let depth = editor.undoStack.count
        try XCTUnwrap(number(p, "moves.in.frames")).commit("0:20")
        XCTAssertEqual(editor.clipMoves(clipId: "clip:a")?.inMove?.frames, 20, "timecode 0:20 at 30 fps is 20 frames")
        redraw(p)
        try XCTUnwrap(number(p, "moves.in.amount")).commit("60")
        XCTAssertEqual(editor.clipMoves(clipId: "clip:a")?.inMove?.amount, 60)
        redraw(p)
        XCTAssertEqual(number(p, "moves.in.amount")?.tier, .explicitCustom)
        let resetAmount = try XCTUnwrap(number(p, "moves.in.amount")?.reset)
        resetAmount()
        redraw(p)
        XCTAssertNil(editor.clipMoves(clipId: "clip:a")?.inMove?.amount, "the reset removes the key")
        try XCTUnwrap(number(p, "moves.in.amount")).commit("999")
        XCTAssertNil(editor.clipMoves(clipId: "clip:a")?.inMove?.amount, "out of range is refused, not clamped")
        try XCTUnwrap(segmented(p, "moves.in.direction")).select("up")
        XCTAssertEqual(editor.clipMoves(clipId: "clip:a")?.inMove?.direction, .up)
        redraw(p)
        try XCTUnwrap(segmented(p, "moves.in.ease")).select("linear")
        XCTAssertEqual(editor.clipMoves(clipId: "clip:a")?.inMove?.ease, .linear)
        redraw(p)
        XCTAssertEqual(segmented(p, "moves.in.ease")?.options.first { $0.active }?.key, "linear")
        XCTAssertEqual(editor.undoStack.count, depth + 5)
    }

    internal func testAnOutAndALoopAreIndependentOfTheIn() throws {
        let (p, editor) = try panel()
        try XCTUnwrap(button(p, "moves.out.kind.shrink")).action()
        redraw(p)
        try XCTUnwrap(button(p, "moves.loop.kind.sway")).action()
        redraw(p)
        let moves = try XCTUnwrap(editor.clipMoves(clipId: "clip:a"))
        XCTAssertNil(moves.inMove)
        XCTAssertEqual(moves.outMove?.kind, .shrink)
        XCTAssertEqual(moves.loop?.kind, .sway)
        XCTAssertEqual(number(p, "moves.loop.frames")?.text, "30", "a loop's period")
        try XCTUnwrap(number(p, "moves.loop.frames")).commit("3")
        XCTAssertEqual(editor.clipMoves(clipId: "clip:a")?.loop?.periodFrames, 30, "an odd period is refused")
        XCTAssertEqual(segmented(p, "moves.out.ease")?.options.first { $0.active }?.key, "ease-in", "an Out eases in by default")
        XCTAssertEqual(segmented(p, "moves.loop.ease")?.options.first { $0.active }?.key, "ease-in-out")
        XCTAssertNil(button(p, "moves.loop.kind.slide"), "a loop has only loop kinds")
    }

    internal func testLengthsParseAsFramesSecondsAndTimecode() {
        let parse = { InspectorPanel.parseMoveFrames($0, fps: 30) }
        XCTAssertEqual(parse("15"), 15); XCTAssertEqual(parse("15f"), 15); XCTAssertEqual(parse(" 15 "), 15)
        XCTAssertEqual(parse("0.5s"), 15); XCTAssertEqual(parse("1s"), 30)
        XCTAssertEqual(parse("1:05"), 35); XCTAssertEqual(parse("0:1:05"), 95)
        XCTAssertNil(parse("0")); XCTAssertNil(parse("-3")); XCTAssertNil(parse("2.5")); XCTAssertNil(parse("abc")); XCTAssertNil(parse(""))
        XCTAssertNil(parse("1:2:3:4")); XCTAssertNil(parse("0.001s"))
    }

    internal func testEveryControlTakesTabAndReturnPicksAKind() throws {
        let (p, editor) = try panel()
        try XCTUnwrap(button(p, "moves.in.kind.slide")).action()
        redraw(p)
        let order = PanelFocus<InspectorPanel.Hit>.order(p.hits, p.isFocusable)
        for key in ["moves.in.kind.none", "moves.in.kind.slide", "moves.out.kind.grow", "moves.loop.kind.pulse"] {
            XCTAssertTrue(order.contains(.button(key)), "\(key) takes Tab")
        }
        for key in ["moves.in.frames", "moves.in.amount"] { XCTAssertTrue(order.contains(.field(key)), "\(key) takes Tab") }
        for option in ["left", "right", "up", "down"] { XCTAssertTrue(order.contains(.segment("moves.in.direction", option)), option) }
        p.focus.current = .button("moves.out.kind.grow")
        p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(editor.clipMoves(clipId: "clip:a")?.outMove?.kind, .grow, "Return presses the focused pick")
    }
}
