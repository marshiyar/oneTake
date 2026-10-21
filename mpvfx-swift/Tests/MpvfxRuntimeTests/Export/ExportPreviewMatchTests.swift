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
import OneTakeKeyframes

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

    /// The base clip's grade parameters in `document()` unless a test passes its own.
    static let exposureGrade = #"{"adjust":{"exposure":0.6}}"#
    /// The base clip's grade keyed (issue #179): exposure 0 at its first frame to +1 at its last, linear.
    static let keyedExposure = #"[{"schemaVersion":1,"id":"param:exposure","parameterId":"grade.adjust.exposure","valueType":"number","frameRate":{"numerator":10,"denominator":1},"keyframes":[{"id":"k0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"k1","frame":19,"value":1,"outgoing":{"type":"linear"}}]}]"#

    /// Curves on all seven tabs: a steep RGB rise, a master curve with its end points inside the range, and hue
    /// curves with a local bump, so export runs every curve table the preview does.
    static let curvesGrade = #"""
    {"curves":{"master":[[0.1,0.05],[0.5,0.6],[0.9,0.95]],"red":[[0,0],[0.4,0.1],[0.45,0.7],[1,1]],"green":[[0,0.1],[1,0.9]],
     "blue":[[0,0],[0.3,0.45],[1,1]]},
     "hueCurves":{"hueVsHue":[[0,0],[200,30],[260,0]],"hueVsSaturation":[[180,0],[220,0.6],[280,0]],"hueVsLuma":[[20,-0.1],[140,0.1],[300,0]]}}
    """#

    /// 96x48 at 10 fps, 2 s; the base clip graded with `grade`, or with `keyedGrade` its exposure animated (0 to +1).
    func document(grade: String = exposureGrade, keyedGrade: Bool = false) throws -> NativeProjectDocument {
        let text = Self.documentText.replacingOccurrences(of: "GRAY_GRADE", with: keyedGrade ? #"{"adjust":{"exposure":0}}"# : grade)
            .replacingOccurrences(of: "GRAY_TRACKS", with: keyedGrade ? Self.keyedExposure : "[]")
        let engine = try KeyframeRuntime()
        installKeyframeEngine(engine)   // export evaluates parameter tracks through the installed engine
        return try parseNativeProjectDocument(try NativeJSONValue.parse(text), engine: engine)
    }

    static let documentText = #"""
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
              "effects":[{"id":"grade","effectId":"color-grading","enabled":true,"parameters":GRAY_GRADE}],
              "parameterTracks":GRAY_TRACKS}]},
           {"id":"music","kind":"audio","lane":{"authoredTrack":3,"displayTrack":3},"clips":[
             {"id":"tone","assetId":"tone","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#

    func export(_ format: ExportFormat, grade: String = exposureGrade, keyedGrade: Bool = false, name: String? = nil) throws
        -> (input: NativeTimelineRenderInput, file: Exported) {
        let output = "\(root)/\(name ?? "match\(keyedGrade ? "-keyed" : "")").\(format.rawValue)"
        try? FileManager.default.removeItem(atPath: output)
        let input = NativeTimelineRenderInput(project: try document(grade: grade, keyedGrade: keyedGrade), projectDir: root, outputPath: output,
                                              format: format, quality: .high)
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

    /// Contract 3 Warmth and Tint (channel gains, issue #172) on the graded video: export is the preview at the first,
    /// a middle and the last frame, and the warm grade shows.
    func testContract3WarmthExportIsThePreviewFrameForFrame() throws {
        let mov = try export(.mov, grade: #"{"version":3,"adjust":{"temperature":0.8,"tint":-0.3,"exposure":0.2}}"#, name: "warm")
        let diffs = try pairs(mov, [0, 1.0, 1.9]).map { maxAbsDiff($0.1, $0.2) }
        XCTAssertEqual(diffs.filter { $0 > 1 }, [], "max channel difference per frame: \(diffs)")
        let f = try mov.file.rgba(1.0)
        let video = Array(f.rgba[(36 * 96 + 80) * 4..<(36 * 96 + 80) * 4 + 3])
        XCTAssertGreaterThan(Int(video[0]) - Int(video[2]), 20, "Warmth +80 warms the video: \(video)")
    }

    func testBypassedEffectExportMatchesPreviewAndEffectFreePixels() throws {
        let bypassed = try export(.mov, grade: #"{"effects":{"monoScreen":1,"monoScreenShape":3},"bypassedEffects":["monoScreen"]}"#, name: "bypassed-effect")
        let frames = try pairs(bypassed, [0, 1.0, 1.9])
        XCTAssertTrue(frames.allSatisfy { maxAbsDiff($0.1, $0.2) <= 1 })
        let neutral = try export(.mov, grade: "{}", name: "effect-free")
        let active = try export(.mov, grade: #"{"effects":{"monoScreen":1,"monoScreenShape":3}}"#, name: "active-effect")
        XCTAssertEqual(maxAbsDiff(try previewExportFrame(bypassed.input, at: 1), try previewExportFrame(neutral.input, at: 1)), 0)
        XCTAssertGreaterThan(maxAbsDiff(try previewExportFrame(active.input, at: 1), try previewExportFrame(neutral.input, at: 1)), 20)
    }

    func testMp4ExportMatchesThePreviewWithinTheEncoderLoss() throws {
        let mp4 = try export(.mp4)
        try assertTimeline(mp4.file)
        XCTAssertEqual(try mp4.file.probe.video?.codec, "h264"); XCTAssertEqual(try mp4.file.probe.audio?.codec, "flac")
        let diffs = try pairs(mp4, [0, 0.5, 1.25, 1.9]).map { meanAbsDiff($0.1, $0.2) }
        XCTAssertEqual(diffs.filter { $0 > 4 }, [], "mean channel difference per frame: \(diffs)")
    }

    /// Issue #179 A3: a keyframed grade is evaluated per frame in preview and export alike, at the clip's first,
    /// middle and last frame, and the exposure really ramps (the video's green channel is a constant 128).
    func testKeyedGradeExportsThePreviewFrameAtTheFirstMiddleAndLastFrame() throws {
        let mov = try export(.mov, keyedGrade: true)
        let diffs = try pairs(mov, [0, 1.0, 1.9]).map { maxAbsDiff($0.1, $0.2) }
        XCTAssertEqual(diffs.filter { $0 > 1 }, [], "max channel difference per frame: \(diffs)")
        let green = try [0.0, 1.0, 1.9].map { t in Int(try mov.file.rgba(t).rgba[(36 * 96 + 40) * 4 + 1]) }
        XCTAssertLessThan(green[0], green[1], "exposure rises through the clip: \(green)")
        XCTAssertLessThan(green[1], green[2], "exposure rises through the clip: \(green)")
        XCTAssertLessThanOrEqual(abs(green[0] - 128), 2, "exposure 0 at the first frame leaves the video as it is: \(green)")
    }

    /// A 48x96 portrait frame at 10 fps, 2 s: the 96x48 video untouched and set to Fill, and the blue still set to
    /// Stretch over the frame's lower half (issue #86).
    func fitDocument() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"fit","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":48,"height":96,"background":"#102030"},
         "assets":[{"id":"gray","kind":"video","name":"gray","source":"gray.mov","durationFrames":20},
                   {"id":"blue","kind":"image","name":"blue","source":"blue.bmp","durationFrames":1}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[
           {"id":"overlay","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
             {"id":"blue","assetId":"blue","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":true,"fit":"stretch",
              "staticParameters":{"layout.left":0,"layout.top":48,"layout.width":48,"layout.height":48},
              "effects":[],"parameterTracks":[]}]},
           {"id":"base","kind":"video","lane":{"authoredTrack":0,"displayTrack":1},"clips":[
             {"id":"gray","assetId":"gray","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":false,"fit":"fill",
              "effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    func testFillAndStretchExportAsThePreviewDrawsThem() throws {
        let output = "\(root)/fit.mov"
        try? FileManager.default.removeItem(atPath: output)
        let input = NativeTimelineRenderInput(project: try fitDocument(), projectDir: root, outputPath: output, format: .mov, quality: .high)
        try renderNativeTimeline(input)
        let file = Exported(path: output)
        // The first, a middle and the last frame.
        let diffs = try pairs((input: input, file: file), [0, 1.0, 1.9]).map { maxAbsDiff($0.1, $0.2) }
        XCTAssertEqual(diffs.filter { $0 > 1 }, [], "max channel difference per frame: \(diffs)")
        let f = try file.rgba(1.0)
        func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * 48 + x) * 4; return f.rgba[i..<i + 3].map { Int($0) } }
        // Fill: the video reaches the frame's top corners, where Fit would leave the #102030 background.
        XCTAssertGreaterThan(rgb(1, 1)[1], 100, "the video, not the background: \(rgb(1, 1))")
        XCTAssertGreaterThan(rgb(46, 1)[1], 100, "the video, not the background: \(rgb(46, 1))")
        // Stretch: the blue still covers the whole lower half, corner to corner.
        for (x, y) in [(1, 49), (46, 49), (1, 94), (46, 94)] {
            XCTAssertGreaterThan(rgb(x, y)[2] - rgb(x, y)[0], 100, "blue at \(x),\(y): \(rgb(x, y))")
        }
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
