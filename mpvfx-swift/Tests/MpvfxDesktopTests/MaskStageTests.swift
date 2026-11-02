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
import MpvfxShared
import MpvfxTimeline
@testable import MpvfxPlayer
@testable import MpvfxDesktop

/// Issue #297 through the session: ⌥M adds a centred rectangle mask in one undo step; each handle drag, with ⇧ and ⌥,
/// is one more; arrow nudges move the grabbed handle 1 / 10 layer px and a burst is one step; Esc cancels a drag, then
/// leaves the mode.
final class MaskStageTests: XCTestCase {
    func makeSession() throws -> EditorSession {
        let s = try EditorSession(projectPath: nil, demo: true)
        s.audio?.stop()
        s.player.size = CanvasSize(1440, 900)
        s.timeline.view.selection = ["clip:a"]
        s.syncStage()
        return s
    }
    func mask(_ s: EditorSession) throws -> NativeClipMask { try XCTUnwrap(s.editor.masks(clipId: "clip:a").first) }
    func layer(_ s: EditorSession) throws -> (ve: StageElement, size: CanvasSize) {
        let e = try XCTUnwrap(s.player.view.elements.first { $0.id == "clip:a" })
        return (s.player.view.chromeElement(e, in: s.player.size), s.player.maskLayerSize(e))
    }
    func handle(_ s: EditorSession, _ h: MaskHandle) throws -> CanvasPoint {
        let (ve, size) = try layer(s)
        let at = try XCTUnwrap(MaskStageEditor.handles(of: try mask(s), layerSize: size).first { $0.handle == h }).point
        return s.player.maskViewPoint(ve, at, layerSize: size)
    }
    func drag(_ s: EditorSession, from p: CanvasPoint, by d: CanvasPoint, shift: Bool = false, option: Bool = false) {
        s.player.modifiers = option ? [.alt] : []
        s.player.pointerDown(x: p.x, y: p.y, shift: shift)
        s.player.pointerMove(x: p.x + d.x, y: p.y + d.y, shift: shift)
        s.player.pointerUp(x: p.x + d.x, y: p.y + d.y)
        s.player.modifiers = []
    }
    func altM() -> EditorKey { EditorKey(.char("m"), alt: true) }

    func testA1OptionMAddsACentredRectangleMaskAsOneUndoStepAndPutsItOnTheStage() throws {
        let s = try makeSession()
        let depth = s.editor.undoStack.count
        XCTAssertTrue(s.commandKey(altM()))
        XCTAssertEqual(s.editor.undoStack.count, depth + 1); XCTAssertEqual(s.editor.undoLabel, "Add mask")
        let m = try mask(s)
        XCTAssertEqual(m.kind, "rectangle"); XCTAssertEqual(m.x, 0.5); XCTAssertEqual(m.y, 0.5)
        XCTAssertEqual(s.player.maskTarget, MaskStageTarget(clipId: "clip:a", maskId: m.id))
        XCTAssertNotNil(s.player.view.maskOverlay, "its outline and handles are drawn")
        XCTAssertTrue(s.editor.undo())
        XCTAssertTrue(s.editor.masks(clipId: "clip:a").isEmpty)
        s.timeline.view.selection = []; s.syncStage()
        XCTAssertFalse(s.commandKey(altM()), "nothing selected: the key is not taken")
    }

    func testA2DraggingAnEdgeIsOneUndoStepAndAClickChangesNothing() throws {
        let s = try makeSession()
        XCTAssertTrue(s.commandKey(altM()))
        let before = try mask(s), (ve, _) = try layer(s), depth = s.editor.undoStack.count
        let right = try handle(s, .edge(1))
        drag(s, from: right, by: CanvasPoint(0, 0))
        XCTAssertEqual(s.editor.undoStack.count, depth, "a click moves nothing")
        drag(s, from: right, by: CanvasPoint(40, 0))
        XCTAssertEqual(s.editor.undoStack.count, depth + 1, "one drag, one step"); XCTAssertEqual(s.editor.undoLabel, "Edit mask")
        let after = try mask(s)
        XCTAssertEqual(try XCTUnwrap(after.width), try XCTUnwrap(before.width) + 40 / ve.rect.width, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(after.x), try XCTUnwrap(before.x) + 20 / ve.rect.width, accuracy: 1e-6, "the left edge stays")
        XCTAssertEqual(after.height, before.height)
        XCTAssertTrue(s.editor.undo())
        XCTAssertEqual(try mask(s), before)
    }

