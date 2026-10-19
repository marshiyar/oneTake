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
// Audio commands (detach / reattach).
import XCTest
@testable import MpvfxShared

final class NativeProjectAudioCommandsTests: XCTestCase {
    let ids = NativeDetachAudioIds(assetId: "audio-asset", clipId: "audio-clip", trackId: "audio-track")
    func project() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(J(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"project","revision":0,"frameRate":{"numerator":30000,"denominator":1001},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"video-asset","kind":"video","name":"camera.mp4","source":"assets/camera.mp4","durationFrames":300}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video-track","kind":"video","lane":{"authoredTrack":7,"displayTrack":3},"clips":[{
          "id":"video-clip","assetId":"video-asset","startFrame":37,"durationFrames":61,"sourceInFrame":17,"sourceInFraction":{"numerator":1,"denominator":3},
          "playbackRate":{"numerator":3,"denominator":2},"muted":false,"staticParameters":{"visual.opacity":0.7,"audio.volume":0.8},
          "effects":[{"id":"visual-fx","effectId":"color","enabled":false}],"parameterTracks":[]}]}]}}
        """#), engine: KeyframeEngineStandIn())
    }

    func testKeepsTimingEditsLinkageAndLanes() throws {
        let original = try project()
        let detached = try detachNativeVideoAudio(original, videoClipId: "video-clip", hasAudioStream: true, ids: ids)
        let video = detached.sequence.tracks[0].clips[0], audio = detached.sequence.tracks[1].clips[0]
        XCTAssertEqual(video.id, "video-clip"); XCTAssertTrue(video.muted)
        XCTAssertEqual(video.staticParameters, ["visual.opacity": .number(0.7), "audio.volume": .number(0.8)])
        XCTAssertEqual(video.effects.map(\.id), ["visual-fx"])
        XCTAssertEqual(audio.id, "audio-clip"); XCTAssertEqual(audio.audioDetachedFrom, "video-clip")
        XCTAssertEqual(audio.startFrame, 37); XCTAssertEqual(audio.durationFrames, 61); XCTAssertEqual(audio.sourceInFrame, 17)
        XCTAssertEqual(audio.sourceInFraction, .init(numerator: 1, denominator: 3)); XCTAssertEqual(audio.playbackRate, .init(numerator: 3, denominator: 2))
        XCTAssertEqual(audio.staticParameters, ["audio.volume": .number(0.8)])
        XCTAssertEqual(detached.sequence.tracks[1].lane, .init(authoredTrack: 0, displayTrack: 4))
        XCTAssertEqual(detached.assets[1].kind, .audio); XCTAssertEqual(detached.assets[1].source, "assets/camera.mp4")
        XCTAssertEqual(original.sequence.tracks.count, 1)
        XCTAssertEqual(try reattachNativeVideoAudio(detached, audioClipId: "audio-clip"), original)
    }

    func testRetainsDetachedAudioEditsOnReattach() throws {
        var original = try project()
        original.sequence.audioGroups = [.init(id: "dialogue")]
        original.sequence.tracks[0].clips[0].audioGroupId = "dialogue"
        var detached = try detachNativeVideoAudio(original, videoClipId: "video-clip", hasAudioStream: true, ids: ids)
        XCTAssertNil(detached.sequence.tracks[0].clips[0].audioGroupId)
        XCTAssertEqual(detached.sequence.tracks[1].clips[0].audioGroupId, "dialogue")
        detached.sequence.tracks[1].clips[0].muted = true
        detached.sequence.tracks[1].clips[0].staticParameters!["audio.volume"] = .number(0.45)
        detached.sequence.tracks[1].clips[0].effects.append(.init(id: "audio-fx", effectId: "gain", enabled: false))
        let attached = try reattachNativeVideoAudio(detached, audioClipId: "audio-clip")
        let clip = attached.sequence.tracks[0].clips[0]
        XCTAssertTrue(clip.muted); XCTAssertEqual(clip.audioGroupId, "dialogue")
        XCTAssertEqual(clip.staticParameters?["audio.volume"], .number(0.45)); XCTAssertEqual(clip.staticParameters?["visual.opacity"], .number(0.7))
        XCTAssertEqual(clip.effects.map(\.id), ["visual-fx", "audio-fx"])
        XCTAssertEqual(attached.sequence.tracks.count, 1)
    }

    func testRefusesSilentVideoAndChangedTiming() throws {
        let original = try project()
        XCTAssertThrowsError(try detachNativeVideoAudio(original, videoClipId: "video-clip", hasAudioStream: false, ids: ids)) {
            XCTAssertTrue(($0 as! NativeAudioCommandError).message.contains("no audio stream")) }
        var detached = try detachNativeVideoAudio(original, videoClipId: "video-clip", hasAudioStream: true, ids: ids)
        detached.sequence.tracks[1].clips[0].startFrame += 1
        detached.sequence.tracks[1].clips[0].staticParameters!["audio.volume"] = .number(0.2)
        XCTAssertThrowsError(try reattachNativeVideoAudio(detached, audioClipId: "audio-clip")) {
            XCTAssertTrue(($0 as! NativeAudioCommandError).message.contains("moved, trimmed, or retimed")) }
        XCTAssertEqual(detached.sequence.tracks[1].clips[0].staticParameters?["audio.volume"], .number(0.2))
        XCTAssertEqual(detached.sequence.tracks[1].clips.count, 1)
    }
}
