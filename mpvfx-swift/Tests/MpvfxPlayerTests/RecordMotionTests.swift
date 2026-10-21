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
@testable import MpvfxPlayer
import MpvfxTimeline
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes

/// Record motion: arming does nothing on its own, a take starts only on a press on the selected layer, the layer
/// keeps its grab offset, release commits one undo step, Esc cancels, and samples are thinned.
final class RecordMotionTests: XCTestCase {
    final class Rig {
        let pb = PlaybackState(duration: 4, fps: 10)
        let c: PlayerController
        var doc: NativeProjectDocument
        var commits: [(edited: NativeProjectDocument, before: NativeProjectDocument)] = []
        /// Stage: 200×100 canvas at view scale 1; the frame's top-left is at (8, 44). B is (58, 69)–(98, 89) in view px.
        init(doc: NativeProjectDocument, select: String = "B", playhead: Double = 0.5) throws {
            pb.seek(playhead)
            let view = PlayerView(playback: pb)
            view.canvasSize = CanvasSize(200, 100)
            view.now = { 100 }
            c = PlayerController(view: view)
            c.size = CanvasSize(216, PreviewToolbar.height + PlayerView.controlsHeight + 116)
            view.elements = [StageElement(id: "A", name: "A", rect: CanvasRect(x: 0, y: 0, width: 200, height: 100), kind: .video),
                             StageElement(id: "B", name: "B", rect: CanvasRect(x: 50, y: 25, width: 40, height: 20), kind: .video)]
            self.doc = doc
            let engine = try KeyframeRuntime()
            c.enableGestureRecording(engine: engine, document: { [unowned self] in self.doc }) { [unowned self] edited, before in
                self.commits.append((edited, before)); self.doc = edited; return true
            }
            view.selectedIds = [select]
        }
        var b: StageElement? { c.view.elements.first { $0.id == "B" } }
        /// Moves to `p` and lets one 0.1 s frame of the transport pass.
        func step(_ x: Double, _ y: Double) { c.pointerMove(x: x, y: y); pb.tick(0.1); c.frameTick() }
    }

    func rig(select: String = "B") throws -> Rig { try Rig(doc: try PreviewCompositorTests.document(), select: select) }

    // MARK: Defects of the old Record (each failed before the rework)

    func testArmingThenHoveringNeverMovesTheLayer() throws {
        let r = try rig()
        r.c.toggleRecording()
        for i in 1...8 { r.step(70 + Double(i) * 6, 75) }
        XCTAssertEqual(r.b?.rect, CanvasRect(x: 50, y: 25, width: 40, height: 20), "the layer ignores the cursor until it is pressed")
        XCTAssertFalse(r.pb.isPlaying, "arming alone does not start the transport")
        r.c.toggleRecording()
        XCTAssertTrue(r.commits.isEmpty, "arming and disarming writes nothing")
    }

    func testAPressOffTheSelectedLayerWritesNothingAndMovesNothing() throws {
        let r = try rig()
        r.c.toggleRecording()
        r.c.pointerDown(x: 20, y: 50)   // on A, not on the selected B
        for i in 1...6 { r.step(20 + Double(i) * 10, 50 + Double(i) * 4) }
        r.c.pointerUp(x: 80, y: 74)
        r.c.toggleRecording()
        XCTAssertTrue(r.commits.isEmpty)
        XCTAssertEqual(r.b?.rect.x, 50); XCTAssertEqual(r.c.view.elements.first?.rect.x, 0, "the pressed layer does not move either")
        XCTAssertEqual(r.c.view.selectedIds, ["A"], "a press elsewhere only selects")
    }

    func testTheLayerKeepsItsGrabOffsetInsteadOfJumping() throws {
        let r = try rig()
        r.c.toggleRecording()
        r.c.pointerDown(x: 90, y: 85)   // near B's lower-right corner
        r.step(110, 95)
        XCTAssertEqual(try XCTUnwrap(r.b).rect.x, 70, accuracy: 1e-9, "moved by the 20 px drag, not to the cursor")
        XCTAssertEqual(try XCTUnwrap(r.b).rect.y, 35, accuracy: 1e-9)
        XCTAssertTrue(r.pb.isPlaying, "the take plays from the press")
    }