    func testShiftKeepsTheProportionsAndOptionResizesAboutTheCentre() throws {
        let s = try makeSession()
        XCTAssertTrue(s.commandKey(altM()))
        var m = try mask(s)
        let ratio = try XCTUnwrap(m.width) * (try layer(s).size.width) / (try XCTUnwrap(m.height) * (try layer(s).size.height))
        drag(s, from: try handle(s, .corner(2)), by: CanvasPoint(60, 5), shift: true)
        m = try mask(s)
        let (_, size) = try layer(s)
        XCTAssertEqual(try XCTUnwrap(m.width) * size.width / (try XCTUnwrap(m.height) * size.height), ratio, accuracy: 1e-6, "⇧ keeps the ratio")
        let centre = (try XCTUnwrap(m.x), try XCTUnwrap(m.y)), width = try XCTUnwrap(m.width)
        drag(s, from: try handle(s, .corner(0)), by: CanvasPoint(-20, -20), option: true)
        m = try mask(s)
        XCTAssertEqual(try XCTUnwrap(m.x), centre.0, accuracy: 1e-6, "⌥ keeps the centre"); XCTAssertEqual(try XCTUnwrap(m.y), centre.1, accuracy: 1e-6)
        XCTAssertGreaterThan(try XCTUnwrap(m.width), width)
    }

    func testA3ArrowsNudgeTheGrabbedHandleByOneOrTenLayerPixelsAndABurstIsOneStep() throws {
        let s = try makeSession()
        XCTAssertTrue(s.commandKey(altM()))
        let before = try mask(s), (_, size) = try layer(s), depth = s.editor.undoStack.count
        drag(s, from: try handle(s, .edge(1)), by: CanvasPoint(0, 0))   // grab the right edge without moving it
        XCTAssertTrue(s.player.keyDown(EditorKey(.right)))
        XCTAssertTrue(s.player.keyDown(EditorKey(.right)))
        XCTAssertTrue(s.player.keyDown(EditorKey(.right, shift: true)))
        XCTAssertEqual(s.editor.undoStack.count, depth, "nothing is committed while the burst runs")
        s.player.flushNudge()
        XCTAssertEqual(s.editor.undoStack.count, depth + 1, "the burst is one step")
        let after = try mask(s)
        XCTAssertEqual(try XCTUnwrap(after.width) * size.width, try XCTUnwrap(before.width) * size.width + 12, accuracy: 1e-6, "1 + 1 + 10 px")
        XCTAssertEqual(try XCTUnwrap(after.x) * size.width, try XCTUnwrap(before.x) * size.width + 6, accuracy: 1e-6, "the centre follows by half")
        XCTAssertTrue(s.editor.undo())
        XCTAssertEqual(try mask(s), before)
    }

    func testEscCancelsADragThenLeavesTheMaskMode() throws {
        let s = try makeSession()
        XCTAssertTrue(s.commandKey(altM()))
        let before = try mask(s), depth = s.editor.undoStack.count, p = try handle(s, .edge(1))
        s.player.pointerDown(x: p.x, y: p.y)
        s.player.pointerMove(x: p.x + 50, y: p.y)
        XCTAssertNotEqual(s.player.maskInEdit, before, "the draft follows the pointer")
        XCTAssertTrue(s.player.keyDown(EditorKey(.escape)))
        s.player.pointerUp(x: p.x + 50, y: p.y)
        XCTAssertEqual(s.editor.undoStack.count, depth, "Esc dropped the drag"); XCTAssertEqual(try mask(s), before)
        XCTAssertNotNil(s.player.maskTarget, "the first Esc only cancels the drag")
        XCTAssertTrue(s.player.keyDown(EditorKey(.escape)))
        XCTAssertNil(s.player.maskTarget); XCTAssertNil(s.player.view.maskOverlay)
    }

    func testSelectingAnotherLayerEndsTheMaskMode() throws {
        let s = try makeSession()
        XCTAssertTrue(s.commandKey(altM()))
        s.player.setSelection([])
        XCTAssertNil(s.player.maskTarget)
    }

    func testTheInspectorButtonPutsAnExistingMaskOnTheStage() throws {
        let s = try makeSession()
        let id = try XCTUnwrap(s.editor.addMask(clipId: "clip:a", kind: "ellipse"))
        s.syncStage()
        XCTAssertNil(s.player.maskTarget)
        s.editMaskOnStage(clipId: "clip:a", maskId: id)
        XCTAssertEqual(s.player.maskTarget, MaskStageTarget(clipId: "clip:a", maskId: id))
        s.editMaskOnStage(clipId: "clip:a", maskId: "missing")
        XCTAssertEqual(s.player.maskTarget?.maskId, id, "an unknown mask changes nothing")
    }
}
