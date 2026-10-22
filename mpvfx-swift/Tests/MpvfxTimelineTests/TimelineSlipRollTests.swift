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
// Slip (issue #87) and roll (issue #88) through the timeline editor and its pointer gestures.
import XCTest
import OneTakeKeyframes
@testable import MpvfxTimeline
@testable import MpvfxShared
import MpvfxCanvas

final class TimelineSlipRollTests: XCTestCase {
    /// v1: clip:a [0,120) plays source 30..<150 with rotation keys at clip frames 10 and 100; clip:b [120,240) plays
    /// 60..<180; clip:c [300,360) sits after a gap. v2 holds a still and a text-layer clip; v3 is locked.
    static let json = """
    {"schemaVersion":1,"id":"project:sliproll","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#111111"},
     "assets":[{"id":"asset:a","kind":"video","name":"a.mp4","durationFrames":600},{"id":"asset:b","kind":"video","name":"b.mp4","durationFrames":600},
               {"id":"asset:logo","kind":"image","name":"logo.png","durationFrames":900},{"id":"asset:title","kind":"element","name":"Title","durationFrames":900}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[
      {"id":"track:v2","kind":"video","lane":{"authoredTrack":2,"displayTrack":0},"clips":[
       {"id":"clip:logo","assetId":"asset:logo","startFrame":0,"durationFrames":90,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"clip:title","assetId":"asset:title","startFrame":90,"durationFrames":60,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
      {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":1},"clips":[
       {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":120,"sourceInFrame":30,"muted":false,"effects":[],
        "parameterTracks":[{"schemaVersion":1,"id":"parameter:a:rotation","parameterId":"transform.rotation","valueType":"number",
          "frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"rotation:10","frame":10,"value":0,"outgoing":{"type":"linear"}},
          {"id":"rotation:100","frame":100,"value":-180,"outgoing":{"type":"linear"}}]}]},
       {"id":"clip:b","assetId":"asset:b","startFrame":120,"durationFrames":120,"sourceInFrame":60,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"clip:c","assetId":"asset:b","startFrame":300,"durationFrames":60,"sourceInFrame":300,"muted":false,"effects":[],"parameterTracks":[]}]},
      {"id":"track:v3","kind":"video","locked":true,"lane":{"authoredTrack":3,"displayTrack":2},"clips":[
       {"id":"clip:l1","assetId":"asset:a","startFrame":0,"durationFrames":60,"sourceInFrame":100,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"clip:l2","assetId":"asset:a","startFrame":60,"durationFrames":60,"sourceInFrame":200,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """
    /// 100 px per second at 30 fps: one frame is 10/3 px; row 1 (track:v1) starts at x 264.
    static let px = 100.0 / 30, rowY = TimelineLayout.rowTop(1) + 20

