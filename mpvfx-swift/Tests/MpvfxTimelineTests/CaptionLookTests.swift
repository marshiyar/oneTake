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
import MpvfxCanvas
import MpvfxShared
@testable import MpvfxTimeline

/// The caption look and a cue's own position as editor commands (one undo step each, saved with the edit history), the
/// look's layout keeping every cue inside the safe area at both orientations, and the lane's badge for a cue that needs
/// more than two lines. The demo project runs at 30 fps and is 1920 x 1080.
final class CaptionLookTests: XCTestCase {
    static let threeCues = [
        NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one"),
        NativeCaptionCue(id: "cue:2", startMs: 2000, endMs: 3000, text: "two"),
        NativeCaptionCue(id: "cue:3", startMs: 5000, endMs: 6000, text: "three"),
    ]

    static let look = NativeCaptionLook(size: 0.05, outlines: [NativeTextLook.Outline(width: 6, color: "#000000")],
                                        shadow: NativeTextLook.Shadow(x: 4, y: 4, blur: 8, color: "#000000"),
                                        plate: NativeCaptionLook.Plate(color: "#000000B3"),
                                        position: NativeCaptionPosition.bottom, safeArea: 0.05, maxWidth: 0.8)

    /// The demo project with a caption track of `cues` and `look`, validated like any loaded project.
    func captioned(_ cues: [NativeCaptionCue] = CaptionLookTests.threeCues, look: NativeCaptionLook? = nil) throws -> NativeProjectDocument {
        var d = try TimelineEditor(json: TimelineEditor.demoJSON).document
        d.sequence.captions = NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues, look: look)
        return try parseNativeProjectDocument(d)
    }

    // MARK: Look as an editor command

    func testSetCaptionLookIsOneUndoStepThatUndoRestoresExactly() throws {
        let e = TimelineEditor(document: try captioned())
        let before = e.document
        XCTAssertTrue(e.setCaptionLook(Self.look))
        XCTAssertEqual(e.document.sequence.captions?.look, Self.look)
        XCTAssertEqual(e.undoLabel, "Change caption look")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before, "undo restores the document exactly")
        XCTAssertNil(e.document.sequence.captions?.look)
    }

    func testSetCaptionLookNilRemovesTheLook() throws {
        let e = TimelineEditor(document: try captioned(look: Self.look))
        XCTAssertTrue(e.setCaptionLook(nil))
        XCTAssertNil(e.document.sequence.captions?.look)
        XCTAssertEqual(e.undoLabel, "Change caption look")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document.sequence.captions?.look, Self.look)

        XCTAssertFalse(TimelineEditor(document: try captioned()).setCaptionLook(nil), "there is no look to remove")
    }

    func testAnIdenticalLookRecordsNothing() throws {
        let e = TimelineEditor(document: try captioned(look: Self.look))
        let before = e.document
        XCTAssertFalse(e.setCaptionLook(Self.look))
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertEqual(e.document, before)
    }

    func testSetCaptionLookNeedsACaptionTrack() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        XCTAssertFalse(e.setCaptionLook(Self.look))
        XCTAssertNil(e.document.sequence.captions)
        XCTAssertTrue(e.undoStack.isEmpty)
    }

    func testSetCaptionPositionMovesOneCueAndOneUndoRestores() throws {
        let e = TimelineEditor(document: try captioned())
        let before = e.document
        XCTAssertTrue(e.setCaptionPosition("cue:2", to: NativeCaptionPosition.top))
        XCTAssertEqual(e.captionCues[1].position, NativeCaptionPosition.top)
        XCTAssertNil(e.captionCues[0].position)
        XCTAssertNil(e.captionCues[2].position)
        XCTAssertEqual(e.undoLabel, "Move caption on screen")
        XCTAssertEqual(e.undoStack.count, 1)

        XCTAssertFalse(e.setCaptionPosition("cue:9", to: NativeCaptionPosition.top), "an unknown cue records nothing")
        XCTAssertEqual(e.undoStack.count, 1)

        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
    }

    func testTheLookSurvivesARestartAndUndoesAfterReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-caption-look-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTimelineHistoryStore(directory: dir)
        let e = TimelineEditor(document: try captioned())
        e.onHistoryChange = { store.save(projectId: "project:caption-look", e.persistedHistory()) }
        let d0 = e.document
        XCTAssertTrue(e.setCaptionLook(Self.look))
        let d1 = e.document

        // "Restart": a fresh editor on the saved document.
        let e2 = TimelineEditor(document: e.document)
        let saved = try XCTUnwrap(store.load(projectId: "project:caption-look"))
        XCTAssertTrue(e2.restoreHistory(saved))
        XCTAssertEqual(e2.undoLabel, "Change caption look")
        XCTAssertEqual(e2.document, d1)
        XCTAssertEqual(e2.document.sequence.captions?.look, Self.look)
        XCTAssertTrue(e2.undo())
        XCTAssertNil(e2.document.sequence.captions?.look)
        XCTAssertEqual(e2.document, d0)
        XCTAssertFalse(e2.canUndo)
    }

    // MARK: Layout inside the safe area

    /// The layout of every cue of `e` on its frame, as the preview paints it (a fixed advance of half an em per character).
    func layouts(_ e: TimelineEditor) -> [(id: String, layout: NativeCaptionLayout)] {
        let c = e.document.canvas
        let look = e.document.sequence.captions?.look
        return e.captionCues.map { cue in
            let layout = nativeCaptionLayout(text: cue.text, look: look, position: cue.position,
                                             frameWidth: c.width, frameHeight: c.height,
                                             measure: { text, size in Double(text.count) * size * 0.5 })
            return (id: cue.id, layout: layout)
        }
    }

    func assertInsideSafeArea(_ e: TimelineEditor, _ frame: String) {
        for (id, layout) in layouts(e) {
            XCTAssertTrue(layout.safeRect.contains(layout.paintedRect),
                          "\(id) at \(frame): painted \(layout.paintedRect) leaves the safe area \(layout.safeRect)")
        }
    }

    func testEveryCueStaysInsideTheSafeAreaAtBothOrientations() throws {
        let cues = [
            NativeCaptionCue(id: "cue:bottom", startMs: 0, endMs: 1000,
                             text: "A caption long enough that it wraps onto a second line at this width"),
            NativeCaptionCue(id: "cue:top", startMs: 2000, endMs: 3000, text: "top", position: NativeCaptionPosition.top),
            NativeCaptionCue(id: "cue:corner", startMs: 5000, endMs: 6000, text: "corner",
                             position: NativeCaptionPosition.custom(x: 0.98, y: 0.98)),
        ]
        let e = TimelineEditor(document: try captioned(cues, look: Self.look))
        XCTAssertEqual(e.document.canvas.width, 1920)
        XCTAssertEqual(e.document.canvas.height, 1080)
        assertInsideSafeArea(e, "1920x1080")

        XCTAssertTrue(e.setCanvasSize(width: 1080, height: 1920))
        assertInsideSafeArea(e, "1080x1920")
    }

    // MARK: Lane badge

    /// The demo project with a caption track of `cues`, wired to a view, a playback and a controller (as CaptionLaneTests).
    func rig(cues: [NativeCaptionCue]) throws -> (view: TimelineView, controller: TimelineController) {
        var d = try TimelineEditor(json: TimelineEditor.demoJSON).document
        d.sequence.captions = NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues)
        let editor = TimelineEditor(document: try parseNativeProjectDocument(d))
        let view = TimelineView(tracks: [], duration: 0), playback = PlaybackState(duration: 0)
        let controller = TimelineController(view: view, playback: playback, editor: editor)
        controller.viewport = CanvasSize(1200, 600)
        controller.relayout()
        return (view, controller)
    }

    func testTheLaneBadgesACueThatNeedsMoreThanTwoLines() throws {
        let threeLines = Array(repeating: "wordy", count: 20).joined(separator: " ")
        let twoLines = Array(repeating: "wordy", count: 12).joined(separator: " ")
        let (view, _) = try rig(cues: [
            NativeCaptionCue(id: "cue:short", startMs: 0, endMs: 1000, text: "one"),
            NativeCaptionCue(id: "cue:two-lines", startMs: 2000, endMs: 3000, text: twoLines),
            NativeCaptionCue(id: "cue:three-lines", startMs: 5000, endMs: 6000, text: threeLines),
        ])
        // Precondition on the fixed advance at 1920 x 1080: 7 words fit a line, so 20 words take three lines and 12 take two.
        func lineCount(_ text: String) -> Int {
            nativeCaptionLayout(text: text, look: nil, position: nil, frameWidth: 1920, frameHeight: 1080,
                                measure: { t, size in Double(t.count) * size * 0.5 }).lines.count
        }
        XCTAssertEqual(lineCount(threeLines), 3)
        XCTAssertEqual(lineCount(twoLines), 2)

        let flagged = view.overflowingCaptionCueIds { text, font in Double(text.count) * font.size * 0.5 }
        XCTAssertTrue(flagged.contains("cue:three-lines"))
        XCTAssertFalse(flagged.contains("cue:two-lines"), "two lines is what a caption should take")
        XCTAssertFalse(flagged.contains("cue:short"))
    }
}
