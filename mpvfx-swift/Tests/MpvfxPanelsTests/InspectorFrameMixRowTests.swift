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
import MpvfxShared
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Media group's "Frame mix" row (#272): shown for a video clip that plays slower than 1x or on a speed ramp, and
/// one undo step to turn on or off.
final class InspectorFrameMixRowTests: XCTestCase {
    func mixRow(_ p: InspectorPanel) -> InspectorRow.Toggle? {
        for r in p.groups.flatMap(\.addressableRows) { if case .toggle(let t) = r.kind, t.key == "frameMix" { return t } }
        return nil
    }

    func panel(_ extra: String = "") throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: InspectorPitchRowTests.json.replacingOccurrences(of: #""muted":false,"#, with: #""muted":false,\#(extra)"#))
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]
        return (p, editor)
    }

    func testRowAppearsOnlyBelowNormalSpeedOrOnARamp() throws {
        let (normal, _) = try panel()
        XCTAssertNil(mixRow(normal), "a clip at 1x has nothing to mix")
        let (slow, editor) = try panel()
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:a", 0.5))
        XCTAssertNotNil(mixRow(slow))
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:a", 2))
        XCTAssertNil(mixRow(slow), "faster than 1x")
        let (ramped, _) = try panel(#""speedRamp":{"v":1,"kind":"speed-ramp","points":[{"t":0,"speed":1},{"t":90,"speed":0.5}]},"#)
        XCTAssertNotNil(mixRow(ramped), "a ramp can slow down")
    }

    func testTurningItOnWritesFrameBlendInOneUndoStep() throws {
        let (p, editor) = try panel()
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:a", 0.5))
        let before = editor.document, steps = editor.undoStack.count
        try XCTUnwrap(mixRow(p)).set(true)
        XCTAssertEqual(editor.undoStack.count, steps + 1, "one undo step")
        XCTAssertTrue(editor.mixesFrames(clipId: "clip:a"))
        XCTAssertEqual(editor.document.sequence.tracks[0].clips[0].frameBlend, "mix")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, before)
        XCTAssertFalse(editor.mixesFrames(clipId: "clip:a"))
    }

    func testOnARampTheSwitchWritesTheRampsBlendAndOffRemovesIt() throws {
        let (p, editor) = try panel(#""speedRamp":{"v":1,"kind":"speed-ramp","points":[{"t":0,"speed":0.5}]},"#)
        try XCTUnwrap(mixRow(p)).set(true)
        XCTAssertEqual(editor.document.sequence.tracks[0].clips[0].speedRamp?.blend, "mix")
        XCTAssertNil(editor.document.sequence.tracks[0].clips[0].frameBlend)
        try XCTUnwrap(mixRow(p)).set(false)
        XCTAssertNil(editor.document.sequence.tracks[0].clips[0].speedRamp?.blend, "off is an absent key")
    }

    func testALockedTrackRefusesTheSwitch() throws {
        let (_, editor) = try panel()
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:a", 0.5))
        XCTAssertTrue(editor.setTrackLocked("track:v1", true))
        XCTAssertFalse(editor.setMixesFrames(clipId: "clip:a", true))
        XCTAssertFalse(editor.mixesFrames(clipId: "clip:a"))
    }
}
