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
import OneTakeKeyframes
import MpvfxShared

/// History labels / coalescing, audio buses, clip hide, insert, keyframes, silence removal, duration growth.
final class TimelineEditorAbilitiesTests: XCTestCase {
    func editor(engine: KeyframeEngine? = nil) throws -> TimelineEditor { try TimelineEditor(json: TimelineEditor.demoJSON, engine: engine) }
    func clip(_ e: TimelineEditor, _ id: String) -> NativeProjectClip? { e.document.sequence.tracks.flatMap(\.clips).first { $0.id == id } }

    // MARK: History

    func testUndoLabelsAndCap() throws {
        let e = try editor()
        let a = try XCTUnwrap(e.address(clipId: "clip:a"))
        e.apply(.trimOut(address: a, endFrameExclusive: 150))
        XCTAssertEqual(e.undoLabel, "Trim clip")
        e.rippleDelete(["clip:logo"]); XCTAssertEqual(e.undoLabel, "Ripple delete")
        e.setTrackLocked("track:a1", true); XCTAssertEqual(e.undoLabel, "Lock track")
        e.withHistory("Inspector edit") { _ = e.setTrackHidden("track:v1", true) }
        XCTAssertEqual(e.undoLabel, "Inspector edit", "outer label wins")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.redoLabel, "Inspector edit")
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.undoLabel, "Inspector edit")
        e.maxHistoryEntries = 2
        e.setTrackHidden("track:v2", true)
        XCTAssertEqual(e.undoStack.map(\.label), ["Inspector edit", "Hide track"])
    }

    func testCoalescingFoldsAGestureIntoOneEntry() throws {
        let e = try editor(); var clock = 100.0; e.now = { clock }
        let before = e.document
        for (i, g) in [0.9, 0.8, 0.7].enumerated() {
            clock += 0.1 * Double(i)
            e.withHistory("Set clip volume", coalesceKey: "vol:clip:music") { _ = e.setClipVolume(clipId: "clip:music", g) }
        }
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.clipVolume(clipId: "clip:music"), 0.7)
        clock += 1   // outside the window: a new entry
        e.withHistory("Set clip volume", coalesceKey: "vol:clip:music") { _ = e.setClipVolume(clipId: "clip:music", 0.5) }
        XCTAssertEqual(e.undoStack.count, 2)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.clipVolume(clipId: "clip:music"), 0.7)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
    }

    // MARK: Audio

    func testClipAudioAttributes() throws {
        let e = try editor(); let before = e.document
        XCTAssertTrue(e.setClipVolume(clipId: "clip:music", 2))
        XCTAssertEqual(e.clipVolume(clipId: "clip:music"), 2)
        XCTAssertTrue(e.setClipVolume(clipId: "clip:music", TimelineEditor.maxAudioGain + 0.0000004))
        XCTAssertEqual(e.clipVolume(clipId: "clip:music"), TimelineEditor.maxAudioGain, "fader rounding is clamped")
        XCTAssertFalse(e.setClipVolume(clipId: "clip:music", 5), "past +12 dB")
        XCTAssertFalse(e.setClipVolume(clipId: "clip:logo", 0.5), "images carry no audio")
        XCTAssertTrue(e.setClipFxChain(clipId: "clip:music", "eq:1"))
        XCTAssertEqual(clip(e, "clip:music")?.audioFxChain, "eq:1")
        XCTAssertTrue(e.setClipAutomation(clipId: "clip:music", "auto"))
        XCTAssertTrue(e.setClipFxChain(clipId: "clip:music", nil)); XCTAssertNil(clip(e, "clip:music")?.audioFxChain)
        while e.undo() {}
        XCTAssertEqual(e.document, before)
    }

    func testLoudnessMatchAppliesEveryGainInOneUndoStep() throws {
        let e = try editor(); let before = e.document
        XCTAssertTrue(e.applyLoudnessMatch(["clip:a": 0.5, "clip:b": 1.25, "clip:music": 4.5]))
        XCTAssertEqual(e.clipVolume(clipId: "clip:a"), 0.5)
        XCTAssertEqual(e.clipVolume(clipId: "clip:b"), 1.25)
        XCTAssertEqual(e.clipVolume(clipId: "clip:music"), 4.5, "matching is not limited by the interactive +12 dB fader")
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Match loudness")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
    }

    func testAudioGroupLifecycle() throws {
        let e = try editor(); let before = e.document
        XCTAssertNil(e.createAudioGroup(clipIds: ["clip:music"]), "needs two clips")
        XCTAssertNil(e.createAudioGroup(clipIds: ["clip:a", "clip:music"]), "a video track joins only whole")
        let g = try XCTUnwrap(e.createAudioGroup(clipIds: ["clip:a", "clip:b", "clip:music"], label: "Dialogue"))
        XCTAssertEqual(e.audioGroup(g)?.label, "Dialogue"); XCTAssertEqual(e.audioGroup(g)?.volume, 1)
        XCTAssertEqual(clip(e, "clip:music")?.audioGroupId, g)
        XCTAssertEqual(e.tracks.first { $0.id == "track:a1" }?.groupId, g)
        XCTAssertTrue(e.setAudioGroupVolume(g, 0.5)); XCTAssertTrue(e.setAudioGroupMuted(g, true))
        XCTAssertTrue(e.setAudioGroupLabel(g, "Dx")); XCTAssertTrue(e.setAudioGroupFxChain(g, "comp"))
        XCTAssertTrue(e.setAudioGroupAutomation(g, "lane"))
        let grp = try XCTUnwrap(e.audioGroup(g))
        XCTAssertEqual([grp.volume, grp.muted == true ? 1 : 0], [0.5, 1]); XCTAssertEqual(grp.label, "Dx")
        XCTAssertEqual(grp.fxChain, "comp"); XCTAssertEqual(grp.automation, "lane")
        XCTAssertFalse(e.setAudioGroupVolume(g, 9))
        XCTAssertTrue(e.removeAudioGroup(g)); XCTAssertNil(clip(e, "clip:music")?.audioGroupId)
        XCTAssertNil(e.document.sequence.audioGroups)
        while e.undo() {}
        XCTAssertEqual(e.document, before)
    }

    func testDetachedVideoStaysMuted() throws {
        let json = TimelineEditor.demoJSON.replacingOccurrences(of: #""name":"clip_001.mp4","#, with: #""name":"clip_001.mp4","source":"media/a.mp4","#)
        let e = try TimelineEditor(json: json)
        XCTAssertTrue(e.detachAudio(clipId: "clip:a"))
        XCTAssertEqual(clip(e, "clip:a")?.muted, true)
        XCTAssertFalse(e.setMuted(clipId: "clip:a", false), "unmute the linked audio instead")
        XCTAssertTrue(e.setTrackMuted("track:v1", true)); XCTAssertTrue(e.setTrackMuted("track:v1", false))
        XCTAssertEqual(clip(e, "clip:a")?.muted, true); XCTAssertEqual(clip(e, "clip:b")?.muted, false)
    }

    // MARK: Clips

    func testHideClipsAndStageElements() throws {
        let e = try editor()
        XCTAssertTrue(e.setClipsHidden(["clip:a", "clip:logo"], true))
        XCTAssertTrue(e.isClipHidden("clip:a"))
        XCTAssertEqual(e.tracks.flatMap(\.clips).filter(\.hidden).map(\.id).sorted(), ["clip:a", "clip:logo"])
        XCTAssertFalse(e.activeElements(at: 1).contains { $0.id == "clip:a" })
        let json = try serializeNativeProjectDocument(try NativeJSONValue.from(e.document))
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(json)).sequence.tracks.flatMap(\.clips).first { $0.id == "clip:a" }?.hidden, true)
        XCTAssertTrue(e.setClipsHidden(["clip:a"], false)); XCTAssertNil(clip(e, "clip:a")?.hidden)
        XCTAssertEqual(e.undoLabel, "Show clip")
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.view.selection = ["clip:logo"]
        XCTAssertTrue(c.toggleSelectionHidden()); XCTAssertFalse(e.isClipHidden("clip:logo"))
    }

    func testInsertPicksFreeLaneOrMakesOne() throws {
        let e = try editor()
        let asset = try XCTUnwrap(e.addAsset(kind: .video, name: "c.mp4", source: "media/c.mp4", durationFrames: 60))
        XCTAssertEqual(e.addAsset(kind: .video, name: "c.mp4", source: "media/c.mp4", durationFrames: 60), asset, "same source reuses the asset")
        // 12s is free on the top video lane (v2 ends at 105 frames).
        let id1 = try XCTUnwrap(e.insertClip(assetId: asset, at: 12))
        XCTAssertEqual(e.address(clipId: id1)?.trackId, "track:v2"); XCTAssertEqual(clip(e, id1)?.startFrame, 360)
        XCTAssertEqual(e.undoStack.count, 2)
        // 1s collides on both video lanes: a new top lane, one undo step.
        let id2 = try XCTUnwrap(e.insertClip(assetId: asset, at: 1))
        let lane = try XCTUnwrap(e.address(clipId: id2)?.trackId)
        XCTAssertEqual(e.displayTrackIds.first, lane)
        XCTAssertTrue(e.undo()); XCTAssertNil(clip(e, id2)); XCTAssertFalse(e.displayTrackIds.contains(lane))
        // Audio goes to an audio lane; explicit track honoured.
        let music = try XCTUnwrap(e.addAsset(kind: .audio, name: "vo.wav", source: "media/vo.wav", durationFrames: 30))
        let id3 = try XCTUnwrap(e.insertClip(assetId: music, at: 20, trackId: "track:a1"))
        XCTAssertEqual(e.address(clipId: id3)?.trackId, "track:a1")
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 30), editor: e)
        c.playback.seek(15)
        let id4 = try XCTUnwrap(c.insertAtPlayhead(assetId: music)); XCTAssertEqual(c.view.selection, [id4])
        XCTAssertEqual(clip(e, id4)?.startFrame, 450)
    }

    func testKeyframeCommandsUndoAndRespectLock() throws {
        let e = try editor(engine: KeyframeRuntime())
        let addr = NativeProjectParameterAddress(sequenceId: e.sequenceId, trackId: "track:v1", clipId: "clip:a", parameterId: "transform.opacity")
        let before = e.document
        XCTAssertTrue(e.applyKeyframe(.atomic(.upsert(address: addr, valueType: .number, frame: 10, value: .number(0.5), baselineValue: .number(1)))),
                      "\(String(describing: e.lastPropertyFailure))")
        XCTAssertEqual(e.undoLabel, "Edit keyframes")
        XCTAssertTrue(e.applyKeyframe(.atomic(.move(address: addr, fromFrame: 10, toFrame: 20)), label: "Move keyframe"))
        XCTAssertEqual(clip(e, "clip:a")?.parameterTracks.first?.keyframes.map(\.frame), [20])
        e.setTrackLocked("track:v1", true)
        XCTAssertFalse(e.applyKeyframe(.atomic(.delete(address: addr, frame: 20))))
        e.undo()
        while e.undo() {}
        XCTAssertEqual(e.document, before)
    }

    func testRemoveSilenceButtsPiecesTogether() throws {
        let e = try editor(); let before = e.document
        // clip:a = 0..6s, source 0..6s. Silences 1-2s and 4-4.5s.
        let removed = e.removeSilence(clipId: "clip:a", sourceSilences: [.init(start: 1, end: 2), .init(start: 4, end: 4.5)])
        XCTAssertEqual(removed, 1.5, accuracy: 1e-9)
        let v1 = try XCTUnwrap(e.document.sequence.tracks.first { $0.id == "track:v1" }).clips
        let pieces = v1.filter { $0.assetId == "asset:a" }.map { [$0.startFrame, $0.durationFrames, $0.sourceInFrame] }
        XCTAssertEqual(pieces, [[0, 30, 0], [30, 60, 60], [90, 45, 135]])
        XCTAssertEqual(v1.first { $0.id == "clip:b" }?.startFrame, 195, "other clips stay put")
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Remove silence")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
        XCTAssertEqual(e.removeSilence(clipId: "clip:a", sourceSilences: [.init(start: 7, end: 8)]), 0, "outside the clip")
    }

    func testSilencePlan() {
        let p = TimelineSilencePlan(start: 10, duration: 4, sourceStart: 2, rate: 2, silences: [.init(start: 2, end: 3), .init(start: 4, end: 6), .init(start: 5.5, end: 7)])
        XCTAssertEqual(p.removed, [.init(start: 10, end: 10.5), .init(start: 11, end: 12.5)])
        XCTAssertEqual(p.cutTimes, [10.5, 11, 12.5])
        XCTAssertEqual(p.segments.map(\.remove), [true, false, true, false])
    }

    func testEditsPastTheEndGrowTheComposition() throws {
        let json = TimelineEditor.demoJSON.replacingOccurrences(of: #""name":"Main","#, with: #""name":"Main","durationFrames":330,"#)
        let e = try TimelineEditor(json: json); let before = e.document
        XCTAssertEqual(e.duration, 11)
        let b = try XCTUnwrap(e.address(clipId: "clip:b"))
        XCTAssertTrue(e.apply(.move(address: b, destination: .init(trackId: "track:v1", startFrame: 300))))
        XCTAssertEqual(e.document.sequence.durationFrames, 420); XCTAssertEqual(e.duration, 14)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.document.sequence.durationFrames, 420)
    }
}

