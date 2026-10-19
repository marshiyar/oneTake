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

final class PreviewRecordingTests: XCTestCase {
    final class Clock { var t = 100.0 }

    /// A stage at 1:1 scale is easiest to reason about: 1920×1080 canvas in a view sized so the fitted frame is the canvas.
    func makeController(clock: Clock, playback: PlaybackState) -> PlayerController {
        let view = PlayerView(playback: playback)
        view.canvasSize = CanvasSize(200, 100)
        view.now = { clock.t }
        let c = PlayerController(view: view)
        c.size = CanvasSize(216, PreviewToolbar.height + PlayerView.controlsHeight + 116)
        view.elements = [StageElement(id: "A", name: "A", rect: CanvasRect(x: 0, y: 0, width: 200, height: 100), kind: .video),
                         StageElement(id: "B", name: "B", rect: CanvasRect(x: 50, y: 25, width: 40, height: 20), kind: .video)]
        return c
    }

    // MARK: Recorder

    func testRecorderModifiersPickTheProperty() {
        var r = GestureRecorder(clipId: "A", startTime: 1, fps: 10, base: .init(x: 5, y: 7, opacity: 1, scale: 1), viewScale: 2, pointer: CanvasPoint(0, 0))
        XCTAssertFalse(r.tick(time: 0), "nothing until the pointer moves")
        r.pointerMoved(CanvasPoint(100, 100), modifiers: [])          // anchors the grab point
        r.pointerMoved(CanvasPoint(120, 140), modifiers: [])
        XCTAssertTrue(r.tick(time: 0.11))
        XCTAssertEqual(r.live.keys, ["x", "y"])
        XCTAssertEqual(r.live["x"], 15); XCTAssertEqual(r.live["y"], 27, "base + view delta / view scale, rounded")
        r.pointerMoved(CanvasPoint(120, 160), modifiers: .meta)
        r.tick(time: 0.14)
        XCTAssertEqual(r.samples.count, 1, "same output frame (0.11 s and 0.14 s both round to frame 1 at 10 fps): replaced")
        XCTAssertEqual(r.live.keys, ["opacity"]); XCTAssertEqual(r.live["opacity"]!, 1 - 30 * 0.005, accuracy: 1e-9)
        r.wheel(10, modifiers: .meta)
        r.tick(time: 0.2)
        XCTAssertEqual(r.live["scale"]!, 1.1, accuracy: 1e-9, "⌘ + wheel scales")
        r.pointerMoved(CanvasPoint(140, 160), modifiers: .alt)
        r.tick(time: 0.3)
        XCTAssertEqual(r.live.keys, ["rotation"]); XCTAssertEqual(r.live["rotation"], 10)
        r.wheel(4, modifiers: [])
        r.pointerMoved(CanvasPoint(140, 160), modifiers: [])
        r.tick(time: 0.4)
        XCTAssertEqual(r.live["z"], 4, "the wheel alone pushes depth")
        XCTAssertEqual(r.samples.map(\.time), [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(r.trail.count, 5)
    }

    func testKeyframesSimplifySmoothAndStartAtZero() throws {
        // A straight 2 s move: RDP keeps the ends, plus a 0 % key.
        let samples = (1...20).map { i in GestureSample(time: Double(i) / 10, properties: NativeOrderedMap([("x", Double(i) * 10), ("y", 0)])) }
        let keys = try GestureKeyframes.keyframes(samples, duration: 2)
        XCTAssertEqual(keys.map(\.percentage), [0, 5, 100])
        XCTAssertEqual(keys.first?.properties["x"], .number(10))
        XCTAssertEqual(keys.last?.properties["x"], .number(200))
        XCTAssertThrowsError(try GestureKeyframes.keyframes(Array(samples.prefix(2)), duration: 2)) { e in
            XCTAssertEqual((e as? GestureKeyframes.Failure)?.message, "No gesture detected — move the pointer while recording")
        }
        // A move that stops dead halfway gets an ease on the segment arriving at the stop.
        let stop = (0...20).map { i in GestureSample(time: Double(i) / 10, properties: NativeOrderedMap([("x", i <= 10 ? 100 * sin(Double(i) / 10 * .pi / 2) : 100)])) }
        let eased = try GestureKeyframes.keyframes(stop, duration: 2)
        XCTAssertTrue(eased.contains { $0.ease != nil }, "deceleration is fitted to an easy-ease")
    }

    func testApplyWritesPositionKeyframesOverTheInterval() throws {
        let doc = try PreviewCompositorTests.document()
        let samples = (0...10).map { i in GestureSample(time: Double(i) / 10, properties: NativeOrderedMap([("x", Double(i * i)), ("y", Double(i) * 5)])) }
        let (edited, count) = try GestureKeyframes.apply(doc, clipId: "A", startTime: 0.5, duration: 1, samples: samples, bounds: nil, engine: try KeyframeRuntime())
        XCTAssertGreaterThanOrEqual(count, 3)
        let clip = try XCTUnwrap(edited.sequence.tracks.flatMap(\.clips).first { $0.id == "A" })
        let ids = clip.parameterTracks.map(\.parameterId)
        XCTAssertTrue(ids.contains { $0.hasPrefix("transform.position") }, "\(ids)")
        let frames = clip.parameterTracks.filter { $0.parameterId.hasPrefix("transform.position") }.flatMap(\.keyframes).map(\.frame)
        XCTAssertEqual(frames.min(), 5, "0 % at the recording start (0.5 s at 10 fps)")
        XCTAssertEqual(frames.max(), 15, "100 % at start + duration")
        XCTAssertNotNil(GestureKeyframes.base(doc, clipId: "A", time: 0.5))
        XCTAssertNil(GestureKeyframes.base(doc, clipId: "nope", time: 0.5))
    }

    // MARK: Controller flow

    func testRecordingPlaysSamplesPreviewsAndCommitsThenSeeksBack() throws {
        let clock = Clock()
        let pb = PlaybackState(duration: 4, fps: 10)
        pb.seek(0.5)
        let c = makeController(clock: clock, playback: pb)
        var doc = try PreviewCompositorTests.document()
        var committed: (NativeProjectDocument, NativeProjectDocument)?
        c.enableGestureRecording(engine: try KeyframeRuntime(), document: { doc }) { edited, before in committed = (edited, before); doc = edited; return true }
        XCTAssertNotNil(c.view.toolbar.onToggleRecording, "Record shows in the tools bar")

        c.toggleRecording()
        XCTAssertNil(c.recorder); XCTAssertEqual(c.view.toast?.message, "Select an element first")

        c.view.selectedIds = ["A"]
        c.pointerMove(x: 60, y: 80)
        c.toggleRecording()
        XCTAssertTrue(c.isRecording); XCTAssertTrue(pb.isPlaying); XCTAssertEqual(c.view.toolbar.recording, .recording)
        XCTAssertTrue(c.editingIds.contains("A"), "the stage keeps the live element while recording")
        let s = c.view.scale(in: c.size)
        for i in 1...12 {
            c.modifiers = []
            c.pointerMove(x: 60 + Double(i) * 4 * s, y: 80)
            pb.tick(0.1)
            c.frameTick()
            if i == 6 { XCTAssertEqual(c.view.elements.first { $0.id == "A" }!.rect.x, Double(i - 1) * 4, accuracy: 1, "live preview follows the pointer from the first move") }
        }
        XCTAssertGreaterThan(c.view.recordingTrail.count, 2)
        c.pointerDown(x: 60, y: 80)   // stage clicks are ignored while recording
        XCTAssertTrue(c.isRecording)
        c.toggleRecording()
        XCTAssertFalse(c.isRecording); XCTAssertFalse(pb.isPlaying)
        XCTAssertEqual(pb.currentTime, 0.5, accuracy: 1e-9, "seeks back to where recording started")
        let (edited, before) = try XCTUnwrap(committed)
        XCTAssertNotEqual(edited, before)
        XCTAssertTrue(c.view.toast?.message.hasPrefix("Recorded ") == true, c.view.toast?.message ?? "")
        XCTAssertEqual(c.view.elements.first { $0.id == "A" }!.rect.x, 0, "the live preview is dropped; the document drives the stage again")
    }

    func testRecordingStopsAtTheClipEndAndWhenPaused() throws {
        let clock = Clock()
        let pb = PlaybackState(duration: 4, fps: 10)
        pb.seek(1.0)
        let c = makeController(clock: clock, playback: pb)
        let doc = try PreviewCompositorTests.document()   // clip B ends at 2 s
        var commits = 0
        c.enableGestureRecording(engine: try KeyframeRuntime(), document: { doc }) { _, _ in commits += 1; return true }
        c.view.selectedIds = ["B"]
        c.toggleRecording()
        for i in 1...15 { c.pointerMove(x: 60 + Double(i) * 3, y: 80); pb.tick(0.1); c.frameTick() }
        XCTAssertFalse(c.isRecording, "auto-stops at the clip's end")
        XCTAssertEqual(commits, 1)
        // Pausing (Space) also ends the recording.
        c.toggleRecording()
        c.pointerMove(x: 10, y: 80); pb.tick(0.1); c.frameTick()
        pb.pause(); c.frameTick()
        XCTAssertFalse(c.isRecording)
        XCTAssertEqual(c.view.toast?.isError, true, "one sample is no gesture")
    }

    // MARK: Drop, nudge, cancel, flash, preferences

    func testAssetDropInsertsAtThePlayheadAndSelects() {
        let clock = Clock(), pb = PlaybackState(duration: 4, fps: 10)
        pb.seek(1.2)
        let c = makeController(clock: clock, playback: pb)
        XCTAssertFalse(c.assetDragMoved(x: 50, y: 80), "no insert hook: not a drop target")
        var inserted: (String, Double)?
        c.onInsertAsset = { id, t in inserted = (id, t); c.view.elements.append(StageElement(id: "new", name: "n", rect: CanvasRect(x: 0, y: 0, width: 10, height: 10), kind: .image)); return "new" }
        XCTAssertTrue(c.assetDragMoved(x: 50, y: 80)); XCTAssertTrue(c.view.assetDropActive)
        XCTAssertFalse(c.assetDragMoved(x: 50, y: 5), "over the tools bar")
        XCTAssertNil(c.dropAsset("asset:x", x: 50, y: c.size.height - 5), "over the transport row")
        XCTAssertEqual(c.dropAsset("asset:x", x: 50, y: 80), "new")
        XCTAssertEqual(inserted?.0, "asset:x"); XCTAssertEqual(inserted?.1 ?? 0, 1.2, accuracy: 1e-9)
        XCTAssertEqual(c.view.selectedIds, ["new"]); XCTAssertFalse(c.view.assetDropActive)
    }

    func testArrowNudgeMovesTheSelectionAndCommitsOncePerBurst() {
        let clock = Clock(), pb = PlaybackState(duration: 4, fps: 10)
        let c = makeController(clock: clock, playback: pb)
        var commits: [StageElement] = []
        c.onCommit = { commits.append($0) }
        XCTAssertFalse(c.keyDown(EditorKey(.right)), "no selection: arrows stay frame steps")
        c.view.selectedIds = ["B"]
        XCTAssertTrue(c.keyDown(EditorKey(.right)))
        XCTAssertTrue(c.keyDown(EditorKey(.down, shift: true)))
        XCTAssertFalse(c.keyDown(EditorKey(.right, alt: true)))
        XCTAssertEqual(c.view.elements[1].rect.x, 51); XCTAssertEqual(c.view.elements[1].rect.y, 35)
        XCTAssertTrue(c.editingIds.contains("B"))
        clock.t += 0.2; c.frameTick()
        XCTAssertTrue(commits.isEmpty, "still inside the burst")
        clock.t += 0.3; c.frameTick()
        XCTAssertEqual(commits.count, 1); XCTAssertEqual(commits[0].rect.x, 51)
        XCTAssertFalse(c.editingIds.contains("B"))
    }

    func testEscapeCancelsADragInProgress() {
        let clock = Clock(), pb = PlaybackState(duration: 4, fps: 10)
        let c = makeController(clock: clock, playback: pb)
        var commits = 0
        c.onCommit = { _ in commits += 1 }
        let f = c.view.frameRect(in: c.size), s = c.view.scale(in: c.size)
        let p = CanvasPoint(f.x + 70 * s, f.y + 35 * s)   // inside B
        c.pointerDown(x: p.x, y: p.y)
        c.pointerMove(x: p.x + 30, y: p.y + 10)
        XCTAssertNotEqual(c.view.elements[1].rect.x, 50)
        XCTAssertTrue(c.keyDown(EditorKey(.escape)))
        XCTAssertEqual(c.view.elements[1].rect, CanvasRect(x: 50, y: 25, width: 40, height: 20))
        c.pointerUp(x: p.x + 30, y: p.y + 10)
        XCTAssertEqual(commits, 0)
    }

    func testZOrderCrossedFlashPulsesForSixHundredMilliseconds() {
        let clock = Clock(), pb = PlaybackState(duration: 4, fps: 10)
        let c = makeController(clock: clock, playback: pb)
        c.view.flashZOrderCrossed("B")
        XCTAssertTrue(c.view.animating)
        XCTAssertEqual(PlayerView.pulse(0), 1, accuracy: 1e-9)
        XCTAssertEqual(PlayerView.pulse(1), 0.5, accuracy: 1e-6, "animate-pulse is at 50 % halfway through its 2 s cycle")
        XCTAssertLessThan(PlayerView.pulse(0.6), 1)
        clock.t += 0.7
        c.view.draw(PreviewRecordingCanvas(), size: c.size)
        XCTAssertNil(c.view.zOrderFlash)
    }

    func testFullscreenKeysAndChromeWhilePlaying() {
        let clock = Clock(), pb = PlaybackState(duration: 4, fps: 10)
        let c = makeController(clock: clock, playback: pb)
        XCTAssertTrue(c.globalKey(EditorKey(.char("f"))))
        XCTAssertTrue(c.view.isFullscreen)
        XCTAssertFalse(c.globalKey(EditorKey(.char("f"), meta: true)))
        XCTAssertTrue(c.keyDown(EditorKey(.escape)), "Esc leaves fullscreen")
        XCTAssertFalse(c.view.isFullscreen)
        XCTAssertFalse(c.globalKey(EditorKey(.char("r"))), "R only when recording is wired")
        // Crop stands down when playback starts.
        c.view.selectedIds = ["A"]
        c.runCrop(.start)
        XCTAssertTrue(c.view.cropActive)
        pb.togglePlay(); c.frameTick()
        XCTAssertFalse(c.view.cropActive)
    }

    func testTransportPreferencesRoundTrip() {
        let store = MemoryPreviewPreferencesStore(PreviewPreferences(playbackRate: 0.5, audioMuted: true))
        let clock = Clock(), pb = PlaybackState(duration: 4, fps: 10)
        let c = makeController(clock: clock, playback: pb)
        c.attachPreferencesStore(store)
        XCTAssertEqual(pb.playbackRate, 0.5); XCTAssertTrue(pb.audioMuted)
        pb.audioMuted = false; c.frameTick()
        XCTAssertEqual(store.value.audioMuted, false, "M (or the volume button) persists mute")
        c.playbackRateChosen(2); c.volumeChosen(1.4)
        XCTAssertEqual(store.value.playbackRate, 2); XCTAssertEqual(store.value.audioVolume, 1)
        XCTAssertNil(PreviewPreferences(json: ["audioVolume": 3]).audioVolume)
    }

    func testPreferencesRestoreAndPersistThroughTheFile() throws {
        let dir = TestMedia.packageRoot.appendingPathComponent(".build/test-tmp/prefs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FilePreviewPreferencesStore.at(userData: dir.path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"leftWidth":300,"snapEnabled":false,"gridSpacing":4,"gridVisible":true,"previewZoom":{"zoomPercent":200,"panX":5000,"panY":0}}"#.utf8)
            .write(to: store.url)
        let clock = Clock(), pb = PlaybackState(duration: 4, fps: 10)
        let c = makeController(clock: clock, playback: pb)
        c.attachPreferencesStore(store)
        XCTAssertFalse(c.view.toolbar.snapEnabled); XCTAssertTrue(c.view.toolbar.gridVisible)
        XCTAssertEqual(c.view.toolbar.gridDivisions, 4); XCTAssertFalse(c.view.toolbar.snapToGrid)
        XCTAssertEqual(c.view.zoom.percent, 200)
        XCTAssertLessThan(c.view.zoom.panX, 5000, "a pan saved on a bigger window is clamped to this one")
        c.view.toolbar.press(.snap)
        c.view.toolbar.press(.gridPreset(2))
        XCTAssertTrue(c.scroll(x: 100, y: 80, dx: 0, dy: 40, zoom: true))
        clock.t += 0.3; c.frameTick()
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        XCTAssertEqual(saved["leftWidth"] as? Int, 300, "other preferences in the file survive")
        XCTAssertEqual(saved["snapEnabled"] as? Bool, true)
        XCTAssertEqual(saved["gridSpacing"] as? Int, 2)
        let z = try XCTUnwrap(saved["previewZoom"] as? [String: Any])
        XCTAssertLessThan(try XCTUnwrap(z["zoomPercent"] as? Double), 200, "the settled zoom is written")
        XCTAssertEqual(PreviewPreferences(json: ["previewZoom": ["zoomPercent": 60, "panX": 9, "panY": 9]]).initialZoom, .fit,
                       "an old below-Fit zoom restores as Fit")
        XCTAssertEqual(PreviewPreferences(json: ["gridSpacing": 7]).resolvedGridSpacing, 3)
    }
}