    func editor() throws -> TimelineEditor { try TimelineEditor(json: Self.json, engine: KeyframeRuntime()) }
    func controller() throws -> (TimelineController, TimelineEditor) {
        let e = try editor()
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(pixelsPerSecond: 100); c.snapEnabled = false
        return (c, e)
    }
    func clip(_ e: TimelineEditor, _ id: String) throws -> NativeProjectClip { try XCTUnwrap(e.clip(id)?.clip) }
    func x(frame: Double) -> Double { 264 + frame * Self.px }
    /// Every clip but `except`, to show an edit left them alone.
    func others(_ e: TimelineEditor, except: Set<String>) -> [NativeProjectClip] {
        e.document.sequence.tracks.flatMap(\.clips).filter { !except.contains($0.id) }
    }
    func assertValid(_ e: TimelineEditor, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try serializeNativeProjectDocument(e.document, engine: e.engine)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(text), engine: e.engine), e.document, file: file, line: line)
    }

    func assertNoSlip(_ e: TimelineEditor, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(e.slipRange(clipId: id), id, file: file, line: line)
        XCTAssertFalse(e.slip(clipId: id, byFrames: 5), id, file: file, line: line)
    }
    func press(_ tb: TimelineToolbar, _ item: TimelineToolbar.Item) throws {
        let r = try XCTUnwrap(tb.layout(width: 1266).first { $0.item == item }?.rect)
        tb.pointerDown(x: r.centerX, y: r.centerY, width: 1266); tb.pointerUp()
    }

    // MARK: Slip (#87)

    func testSlipByTenFramesChangesOnlyTheInPointAsOneUndoStep() throws {
        let e = try editor()
        let before = e.document, steps = e.undoStack.count
        XCTAssertTrue(e.slip(clipId: "clip:a", byFrames: 10))
        let a = try clip(e, "clip:a")
        XCTAssertEqual(a.sourceInFrame, 40, "10 frames at 1x")
        XCTAssertEqual(a.startFrame, 0); XCTAssertEqual(a.durationFrames, 120)
        XCTAssertEqual(others(e, except: ["clip:a"]), before.sequence.tracks.flatMap(\.clips).filter { $0.id != "clip:a" })
        XCTAssertEqual(e.undoStack.count, steps + 1); XCTAssertEqual(e.undoLabel, "Slip clip")
        try assertValid(e)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
    }

    func testSlipClampsAtTheStartAndEndOfTheSource() throws {
        let e = try editor()
        XCTAssertEqual(e.slipRange(clipId: "clip:a"), -30...450)
        XCTAssertTrue(e.slip(clipId: "clip:a", byFrames: -100))
        XCTAssertEqual(try clip(e, "clip:a").sourceInFrame, 0, "clamped at the first source frame")
        XCTAssertFalse(e.slip(clipId: "clip:a", byFrames: -1), "already at the start: nothing to do, no undo step")
        XCTAssertTrue(e.slip(clipId: "clip:a", byFrames: 10_000))
        XCTAssertEqual(try clip(e, "clip:a").sourceInFrame, 480, "clamped so the clip ends on the last source frame")
        try assertValid(e)
        XCTAssertFalse(e.slip(clipId: "clip:a", byFrames: .nan)); XCTAssertFalse(e.slip(clipId: "clip:a", byFrames: .infinity))
    }

    func testStillsTextAndLockedTracksRefuseTheSlip() throws {
        let e = try editor()
        let before = e.document
        assertNoSlip(e, "clip:logo"); assertNoSlip(e, "clip:title"); assertNoSlip(e, "clip:l1"); assertNoSlip(e, "clip:missing")
        XCTAssertFalse(e.apply(.slip(address: try XCTUnwrap(e.address(clipId: "clip:l1")), deltaFrames: 5)), "apply refuses a locked track too")
        XCTAssertEqual(e.document, before); XCTAssertTrue(e.undoStack.isEmpty)
    }

    func testSlipKeepsKeyframesAtTheirTimelinePositions() throws {
        let e = try editor()
        let keys = try clip(e, "clip:a").parameterTracks
        let timelineKeys = e.tracks.flatMap(\.clips).first { $0.id == "clip:a" }?.keyframes
        XCTAssertTrue(e.slip(clipId: "clip:a", byFrames: 25))
        XCTAssertEqual(try clip(e, "clip:a").parameterTracks, keys)
        XCTAssertEqual(e.tracks.flatMap(\.clips).first { $0.id == "clip:a" }?.keyframes, timelineKeys)
    }

    func testSlipToolDragPreviewsThenCommitsOnRelease() throws {
        let (c, e) = try controller()
        XCTAssertTrue(c.keyDown(EditorKey(.char("y")))); XCTAssertEqual(c.tool, .slip)
        c.pointerDown(x: x(frame: 60), y: Self.rowY)
        c.pointerMove(x: x(frame: 50), y: Self.rowY)   // content follows the pointer: 10 frames left shows later source
        XCTAssertEqual(c.view.drag, .slip(clipId: "clip:a", deltaFrames: 10, sourceShift: 10.0 / 600))
        XCTAssertEqual(c.cursor, .slip)
        XCTAssertEqual(try clip(e, "clip:a").sourceInFrame, 30, "nothing is committed during the drag")
        let model = try XCTUnwrap(c.view.tracks[1].clips.first { $0.id == "clip:a" })
        let drawn = c.view.slipPreview(model)
        XCTAssertEqual(drawn.sourceStartFraction - model.sourceStartFraction, 10.0 / 600, accuracy: 1e-12, "the waveform window moves with the slip")
        XCTAssertEqual(drawn.sourceEndFraction - model.sourceEndFraction, 10.0 / 600, accuracy: 1e-12)
        XCTAssertEqual(drawn.start, model.start, "the clip itself is drawn where it is")
        c.pointerUp(x: x(frame: 50), y: Self.rowY)
        XCTAssertEqual(try clip(e, "clip:a").sourceInFrame, 40); XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertNil(c.view.drag)
        XCTAssertTrue(c.keyDown(EditorKey(.char("y")))); XCTAssertEqual(c.tool, .select, "Y again returns to select")
    }

    func testCommandOptionDragSlipsWithTheSelectTool() throws {
        let (c, e) = try controller()
        c.pointerDown(x: x(frame: 60), y: Self.rowY, keys: TimelineGestureKeys(alt: true, command: true))
        c.pointerMove(x: x(frame: 2000), y: Self.rowY)   // far right: clamped at the first source frame
        XCTAssertEqual(c.view.drag, .slip(clipId: "clip:a", deltaFrames: -30, sourceShift: -30.0 / 600))
        c.pointerUp(x: x(frame: 2000), y: Self.rowY)
        XCTAssertEqual(try clip(e, "clip:a").sourceInFrame, 0)
        XCTAssertEqual(try clip(e, "clip:a").startFrame, 0, "the clip itself did not move")
    }

    func testEscapeCancelsASlip() throws {
        let (c, e) = try controller()
        c.tool = .slip
        c.pointerDown(x: x(frame: 60), y: Self.rowY); c.pointerMove(x: x(frame: 40), y: Self.rowY)
        XCTAssertTrue(c.keyDown(EditorKey(.escape))); XCTAssertNil(c.view.drag)
        c.pointerUp(x: x(frame: 40), y: Self.rowY)
        XCTAssertTrue(e.undoStack.isEmpty)
    }

    // MARK: Roll (#88)

    func testRollByTwelveMovesTheCutAsOneUndoStep() throws {
        let e = try editor()
        let before = e.document, duration = e.duration
        XCTAssertTrue(e.roll(clipId: "clip:a", edge: .end, toFrame: 132))
        let a = try clip(e, "clip:a"), b = try clip(e, "clip:b")
        XCTAssertEqual(a.durationFrames, 132); XCTAssertEqual(a.sourceInFrame, 30)
        XCTAssertEqual(b.startFrame, 132); XCTAssertEqual(b.durationFrames, 108); XCTAssertEqual(b.sourceInFrame, 72)
        XCTAssertEqual(e.duration, duration, "the sequence keeps its length")
        XCTAssertEqual(others(e, except: ["clip:a", "clip:b"]), before.sequence.tracks.flatMap(\.clips).filter { !["clip:a", "clip:b"].contains($0.id) })
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Roll edit")
        try assertValid(e)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.roll(clipId: "clip:b", edge: .start, toFrame: 132), "the same cut rolls from the incoming clip's edge")
        XCTAssertEqual(try clip(e, "clip:a").durationFrames, 132)
    }

    func testRollClampsAtTheSourceAndAtOneFrame() throws {
        let e = try editor()
        // clip:b has 60 source frames before its in-point, so the cut cannot move back past frame 60.
        XCTAssertEqual(e.rollRange(clipId: "clip:a", edge: .end), 60...239)
        XCTAssertTrue(e.roll(clipId: "clip:a", edge: .end, toFrame: 0))
        XCTAssertEqual(try clip(e, "clip:a").durationFrames, 60); XCTAssertEqual(try clip(e, "clip:b").sourceInFrame, 0)
        XCTAssertTrue(e.roll(clipId: "clip:a", edge: .end, toFrame: 10_000))
        XCTAssertEqual(try clip(e, "clip:b").durationFrames, 1, "the incoming clip keeps one frame")
        XCTAssertEqual(try clip(e, "clip:a").durationFrames, 239)
        try assertValid(e)
    }

    func testAnEdgeWithAGapBehindItTrimsInstead() throws {
        let e = try editor()
        XCTAssertNil(e.rollPartner(clipId: "clip:b", edge: .end))
        XCTAssertTrue(e.roll(clipId: "clip:b", edge: .end, toFrame: 260))
        XCTAssertEqual(try clip(e, "clip:b").durationFrames, 140)
        XCTAssertEqual(try clip(e, "clip:c").startFrame, 300, "the next clip stays: no roll across a gap")
        XCTAssertEqual(e.undoLabel, "Trim clip")
        XCTAssertTrue(e.roll(clipId: "clip:c", edge: .start, toFrame: 310))
        XCTAssertEqual(try clip(e, "clip:c").startFrame, 310); XCTAssertEqual(try clip(e, "clip:b").durationFrames, 140)
    }

    func testLockedTracksRefuseTheRoll() throws {
        let e = try editor()
        let before = e.document
        XCTAssertNotNil(e.rollPartner(clipId: "clip:l1", edge: .end))
        XCTAssertNil(e.rollRange(clipId: "clip:l1", edge: .end))
        XCTAssertFalse(e.roll(clipId: "clip:l1", edge: .end, toFrame: 70))
        let roll = NativeProjectClipRoll(outgoing: try XCTUnwrap(e.address(clipId: "clip:l1")), incoming: try XCTUnwrap(e.address(clipId: "clip:l2")), deltaFrames: 10)
        XCTAssertFalse(e.apply(.roll(roll)))
        XCTAssertEqual(e.document, before); XCTAssertTrue(e.undoStack.isEmpty)
    }

    func testRollRebasesKeyframesTheWayATrimDoes() throws {
        let rolled = try editor(), trimmed = try editor()
        XCTAssertTrue(rolled.roll(clipId: "clip:a", edge: .end, toFrame: 100))
        XCTAssertTrue(trimmed.apply(.trimOut(address: try XCTUnwrap(trimmed.address(clipId: "clip:a")), endFrameExclusive: 100)))
        XCTAssertEqual(try clip(rolled, "clip:a").parameterTracks, try clip(trimmed, "clip:a").parameterTracks)
    }

    func testShiftDragOnASharedEdgeRolls() throws {
        let (c, e) = try controller()
        c.pointerDown(x: x(frame: 118), y: Self.rowY, shift: true)   // clip:a's end handle, touching clip:b
        c.pointerMove(x: x(frame: 132), y: Self.rowY)
        XCTAssertEqual(c.view.drag, .roll(outgoingId: "clip:a", incomingId: "clip:b", time: 132.0 / 30))
        XCTAssertEqual(c.view.rollCut?.row, 1)
        let r = c.view.clipRect(track: 1, try XCTUnwrap(c.view.tracks[1].clips.first { $0.id == "clip:b" }))
        XCTAssertEqual(r.x, x(frame: 132), accuracy: 1e-9, "the incoming clip previews its new start")
        c.pointerUp(x: x(frame: 132), y: Self.rowY)
        XCTAssertEqual(try clip(e, "clip:a").durationFrames, 132); XCTAssertEqual(try clip(e, "clip:b").startFrame, 132)
        XCTAssertEqual(e.undoStack.count, 1)
    }

    func testShiftClickOnAnEdgeWithoutDraggingKeepsTheSelection() throws {
        let (c, e) = try controller()
        c.view.selection = ["clip:c"]
        c.pointerDown(x: x(frame: 118), y: Self.rowY, shift: true)   // clip:a's shared end edge
        c.pointerUp(x: x(frame: 118), y: Self.rowY)
        XCTAssertEqual(c.view.selection, ["clip:a", "clip:c"], "⇧-click still adds to the selection")
        XCTAssertTrue(e.undoStack.isEmpty, "no drag, no roll")
    }

    func testRollHoverRedrawsWhenTheMarkedCutGoesAway() throws {
        let (c, _) = try controller()
        c.tool = .roll
        c.pointerMove(x: x(frame: 118), y: Self.rowY)
        XCTAssertNotNil(c.view.rollHover)
        var redraws = 0
        c.needsDisplay = { redraws += 1 }
        c.pointerMove(x: x(frame: 2), y: Self.rowY)   // clip:a's start: nothing touches it
        XCTAssertNil(c.view.rollHover); XCTAssertEqual(c.cursor, .roll, "same clip, same cursor")
        XCTAssertGreaterThan(redraws, 0, "the stale bracket is repainted away")
    }

    func testRollToolHoverMarksTheCutAndAGapEdgePreviewsATrim() throws {
        let (c, e) = try controller()
        c.tool = .roll
        c.pointerMove(x: x(frame: 118), y: Self.rowY)
        XCTAssertEqual(c.cursor, .roll); XCTAssertEqual(c.view.rollHover?.time, 4)
        c.pointerDown(x: x(frame: 238), y: Self.rowY)   // clip:b's end: a gap follows
        c.pointerMove(x: x(frame: 260), y: Self.rowY)
        guard case let .trim(id, edge, time, _)? = c.view.drag else { return XCTFail("a gap edge previews a plain trim") }
        XCTAssertEqual(id, "clip:b"); XCTAssertEqual(edge, .end)
        XCTAssertEqual(time, 260.0 / 30, accuracy: 0.5 / 30, "within half a frame: the pointer time is seconds from pixels")
        c.pointerUp(x: x(frame: 260), y: Self.rowY)
        XCTAssertEqual(try clip(e, "clip:b").durationFrames, 140); XCTAssertEqual(try clip(e, "clip:c").startFrame, 300)
    }

    func testToolbarSlipAndRollButtons() throws {
        let (c, _) = try controller()
        let tb = TimelineToolbar(controller: c)
        try press(tb, .slip); XCTAssertEqual(c.tool, .slip); XCTAssertTrue(tb.isPressed(.slip))
        try press(tb, .roll); XCTAssertEqual(c.tool, .roll); XCTAssertTrue(tb.isPressed(.roll)); XCTAssertFalse(tb.isPressed(.slip))
        try press(tb, .select); XCTAssertEqual(c.tool, .select)
        XCTAssertEqual(tb.tooltip(.slip), "Slip tool (Y) — drag a clip to change which part of its media plays")
        XCTAssertEqual(TimelineView.slipLabel(10), "Slip +10f"); XCTAssertEqual(TimelineView.slipLabel(-3), "Slip \u{2212}3f")
    }
}

