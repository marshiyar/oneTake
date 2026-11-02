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

/// Issue #297: mask edits are one undo step each, saved with the document, and refused when the document would not take them.
final class MaskEditTests: XCTestCase {
    func editor() throws -> TimelineEditor { try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime()) }

    func testA1AddingARectangleMaskIsOneUndoStepAtTheLayersCentre() throws {
        let e = try editor()
        let id = try XCTUnwrap(e.addMask(clipId: "natural"))
        XCTAssertEqual(id, "mask-1")
        let mask = try XCTUnwrap(e.masks(clipId: "natural").first)
        XCTAssertEqual(mask.kind, "rectangle"); XCTAssertEqual(mask.x, 0.5); XCTAssertEqual(mask.y, 0.5)
        XCTAssertEqual(mask.width, 0.5); XCTAssertEqual(mask.height, 0.5)
        XCTAssertEqual(e.undoLabel, "Add mask")
        _ = e.undo()
        XCTAssertNil(e.clip("natural")?.clip.masks, "one undo removes it and omits the key")
        XCTAssertFalse(e.canUndo)
    }

    func testEveryKindCanBeAddedAndIdsAreNeverReused() throws {
        let e = try editor()
        let ids = ["rectangle", "ellipse", "linear", "band"].compactMap { e.addMask(clipId: "natural", kind: /opt/homebrew/bin/bash) }
        XCTAssertEqual(ids, ["mask-1", "mask-2", "mask-3", "mask-4"])
        XCTAssertTrue(e.removeMask(clipId: "natural", maskId: "mask-2"))
        XCTAssertEqual(e.addMask(clipId: "natural"), "mask-5")
        XCTAssertNil(e.addMask(clipId: "natural", kind: "pen"), "a kind this version does not draw")
        let reopened = try TimelineEditor(json: try serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
        XCTAssertEqual(reopened.masks(clipId: "natural").map(\.id), ["mask-1", "mask-3", "mask-4", "mask-5"])
    }

    func testChangingAMaskIsOneStepARefusedValueRecordsNothingAndABurstFoldsIntoOne() throws {
        let e = try editor()
        let id = try XCTUnwrap(e.addMask(clipId: "natural"))
        XCTAssertTrue(e.setMask(clipId: "natural", maskId: id) { $0.width = 0.8 })
        XCTAssertEqual(e.masks(clipId: "natural").first?.width, 0.8)
        XCTAssertFalse(e.setMask(clipId: "natural", maskId: id) { $0.width = 0.8 }, "no change is no edit")
        XCTAssertFalse(e.setMask(clipId: "natural", maskId: id) { $0.width = -1 }, "a negative width is refused")
        XCTAssertFalse(e.setMask(clipId: "natural", maskId: id) { $0.opacity = 2 })
        XCTAssertFalse(e.setMask(clipId: "natural", maskId: "missing") { $0.width = 0.1 })
        XCTAssertEqual(e.masks(clipId: "natural").first?.width, 0.8)
        for step in 1...5 { XCTAssertTrue(e.setMask(clipId: "natural", maskId: id, coalesceKey: "nudge") { $0.x = 0.5 + Double(step) * 0.01 }) }
        XCTAssertEqual(try XCTUnwrap(e.masks(clipId: "natural").first?.x), 0.55, accuracy: 1e-9)
        _ = e.undo()
        XCTAssertEqual(try XCTUnwrap(e.masks(clipId: "natural").first?.x), 0.5, accuracy: 1e-9, "five nudges are one undo step")
        XCTAssertEqual(e.masks(clipId: "natural").first?.width, 0.8)
    }

    func testLockedTracksAndMissingClipsAreRefused() throws {
        let e = try editor()
        XCTAssertNil(e.addMask(clipId: "missing"))
        XCTAssertTrue(e.setTrackLocked("v1", true))
        XCTAssertNil(e.addMask(clipId: "natural"))
        XCTAssertTrue(e.setTrackLocked("v1", false))
        let id = try XCTUnwrap(e.addMask(clipId: "natural"))
        XCTAssertTrue(e.setTrackLocked("v1", true))
        XCTAssertFalse(e.setMask(clipId: "natural", maskId: id) { $0.width = 0.9 })
        XCTAssertFalse(e.removeMask(clipId: "natural", maskId: id))
    }
}
