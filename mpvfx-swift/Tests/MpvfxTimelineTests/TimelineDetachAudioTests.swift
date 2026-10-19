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
import MpvfxShared

/// Clip menu Detach / Reattach audio (nativeAudioState,
/// nativeProjectAudioCommands): a clip placed in the native app has no preview binding and still offers it.
final class TimelineDetachAudioTests: XCTestCase {
    func clip(_ e: TimelineEditor, _ id: String) -> NativeProjectClip? { e.document.sequence.tracks.flatMap(\.clips).first { $0.id == id } }
    func labels(_ m: TimelineClipMenu?) -> [String] {
        (m?.entries ?? []).map { e -> String in if case .item(let i) = e { return i.label }; return "—" }
    }

    /// A video file inserted the way the app's bin does it (insertClip: no binding), plus a controller on it.
    func setup() throws -> (TimelineEditor, TimelineController, String) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let asset = try XCTUnwrap(e.addAsset(kind: .video, name: "talk.mp4", source: "media/talk.mp4", durationFrames: 300))
        let id = try XCTUnwrap(e.insertClip(assetId: asset, at: 30, durationFrames: 60))
        XCTAssertNil(clip(e, id)?.binding)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        return (e, c, id)
    }

    func row(_ c: TimelineController, _ id: String) -> TimelineClipModel? { c.view.tracks.flatMap(\.clips).first { $0.id == id } }
    func linked(_ e: TimelineEditor, _ video: String) -> NativeProjectClip? {
        e.document.sequence.tracks.flatMap(\.clips).first { $0.audioDetachedFrom == video }
    }

    func testUnboundVideoOffersDetachAndDetachCreatesLinkedAudio() throws {
        let (e, c, id) = try setup()
        XCTAssertEqual(row(c, id)?.canDetachAudio, true)
        c.openClipMenu(id, x: 10, y: 10)
        XCTAssertEqual(labels(c.view.clipMenu), ["Split", "—", "Show thumbnails", "—", "Mute", "—", "Detach audio", "—", "Delete"])
        var v = try XCTUnwrap(clip(e, id))
        let chain = #"{"version":1,"nodes":[{"type":"gain","id":"g","params":{"gain":-3}}]}"#
        let auto = #"{"version":1,"lanes":[{"target":"volume","points":[{"t":0,"v":0.2},{"t":0.5,"v":1}]}]}"#
        v.audioGroupId = "dx"; v.audioFxChain = chain; v.audioAutomation = auto
        v.staticParameters = ["audio.volume": .number(0.5)]
        v.playbackRate = .init(numerator: 3, denominator: 2); v.sourceInFrame = 12
        var d = e.document
        d.sequence.audioGroups = [.bus(id: "dx", label: "Dx")]
        for t in d.sequence.tracks.indices { if let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == id }) { d.sequence.tracks[t].clips[i] = v } }
        e.replaceDocument(d, inverse: .restoreDocument(e.document))
        let undoDepth = e.undoStack.count

        XCTAssertTrue(c.runClipMenu(.detachAudio, clipId: id), e.lastFailure?.message ?? "")
        XCTAssertEqual(e.undoStack.count, undoDepth + 1, "one undo step")
        XCTAssertEqual(e.undoLabel, "Detach audio")
        let a = try XCTUnwrap(linked(e, id))
        let video = try XCTUnwrap(clip(e, id))
        XCTAssertEqual([a.startFrame, a.durationFrames, a.sourceInFrame], [v.startFrame, v.durationFrames, 12])
        XCTAssertEqual(a.playbackRate, v.playbackRate)
        XCTAssertEqual([a.audioGroupId, a.audioFxChain, a.audioAutomation], ["dx", chain, auto])
        XCTAssertEqual(a.staticParameters?["audio.volume"], .number(0.5))
        XCTAssertTrue(video.muted)
        XCTAssertNil(video.audioFxChain); XCTAssertNil(video.audioGroupId)
        let audioTrack = try XCTUnwrap(e.document.sequence.tracks.first { $0.clips.contains { $0.id == a.id } })
        XCTAssertEqual(audioTrack.kind, .audio)
        let audioAsset = try XCTUnwrap(e.document.assets.first { $0.id == a.assetId })
        XCTAssertEqual(audioAsset.kind, .audio); XCTAssertEqual(audioAsset.source, "media/talk.mp4")

        // muteAvailable false and no audio action on the detached video; Reattach on its audio.
        XCTAssertEqual(row(c, id)?.canDetachAudio, false)
        c.openClipMenu(id, x: 10, y: 10)
        XCTAssertEqual(labels(c.view.clipMenu), ["Split", "—", "Show thumbnails", "—", "Delete"])
        c.openClipMenu(a.id, x: 10, y: 10)
        XCTAssertEqual(labels(c.view.clipMenu), ["Split", "—", "Mute", "—", "Reattach audio", "—", "Delete"])
        XCTAssertEqual(row(c, a.id)?.assetId, audioAsset.id, "waveform loads by the audio asset (same file as the video)")
    }

    func testReattachRestoresAndUndoRedoAreOneStepEach() throws {
        let (e, c, id) = try setup()
        let original = e.document
        XCTAssertTrue(c.runClipMenu(.detachAudio, clipId: id))
        let detached = e.document
        let a = try XCTUnwrap(linked(e, id)).id
        XCTAssertTrue(c.runClipMenu(.reattachAudio, clipId: a))
        XCTAssertEqual(e.undoLabel, "Reattach audio")
        XCTAssertEqual(e.document, original, "track, asset and clip removed; video unmuted")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, detached)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, original)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.document, detached)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.document, original)
    }

    func testReattachRefusesAfterMoveOrTrimUntilRealigned() throws {
        let (e, c, id) = try setup()
        XCTAssertTrue(c.runClipMenu(.detachAudio, clipId: id))
        let a = try XCTUnwrap(linked(e, id)).id
        let aligned = e.document
        let addr = try XCTUnwrap(e.address(clipId: a))
        XCTAssertTrue(e.apply(.move(address: addr, destination: .init(trackId: addr.trackId, startFrame: 200))))
        XCTAssertFalse(c.runClipMenu(.reattachAudio, clipId: a))
        XCTAssertNotNil(linked(e, id))
        XCTAssertEqual(e.lastFailure?.message, "The detached audio or video was moved, trimmed, or retimed; align them before reattaching")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, aligned)
        let vaddr = try XCTUnwrap(e.address(clipId: id))
        let v = try XCTUnwrap(clip(e, id))
        XCTAssertTrue(e.apply(.trimOut(address: vaddr, endFrameExclusive: v.startFrame + v.durationFrames - 10)))
        XCTAssertFalse(e.reattachAudio(clipId: a))
        XCTAssertTrue(e.undo())
        XCTAssertTrue(e.reattachAudio(clipId: a)); XCTAssertNil(linked(e, id))
    }

    func testBrokenLinkAndHostHook() throws {
        let (e, c, id) = try setup()
        XCTAssertTrue(c.runClipMenu(.detachAudio, clipId: id))
        let a = try XCTUnwrap(linked(e, id)).id
        // The video was deleted: reattach refuses, the audio stays a plain clip.
        let vaddr = try XCTUnwrap(e.address(clipId: id))
        XCTAssertTrue(e.apply(.delete(address: vaddr)))
        XCTAssertFalse(e.reattachAudio(clipId: a))
        XCTAssertEqual(e.lastFailure?.message, "The detached audio's source video is no longer available")
        XCTAssertTrue(e.undo())
        // With a host hook the menu hands the action over (the app probes the file first).
        var asked: [String] = []
        c.onNativeAudioAction = { asked.append("\($0):\($1.rawValue)") }
        XCTAssertTrue(c.runClipMenu(.reattachAudio, clipId: a))
        XCTAssertEqual(asked, ["\(a):reattach"]); XCTAssertNotNil(linked(e, id))
        // No audio stream: detach refuses.
        XCTAssertTrue(e.reattachAudio(clipId: a))
        XCTAssertFalse(e.detachAudio(clipId: id, hasAudioStream: false))
        XCTAssertEqual(e.lastFailure?.message, "This video has no audio stream to detach")
    }

    func testDetachedLinkSurvivesJSONRoundTrip() throws {
        let (e, _, id) = try setup()
        XCTAssertTrue(e.detachAudio(clipId: id))
        let json = try serializeNativeProjectDocument(e.document)
        let back = try TimelineEditor(json: json)
        XCTAssertEqual(back.document, e.document)
        XCTAssertEqual(linked(back, id)?.audioDetachedFrom, id)
        XCTAssertEqual(back.tracks.flatMap(\.clips).first { $0.id == id }?.canMute, false)
        XCTAssertTrue(back.reattachAudio(clipId: try XCTUnwrap(linked(back, id)).id))
    }
}
