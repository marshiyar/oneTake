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
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline

/// The distort tool on the stage (#451): drag and keyboard paths, draft until Apply, one commit per Apply.
final class DistortStageTests: XCTestCase {
    private func stage() -> (PlayerView, PlayerController, CanvasRect) {
        let v = PlayerView(playback: PlaybackState(duration: 10)); v.canvasSize = CanvasSize(1000, 500)
        let c = PlayerController(view: v); c.size = CanvasSize(1016, 36 + 516 + 40)
        v.elements = [StageElement(id: "m", name: "M", rect: CanvasRect(x: 0, y: 0, width: 1000, height: 500), kind: .video)]
        let f = v.frameRect(in: c.size)
        c.pointerDown(x: f.midX, y: f.midY); c.pointerUp(x: f.midX, y: f.midY)
        return (v, c, f)
    }

    func testDragACornerIsADraftUntilApplyThenOneCommit() {
        let (v, c, f) = stage()
        var commits: [StageElement] = []
        c.onCommit = { commits.append($0) }
        XCTAssertTrue(c.keyDown(EditorKey(.char("d")))); XCTAssertTrue(v.distortActive)
        let s = v.scale(in: c.size)
        c.pointerDown(x: f.x, y: f.y); c.pointerMove(x: f.x + 100, y: f.y + 50); c.pointerUp(x: f.x + 100, y: f.y + 50)
        let draft = try! XCTUnwrap(c.distortDraft)
        XCTAssertEqual(draft.tl.x, 100 / s / 1000, accuracy: 1e-6)
        XCTAssertEqual(draft.tl.y, 50 / s / 500, accuracy: 1e-6)
        XCTAssertEqual(draft.tr, .zero, "only the dragged corner moved")
        XCTAssertTrue(commits.isEmpty, "nothing is committed before Apply")
        XCTAssertTrue(c.keyDown(EditorKey(.enter)))
        XCTAssertFalse(v.distortActive); XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].corners, draft)
        XCTAssertNil(v.elements[0].corners, "the document's corners show again after Apply")
    }

    func testKeyboardPathPicksCornersNudgesResetsAndCancels() {
        let (v, c, _) = stage()
        var commits = 0
        c.onCommit = { _ in commits += 1 }
        XCTAssertTrue(c.keyDown(EditorKey(.char("d"))))
        XCTAssertTrue(c.keyDown(EditorKey(.tab))); XCTAssertEqual(v.activeCorner, .topRight)
        XCTAssertTrue(c.keyDown(EditorKey(.right)))
        XCTAssertEqual(try XCTUnwrap(c.distortDraft).tr.x, 1.0 / 1000, accuracy: 1e-9, "an arrow moves the corner one canvas pixel")
        XCTAssertTrue(c.keyDown(EditorKey(.left, shift: true)))
        XCTAssertEqual(try XCTUnwrap(c.distortDraft).tr.x, -9.0 / 1000, accuracy: 1e-9, "Shift moves ten")
        XCTAssertTrue(c.keyDown(EditorKey(.tab, shift: true))); XCTAssertEqual(v.activeCorner, .topLeft)
        XCTAssertTrue(c.keyDown(EditorKey(.char("0"))))
        XCTAssertEqual(c.distortDraft, .identity, "0 resets the draft to the plain box")
        XCTAssertTrue(c.keyDown(EditorKey(.down)))
        XCTAssertTrue(c.keyDown(EditorKey(.escape)))
        XCTAssertFalse(v.distortActive); XCTAssertFalse(v.cropActive)
        XCTAssertNil(v.elements[0].corners); XCTAssertEqual(commits, 0, "Esc cancels without a commit")
    }

    func testShiftEnterAppliesAndKeysTheCorners() {
        let (_, c, _) = stage()
        var keyed: [Bool] = []
        c.onCommit = { _ in keyed.append(c.distortKeyframe) }
        XCTAssertTrue(c.keyDown(EditorKey(.char("d"))))
        XCTAssertTrue(c.keyDown(EditorKey(.right)))
        XCTAssertTrue(c.keyDown(EditorKey(.enter, shift: true)))
        XCTAssertEqual(keyed, [true])
    }

    func testToolbarOffersDistortBesideCrop() {
        let (v, c, _) = stage()
        let items = v.toolbar.layout(width: c.size.width, cropAvailable: true, cropActive: false, nil).map(\.0)
        XCTAssertTrue(items.contains(.distort)); XCTAssertTrue(items.contains(.crop))
        let r = v.toolbar.layout(width: c.size.width, cropAvailable: true, cropActive: false, nil).first { $0.0 == .distort }!.1
        c.pointerDown(x: r.midX, y: r.midY)
        XCTAssertTrue(v.distortActive, "the toolbar button opens the tool")
    }
}