#if os(Linux)
final class TimelineClipContentVisualTests: XCTestCase {
    func render(_ setup: (TimelineController) -> Void) throws -> CairoImageTarget {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(pixelsPerSecond: 100)
        setup(c)
        let t = CairoImageTarget(width: 1264, height: 300)
        c.view.draw(t.canvas, size: CanvasSize(1264, 300))
        return t
    }
    func rgb(_ t: CairoImageTarget, _ x: Int, _ y: Int) -> [Int] { let p = t.pixel(x, y); return [Int(p.r), Int(p.g), Int(p.b)] }

    func testAudioWaveformBarsAreBottomAlignedBlue() throws {
        let row = Int(TimelineLayout.rowTop(2)), clipBottom = row + Int(TimelineLayout.clipY + TimelineLayout.defaultTrackHeight - 2 * TimelineLayout.clipY) - 1
        let plain = try render { _ in }
        let t = try render { $0.view.waveforms = ["asset:music": Array(repeating: 0.5, count: 900)] }
        let bar = rgb(t, 264 + 300, clipBottom - 2), gapBetweenBars = rgb(t, 264 + 302, clipBottom - 2)
        XCTAssertGreaterThan(bar[2], bar[0] + 40, "waveform bar is blue: \(bar)")
        XCTAssertEqual(gapBetweenBars, rgb(plain, 264 + 302, clipBottom - 2), "3px step leaves a 1px gap")
        XCTAssertEqual(rgb(t, 264 + 300, row + 8), rgb(plain, 264 + 300, row + 8), "half-height bars leave the top clear")
    }