    func testReleaseEndsTheTakeAsOneCommit() throws {
        let r = try rig()
        let before = r.doc
        r.c.toggleRecording()
        r.c.pointerDown(x: 70, y: 75)
        for i in 1...8 { r.step(70 + Double(i) * 5, 75 + Double(i)) }
        r.c.pointerUp(x: 110, y: 83)
        XCTAssertFalse(r.c.isRecording, "release ends the take")
        XCTAssertFalse(r.pb.isPlaying)
        XCTAssertEqual(r.pb.currentTime, 0.5, accuracy: 1e-9, "back to where the take started")
        XCTAssertEqual(r.commits.count, 1, "one take is one undo step")
        XCTAssertEqual(r.commits.first?.before, before)
        for i in 1...4 { r.step(110 + Double(i) * 5, 83) }
        XCTAssertEqual(r.commits.count, 1, "moves after the release record nothing")
        XCTAssertEqual(r.b?.rect.x, 50, "the document drives the stage again")
    }

    func testEscapeCancelsTheTakeAndRestoresTheLayer() throws {
        let r = try rig()
        r.c.toggleRecording()
        r.c.pointerDown(x: 70, y: 75)
        for i in 1...5 { r.step(70 + Double(i) * 8, 75) }
        XCTAssertTrue(r.c.keyDown(EditorKey(.escape)))
        XCTAssertFalse(r.c.isRecording)
        XCTAssertEqual(r.b?.rect, CanvasRect(x: 50, y: 25, width: 40, height: 20))
        r.c.pointerUp(x: 110, y: 75)
        XCTAssertTrue(r.commits.isEmpty, "the previous keys stay as they were")
        XCTAssertNotEqual(r.c.view.toolbar.recording, .idle, "still armed after a cancelled take")
        XCTAssertTrue(r.c.keyDown(EditorKey(.escape)), "Esc with no take disarms")
        XCTAssertEqual(r.c.view.toolbar.recording, .idle)
    }

    func testLockedAndHiddenLayersAreNotRecorded() throws {
        for flag in ["locked", "hidden"] {
            var doc = try PreviewCompositorTests.document()
            let t = try XCTUnwrap(doc.sequence.tracks.firstIndex { $0.clips.contains { $0.id == "B" } })
            if flag == "locked" { doc.sequence.tracks[t].locked = true } else { doc.sequence.tracks[t].hidden = true }
            let r = try Rig(doc: doc)
            r.c.toggleRecording()
            r.c.pointerDown(x: 70, y: 75)
            for i in 1...5 { r.step(70 + Double(i) * 8, 75) }
            r.c.pointerUp(x: 110, y: 75)
            r.c.toggleRecording()
            XCTAssertTrue(r.commits.isEmpty, flag)
            XCTAssertEqual(r.b?.rect.x, 50, flag)
        }
    }

    func testKeyThinningBounds() throws {
        // 3 s at 30 fps with the pointer reporting at 240 Hz: at most one sample and one trail point per frame.
        var rec = GestureRecorder(clipId: "B", startTime: 0, fps: 30, base: .init(), viewScale: 1, pointer: CanvasPoint(0, 0), anchored: true)
        for i in 0...720 {
            let t = Double(i) / 240
            rec.pointerMoved(CanvasPoint(t * 100, 2 * sin(Double(i))), modifiers: [])   // a straight line with ±2 px jitter
            rec.tick(time: t)
        }
        XCTAssertLessThanOrEqual(rec.samples.count, 91); XCTAssertLessThanOrEqual(rec.trail.count, 91)
        XCTAssertEqual(Set(rec.samples.map(\.time)).count, rec.samples.count, "no two samples on one frame")
        let keys = try GestureKeyframes.keyframes(rec.samples, duration: try XCTUnwrap(rec.samples.last).time)
        XCTAssertLessThanOrEqual(keys.count, 3, "jitter inside the tolerance simplifies to the line's ends: \(keys.map(\.percentage))")
        XCTAssertEqual(keys.first?.percentage, 0); XCTAssertEqual(keys.last?.percentage, 100)
    }