#if os(Linux)
/// The slip badge and the roll bracket on screen (Cairo). Set `MPVFX_SNAPSHOT_DIR` to also write the PNGs.
final class TimelineSlipRollVisualTests: XCTestCase {
    typealias F = TimelineSlipRollTests
    func controller() throws -> TimelineController {
        let e = try TimelineEditor(json: F.json, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(pixelsPerSecond: 100); c.snapEnabled = false
        return c
    }
    func render(_ c: TimelineController, _ name: String) -> CairoImageTarget {
        let t = CairoImageTarget(width: 1264, height: 300)
        c.view.draw(t.canvas, size: CanvasSize(1264, 300))
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/timeline-\(name).png"), 0)
        }
        return t
    }
    /// Within 40 of the theme accent on every channel.
    func isAccent(_ t: CairoImageTarget, _ x: Double, _ y: Double) -> Bool {
        let p = t.pixel(Int(x), Int(y)), a = TimelineTheme.default.accent
        return abs(Double(p.r) - a.r * 255) < 40 && abs(Double(p.g) - a.g * 255) < 40 && abs(Double(p.b) - a.b * 255) < 40
    }

    func testRollDrawsADoubleBracketAtTheCut() throws {
        let c = try controller()
        c.pointerDown(x: 264 + 118 * F.px, y: F.rowY, shift: true)
        c.pointerMove(x: 264 + 132 * F.px, y: F.rowY)
        let t = render(c, "roll")
        let cut = 264 + 132 * F.px, mid = TimelineLayout.rowTop(1) + c.view.trackHeight / 2
        XCTAssertTrue(isAccent(t, cut - 2, mid), "outgoing bracket left of the cut")
        XCTAssertTrue(isAccent(t, cut + 2, mid), "incoming bracket right of the cut")
        XCTAssertFalse(isAccent(t, cut - 20, mid), "the clip body is not painted over")
    }