    func testFilmstripTilesVideoClipsWhenThumbnailsOn() throws {
        let red = CanvasImage(width: 16, height: 9, rgba: Array([UInt8]([255, 0, 0, 255]).repeated(16 * 9)))
        let y = Int(TimelineLayout.rowTop(1)) + 24
        let on = try render { $0.view.thumbnails = ["asset:a": .init(frames: [red], aspect: 16.0 / 9)] }
        XCTAssertGreaterThan(rgb(on, 264 + 300, y)[0], 200, "frame drawn")
        let off = try render { $0.view.thumbnails = ["asset:a": .init(frames: [red], aspect: 16.0 / 9)]; $0.view.thumbnailsEnabled = false }
        XCTAssertLessThan(rgb(off, 264 + 300, y)[0], 100, "thumbnail mode hidden: plain bar")
    }

    func testClipHeaderStripIsKindColouredOverContent() throws {
        // docs/DESIGN.md Principle 3: the name sits on an 18 px strip of the kind colour; the content fills the body below.
        let red = CanvasImage(width: 16, height: 9, rgba: Array([UInt8]([255, 0, 0, 255]).repeated(16 * 9)))
        let video = Int(TimelineLayout.rowTop(1) + TimelineLayout.clipY), audio = Int(TimelineLayout.rowTop(2) + TimelineLayout.clipY)
        let header = 18, x = 264 + 300   // ThemeTokens.clipHeaderHeight
        let t = try render {
            $0.view.thumbnails = ["asset:a": .init(frames: [red], aspect: 16.0 / 9)]
            $0.view.waveforms = ["asset:music": Array(repeating: 1, count: 900)]
        }
        XCTAssertEqual(rgb(t, x, video + header / 2), [29, 74, 100], "video header = clipVideo #1D4A64")
        XCTAssertEqual(rgb(t, x, video + header - 1), [29, 74, 100], "header is 18 px tall")
        XCTAssertGreaterThan(rgb(t, x, video + header + 1)[0], 200, "frame drawn right below the header")
        XCTAssertEqual(rgb(t, x, audio + header / 2), [47, 74, 23], "audio header = clipAudio #2F4A17, full-height peaks stop below it")
        let bar = rgb(t, x, audio + header + 1)
        XCTAssertGreaterThan(bar[2], bar[0] + 40, "full-height waveform bar reaches the header: \(bar)")
        let plain = try render { _ in }
        XCTAssertEqual(rgb(plain, x, video + header / 2), [29, 74, 100], "the strip is there on a plain clip too")
        let hovered = try render { $0.view.thumbnails = ["asset:a": .init(frames: [red], aspect: 16.0 / 9)]; $0.view.hoveredClip = "clip:a" }
        XCTAssertEqual(rgb(hovered, x, video + header / 2), [36, 90, 121], "the header carries the hover state (clipVideoHover #245A79)")
    }

    func testHiddenTrackFadesClips() throws {
        let y = Int(TimelineLayout.rowTop(1)) + 24
        let red = CanvasImage(width: 16, height: 9, rgba: Array([UInt8]([255, 0, 0, 255]).repeated(16 * 9)))
        let shown = try render { $0.view.thumbnails = ["asset:a": .init(frames: [red], aspect: 16.0 / 9)] }
        let hidden = try render { c in c.view.thumbnails = ["asset:a": .init(frames: [red], aspect: 16.0 / 9)]; c.toggleTrackHidden(row: 1) }
        let s = rgb(shown, 264 + 300, y)[0], h = rgb(hidden, 264 + 300, y)[0]
        XCTAssertEqual(Double(h), Double(s) * 0.35 + 29 * 0.65, accuracy: 6, "opacity 0.35 over the row background")
    }
}

private extension Array {
    func repeated(_ n: Int) -> [Element] { (0..<n).flatMap { _ in self } }
}
#endif