    // MARK: Model choices

    func testAPressOnAToolReportedHandleStartsATake() throws {
        let r = try rig()
        r.c.extraHandleHit = { p, ve in abs(p.x - (ve.rect.x + ve.rect.width / 2)) < 4 && abs(p.y - (ve.rect.y - 30)) < 4 }   // a handle above B
        r.c.toggleRecording()
        r.c.pointerDown(x: 78, y: 39)
        XCTAssertTrue(r.c.isRecording)
        XCTAssertTrue(r.c.keyDown(EditorKey(.escape)))
        r.c.pointerDown(x: 140, y: 120)   // on A only
        XCTAssertFalse(r.c.isRecording)
    }

    func testAHeldPressThatNeverMovesWritesNothing() throws {
        let r = try rig()
        r.c.toggleRecording()
        r.c.pointerDown(x: 70, y: 75)
        for _ in 1...5 { r.step(71, 75) }   // under the 4 px drag threshold
        r.c.pointerUp(x: 71, y: 75)
        XCTAssertTrue(r.commits.isEmpty)
        XCTAssertEqual(r.c.view.toast?.message, "Nothing recorded: hold the button and drag the layer")
    }

    func testArmedStateShowsOnTheControlAndTheStage() throws {
        let r = try rig(select: "B")
        XCTAssertEqual(r.c.view.toolbar.recording, .idle); XCTAssertNil(r.c.view.recordOverlay)
        r.c.toggleRecording()
        XCTAssertTrue(r.c.isRecordArmed); XCTAssertEqual(r.c.view.toolbar.recording, .armed)
        XCTAssertEqual(r.c.view.recordOverlay, RecordOverlay(state: .ready, message: "Drag the selected layer to record its motion"))
        r.c.view.selectedIds = []; r.c.frameTick()
        XCTAssertEqual(r.c.view.recordOverlay?.state, .blocked)
        XCTAssertEqual(r.c.view.recordOverlay?.message, "Select a layer, then drag it to record its motion")
        r.c.view.selectedIds = ["B"]
        r.c.pointerDown(x: 70, y: 75); r.step(80, 75)
        XCTAssertEqual(r.c.view.toolbar.recording, .recording)
        XCTAssertEqual(r.c.view.recordOverlay?.state, .recording)
        XCTAssertEqual(r.c.view.recordOverlay?.title, "REC 0:00.1")
        XCTAssertEqual(r.c.view.toolbar.recordTip, "Release to finish (Esc cancels)")
        r.c.pointerUp(x: 80, y: 75)
        XCTAssertEqual(r.c.view.toolbar.recording, .armed, "Record stays armed for the next take")
        XCTAssertTrue(r.c.globalKey(EditorKey(.char("r"))), "R disarms")
        XCTAssertFalse(r.c.isRecordArmed); XCTAssertNil(r.c.view.recordOverlay)
        XCTAssertEqual(r.c.view.toolbar.recordTip, "Record motion (R)")
    }

    func testTheRecordControlIsAStableTwentyEightPointTarget() {
        let tb = PreviewToolbar()
        tb.onToggleRecording = {}
        var rects: [CanvasRect] = []
        for state in [PreviewToolbar.Recording.idle, .armed, .recording] {
            tb.recording = state
            rects.append(tb.layout(width: 600, cropAvailable: false, cropActive: false, nil).first { $0.0 == .record }?.1 ?? .init(x: 0, y: 0, width: 0, height: 0))
        }
        XCTAssertEqual(Set(rects.map(\.width)).count, 1, "the width never changes with the state")
        XCTAssertGreaterThanOrEqual(rects[0].height, 24)
        XCTAssertEqual(rects[0].y + rects[0].height / 2, PreviewToolbar.height / 2, "centred on the bar like the snap and grid buttons")
        XCTAssertEqual(rects[0].x, PreviewToolbar.paddingX)
    }

