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
import MpvfxShared
import OneTakeKeyframes
@testable import MpvfxTimeline

/// Distort edits (#451): each one is a single undo step and survives a save.
final class CornerPinEditTests: XCTestCase {
    func testSettingCornersIsOneUndoStepAndReloads() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let skew = NativeClipCorners(tl: .init(x: 0.2), br: .init(x: -0.1, y: 0.05))
        XCTAssertTrue(e.setCorners(clipId: "clip:a", skew, time: 0))
        XCTAssertEqual(e.corners(clipId: "clip:a", time: 0), skew)
        XCTAssertFalse(e.setCorners(clipId: "clip:a", skew, time: 0), "no change, no undo step")
        XCTAssertEqual(e.undoLabel, TimelineEditor.distortLabel)
        let reloaded = try TimelineEditor(json: try serializeNativeProjectDocument(e.document))
        XCTAssertEqual(reloaded.corners(clipId: "clip:a", time: 0), skew)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.corners(clipId: "clip:a", time: 0), .identity)
        XCTAssertFalse(e.canUndo, "one edit was one undo step")
        XCTAssertTrue(e.redo())
    }

    func testResetRemovesCornersAndKeyframesInOneStep() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        XCTAssertFalse(e.resetCorners(clipId: "clip:a"), "nothing to reset")
        XCTAssertTrue(e.setCorners(clipId: "clip:a", NativeClipCorners(tr: .init(y: 0.3)), time: 0, keyframed: true))
        XCTAssertTrue(e.hasCornerState(clipId: "clip:a"))
        XCTAssertTrue(e.resetCorners(clipId: "clip:a"))
        XCTAssertFalse(e.hasCornerState(clipId: "clip:a"))
        XCTAssertEqual(e.undoLabel, TimelineEditor.resetDistortLabel)
        XCTAssertTrue(e.undo())
        XCTAssertTrue(e.hasCornerState(clipId: "clip:a"), "undo restores the distort and its keyframes together")
    }
}
