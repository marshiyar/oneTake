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
import OneTakeKeyframes
@testable import MpvfxTimeline

/// Marking clips as template placeholders: numbered from 1, one undo step each, and filled by replacing the media.
final class TimelinePlaceholderTests: XCTestCase {
    func make() throws -> TimelineEditor {
        try TimelineEditor(json: TimelineChunk6Tests.json, engine: try? KeyframeRuntime())
    }

    func asset(_ frames: Double = 600) -> NativeProjectAsset {
        NativeProjectAsset(id: "replacement", kind: .video, name: "New take", source: "new.mov", durationFrames: frames)
    }

    func testMarkingTakesTheLowestFreeNumberAndUndoesInOneStep() throws {
        let e = try make()
        let before = e.document
        XCTAssertTrue(e.markPlaceholder(clipId: "clip:a"))
        XCTAssertEqual(e.clip("clip:a")?.clip.placeholder, NativeClipPlaceholder(index: 1))
        XCTAssertTrue(e.markPlaceholder(clipId: "clip:m1"))
        XCTAssertTrue(e.markPlaceholder(clipId: "clip:m2"))
        XCTAssertEqual(e.document.unfilledPlaceholderNumbers, [1, 2, 3])
        XCTAssertEqual(e.undoStack.count, 3)
        XCTAssertEqual(e.undoLabel, "Mark as placeholder")
        XCTAssertTrue(e.clearPlaceholder(clipId: "clip:m1"))
        XCTAssertEqual(e.document.unfilledPlaceholderNumbers, [1, 3])
        XCTAssertTrue(e.markPlaceholder(clipId: "clip:m1"), "the freed number is taken again")
        XCTAssertEqual(e.clip("clip:m1")?.clip.placeholder?.number, 2)
        for _ in 0..<5 { _ = e.undo() }
        XCTAssertEqual(e.document, before)
    }

    func testRefusals() throws {
        let e = try make()
        XCTAssertFalse(e.markPlaceholder(clipId: "clip:missing"))
        XCTAssertEqual(e.lastFailure?.code, .missingClip)
        XCTAssertTrue(e.markPlaceholder(clipId: "clip:a"))
        XCTAssertFalse(e.markPlaceholder(clipId: "clip:a"))
        XCTAssertEqual(e.lastFailure?.message, "This clip is already a placeholder")
        XCTAssertFalse(e.clearPlaceholder(clipId: "clip:m1"), "nothing to clear")
        XCTAssertEqual(e.undoStack.count, 1)
        var d = e.document
        d.sequence.tracks[1].locked = true
        let locked = TimelineEditor(document: d)
        XCTAssertFalse(locked.markPlaceholder(clipId: "clip:m1"))
        XCTAssertEqual(locked.lastFailure?.message, "Track is locked")
        var elements = e.document
        elements.assets.append(NativeProjectAsset(id: "asset:t", kind: .element, name: "Title", durationFrames: 90))
        elements.sequence.tracks[0].clips[0].assetId = "asset:t"
        elements.sequence.tracks[0].clips[0].placeholder = nil
        let text = TimelineEditor(document: elements)
        XCTAssertFalse(text.markPlaceholder(clipId: "clip:a"))
        XCTAssertEqual(text.lastFailure?.code, .incompatibleDestination)
    }

    func testReplacingMediaFillsThePlaceholderInTheSameUndoStep() throws {
        let e = try make()
        XCTAssertTrue(e.markPlaceholder(clipId: "clip:a"))
        let marked = e.document
        XCTAssertTrue(e.replaceMedia(clipId: "clip:a", asset: asset()))
        XCTAssertNil(e.clip("clip:a")?.clip.placeholder)
        XCTAssertEqual(e.clip("clip:a")?.clip.assetId, "replacement")
        XCTAssertEqual(e.document.unfilledPlaceholderNumbers, [])
        XCTAssertEqual(e.undoStack.count, 2)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, marked)
    }

    func testAPlaceholderFromANewerVersionIsNotTouched() throws {
        let e = try make()
        var d = e.document
        d.sequence.tracks[0].clips[0].placeholder = try JSONDecoder().decode(NativeClipPlaceholder.self, from: Data(#"{"v":2,"slot":1}"#.utf8))
        let newer = TimelineEditor(document: d)
        XCTAssertFalse(newer.markPlaceholder(clipId: "clip:a"))
        XCTAssertFalse(newer.clearPlaceholder(clipId: "clip:a"))
        XCTAssertEqual(newer.document, d)
    }

    func controller() throws -> (TimelineController, TimelineEditor) {
        let e = try make()
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1200, 600)
        return (c, e)
    }

    func testTheClipModelAndTheClipMenuFollowTheMarker() throws {
        let (c, e) = try controller()
        func model(_ id: String) -> TimelineClipModel? { c.view.tracks.flatMap(\.clips).first { $0.id == id } }
        func label() -> String? {
            c.view.clipMenu?.entries.compactMap { entry -> TimelineClipMenu.Item? in
                if case .item(let item) = entry, item.action == .placeholder { return item }; return nil
            }.first?.label
        }
        XCTAssertNil(model("clip:a")?.placeholder)
        c.openClipMenu("clip:a", x: 10, y: 10)
        XCTAssertEqual(label(), "Mark as placeholder")
        XCTAssertTrue(c.runClipMenu(.placeholder, clipId: "clip:a"))
        XCTAssertEqual(model("clip:a")?.placeholder, 1)
        c.openClipMenu("clip:a", x: 10, y: 10)
        XCTAssertEqual(label(), "Unmark placeholder")
        XCTAssertTrue(c.runClipMenu(.placeholder, clipId: "clip:a"))
        XCTAssertNil(model("clip:a")?.placeholder)
        XCTAssertNil(e.clip("clip:a")?.clip.placeholder)
    }

    func testOptionCommandPTogglesTheSelectedClips() throws {
        let (c, e) = try controller()
        c.view.selection = ["clip:m1", "clip:a"]
        XCTAssertTrue(c.keyDown(EditorKey(.char("p"), meta: true, alt: true)))
        XCTAssertEqual(e.clip("clip:a")?.clip.placeholder?.number, 1, "numbered in timeline order")
        XCTAssertEqual(e.clip("clip:m1")?.clip.placeholder?.number, 2)
        XCTAssertTrue(c.keyDown(EditorKey(.char("p"), meta: true, alt: true)), "all marked: unmark them")
        XCTAssertEqual(e.document.unfilledPlaceholderNumbers, [])
    }
}