    func testRecordingOverARangeReplacesOnlyThatRange() throws {
        let engine = try KeyframeRuntime()
        let doc = try PreviewCompositorTests.document()
        // First take: frames 0–20, a curve so many keys survive simplification.
        let first = (0...20).map { i -> GestureSample in
            let t = Double(i)
            return Self.sample(t / 10, x: 60 * sin(t / 3), y: t * t / 4)
        }
        let (once, _) = try GestureKeyframes.apply(doc, clipId: "A", startTime: 0, duration: 2, samples: first, bounds: nil, engine: engine)
        let framesBefore = try Self.positionFrames(once)
        XCTAssertTrue(framesBefore.contains { $0 > 5 && $0 < 15 }, "\(framesBefore)")
        // Second take over frames 5–15 only.
        let second = (0...10).map { i -> GestureSample in Self.sample(Double(i) / 10, x: 100 + Double(i) * 7, y: 3) }
        let (twice, _) = try GestureKeyframes.apply(once, clipId: "A", startTime: 0.5, duration: 1, samples: second, bounds: nil, engine: engine)
        let framesAfter = try Self.positionFrames(twice)
        let outside: (Double) -> Bool = { f in f < 5 || f > 15 }
        let keptAfter: [Double] = framesAfter.filter(outside), keptBefore: [Double] = framesBefore.filter(outside)
        XCTAssertEqual(keptAfter, keptBefore, "keys outside the take stay")
        XCTAssertTrue(framesAfter.contains(5) && framesAfter.contains(15), "\(framesAfter)")
        let inside = try Self.positionKeys(twice).filter { $0.frame >= 5 && $0.frame <= 15 }
        let earlier = try Self.positionKeys(once).filter { $0.frame > 5 && $0.frame < 15 }
        XCTAssertFalse(inside.isEmpty)
        XCTAssertFalse(earlier.contains { e in inside.contains { $0.frame == e.frame && $0.value == e.value } }, "the old keys inside the range are replaced")
    }

    static func sample(_ time: Double, x: Double, y: Double) -> GestureSample {
        GestureSample(time: time, properties: NativeOrderedMap([("x", x), ("y", y)]))
    }

    static func positionKeys(_ doc: NativeProjectDocument) throws -> [(frame: Double, value: String)] {
        let clip = try XCTUnwrap(doc.sequence.tracks.flatMap(\.clips).first { $0.id == "A" })
        return clip.parameterTracks.filter { $0.parameterId.hasPrefix("transform.position") }.flatMap { t in
            t.keyframes.map { (frame: $0.frame, value: "\($0.value)") }
        }
    }

    static func positionFrames(_ doc: NativeProjectDocument) throws -> [Double] { Array(Set(try positionKeys(doc).map(\.frame))).sorted() }

    func testTheAppNeverWarpsOrCapturesTheSystemCursor() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let banned = ["XWarpPointer", "gdk_device_warp", "CGWarpMouseCursorPosition", "CGAssociateMouseAndMouseCursorPosition",
                      "SetCursorPos", "warpCursor", "gdk_seat_grab", "ClipCursor"]
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path)).compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") || $0.hasSuffix(".c") || $0.hasSuffix(".cpp") || $0.hasSuffix(".h") || $0.hasSuffix(".m") }
        XCTAssertGreaterThan(files.count, 50)
        for f in files {
            let text = try String(contentsOf: sources.appendingPathComponent(f), encoding: .utf8)
            for b in banned { XCTAssertFalse(text.contains(b), "\(f) calls \(b)") }
        }
    }
}
