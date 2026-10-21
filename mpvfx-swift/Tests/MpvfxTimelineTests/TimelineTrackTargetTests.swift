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

/// Compact track headers (docs/DESIGN.md step 4): track tags and targeting, lock and solo buttons, the 28 px row.
final class TimelineTrackTargetTests: XCTestCase {
    // demoJSON display order: v2 [logo], v1 [a, b], a1 [music].
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(percent: 600)
        return (c, e)
    }
    func rect(_ c: TimelineController, row: Int, _ control: TimelineHeaderControl) -> CanvasRect? {
        c.view.headerControls(row: row).first { $0.control == control }?.rect
    }
    func click(_ c: TimelineController, row: Int, _ control: TimelineHeaderControl) -> TimelineController.HeaderAction? {
        guard let r = rect(c, row: row, control) else { XCTFail("no \(control) on row \(row)"); return nil }
        c.pointerDown(x: r.centerX, y: r.centerY); c.pointerUp(x: r.centerX, y: r.centerY)
        return c.lastHeaderAction
    }

    func testTagsCountVideoFromTheBottomAndAudioFromTheTop() throws {
        let (c, e) = try make()
        XCTAssertEqual(c.view.trackTags, ["V2", "V1", "A1"])
        XCTAssertNotNil(e.addTrack(kind: .audio))
        XCTAssertNotNil(e.addTrack(kind: .video, at: 0))
        XCTAssertEqual(c.view.trackTags, ["V3", "V2", "V1", "A1", "A2"])
    }

    func testV1AndA1AreTargetedByDefault() throws {
        let (c, _) = try make()
        XCTAssertEqual(c.view.targetedTrackIds, ["track:v1", "track:a1"])
        XCTAssertEqual(c.view.trackTargets.target(.video, in: c.view.tracks), "track:v1")
        XCTAssertEqual(c.view.trackTargets.target(.audio, in: c.view.tracks), "track:a1")
    }

    func testClickingATagMovesTheTargetAndASecondClickReleasesIt() throws {
        let (c, e) = try make()
        let undo = e.undoStack.count
        XCTAssertEqual(click(c, row: 0, .target), .toggledTarget(row: 0, targeted: true))
        XCTAssertEqual(c.view.targetedTrackIds, ["track:v2", "track:a1"], "one target per family: V1 is released")
        XCTAssertEqual(click(c, row: 0, .target), .toggledTarget(row: 0, targeted: false))
        XCTAssertEqual(c.view.targetedTrackIds, ["track:a1"])
        XCTAssertEqual(click(c, row: 2, .target), .toggledTarget(row: 2, targeted: false))
        XCTAssertEqual(c.view.targetedTrackIds, [])
        XCTAssertEqual(click(c, row: 1, .target), .toggledTarget(row: 1, targeted: true))
        XCTAssertEqual(c.view.targetedTrackIds, ["track:v1"])
        XCTAssertEqual(e.undoStack.count, undo, "targeting is editor state, not an edit")
    }

    func testARemovedTargetFallsBackToTheDefault() throws {
        let (c, e) = try make()
        _ = click(c, row: 0, .target)
        XCTAssertTrue(e.removeTrack("track:v2"))
        XCTAssertEqual(c.view.targetedTrackIds, ["track:v1", "track:a1"])
    }

    func testAddAtPlayheadUsesTheTargetedTrackWhenItIsFree() throws {
        let (c, e) = try make()
        _ = click(c, row: 0, .target)                                    // target V2 (logo spans 0.5 s ... 3.5 s)
        c.playback.seek(4); XCTAssertEqual(c.playback.currentTime, 4)
        XCTAssertEqual(c.targetedInsertTrack(assetId: "asset:logo", at: 4), "track:v2")
        let id = try XCTUnwrap(c.insertAtPlayhead(assetId: "asset:logo"))
        XCTAssertEqual(e.address(clipId: id)?.trackId, "track:v2")
        // Busy at the playhead: no target, so the editor keeps its own first-free-lane rule.
        XCTAssertNil(c.targetedInsertTrack(assetId: "asset:logo", at: 4))
        // A locked target is never used.
        XCTAssertTrue(e.setTrackLocked("track:v2", true))
        XCTAssertNil(c.targetedInsertTrack(assetId: "asset:logo", at: 20))
        // Sound goes onto the audio target.
        XCTAssertEqual(c.targetedInsertTrack(assetId: "asset:music", at: 20), "track:a1")
        XCTAssertNil(c.targetedInsertTrack(assetId: "asset:music", at: 0), "music already plays from 0 s")
    }

    func testLockButtonLocksAndUnlocksTheTrack() throws {
        let (c, e) = try make()
        XCTAssertEqual(click(c, row: 1, .lock), .toggledLocked(row: 1))
        XCTAssertTrue(e.isTrackLocked("track:v1")); XCTAssertTrue(c.view.tracks[1].locked)
        XCTAssertEqual(e.undoLabel, "Lock track")
        _ = click(c, row: 1, .lock)
        XCTAssertFalse(e.isTrackLocked("track:v1"))
    }

    func testSoloButtonIsOnAudioRowsAndWorksOnALockedTrack() throws {
        let (c, e) = try make()
        XCTAssertNil(rect(c, row: 1, .solo), "video rows have no solo")
        XCTAssertTrue(e.setTrackLocked("track:a1", true))
        let undo = e.undoStack.count
        XCTAssertEqual(click(c, row: 2, .solo), .toggledSoloed(row: 2))
        XCTAssertEqual(e.document.sequence.tracks.first { $0.id == "track:a1" }?.soloed, true)
        XCTAssertTrue(c.view.tracks[2].soloed)
        XCTAssertEqual(e.undoStack.count, undo + 1); XCTAssertEqual(e.undoLabel, "Solo track")
        XCTAssertTrue(e.undo())
        XCTAssertNil(e.document.sequence.tracks.first { $0.id == "track:a1" }?.soloed)
    }

    func testCompactRowsKeepEveryTargetAtLeast24PointsAndTheColumnsAligned() throws {
        let (c, e) = try make()
        XCTAssertEqual(TimelineLayout.defaultTrackHeight, 28)
        XCTAssertEqual(c.view.trackHeight, 28)
        XCTAssertNotNil(e.addTrack(kind: .audio))   // an empty audio row: its speaker column stays reserved
        let rows = Array(c.view.tracks.indices)
        XCTAssertEqual(rows.map { layoutProblems(c, row: $0) }, rows.map { _ in [String]() })
        XCTAssertEqual(rows.compactMap { rect(c, row: $0, .lock) }.count, rows.count, "every row has a lock")
        XCTAssertEqual(Set(rows.compactMap { rect(c, row: $0, .lock)?.x }).count, 1, "one lock column")
        XCTAssertEqual(Set(rows.compactMap { rect(c, row: $0, .visibility)?.x }).count, 1, "one eye / speaker column")
    }

    /// Every way the header of `row` breaks the compact layout (empty when it holds): a target under 24 x 24 (the FX
    /// text buttons only need the height), a control outside the row or past the label column, two that overlap.
    func layoutProblems(_ c: TimelineController, row: Int) -> [String] {
        let controls = c.view.headerControls(row: row), top = c.view.rowTop(row)
        var out: [String] = []
        for (control, r) in controls {
            let textButton: Bool = { if case .fx = control { return true }; return control == .groupPointer }()
            if r.height < 24 || (!textButton && r.width < 24) { out.append("\(control) is \(r.width) x \(r.height)") }
            if r.y < top || r.maxY > top + c.view.trackHeight || r.maxX > TimelineLayout.labelColumnWidth { out.append("\(control) leaves the header") }
        }
        for (a, b) in zip(controls, controls.dropFirst()) where a.rect.maxX > b.rect.x { out.append("\(a.control) overlaps \(b.control)") }
        return out
    }

    func testTrackHeightRangeStartsAtTheCompactDefault() {
        XCTAssertEqual(TimelineLayout.clampTrackHeight(20), 28)
        XCTAssertEqual(TimelineLayout.clampTrackHeight(48), 48, "a height saved by an earlier version stays")
        let p = try? JSONDecoder().decode(TimelineUIPreferences.self, from: Data(#"{"timelineTrackHeight":12}"#.utf8))
        XCTAssertEqual(p?.timelineTrackHeight, 28)
    }

    func testHoverMarksTheControlAndNamesItsActionOnTheStatusLine() throws {
        let (c, _) = try make()
        let lock = try XCTUnwrap(rect(c, row: 1, .lock))
        c.pointerMove(x: lock.centerX, y: lock.centerY)
        XCTAssertEqual(c.view.hoveredHeader, TimelineHeaderHover(row: 1, control: .lock))
        XCTAssertEqual(c.headerHint, "Lock V1 against edits")
        let tag = try XCTUnwrap(rect(c, row: 0, .target))
        c.pointerMove(x: tag.centerX, y: tag.centerY)
        XCTAssertEqual(c.headerHint, "Target V2: clips added at the playhead go onto this track")
        let solo = try XCTUnwrap(rect(c, row: 2, .solo))
        c.pointerMove(x: solo.centerX, y: solo.centerY)
        XCTAssertEqual(c.headerHint, "Solo A1: hear only soloed tracks")
        c.pointerMove(x: TimelineLayout.contentOrigin + 500, y: lock.centerY)
        XCTAssertNil(c.view.hoveredHeader); XCTAssertNil(c.headerHint)
    }
}

#if os(Linux)
/// Pixels of the compact header: the targeted tag is an accent pill, an idle one only an outline.
final class TimelineTrackHeaderPixelTests: XCTestCase {
    func render(_ setup: (TimelineController) -> Void = { _ in }) throws -> (CairoImageTarget, TimelineController) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(percent: 600)
        setup(c)
        let t = CairoImageTarget(width: 1264, height: 300)
        c.view.draw(t.canvas, size: CanvasSize(1264, 300))
        return (t, c)
    }
    func rgb(_ t: CairoImageTarget, _ x: Double, _ y: Double) -> [Int] { let p = t.pixel(Int(x), Int(y)); return [Int(p.r), Int(p.g), Int(p.b)] }

    func testTargetedTagIsFilledWithTheAccent() throws {
        let (t, c) = try render()
        let accent = c.view.theme.accent
        let want = [Int((accent.r * 255).rounded()), Int((accent.g * 255).rounded()), Int((accent.b * 255).rounded())]
        let v1 = try XCTUnwrap(c.view.headerControls(row: 1).first { $0.control == .target }?.rect)
        let v2 = try XCTUnwrap(c.view.headerControls(row: 0).first { $0.control == .target }?.rect)
        // Inside the pill, clear of the letters: the pill's left padding.
        XCTAssertEqual(rgb(t, v1.x + 2, v1.centerY), want, "V1 is targeted")
        XCTAssertNotEqual(rgb(t, v2.x + 2, v2.centerY), want, "V2 is not")
        let gutter = c.view.theme.gutterBackground
        XCTAssertEqual(rgb(t, v2.x + 2, v2.centerY), [Int((gutter.r * 255).rounded()), Int((gutter.g * 255).rounded()), Int((gutter.b * 255).rounded())],
                       "an idle tag is an outline over the gutter")
    }

    /// A 22 px clip bar (28 px row) keeps its filmstrip under the name and draws the name on a chip of the kind colour;
    /// from 36 px the name strip spans the clip again.
    func testCompactClipKeepsItsFilmstripAndPutsTheNameOnAChip() throws {
        let red = CanvasImage(width: 16, height: 9, rgba: (0..<(16 * 9)).flatMap { _ in [UInt8(255), 0, 0, 255] })
        let thumbs: (TimelineController) -> Void = { $0.view.thumbnails = ["asset:a": .init(frames: [red], aspect: 16.0 / 9)] }
        let (compact, c) = try render(thumbs)
        let top = c.view.rowTop(1) + TimelineLayout.clipY
        XCTAssertGreaterThan(rgb(compact, 264 + 300, top + 5)[0], 200, "no strip over the frames at the top of a compact clip")
        let fill = TimelineView.clipBackground(audio: false, hovered: false, dragging: false)
        let want = [Int((fill.r * 255).rounded()), Int((fill.g * 255).rounded()), Int((fill.b * 255).rounded())]
        XCTAssertEqual(rgb(compact, 264 + 9, top + 11), want, "the name's chip, left of its first letter")
        let (tall, c48) = try render { thumbs($0); $0.setTrackHeight(48) }
        XCTAssertEqual(rgb(tall, 264 + 300, c48.view.rowTop(1) + TimelineLayout.clipY + 5), want, "a 42 px clip has the full-width strip")
    }

    func testLockedTrackDrawsAFilledAccentLock() throws {
        let (plain, c) = try render()
        let (locked, _) = try render { XCTAssertTrue($0.toggleTrackLocked(row: 1)) }
        let r = try XCTUnwrap(c.view.headerControls(row: 1).first { $0.control == .lock }?.rect)
        // The lock body's centre: filled only when locked.
        let accent = c.view.theme.accent
        XCTAssertEqual(rgb(locked, r.centerX, r.centerY + 3), [Int((accent.r * 255).rounded()), Int((accent.g * 255).rounded()), Int((accent.b * 255).rounded())])
        XCTAssertNotEqual(rgb(plain, r.centerX, r.centerY + 3), rgb(locked, r.centerX, r.centerY + 3))
    }
}
#endif
