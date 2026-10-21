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
// A real project (a graded video clip with sound, a moved half-transparent still above it, a text layer and an
// audio-only clip) exported as MOV and MP4 and read back with the media engine: every checked frame is the preview
// painter's frame for the same time (MOV: within 1 per channel, PNG is lossless; MP4: mean difference at most 4 per
// channel, the H.264 4:2:0 loss), and duration, frame rate, size and sound length are what the timeline says.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime

final class ExportPreviewMatchTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("export-match-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(root)/tone.wav") else { return }
        // A mid-gray video that brightens over its 2 s, with a 440 Hz tone; a blue still; a 660 Hz tone.
        try TestMedia.write(TestVideo(width: 96, height: 48, color: { t in [UInt8(96 + 40 * t), 128, UInt8(160 - 40 * t)] }, tone: 440),
                            to: "\(root)/gray.mov")
        try TestMedia.bmp(width: 32, height: 16, rgb: [0, 0, 255], to: "\(root)/blue.bmp")
        try TestMedia.wav(660, seconds: 2, to: "\(root)/tone.wav")
    }
    var root: String { Self.root }

    /// The video clip's grade parameters in `document()`.
    static let exposureGrade = #"{"adjust":{"exposure":0.6}}"#
    /// Curves on all seven tabs: a steep RGB rise, a master curve with its end points inside the range, and hue
    /// curves with a local bump, so export runs every curve table the preview does.
    static let curvesGrade = #"""
    {"curves":{"master":[[0.1,0.05],[0.5,0.6],[0.9,0.95]],"red":[[0,0],[0.4,0.1],[0.45,0.7],[1,1]],"green":[[0,0.1],[1,0.9]],
     "blue":[[0,0],[0.3,0.45],[1,1]]},
     "hueCurves":{"hueVsHue":[[0,0],[200,30],[260,0]],"hueVsSaturation":[[180,0],[220,0.6],[280,0]],"hueVsLuma":[[20,-0.1],[140,0.1],[300,0]]}}
    """#

    /// 96x48 at 10 fps, 2 s; the video clip graded with `grade`.
    func document(grade: String = exposureGrade) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"match","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":96,"height":48,"background":"#102030"},
         "assets":[{"id":"gray","kind":"video","name":"gray","source":"gray.mov","durationFrames":20},
                   {"id":"blue","kind":"image","name":"blue","source":"blue.bmp","durationFrames":1},
                   {"id":"title","kind":"element","name":"Title","durationFrames":20},
                   {"id":"tone","kind":"audio","name":"tone","source":"tone.wav","durationFrames":20}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[
           {"id":"text","kind":"video","lane":{"authoredTrack":2,"displayTrack":0},"clips":[
             {"id":"title","assetId":"title","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":true,
              "staticParameters":{"layout.left":4,"layout.top":24,"layout.width":60,"layout.height":20},
              "text":{"content":"Hi","fontSize":16,"color":"#ffffff"},"effects":[],"parameterTracks":[]}]},
           {"id":"overlay","kind":"video","lane":{"authoredTrack":1,"displayTrack":1},"clips":[
             {"id":"blue","assetId":"blue","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":true,
              "staticParameters":{"layout.width":32,"layout.height":16,"transform.position":{"x":64,"y":0},"visual.opacity":0.5},
              "effects":[],"parameterTracks":[]}]},
           {"id":"base","kind":"video","lane":{"authoredTrack":0,"displayTrack":2},"clips":[
             {"id":"gray","assetId":"gray","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":false,
              "effects":[{"id":"grade","effectId":"color-grading","enabled":true,"parameters":\#(grade)}],
              "parameterTracks":[]}]},
           {"id":"music","kind":"audio","lane":{"authoredTrack":3,"displayTrack":3},"clips":[
             {"id":"tone","assetId":"tone","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    func export(_ format: ExportFormat, grade: String = exposureGrade, name: String = "match") throws -> (input: NativeTimelineRenderInput, file: Exported) {
        let output = "\(root)/\(name).\(format.rawValue)"
        try? FileManager.default.removeItem(atPath: output)
        let input = NativeTimelineRenderInput(project: try document(grade: grade), projectDir: root, outputPath: output, format: format, quality: .high)
        try renderNativeTimeline(input)
        return (input, Exported(path: output))
    }

    /// The exported frame and the preview painter's frame at each of `times`.
    func pairs(_ export: (input: NativeTimelineRenderInput, file: Exported), _ times: [Double]) throws -> [(Double, [UInt8], [UInt8])] {
        try times.map { ($0, try export.file.rgba($0).rgba, try previewExportFrame(export.input, at: $0)) }
    }

    func assertTimeline(_ file: Exported) throws {
        let probe = try file.probe
        XCTAssertEqual(probe.duration ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(probe.video?.displayWidth, 96); XCTAssertEqual(probe.video?.displayHeight, 48)
        XCTAssertEqual(probe.video?.frameRate ?? 0, 10, accuracy: 1e-9); XCTAssertEqual(probe.video?.frames, 20)
        XCTAssertEqual(probe.audio?.sampleRate, 48_000); XCTAssertEqual(probe.audio?.channels, 2)
        let sound = try file.audio()
        XCTAssertEqual(sound.count / 2, 96_000, "two seconds of sound, ending with the picture")
        XCTAssertGreaterThan(TestAudio.rms(sound, from: 48_000, count: 4800), 0.1, "the video's tone and the music clip are mixed")
    }

    func testMovExportIsThePreviewFrameForFrame() throws {
        let mov = try export(.mov)
        try assertTimeline(mov.file)
        let diffs = try pairs(mov, [0, 0.5, 1.25, 1.9]).map { maxAbsDiff($0.1, $0.2) }
        XCTAssertEqual(diffs.filter { $0 > 1 }, [], "max channel difference per frame: \(diffs)")
        // The layers really are there: text ink, the half-transparent blue still over the graded video.
        let f = try mov.file.rgba(1.0)
        let still = Array(f.rgba[(8 * 96 + 80) * 4..<(8 * 96 + 80) * 4 + 3]), video = Array(f.rgba[(36 * 96 + 80) * 4..<(36 * 96 + 80) * 4 + 3])
        XCTAssertGreaterThan(Int(still[2]) - Int(still[0]), 40, "blue over the video: \(still)")
        XCTAssertGreaterThan(Int(video[1]), 150, "the +0.6 exposure grade lifts the video: \(video)")
        XCTAssertTrue(stride(from: 24, to: 44, by: 1).contains { y in (4..<64).contains { x in f.rgba[(y * 96 + x) * 4] > 240 } }, "white text ink")
    }

    /// Curves on every tab: the exported frames are the preview's, first and last frame included, and the curves
    /// really change the picture (the same project with the exposure grade gives other pixels).
    func testCurvesGradeExportIsThePreviewFrameForFrame() throws {
        let mov = try export(.mov, grade: Self.curvesGrade, name: "curves")
        try assertTimeline(mov.file)
        let frames = try pairs(mov, [0, 0.7, 1.3, 1.9])
        let diffs = frames.map { maxAbsDiff($0.1, $0.2) }
        XCTAssertEqual(diffs.filter { $0 > 1 }, [], "max channel difference per frame: \(diffs)")
        let plain = try previewExportFrame(try export(.mov).input, at: 0.7)
        XCTAssertGreaterThan(maxAbsDiff(frames[1].2, plain), 20, "the curves grade differs from the exposure grade")
    }

    func testMp4ExportMatchesThePreviewWithinTheEncoderLoss() throws {
        let mp4 = try export(.mp4)
        try assertTimeline(mp4.file)
        XCTAssertEqual(try mp4.file.probe.video?.codec, "h264"); XCTAssertEqual(try mp4.file.probe.audio?.codec, "flac")
        let diffs = try pairs(mp4, [0, 0.5, 1.25, 1.9]).map { meanAbsDiff($0.1, $0.2) }
        XCTAssertEqual(diffs.filter { $0 > 4 }, [], "mean channel difference per frame: \(diffs)")
    }

    func testCancelledExportLeavesNoFile() throws {
        let cancellation = MediaCancellation()
        var input = NativeTimelineRenderInput(project: try document(), projectDir: root, outputPath: "\(root)/cancelled.mp4", format: .mp4)
        input.cancellation = cancellation
        input.onProgress = { if $0 > 20 { cancellation.cancel() } }
        XCTAssertThrowsError(try renderNativeTimeline(input)) { XCTAssertTrue($0 is MediaAbortError, "\($0)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/cancelled.mp4"))
        XCTAssertEqual(try leftovers(root), [])
    }
}
