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
@testable import MpvfxTimeline
import MpvfxCanvas
import MpvfxShared

/// Ripple, track ops, snapping toggle, duplicate / select all, and undo coverage.
final class TimelineEditingOpsTests: XCTestCase {
    // demoJSON @30fps: v2 [logo 15..105], v1 [a 0..180, b 195..315], a1 [music 0..330].
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(pixelsPerSecond: 100)
        return (c, e)
    }
    func clip(_ e: TimelineEditor, _ id: String) -> NativeProjectClip? {
        e.document.sequence.tracks.flatMap(\.clips).first { $0.id == id }
    }
    func track(_ e: TimelineEditor, _ id: String) -> NativeProjectTrack? { e.document.sequence.tracks.first { $0.id == id } }
    func assertUndoRedo(_ e: TimelineEditor, before: NativeProjectDocument, file: StaticString = #filePath, line: UInt = #line) {
        let after = e.document
        XCTAssertTrue(e.undo(), file: file, line: line); XCTAssertEqual(e.document, before, "undo restores", file: file, line: line)
        XCTAssertTrue(e.redo(), file: file, line: line); XCTAssertEqual(e.document, after, "redo reapplies", file: file, line: line)
    }

    // MARK: Ripple

    func testRippleDeletePullsLaneLeftOnly() throws {
        let (_, e) = try make(); let before = e.document
        XCTAssertTrue(e.rippleDelete(["clip:a"]))
        XCTAssertNil(clip(e, "clip:a"))
        XCTAssertEqual(clip(e, "clip:b")?.startFrame, 15, "b moves left by a's 180 frames")
        XCTAssertEqual(clip(e, "clip:music")?.startFrame, 0, "other lanes stay put")
        XCTAssertEqual(clip(e, "clip:logo")?.startFrame, 15)
        XCTAssertEqual(e.undoStack.count, 1, "one undo step")
        assertUndoRedo(e, before: before)
    }

    func testRippleDeleteWholeLaneAndAcrossLanes() throws {
        let (_, e) = try make()
        XCTAssertTrue(e.rippleDelete(["clip:a", "clip:logo"]))
        XCTAssertEqual(clip(e, "clip:b")?.startFrame, 15)
        XCTAssertEqual(track(e, "track:v2")?.clips.count, 0)
        XCTAssertFalse(e.rippleDelete(["nope"]))
    }

    func testRippleHolesIgnoreSpansStillCovered() {
        let holes = TimelineEditor.subtract(TimelineEditor.union([(0, 100), (50, 150), (200, 250)]), [(120, 210)])
        XCTAssertEqual(holes.map { [$0.0, $0.1] }, [[0, 120], [210, 250]])
    }

    func testRippleTrimEndShrinkAndExtend() throws {
        let (_, e) = try make(); let before = e.document
        XCTAssertTrue(e.rippleTrim(clipId: "clip:a", edge: .end, toFrame: 150))
        XCTAssertEqual(clip(e, "clip:a")?.durationFrames, 150)
        XCTAssertEqual(clip(e, "clip:b")?.startFrame, 165, "the 15-frame gap is preserved")
        assertUndoRedo(e, before: before)
        XCTAssertTrue(e.undo())
        XCTAssertTrue(e.rippleTrim(clipId: "clip:a", edge: .end, toFrame: 200))
        XCTAssertEqual(clip(e, "clip:a")?.durationFrames, 200); XCTAssertEqual(clip(e, "clip:b")?.startFrame, 215)
        XCTAssertFalse(e.rippleTrim(clipId: "clip:a", edge: .end, toFrame: 200), "no-op")
    }

    func testRippleTrimStartKeepsPositionAndShiftsFollowers() throws {
        let (_, e) = try make(); let before = e.document
        XCTAssertTrue(e.rippleTrim(clipId: "clip:a", edge: .start, toFrame: 30))
        XCTAssertEqual(clip(e, "clip:a")?.startFrame, 0); XCTAssertEqual(clip(e, "clip:a")?.durationFrames, 150)
        XCTAssertEqual(clip(e, "clip:a")?.sourceInFrame, 30)
        XCTAssertEqual(clip(e, "clip:b")?.startFrame, 165)
        assertUndoRedo(e, before: before)
        // Extend the head back by 20 frames: clip stays at 0, followers move right.
        XCTAssertTrue(e.rippleTrim(clipId: "clip:a", edge: .start, toFrame: -20))
        XCTAssertEqual(clip(e, "clip:a")?.startFrame, 0); XCTAssertEqual(clip(e, "clip:a")?.sourceInFrame, 10)
        XCTAssertEqual(clip(e, "clip:a")?.durationFrames, 170); XCTAssertEqual(clip(e, "clip:b")?.startFrame, 185)
        XCTAssertFalse(e.rippleTrim(clipId: "clip:a", edge: .start, toFrame: -100), "cannot extend past the source start")
        XCTAssertEqual(clip(e, "clip:a")?.sourceInFrame, 10, "failed transaction leaves the document alone")
    }

    func testAltDragTrimRipplesAndShiftDeleteRipples() throws {
        let (c, e) = try make()
        let y1 = TimelineLayout.rowTop(1) + 20
        c.pointerDown(x: 264 + 597, y: y1, alt: true)     // clip:a end handle
        c.pointerMove(x: 264 + 450, y: y1); c.pointerUp(x: 264 + 450, y: y1)
        XCTAssertEqual(clip(e, "clip:a")?.durationFrames, 135)
        XCTAssertEqual(clip(e, "clip:b")?.startFrame, 150)
        c.view.selection = ["clip:a"]
        XCTAssertTrue(c.keyDown(EditorKey(.delete, shift: true)))
        XCTAssertEqual(clip(e, "clip:b")?.startFrame, 15)
        XCTAssertTrue(c.view.selection.isEmpty)
    }

    func testCloseAllGapsEverywhere() throws {
        let (c, e) = try make(); let before = e.document
        XCTAssertTrue(c.closeAllGapsEverywhere())
        XCTAssertEqual(clip(e, "clip:logo")?.startFrame, 0); XCTAssertEqual(clip(e, "clip:b")?.startFrame, 180)
        assertUndoRedo(e, before: before)
        XCTAssertTrue(e.undo())
        XCTAssertTrue(c.closeGap(row: 1, at: 6.2)); XCTAssertEqual(clip(e, "clip:b")?.startFrame, 180)
    }

    // MARK: Tracks

    func testAddTrackAtPositionAndUndo() throws {
        let (c, e) = try make(); let before = e.document
        let id = try XCTUnwrap(c.addTrack(kind: .video, below: 0))
        XCTAssertEqual(e.displayTrackIds, ["track:v2", id, "track:v1", "track:a1"])
        XCTAssertEqual(track(e, id)?.lane?.authoredTrack, 3, "next free authored video lane")
        XCTAssertEqual(c.view.tracks.map(\.id), e.displayTrackIds)
        assertUndoRedo(e, before: before)
        let audio = try XCTUnwrap(e.addTrack(kind: .audio))
        XCTAssertEqual(e.displayTrackIds.last, audio)
        XCTAssertNotEqual(audio, id)
    }

    func testRemoveTrackDropsClipsAndRenumbers() throws {
        let (c, e) = try make(); let before = e.document
        XCTAssertTrue(c.removeTrack(row: 1))
        XCTAssertNil(track(e, "track:v1")); XCTAssertNil(clip(e, "clip:a"))
        XCTAssertEqual(e.document.sequence.tracks.compactMap { $0.lane?.displayTrack }.sorted(), [0, 1])
        XCTAssertEqual(e.undoStack.count, 1)
        assertUndoRedo(e, before: before)
    }

    func testMoveTrackReorders() throws {
        let (c, e) = try make(); let before = e.document
        XCTAssertTrue(c.moveTrack(row: 2, by: -2))
        XCTAssertEqual(e.displayTrackIds, ["track:a1", "track:v2", "track:v1"])
        XCTAssertFalse(e.moveTrack("track:a1", to: 0), "already there")
        assertUndoRedo(e, before: before)
    }

    func testHideMuteLock() throws {
        let (c, e) = try make()
        // Hide: dropped from stage elements, flagged on the model.
        XCTAssertTrue(e.activeElements(at: 1).contains { $0.id == "clip:a" })
        XCTAssertTrue(c.toggleTrackHidden(row: 1))
        XCTAssertTrue(c.view.tracks[1].hidden); XCTAssertEqual(track(e, "track:v1")?.hidden, true)
        XCTAssertFalse(e.activeElements(at: 1).contains { $0.id == "clip:a" })
        XCTAssertTrue(c.toggleTrackHidden(row: 1)); XCTAssertNil(track(e, "track:v1")?.hidden)
        // Mute: every clip on the track.
        XCTAssertTrue(c.toggleTrackMuted(row: 1))
        XCTAssertTrue(c.view.tracks[1].muted); XCTAssertTrue(e.isTrackMuted("track:v1"))
        XCTAssertEqual(track(e, "track:v1")?.clips.map(\.muted), [true, true])
        XCTAssertTrue(e.undo()); XCTAssertFalse(e.isTrackMuted("track:v1"))
        // Lock: edits refused, unlock allowed.
        XCTAssertTrue(c.toggleTrackLocked(row: 1)); XCTAssertTrue(c.view.tracks[1].locked)
        let locked = e.document
        let a = try XCTUnwrap(e.address(clipId: "clip:a"))
        XCTAssertFalse(e.apply(.trimOut(address: a, endFrameExclusive: 90)))
        XCTAssertFalse(e.apply(.split(address: a, splitFrame: 90)))
        XCTAssertFalse(e.apply(.delete(address: a)))
        let m = try XCTUnwrap(e.address(clipId: "clip:logo"))
        XCTAssertFalse(e.apply(.move(address: m, destination: .init(trackId: "track:v1", startFrame: 400))), "cannot move into a locked track")
        XCTAssertFalse(e.rippleDelete(["clip:a"])); XCTAssertFalse(e.rippleTrim(clipId: "clip:a", edge: .end, toFrame: 90))
        XCTAssertFalse(e.setMuted(clipId: "clip:a", true)); XCTAssertFalse(e.setTrackMuted("track:v1", true))
        XCTAssertFalse(e.removeTrack("track:v1"))
        XCTAssertTrue(e.paste(try XCTUnwrap(e.copyClips(["clip:a"])), at: 20).isEmpty)
        let y1 = TimelineLayout.rowTop(1) + 20
        c.pointerDown(x: 264 + 100, y: y1); c.pointerMove(x: 264 + 300, y: y1); c.pointerUp(x: 264 + 300, y: y1)
        XCTAssertEqual(c.view.selection, ["clip:a"], "still selectable"); XCTAssertNil(c.view.drag)
        XCTAssertEqual(e.document, locked, "nothing changed while locked")
        XCTAssertTrue(c.toggleTrackLocked(row: 1)); XCTAssertNil(track(e, "track:v1")?.locked)
        XCTAssertTrue(e.apply(.trimOut(address: a, endFrameExclusive: 90)))
    }

    func testTrackFlagsSurviveSerializeAndRejectNonBooleans() throws {
        let (_, e) = try make()
        e.setTrackHidden("track:v2", true); e.setTrackLocked("track:a1", true)
        let json = try serializeNativeProjectDocument(try NativeJSONValue.from(e.document))
        let back = try parseNativeProjectDocument(try NativeJSONValue.parse(json))
        XCTAssertEqual(back.sequence.tracks.first { $0.id == "track:v2" }?.hidden, true)
        XCTAssertEqual(back.sequence.tracks.first { $0.id == "track:a1" }?.locked, true)
        XCTAssertNil(back.sequence.tracks.first { $0.id == "track:v1" }?.hidden, "absent stays absent")
        var raw = try NativeJSONValue.parse(json)
        var seq = raw["sequence"]!; var tracks = seq["tracks"]!.arrayValue!
        tracks[0]["locked"] = .string("yes"); seq["tracks"] = .array(tracks); raw["sequence"] = seq
        XCTAssertThrowsError(try parseNativeProjectDocument(raw))
    }

    // MARK: Snapping, duplicate, select all

    func testNTogglesSnapping() throws {
        let (c, e) = try make()
        let y1 = TimelineLayout.rowTop(1) + 20
        XCTAssertTrue(c.keyDown(EditorKey(.char("n")))); XCTAssertFalse(c.snapEnabled)
        c.pointerDown(x: 264 + 700, y: y1)
        c.pointerMove(x: 264 + 700 - 47, y: y1)          // 6.03s: would snap to 6.0 with snapping on
        if case .move(_, _, _, let snap)? = c.view.drag { XCTAssertNil(snap) } else { XCTFail("no drag") }
        c.pointerUp(x: 0, y: y1)
        XCTAssertEqual(try XCTUnwrap(clip(e, "clip:b")?.startFrame), 181, accuracy: 1)
        XCTAssertTrue(c.keyDown(EditorKey(.char("N")))); XCTAssertTrue(c.snapEnabled)
    }

    func testDuplicateAndSelectAll() throws {
        let (c, e) = try make()
        c.view.selection = ["clip:b"]
        c.copySelection(); let clipboard = c.clipboard
        c.view.selection = ["clip:a"]
        XCTAssertTrue(c.keyDown(EditorKey(.char("d"), meta: true)))
        let dup = try XCTUnwrap(c.view.selection.first)
        XCTAssertNotEqual(dup, "clip:a")
        XCTAssertEqual(clip(e, dup)?.startFrame, 180, "lands at the source clip's end")
        XCTAssertEqual(e.address(clipId: dup)?.trackId, "track:v1")
        XCTAssertEqual(c.clipboard, clipboard, "duplicate leaves the clipboard alone")
        XCTAssertTrue(e.undo()); XCTAssertNil(clip(e, dup))
        XCTAssertTrue(c.keyDown(EditorKey(.char("a"), ctrl: true)))
        XCTAssertEqual(c.view.selection, ["clip:logo", "clip:a", "clip:b", "clip:music"])
        XCTAssertFalse(c.duplicateSelection(), "one clip at a time")
    }

    // MARK: Undo coverage

    func testEveryOpIsOneUndoStep() throws {
        let ops: [(String, (TimelineController, TimelineEditor) -> Bool)] = [
            ("rippleDelete", { _, e in e.rippleDelete(["clip:a"]) }),
            ("rippleTrimEnd", { _, e in e.rippleTrim(clipId: "clip:a", edge: .end, toFrame: 120) }),
            ("rippleTrimStart", { _, e in e.rippleTrim(clipId: "clip:a", edge: .start, toFrame: 60) }),
            ("closeGap", { _, e in e.closeGap(trackId: "track:v1", at: 6.2) }),
            ("closeAllGaps", { _, e in e.closeAllGapsEverywhere() }),
            ("addTrack", { _, e in e.addTrack(kind: .audio, at: 0) != nil }),
            ("removeTrack", { _, e in e.removeTrack("track:a1") }),
            ("moveTrack", { _, e in e.moveTrack("track:v2", to: 2) }),
            ("hide", { _, e in e.setTrackHidden("track:v1", true) }),
            ("lock", { _, e in e.setTrackLocked("track:v1", true) }),
            ("mute", { _, e in e.setTrackMuted("track:a1", true) }),
            ("duplicate", { c, _ in c.view.selection = ["clip:b"]; return c.duplicateSelection() }),
            ("paste", { c, _ in c.view.selection = ["clip:a", "clip:b"]; c.copySelection(); return c.pasteClipboard() }),
            ("split", { c, _ in c.playback.seek(2); return c.splitAtPlayhead() }),
            ("delete", { c, _ in c.view.selection = ["clip:music"]; return c.keyDown(EditorKey(.delete)) }),
        ]
        for (name, op) in ops {
            let (c, e) = try make(); let before = e.document
            XCTAssertTrue(op(c, e), name)
            XCTAssertEqual(e.undoStack.count, 1, "\(name): one undo step")
            XCTAssertNotEqual(e.document, before, name)
            assertUndoRedo(e, before: before)
        }
    }
}

final class TimelineSplitUndoTests: XCTestCase {
    func testRazorShiftClickSplitsAllTracksInOneUndoStep() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(pixelsPerSecond: 100)
        let before = e.document
        c.tool = .razor
        c.pointerDown(x: 264 + 200, y: TimelineLayout.rowTop(1) + 20, shift: true)   // 2s: logo, a, music
        XCTAssertEqual(e.document.sequence.tracks.flatMap(\.clips).count, 7)
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
    }
}
