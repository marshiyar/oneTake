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

/// Issue #300: the colour key is one `color-key` effect per clip, written with defaults omitted, one undo step per edit.
final class ColorKeyEditTests: XCTestCase {
    func editor() throws -> TimelineEditor { try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime()) }

    func testAddingTheKeyWritesOnlyWhatDiffersFromTheDefaultsInOneUndoStep() throws {
        let e = try editor()
        XCTAssertNil(e.colorKey(clipId: "natural")); XCTAssertFalse(e.isColorKeyEnabled(clipId: "natural"))
        XCTAssertTrue(e.setColorKey(clipId: "natural", ColorKeySettings()))
        let effect = try XCTUnwrap(e.clip("natural")?.clip.effects.first)
        XCTAssertEqual(effect.effectId, "color-key"); XCTAssertEqual(effect.id, "effect:color-key-1"); XCTAssertTrue(effect.enabled)
        XCTAssertEqual(effect.parameters, ["v": .number(1), "kind": .string("chroma")], "a default key stores just v and kind")
        XCTAssertEqual(e.colorKey(clipId: "natural"), ColorKeySettings())
        var s = ColorKeySettings(); s.color = [0.1, 0.2, 0.9]; s.similarity = 0.3; s.spill = 0.5
        XCTAssertTrue(e.setColorKey(clipId: "natural", s))
        XCTAssertEqual(e.colorKey(clipId: "natural"), s)
        XCTAssertFalse(e.setColorKey(clipId: "natural", s), "the same key is no edit")
        _ = e.undo()
        XCTAssertEqual(e.colorKey(clipId: "natural"), ColorKeySettings())
        _ = e.undo()
        XCTAssertNil(e.colorKey(clipId: "natural")); XCTAssertTrue(e.clip("natural")?.clip.effects.isEmpty ?? false)
    }

    func testOutOfRangeValuesAreRefusedAndTheKeyCanBeSwitchedOffAndRemoved() throws {
        let e = try editor()
        XCTAssertTrue(e.setColorKey(clipId: "natural", ColorKeySettings()))
        var bad = ColorKeySettings(); bad.similarity = 1.5
        XCTAssertFalse(e.setColorKey(clipId: "natural", bad), "a similarity above 1 is refused")
        bad = ColorKeySettings(); bad.color = [0, 2, 0]
        XCTAssertFalse(e.setColorKey(clipId: "natural", bad))
        XCTAssertEqual(e.colorKey(clipId: "natural"), ColorKeySettings())
        XCTAssertTrue(e.setColorKeyEnabled(clipId: "natural", false))
        XCTAssertFalse(e.isColorKeyEnabled(clipId: "natural")); XCTAssertNotNil(e.colorKey(clipId: "natural"), "settings stay")
        XCTAssertFalse(e.setColorKeyEnabled(clipId: "natural", false))
        XCTAssertTrue(e.setColorKey(clipId: "natural", nil))
        XCTAssertNil(e.colorKey(clipId: "natural"))
        XCTAssertFalse(e.setColorKey(clipId: "natural", nil), "nothing to remove")
    }

    func testAKeyFromANewerVersionStaysAsItIsAndLockedClipsAreRefused() throws {
        let e = try editor()
        var d = e.document
        d.sequence.tracks[0].clips[0].effects = [NativeClipEffect(id: "effect:k", effectId: "color-key", enabled: true,
                                                                  parameters: ["v": .number(2), "kind": .string("chroma"), "future": .bool(true)])]
        e.replaceDocument(try parseNativeProjectDocument(d, engine: e.engine), inverse: .restoreDocument(e.document))
        XCTAssertNil(e.colorKey(clipId: "natural"), "not a version-1 key")
        XCTAssertFalse(e.setColorKey(clipId: "natural", ColorKeySettings()), "left alone")
        XCTAssertFalse(e.setColorKey(clipId: "natural", nil))
        XCTAssertEqual(e.clip("natural")?.clip.effects.first?.parameters?["future"], .bool(true))
        XCTAssertTrue(e.setTrackLocked("v1", true))
        XCTAssertFalse(e.setColorKey(clipId: "placed", ColorKeySettings()))
    }
}