    func testSlipDrawsAnOffsetBadgeOnTheClip() throws {
        let c = try controller()
        c.tool = .slip
        c.pointerDown(x: 264 + 60 * F.px, y: F.rowY)
        c.pointerMove(x: 264 + 50 * F.px, y: F.rowY)
        let t = render(c, "slip")
        let r = c.view.clipRect(track: 1, try XCTUnwrap(c.view.tracks[1].clips.first { $0.id == "clip:a" }))
        XCTAssertTrue(isAccent(t, r.centerX, r.centerY - 7.5), "the badge's accent border crosses the clip centre")
    }

    func testToolbarDrawsTheSlipAndRollButtonsWithThePickedOnePressed() throws {
        let c = try controller()
        c.tool = .slip
        let tb = TimelineToolbar(controller: c), t = CairoImageTarget(width: 1264, height: Int(TimelineToolbar.height))
        tb.draw(t.canvas, width: 1264)
        _ = write(t, "toolbar")
        let slip = try XCTUnwrap(tb.layout(width: 1264).first { $0.item == .slip }?.rect)
        let roll = try XCTUnwrap(tb.layout(width: 1264).first { $0.item == .roll }?.rect)
        let pressed = t.pixel(Int(slip.x + 3), Int(slip.centerY)), idle = t.pixel(Int(roll.x + 3), Int(roll.centerY))
        XCTAssertGreaterThan(Int(pressed.r), Int(idle.r), "the picked tool has the pressed fill")
    }

    @discardableResult
    func write(_ t: CairoImageTarget, _ name: String) -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] else { return false }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return t.writePNG("\(dir)/timeline-\(name).png") == 0
    }
}
#endif
