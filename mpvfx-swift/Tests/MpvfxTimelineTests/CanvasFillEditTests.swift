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

/// Canvas fill edits are one undo step each, saved with the document, and refused when the document would not take them.
final class CanvasFillEditTests: XCTestCase {
    func editor() throws -> TimelineEditor { try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime()) }

    func testSettingTheProjectFillIsOneUndoStepAndSurvivesReopening() throws {
        let e = try editor()
        let fill = NativeFill(kind: "color", color: "#112233")
        XCTAssertTrue(e.setCompositionCanvasFill(fill))
        XCTAssertEqual(e.document.compositionFill, fill)
        XCTAssertFalse(e.setCompositionCanvasFill(fill), "the same fill is no edit")
        let reopened = try TimelineEditor(json: try serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
        XCTAssertEqual(reopened.document.compositionFill?.color, "#112233")
        _ = e.undo()
        XCTAssertNil(e.document.compositionFill, "one undo removes it")
    }

    func testAClipFillIsOneUndoStepAndABadFillIsRefused() throws {
        let e = try editor()
        XCTAssertTrue(e.setClipCanvasFill(clipId: "natural", NativeFill(kind: "blur", blur: 30)))
        XCTAssertEqual(e.clip("natural")?.clip.fill?.blur, 30)
        XCTAssertFalse(e.setClipCanvasFill(clipId: "natural", NativeFill(kind: "blur", blur: 999)), "out of range")
        XCTAssertFalse(e.setClipCanvasFill(clipId: "missing", NativeFill(kind: "none")))
        XCTAssertFalse(e.setCompositionCanvasFill(NativeFill(kind: "image", assetId: "sq")), "a video is not an image fill")
        XCTAssertEqual(e.clip("natural")?.clip.fill?.blur, 30)
        _ = e.undo()
        XCTAssertNil(e.clip("natural")?.clip.fill)
    }
    // MARK: Clip menu toggle (issue #320 A2)

    func testToggleOnThreeClipsIsOneUndoStepAndTurnsAnEmptyFillIntoABlurredCopy() throws {
        let e = try editor()
        let ids: Set<String> = ["natural", "placed", "legacy"]
        XCTAssertFalse(e.canvasFillIsOn(clipIds: ids), "no project fill and no clip fill: bars")
        XCTAssertTrue(e.toggleCanvasFill(clipIds: ids))
        XCTAssertEqual(e.undoLabel, "Set canvas fill")
        for id in ids { XCTAssertEqual(e.clip(id)?.clip.fill?.kind, "blur", id) }
        XCTAssertTrue(e.canvasFillIsOn(clipIds: ids))
        XCTAssertNil(e.clip("cropped")?.clip.fill, "clips outside the selection are untouched")
        _ = e.undo()
        for id in ids { XCTAssertNil(e.clip(id)?.clip.fill, "\(id): one undo restores all three") }
        XCTAssertFalse(e.canUndo, "the toggle recorded exactly one step")
        _ = e.redo()
        XCTAssertTrue(e.toggleCanvasFill(clipIds: ids), "toggled off")
        for id in ids { XCTAssertEqual(e.clip(id)?.clip.fill?.kind, "none", id) }
        XCTAssertFalse(e.canvasFillIsOn(clipIds: ids))
        _ = e.undo()
        for id in ids { XCTAssertEqual(e.clip(id)?.clip.fill?.kind, "blur", id) }
    }

    func testToggleOnFollowsTheProjectFillAndAMixedSelectionTurnsOn() throws {
        let e = try editor()
        XCTAssertTrue(e.setCompositionCanvasFill(NativeFill(kind: "color", color: "#112233")))
        XCTAssertTrue(e.canvasFillIsOn(clipIds: ["natural"]), "a clip with no fill of its own shows the project's")
        XCTAssertTrue(e.toggleCanvasFill(clipIds: ["natural"]))
        XCTAssertEqual(e.clip("natural")?.clip.fill?.kind, "none")
        XCTAssertFalse(e.canvasFillIsOn(clipIds: ["natural", "placed"]))
        XCTAssertTrue(e.toggleCanvasFill(clipIds: ["natural", "placed"]), "mixed: everything goes on")
        XCTAssertNil(e.clip("natural")?.clip.fill, "back to the project's fill")
        XCTAssertNil(e.clip("placed")?.clip.fill)
        XCTAssertTrue(e.canvasFillIsOn(clipIds: ["natural", "placed"]))
    }

    func testToggleSkipsLockedAndMissingClipsAndRefusesAnEmptySelection() throws {
        let e = try editor()
        XCTAssertTrue(e.setTrackLocked("v1", true))
        XCTAssertFalse(e.toggleCanvasFill(clipIds: ["natural"]), "a locked track refuses the edit")
        XCTAssertNil(e.clip("natural")?.clip.fill)
        XCTAssertTrue(e.setTrackLocked("v1", false))
        XCTAssertFalse(e.toggleCanvasFill(clipIds: []))
        XCTAssertFalse(e.toggleCanvasFill(clipIds: ["missing"]))
        XCTAssertFalse(e.canvasFillIsOn(clipIds: []))
    }
}
