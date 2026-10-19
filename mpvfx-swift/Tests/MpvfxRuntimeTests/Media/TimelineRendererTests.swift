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
// Native timeline rendering with the media engine: cuts, trims, speed, gaps, layers and output size checked on decoded
// pixels; audio groups (bus gain/mute), grouped video sound, bus and clip FX through the bus/FX graph checked on
// decoded samples; cancellation, refusals and the MOV/WebM rules. Inputs are MOV files (PNG + LPCM) written by
// MediaWriter, so these run without the H.264 encoder. The startExport cases are in ExportStartOutcomeTests and
// ExportCompletenessTests.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime

final class TimelineRendererTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("native-timeline-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        installAppExportFrames()
        try makeInputs(Self.root)
    }
    var root: String { Self.root }

    /// red.mov: red for 1 s then yellow for 1 s with a 440 Hz tone; blue.mov: blue with 880 Hz; voice.wav: 660 Hz;
    /// silent.mov: green, no sound track. Written once.
    func makeInputs(_ dir: String) throws {
        guard !FileManager.default.fileExists(atPath: "\(dir)/silent.mov") else { return }
        try TestMedia.write(TestVideo(color: { $0 < 1 ? [255, 0, 0] : [255, 255, 0] }, tone: 440), to: "\(dir)/red.mov")
        try TestMedia.write(TestVideo(color: { _ in [0, 0, 255] }, tone: 880), to: "\(dir)/blue.mov")
        try TestMedia.wav(660, seconds: 2, to: "\(dir)/voice.wav")
        try TestMedia.write(TestVideo(color: { _ in [0, 255, 0] }), to: "\(dir)/silent.mov")
    }

    func project() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"test","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"red","kind":"video","name":"red","source":"red.mov","durationFrames":20},
                   {"id":"blue","kind":"video","name":"blue","source":"blue.mov","durationFrames":20}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"red","assetId":"red","startFrame":0,"durationFrames":5,"sourceInFrame":5,"playbackRate":{"numerator":2,"denominator":1},"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"blue","assetId":"blue","startFrame":10,"durationFrames":5,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }
    func render(_ document: NativeProjectDocument, _ name: String, format: ExportFormat = .mov, quality: ExportQuality? = nil,
                outputDimensions: ExportDimensions? = nil, cancellation: MediaCancellation? = nil, onProgress: ((Double) -> Void)? = nil) throws -> Exported {
        let output = "\(root)/\(name)"
        try? FileManager.default.removeItem(atPath: output)
        try renderNativeTimeline(.init(project: document, projectDir: root, outputPath: output, format: format, outputDimensions: outputDimensions,
                                       quality: quality, cancellation: cancellation, onProgress: onProgress))
        return Exported(path: output)
    }
    /// Mean RGB of the frame at `seconds` (the old 1×1 scale-down).
    func frame(_ file: Exported, _ seconds: Double) throws -> [UInt8] {
        let rgb = try file.rgb(seconds), n = rgb.count / 3
        return (0..<3).map { c in UInt8((stride(from: c, to: rgb.count, by: 3).reduce(0) { $0 + Int(rgb[$1]) } + n / 2) / n) }
    }
    /// The video clip plays at 1x from source frame 0 for 10 frames (several cases set this up).
    func plainRed(_ clip: inout NativeProjectClip) { clip.durationFrames = 10; clip.sourceInFrame = 0; clip.playbackRate = .init(numerator: 1, denominator: 1) }
    func level(_ output: Exported) throws -> Double { try output.rms(0.2) }
    func gainChain() -> String { #"{"version":1,"nodes":[{"type":"gain","params":{"gain":-6},"enabled":true}]}"# }
    func withVoiceInGroup(_ group: NativeAudioGroup) throws -> NativeProjectDocument {
        var document = try project()
        plainRed(&document.sequence.tracks[0].clips[0])
        document.sequence.tracks[0].clips[0].audioGroupId = group.id
        document.sequence.tracks[0].clips.removeLast()
        document.assets.append(.init(id: "voice", kind: .audio, name: "voice.wav", source: "voice.wav", durationFrames: 20))
        var voice = document.sequence.tracks[0].clips[0]; voice.id = "voice-clip"; voice.assetId = "voice"
        document.sequence.tracks.append(NativeProjectTrack(id: "voice-track", kind: .audio, lane: .init(authoredTrack: 1, displayTrack: 1), clips: [voice]))
        document.sequence.audioGroups = [group]
        return document
    }

    func testRendersDetachedSoundOnceWhileLeavingItsVideoPictureIntact() throws {
        var document = try project()
        document.sequence.tracks[0].clips.removeLast()
        plainRed(&document.sequence.tracks[0].clips[0])
        let baseline = try render(document, "detach-baseline.mov")
        var detached = try detachNativeVideoAudio(document, videoClipId: "red", hasAudioStream: true,
                                                  ids: .init(assetId: "red-audio", clipId: "red-audio-clip", trackId: "red-audio-track"))
        detached.sequence.tracks[0].clips[0].muted = false   // a stale preview mute must not make the export play both
        let output = try render(detached, "detach-output.mov")
        XCTAssertEqual(try output.rms(0.2) / baseline.rms(0.2), 1, accuracy: 0.05)
        XCTAssertGreaterThan(try frame(output, 0.2)[0], 220)
    }

    /// Routes mixed video and audio into one native bus with gain and mute.
    func testRoutesVideoAndAudioIntoOneBusWithGain() throws {
        let document = try withVoiceInGroup(NativeAudioGroup(id: "dialogue", label: "Dialogue", volume: 1))
        let full = try render(document, "group-full.mov")
        XCTAssertGreaterThan(try level(full), 0.05)
        XCTAssertGreaterThan(try frame(full, 0.2)[0], 220)
        // Bus gain: half the fader is half the level.
        var half = document; half.sequence.audioGroups![0].volume = 0.5
        XCTAssertEqual(try level(try render(half, "group-half.mov")) / level(full), 0.5, accuracy: 0.03)
    }

    /// A muted group is dropped (silent), with or without FX/automation: no sound track at all.
    func testDropsAMutedAudioGroupWithOrWithoutFXOrAutomation() throws {
        let document = try withVoiceInGroup(NativeAudioGroup(id: "dialogue", label: "Dialogue", volume: 1, muted: true))
        let output = try render(document, "group-muted.mov")
        XCTAssertNil(try output.probe.audio, "dropped muted group must leave no audio")
        XCTAssertGreaterThan(try frame(output, 0.1)[0], 220, "picture of the grouped video clip is still rendered")

        // Decision D4: a muted group stays silent even with group/member FX or automation.
        var groupFx = document; groupFx.sequence.audioGroups![0].fxChain = gainChain()
        var clipFx = document; clipFx.sequence.tracks[1].clips[0].audioFxChain = gainChain()
        var automated = document; automated.sequence.audioGroups![0].automation = #"{"version":1,"lanes":[]}"#
        let tracks = try [(groupFx, "muted-group-fx.mov"), (clipFx, "muted-clip-fx.mov"), (automated, "muted-group-auto.mov")]
            .map { try render($0.0, $0.1).probe.audio }
        XCTAssertEqual(tracks.map { $0 == nil }, [true, true, true])
    }

    func testRejectsGroupingAVideoWithoutAnAudioStream() throws {
        var document = try project()
        document.assets[0].source = "silent.mov"
        document.sequence.audioGroups = [NativeAudioGroup(id: "dialogue")]
        document.sequence.tracks[0].clips[0].audioGroupId = "dialogue"
        XCTAssertThrowsError(try render(document, "silent-group.mov")) { XCTAssertTrue("\($0)".contains("no audio stream"), "\($0)") }
    }

    /// Keeps two grouped video sound tracks on their native trim and gap positions.
    func testKeepsTwoGroupedVideoSoundTracksOnTheirTrimAndGapPositions() throws {
        var document = try project()
        document.sequence.audioGroups = [NativeAudioGroup(id: "videos", volume: 0.5)]
        document.sequence.tracks[0].clips = document.sequence.tracks[0].clips.map { var c = $0; c.audioGroupId = "videos"; c.muted = false; return c }
        let output = try render(document, "group-two-videos.mov")
        XCTAssertGreaterThan(try output.rms(0.2), 0.01)    // red's sound at its trim
        XCTAssertLessThan(try output.rms(0.7), 0.001)       // the gap stays silent
        XCTAssertGreaterThan(try output.rms(1.2), 0.01)    // blue's sound at its position
    }

    /// Cleans grouped render staging when cancelled before video encoding.
    func testLeavesNoGroupedRenderOutputOrPartialFileWhenCancelled() throws {
        var document = try project()
        document.sequence.audioGroups = [NativeAudioGroup(id: "dialogue")]
        document.sequence.tracks[0].clips[0].audioGroupId = "dialogue"
        let cancellation = MediaCancellation()
        XCTAssertThrowsError(try render(document, "group-cancelled.mov", cancellation: cancellation, onProgress: { if $0 >= 10 { cancellation.cancel() } })) {
            XCTAssertTrue($0 is MediaAbortError, "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/group-cancelled.mov"))
        XCTAssertEqual(try leftovers(root), [])
    }

    /// Applies the saved bus FX chain through the shared audio processor.
    func testAppliesTheSavedBusFXChainThroughTheSharedAudioGraph() throws {
        var document = try project()
        document.sequence.tracks[0].clips.removeLast()
        plainRed(&document.sequence.tracks[0].clips[0])
        document.sequence.tracks[0].clips[0].audioGroupId = "fx"
        document.sequence.audioGroups = [NativeAudioGroup(id: "fx", volume: 1, fxChain: gainChain())]
        let wet = try render(document, "group-fx-wet.mov")
        var dryDoc = document; dryDoc.sequence.audioGroups![0].fxChain = nil
        let dry = try render(dryDoc, "group-fx-dry.mov")
        XCTAssertEqual(try level(wet) / level(dry), 0.501, accuracy: 0.03)   // -6 dB gain node on the bus
    }

    /// Exports clip FX saved after detaching video audio.
    func testExportsClipFXSavedAfterDetachingVideoAudio() throws {
        var document = try project()
        document.sequence.tracks[0].clips.removeLast()
        plainRed(&document.sequence.tracks[0].clips[0])
        var detached = try detachNativeVideoAudio(document, videoClipId: "red", hasAudioStream: true,
                                                  ids: .init(assetId: "clip-fx-audio", clipId: "clip-fx-clip", trackId: "clip-fx-track"))
        let dry = try render(detached, "clip-fx-dry.mov")
        detached.sequence.tracks[1].clips[0].audioFxChain = gainChain()
        let wet = try render(detached, "clip-fx-wet.mov")
        XCTAssertEqual(try level(wet) / level(dry), 0.501, accuracy: 0.03)
        XCTAssertGreaterThan(try frame(wet, 0.2)[0], 220)
    }

    func testExportsCutsSourceTrimsSpeedGapsAndMuteWithNoHTMLFile() throws {
        let output = try render(try project(), "cuts.mov")
        XCTAssertGreaterThan(try frame(output, 0.2)[0], 220)
        XCTAssertLessThan(try frame(output, 0.2)[1], 12)
        XCTAssertGreaterThan(try frame(output, 0.4)[1], 220)   // source trim + 2x speed crosses into yellow at timeline frame 3
        XCTAssertTrue(try frame(output, 0.7).allSatisfy { $0 < 8 })
        XCTAssertGreaterThan(try frame(output, 1.2)[2], 220)
        XCTAssertGreaterThan(try output.rms(0.2), 0.01)
        XCTAssertLessThan(try output.rms(0.7), 0.001)
        XCTAssertLessThan(try output.rms(1.2), 0.001)
        let probe = try output.probe
        XCTAssertEqual(probe.video?.displayWidth, 64); XCTAssertEqual(probe.video?.displayHeight, 32)
        XCTAssertEqual(probe.video?.frames, 15); XCTAssertEqual(probe.video?.frameRate ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(probe.duration ?? 0, 1.5, accuracy: 0.01)
        XCTAssertEqual(Double(try output.audio().count / 2) / 48_000, 1.5, accuracy: 1e-3, "the sound track ends with the picture")
    }

    func testCompositesLayersWithOpacityAndOutputsTheRequestedDimensions() throws {
        var document = try project()
        var base = document.sequence.tracks[0].clips[0]
        plainRed(&base); base.muted = true
        document.sequence.tracks[0].clips = [base]
        var overlay = base; overlay.id = "overlay"; overlay.assetId = "blue"; overlay.staticParameters = ["visual.opacity": .number(0.5)]
        // The overlay sits on the top timeline row, so it draws over the base.
        document.sequence.tracks[0].lane = .init(authoredTrack: 0, displayTrack: 1)
        document.sequence.tracks.append(NativeProjectTrack(id: "overlay", kind: .video, lane: .init(authoredTrack: 1, displayTrack: 0), clips: [overlay]))
        let output = try render(document, "layers.mov", outputDimensions: .init(width: 128, height: 64))
        XCTAssertEqual(try output.probe.video?.displayWidth, 128)
        let color = try frame(output, 0.4)
        XCTAssertGreaterThan(color[0], 110); XCTAssertLessThan(color[0], 145)
        XCTAssertGreaterThan(color[2], 110); XCTAssertLessThan(color[2], 145)
        XCTAssertLessThan(color[1], 12)
    }

    func testDoesNotOmitAnUnsupportedEffect() throws {
        var document = try project()
        document.sequence.tracks[0].clips[0].effects.append(.init(id: "grade", effectId: "legacy-grade", enabled: true))
        XCTAssertThrowsError(try render(document, "unsupported.mov")) { XCTAssertTrue("\($0)".contains("effects that have not been migrated"), "\($0)") }
    }

    func testDoesNotOverwriteAnExistingOutput() throws {
        let output = "\(root)/existing.mov"
        try "keep".write(toFile: output, atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try renderNativeTimeline(.init(project: try project(), projectDir: root, outputPath: output, format: .mov)))
        XCTAssertEqual(try String(contentsOfFile: output, encoding: .utf8), "keep")
    }

    func testRejectsAMediaSymlinkEscapingTheProject() throws {
        let outside = try makeMediaTempDir("native-timeline-outside-")
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try TestMedia.write(TestVideo(), to: "\(outside)/elsewhere.mov")
        try? FileManager.default.removeItem(atPath: "\(root)/escape.mov")
        try FileManager.default.createSymbolicLink(atPath: "\(root)/escape.mov", withDestinationPath: "\(outside)/elsewhere.mov")
        var document = try project(); document.assets[0].source = "escape.mov"
        XCTAssertThrowsError(try render(document, "escape-output.mov")) { XCTAssertTrue("\($0)".contains("inside its project"), "\($0)") }
    }

    func testHonorsCancellationBeforeStartingAnyRender() throws {
        let abort = MediaCancellation(); abort.cancel()
        XCTAssertThrowsError(try render(try project(), "cancelled.mov", cancellation: abort)) { XCTAssertTrue($0 is MediaAbortError, "\($0)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/cancelled.mov"))
    }

    func testStopsAnActiveNativeEncodeWhenItsOwningJobIsCancelled() throws {
        var document = try project()
        document.sequence.tracks = []
        document.canvas = .init(width: 1920, height: 1080, background: "#000000")
        document.sequence.durationFrames = 100_000
        let abort = MediaCancellation()
        let started = Date()
        XCTAssertThrowsError(try render(document, "cancelled-active.mov", cancellation: abort, onProgress: { _ in abort.cancel() })) {
            XCTAssertTrue($0 is MediaAbortError, "\($0)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/cancelled-active.mov"))
        XCTAssertEqual(try leftovers(root), [], "the writer's partial file is removed")
    }

    func testRefusesSourceRangesLongerThanTheActualMedia() throws {
        var document = try project()
        document.assets[0].durationFrames = 100
        document.sequence.tracks[0].clips[0].sourceInFrame = 50
        XCTAssertThrowsError(try render(document, "short-media.mov")) { XCTAssertTrue("\($0)".contains("extends beyond its media file"), "\($0)") }
    }

    /// A video with AAC sound (the 0.53 s sine of TestMedia.aacTrack) exports its picture and its sound: the sine
    /// where the source has it (FFmpeg's `sine` source: amplitude 1/8, RMS 0.088), silence after it ends.
    func testAVideoWithAACSoundExportsItsPictureAndSound() throws {
        let red = TestMedia.solid((255, 0, 0), width: 64, height: 32)
        try TestMedia.movie([TestMedia.pngTrack(Array(repeating: red, count: 20), width: 64, height: 32), TestMedia.aacTrack()])
            .write(to: URL(fileURLWithPath: "\(root)/aac.mp4"))
        var document = try project()
        document.assets[0].source = "aac.mp4"
        document.sequence.tracks[0].clips.removeLast()
        plainRed(&document.sequence.tracks[0].clips[0])
        let output = try render(document, "aac-out.mov")
        XCTAssertEqual(try output.probe.audio?.codec, "pcm")
        XCTAssertGreaterThan(try output.rms(0.2), 0.04)
        XCTAssertLessThan(try output.rms(0.7), 0.001)
        XCTAssertGreaterThan(try frame(output, 0.5)[0], 220)
    }

    /// MOV (PNG + LPCM) and MP4 (H.264 + FLAC) are the v1 presets (formats.md); WebM is refused with its message.
    func testEncodesMovAndMp4AndRefusesWebm() throws {
        let mov = try render(try project(), "format.mov", quality: .draft)
        XCTAssertGreaterThan(try frame(mov, 1.2)[2], 220)
        XCTAssertLessThan(try mov.rms(1.2), 0.001)
        XCTAssertEqual(try mov.probe.video?.codec, "png"); XCTAssertEqual(try mov.probe.audio?.codec, "pcm")
        let mp4 = try render(try project(), "format.mp4", format: .mp4, quality: .draft)
        XCTAssertGreaterThan(try frame(mp4, 1.2)[2], 200)
        XCTAssertEqual(try mp4.probe.video?.codec, "h264"); XCTAssertEqual(try mp4.probe.audio?.codec, "flac")
        XCTAssertThrowsError(try render(try project(), "format.webm", format: .webm)) { XCTAssertEqual("\($0)", WEBM_EXPORT_UNSUPPORTED_MESSAGE) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/format.webm"))
    }
}
