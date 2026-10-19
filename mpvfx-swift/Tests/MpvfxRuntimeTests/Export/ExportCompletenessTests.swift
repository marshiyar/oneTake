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
// Export renders what the timeline shows: keyframed transforms/opacity, crop, keyframed clip volume, hidden tracks, a
// frame range, the v1 formats, and the export session API (presets, progress, cancellation). Every case renders a
// real file through the media engine (frames painted by the preview's painter) and decodes its pixels and samples back
// with the engine. Inputs are MOV (PNG + LPCM) written by MediaWriter; outputs are MOV unless a case is about MP4.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime
import OneTakeKeyframes

final class ExportCompletenessTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("export-complete-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    var engine: KeyframeRuntime!
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        engine = try KeyframeRuntime(); installKeyframeEngine(engine)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(root)/still.bmp") else { return }
        try TestMedia.write(TestVideo(tone: 440), to: "\(root)/red.mov")
        try TestMedia.bmp(width: 64, height: 32, rgb: [255, 0, 0], to: "\(root)/still.bmp")
    }
    var root: String { Self.root }

    func project(_ clipExtra: String = "", parameterTracks: String = "[]", canvas: String = ##"{"width":64,"height":32,"background":"#000000"}"##) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"test","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":\#(canvas),
         "assets":[{"id":"red","kind":"video","name":"red","source":"red.mov","durationFrames":20}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"red","assetId":"red","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":false,\#(clipExtra)"effects":[],"parameterTracks":\#(parameterTracks)}]}]}}
        """#))
    }
    func track(_ parameter: String, _ type: String, _ keys: [(Int, String)]) -> String {
        let k = keys.enumerated().map { #"{"id":"k\#($0.offset)","frame":\#($0.element.0),"value":\#($0.element.1),"outgoing":{"type":"linear"}}"# }
        return #"{"schemaVersion":1,"id":"t:\#(parameter)","parameterId":"\#(parameter)","valueType":"\#(type)","frameRate":{"numerator":10,"denominator":1},"keyframes":[\#(k.joined(separator: ","))]}"#
    }
    func render(_ document: NativeProjectDocument, _ name: String, range: ExportFrameRange? = nil) throws -> String {
        let output = "\(root)/\(name)"
        try? FileManager.default.removeItem(atPath: output)
        let format: ExportFormat = name.hasSuffix(".mp4") ? .mp4 : name.hasSuffix(".webm") ? .webm : .mov
        try renderNativeTimeline(.init(project: document, projectDir: root, outputPath: output, format: format, quality: .high,
                                       keyframeEngine: engine, range: range))
        return output
    }
    /// Full 64x32 RGB frame at `seconds`.
    func picture(_ path: String, _ seconds: Double) throws -> [UInt8] { try Exported(path: path).rgb(seconds) }
    func red(_ frame: [UInt8], _ x: Int, _ y: Int, width: Int = 64) -> Int { Int(frame[(y * width + x) * 3]) }
    func rms(_ path: String, _ seconds: Double) throws -> Double { try Exported(path: path).rms(seconds) }

    // MARK: keyframes

    func testKeyframedPositionMovesTheClipAcrossTheCanvas() throws {
        let doc = try project(#""staticParameters":{"layout.width":16,"layout.height":16},"#,
                              parameterTracks: "[\(track("transform.position", "vec2", [(0, #"{"x":0,"y":8}"#), (9, #"{"x":48,"y":8}"#)]))]")
        let out = try render(doc, "position.mov")
        let start = try picture(out, 0), end = try picture(out, 0.9)
        XCTAssertGreaterThan(red(start, 8, 16), 200); XCTAssertLessThan(red(start, 56, 16), 40)
        XCTAssertLessThan(red(end, 8, 16), 40); XCTAssertGreaterThan(red(end, 56, 16), 200)
        let mid = try picture(out, 0.5)   // x = 48 * 5/9 ~ 26.7 -> box spans ~27...43
        XCTAssertGreaterThan(red(mid, 34, 16), 200); XCTAssertLessThan(red(mid, 20, 16), 40)
        let p = try MediaProbe.probe(path: out)
        XCTAssertEqual(p.duration ?? 0, 2, accuracy: 0.01)
        XCTAssertNotNil(p.video); XCTAssertNotNil(p.audio)
    }

    func testKeyframedOpacityFadesIn() throws {
        let doc = try project(parameterTracks: "[\(track("transform.opacity", "number", [(0, "0"), (10, "1")]))]")
        let out = try render(doc, "opacity.mov")
        XCTAssertLessThan(red(try picture(out, 0), 32, 16), 30)
        XCTAssertEqual(Double(red(try picture(out, 0.5), 32, 16)), 128, accuracy: 30)
        XCTAssertGreaterThan(red(try picture(out, 1.5), 32, 16), 220)
    }

    func testKeyframedRotationTurnsAboutTheBoxCentre() throws {
        let doc = try project(parameterTracks: "[\(track("transform.rotation", "number", [(0, "0"), (10, "90")]))]")
        let out = try render(doc, "rotation.mov")
        let start = try picture(out, 0), end = try picture(out, 1.5)
        XCTAssertGreaterThan(red(start, 4, 16), 200)                      // unrotated: fills the canvas
        XCTAssertLessThan(red(end, 4, 16), 40)                            // 90 deg: a 32x64 column centred on the canvas
        XCTAssertGreaterThan(red(end, 32, 2), 200)
        XCTAssertGreaterThan(red(end, 32, 29), 200)
    }

    func testKeyframedScaleAndBoxSizeGrowTheClip() throws {
        let doc = try project(parameterTracks: "[\(track("transform.scale", "number", [(0, "0.25"), (10, "1")]))]")
        let out = try render(doc, "scale.mov")
        let start = try picture(out, 0), end = try picture(out, 1.5)
        XCTAssertGreaterThan(red(start, 32, 16), 200); XCTAssertLessThan(red(start, 4, 16), 40)   // 16x8 in the middle
        XCTAssertGreaterThan(red(end, 4, 16), 200)
    }

    /// A long, busy animation (a key on every frame for 45 s) exports whole and lands where its keys say.
    func testLongKeyframedImageClipExportsEveryFrame() throws {
        var doc = try project()
        doc.assets.append(.init(id: "still", kind: .image, name: "still", source: "still.bmp", durationFrames: 1))
        let keys = (0..<450).map { ($0, #"{"x":\#($0 % 2 == 0 ? 0 : 20),"y":\#($0 % 3 == 0 ? 0 : 8)}"#) }
        var still = doc.sequence.tracks[0].clips[0]
        still.id = "still"; still.assetId = "still"; still.durationFrames = 450
        still.staticParameters = ["layout.width": .number(16), "layout.height": .number(8)]
        still.parameterTracks = [try JSONDecoder().decode(NativeParameterTrack.self, from: Data(track("transform.position", "vec2", keys).utf8))]
        doc.sequence.tracks[0].clips = [still]
        let out = try render(doc, "long-animated.mov")
        let p = try MediaProbe.probe(path: out)
        XCTAssertEqual(p.duration ?? 0, 45, accuracy: 0.01); XCTAssertEqual(p.video?.frames, 450)
        let f = try picture(out, 1.0)   // key 10: x=0, y=8 (10 % 3 != 0)
        XCTAssertGreaterThan(red(f, 8, 12), 200); XCTAssertLessThan(red(f, 40, 12), 40)
        XCTAssertEqual(try leftovers(root), [])
    }

    func testRefusesKeyframesOnAParameterItCannotRender() throws {
        let doc = try project(parameterTracks: "[\(track("layout.zIndex", "number", [(0, "0"), (10, "1")]))]")
        XCTAssertThrowsError(try render(doc, "zindex.mov")) { XCTAssertTrue("\($0)".contains("does not support animating layout.zIndex"), "\($0)") }
    }

    // MARK: crop

    func testCropMasksTheStaticClip() throws {
        let out = try render(try project(#""crop":{"top":0,"right":0,"bottom":0,"left":32},"#), "crop.mov")
        let f = try picture(out, 0.5)
        XCTAssertLessThan(red(f, 10, 16), 40); XCTAssertGreaterThan(red(f, 50, 16), 200)
    }

    func testCropFollowsAnAnimatedClip() throws {
        let doc = try project(#""crop":{"top":0,"right":0,"bottom":0,"left":32},"#,
                              parameterTracks: "[\(track("transform.position", "vec2", [(0, #"{"x":0,"y":0}"#), (10, #"{"x":-32,"y":0}"#)]))]")
        let out = try render(doc, "crop-animated.mov")
        let start = try picture(out, 0), end = try picture(out, 1.5)
        XCTAssertLessThan(red(start, 10, 16), 40); XCTAssertGreaterThan(red(start, 50, 16), 200)
        XCTAssertGreaterThan(red(end, 10, 16), 200); XCTAssertLessThan(red(end, 50, 16), 40)   // the visible half moved left
    }

    // MARK: audio

    func testKeyframedClipVolumeRampsTheSound() throws {
        let doc = try project(parameterTracks: "[\(track("audio.volume", "number", [(0, "0"), (10, "1")]))]")
        let out = try render(doc, "volume.mov")
        let flat = try render(try project(), "volume-flat.mov")
        XCTAssertLessThan(try rms(out, 0.0) / rms(flat, 0.0), 0.15)
        XCTAssertEqual(try rms(out, 0.5) / rms(flat, 0.5), 0.55, accuracy: 0.1)
        XCTAssertEqual(try rms(out, 1.5) / rms(flat, 1.5), 1, accuracy: 0.05)
    }

    func testLeavesHiddenTracksOutButKeepsTheSequenceLength() throws {
        var doc = try project()
        doc.sequence.tracks[0].hidden = true
        doc.sequence.tracks.append(NativeProjectTrack(id: "shown", kind: .video, lane: .init(authoredTrack: 1, displayTrack: 1), clips: []))
        let out = try render(doc, "hidden.mov")
        let p = try MediaProbe.probe(path: out)
        XCTAssertEqual(p.duration ?? 0, 2, accuracy: 0.01)
        XCTAssertNotNil(p.video); XCTAssertNil(p.audio, "the hidden clip's sound is left out too")
        XCTAssertLessThan(red(try picture(out, 0.5), 32, 16), 20)
    }

    // MARK: range, formats

    func testExportsOnlyTheChosenRange() throws {
        var doc = try project()
        doc.sequence.tracks[0].clips[0].staticParameters = ["layout.width": .number(64)]
        let out = try render(doc, "range.mov", range: .init(startFrame: 5, endFrame: 15))
        let p = try MediaProbe.probe(path: out)
        XCTAssertEqual(p.duration ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(p.video?.frames, 10)
        XCTAssertEqual(Double(try Exported(path: out).audio().count / 2) / 48_000, 1, accuracy: 1e-3)
        XCTAssertThrowsError(try render(doc, "range-bad.mov", range: .init(startFrame: 15, endFrame: 5)))
    }

    /// MOV keeps alpha in PNG frames with LPCM sound; MP4 is H.264 with FLAC sound; WebM is refused (formats.md).
    func testAnimatedExportsAsMovAndMp4() throws {
        let doc = try project(parameterTracks: "[\(track("transform.opacity", "number", [(0, "0"), (10, "1")]))]")
        let results = try ["animated.mov", "animated.mp4"].map { name -> (Int, String?, String?) in
            let out = try render(doc, name)
            let p = try MediaProbe.probe(path: out)
            return (red(try picture(out, 1.5), 32, 16), p.video?.codec, p.audio?.codec)
        }
        XCTAssertGreaterThan(results[0].0, 200); XCTAssertEqual(results[0].1, "png"); XCTAssertEqual(results[0].2, "pcm")
        XCTAssertGreaterThan(results[1].0, 200); XCTAssertEqual(results[1].1, "h264"); XCTAssertEqual(results[1].2, "flac")
        XCTAssertThrowsError(try render(doc, "animated.webm")) { XCTAssertEqual("\($0)", WEBM_EXPORT_UNSUPPORTED_MESSAGE) }
    }

    /// MOV keeps transparency: a canvas smaller than the output is padded with clear pixels, MP4 with black.
    func testMovPadsWithTransparencyAndMp4WithBlack() throws {
        let doc = try project()
        let settings = ExportDimensions(width: 64, height: 64)
        let pads = try [ExportFormat.mov, .mp4].map { format -> [UInt8] in
            let out = "\(root)/pad.\(format.rawValue)"
            try? FileManager.default.removeItem(atPath: out)
            try renderNativeTimeline(.init(project: doc, projectDir: root, outputPath: out, format: format, outputDimensions: settings, keyframeEngine: engine))
            let f = try Exported(path: out).rgba(0.5)
            return Array(f.rgba[(4 * 64 + 32) * 4..<(4 * 64 + 32) * 4 + 4])
        }
        XCTAssertEqual(pads[0][3], 0, "MOV pad is transparent")
        XCTAssertEqual(pads[1][3], 255, "MP4 pad is opaque"); XCTAssertLessThan(Int(pads[1][0]), 20)
    }

    // MARK: session API

    func testStartExportRendersAPresetWithProgressAndAnAtomicFinish() throws {
        let output = "\(root)/session.mp4"
        var seen: [Double] = []
        let lock = NSLock()
        let settings = ExportSettings(format: .mp4, quality: .draft, fps: .fps24, resolution: .custom,
                                      customDimensions: .init(width: 128, height: 64))
        let plan = planExport(try project(), settings: settings)
        XCTAssertTrue(plan.canStart, "\(plan.issues)")
        XCTAssertEqual(plan.outputDimensions, .init(width: 128, height: 64))
        XCTAssertEqual(plan.frameCount, 48)
        let job = try startExport(project: try project(), projectDir: root, outputPath: output, settings: settings, keyframeEngine: engine,
                                  progress: { p in lock.lock(); seen.append(p.percent); lock.unlock() })
        guard case .completed(let path, let size, _)? = job.wait(timeout: 120) else { return XCTFail("\(String(describing: job.outcome))") }
        XCTAssertEqual(path, output); XCTAssertGreaterThan(size, 0)
        XCTAssertEqual(job.status, .completed)
        lock.lock(); let progress = seen; lock.unlock()
        XCTAssertEqual(progress.last, 100); XCTAssertEqual(progress, progress.sorted())
        let video = try XCTUnwrap(try MediaProbe.probe(path: output).video)
        XCTAssertEqual(video.displayWidth, 128); XCTAssertEqual(video.displayHeight, 64)
        XCTAssertEqual(video.frameRate ?? 0, 24, accuracy: 1e-9); XCTAssertEqual(video.frames, 48)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/.studio-render-tmp"))
        XCTAssertTrue(try String(contentsOfFile: "\(root)/session.meta.json", encoding: .utf8).hasPrefix(#"{"status":"complete","durationMs":"#))
    }

    func testStartExportCancelsAndLeavesNothingBehind() throws {
        var doc = try project()
        doc.canvas = .init(width: 1920, height: 1080, background: "#000000")
        doc.sequence.tracks = []
        doc.sequence.durationFrames = 100_000
        let output = "\(root)/session-cancel.mov"
        let gate = DispatchSemaphore(value: 0)
        let job = try startExport(project: doc, projectDir: root, outputPath: output, settings: ExportSettings(format: .mov, quality: .draft),
                                  progress: { p in if p.percent > 0 { gate.signal() } })
        _ = gate.wait(timeout: .now() + 30)
        job.cancel()
        XCTAssertEqual(job.wait(timeout: 30), .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/session-cancel.meta.json"))
        XCTAssertEqual(try leftovers(root), [])
    }

    func testPlanAndStartRejectBadSettingsBeforeRendering() throws {
        let doc = try project()
        XCTAssertFalse(planExport(doc, settings: .init(resolution: .custom, customDimensions: .init(width: 101, height: 64))).canStart)
        XCTAssertFalse(planExport(doc, settings: .init(range: .init(startFrame: 0, endFrame: 999))).canStart)
        XCTAssertFalse(planExport(doc, settings: .init(format: .mov)).qualityApplies)
        XCTAssertEqual(planExport(doc, settings: .init(format: .webm)).issues, [WEBM_EXPORT_UNSUPPORTED_MESSAGE])
        // Legacy 1080p follows the canvas aspect (2:1 canvas -> landscape Full HD).
        XCTAssertEqual(planExport(doc, settings: .init(resolution: .scale(.p1080))).outputDimensions, .init(width: 1920, height: 1080))
        XCTAssertEqual(planExport(doc, settings: .init(resolution: .preset(.verticalHd))).outputDimensions, .init(width: 720, height: 1280))
        XCTAssertThrowsError(try startExport(project: doc, projectDir: root, outputPath: "\(root)/wrong.mov", settings: .init(format: .mp4))) {
            XCTAssertTrue("\($0)".contains(".mp4"), "\($0)")
        }
    }

    func testStartRefusesWithoutAFrameRenderer() throws {
        NativeExportFrames.defaultRenderer = nil
        defer { installAppExportFrames() }
        XCTAssertThrowsError(try startExport(project: try project(), projectDir: root, outputPath: "\(root)/no-renderer.mov",
                                             settings: .init(format: .mov))) {
            XCTAssertEqual(($0 as? ExportStartError)?.issues, [EXPORT_NO_FRAME_RENDERER_MESSAGE])
        }
    }
}
