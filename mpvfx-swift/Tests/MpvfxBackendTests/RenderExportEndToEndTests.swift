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
// The Renders tab's Export, end to end, the way the app runs it: the backend the app builds, the frame renderer
// main.swift installs (the preview's painter), RenderRun started exactly as SessionPanels.startRender starts it, on a
// project with a graded video, a half-transparent moved image on the row above it and an audio-only track. The
// finished MP4 is read back with the media engine (MediaProbe, VideoFrameReader, AudioSampleReader); the inputs are
// written with our own code (MediaWriter MOV, BMP and WAV bytes).
import Foundation
import XCTest
import MpvfxBackend
import MpvfxDesktopCore
import OneTakeMedia
import MpvfxPlayer
import MpvfxRuntime
import MpvfxShared

private enum Inputs {
    static func video(_ path: String) throws {
        var config = MediaWriter.Config(container: .mov, width: 96, height: 48)
        config.fpsNumerator = 10
        let writer = try MediaWriter(path: path, config: config)
        let gray = [UInt8](repeating: 128, count: 96 * 48 * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }
        for i in 0..<20 {
            try writer.addVideo(gray)
            try writer.addAudio((i * 4800..<(i + 1) * 4800).flatMap { k -> [Float] in
                let v = Float(0.125 * sin(2 * Double.pi * 440 * Double(k) / 48_000)); return [v, v] })
        }
        try writer.finish()
    }
    static func bmp(_ path: String) throws {
        var d = Data("BM".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(54 + 96 * 16); u32(0); u32(54); u32(40); u32(32); u32(16); u16(1); u16(24); u32(0); u32(96 * 16); u32(2835); u32(2835); u32(0); u32(0)
        for _ in 0..<(32 * 16) { d.append(contentsOf: [255, 0, 0]) }   // BGR: blue
        try d.write(to: URL(fileURLWithPath: path))
    }
    static func wav(_ path: String) throws {
        let n = 96_000
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(n * 2)
        for k in 0..<n { var x = Int16(4096 * sin(2 * Double.pi * 660 * Double(k) / 48_000)).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        try d.write(to: URL(fileURLWithPath: path))
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    func update(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
}

final class RenderExportEndToEndTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "mpvfx-render-e2e-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    /// 96x48 at 10 fps, 2 s: mid-gray video with a 440 Hz tone (graded, bottom row), a blue 32x16 still moved to the
    /// top-right corner at half opacity (top row, so it draws over the video) and a 660 Hz audio-only clip.
    private func document() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"e2e","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":96,"height":48,"background":"#000000"},
         "assets":[{"id":"gray","kind":"video","name":"gray","source":"gray.mov","durationFrames":20},
                   {"id":"blue","kind":"image","name":"blue","source":"blue.bmp","durationFrames":1},
                   {"id":"tone","kind":"audio","name":"tone","source":"tone.wav","durationFrames":20}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[
           {"id":"overlay","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
             {"id":"blue","assetId":"blue","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":true,
              "staticParameters":{"layout.width":32,"layout.height":16,"transform.position":{"x":64,"y":0},"visual.opacity":0.5},
              "effects":[],"parameterTracks":[]}]},
           {"id":"base","kind":"video","lane":{"authoredTrack":0,"displayTrack":1},"clips":[
             {"id":"gray","assetId":"gray","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":false,
              "effects":[{"id":"grade","effectId":"color-grading","enabled":true,"parameters":{"adjust":{"exposure":0.6}}}],
              "parameterTracks":[]}]},
           {"id":"music","kind":"audio","lane":{"authoredTrack":2,"displayTrack":2},"clips":[
             {"id":"tone","assetId":"tone","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    private func makeMedia(in dir: String) throws {
        try Inputs.video(dir + "/gray.mov")
        try Inputs.bmp(dir + "/blue.bmp")
        try Inputs.wav(dir + "/tone.wav")
    }

    /// RGB pixel (x, y) of the 96x48 frame at `seconds`.
    private func pixel(_ path: String, _ seconds: Double, _ x: Int, _ y: Int) throws -> [Int] {
        let reader = try VideoFrameReader(path: path)
        XCTAssertEqual([reader.info.width, reader.info.height], [96, 48], "decoded frame size")
        let rgba = try reader.frame(at: seconds, width: 96, height: 48, fit: .stretch).rgba
        let i = (y * 96 + x) * 4
        return [Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2])]
    }

    func testRendersTabExportWritesAGradedLayeredFileWithSound() throws {
        NativeExportFrames.defaultRenderer = PreviewExportFrames.factory   // as main.swift installs it
        let backend = RuntimeDesktopBackend(userData: root + "/userData", durableWrite: NativeDurableWrite())
        let project = try backend.createProject(name: "Export E2E", directory: nil)
        try makeMedia(in: project.directory)
        let doc = try document()
        try backend.saveProject(id: project.id, content: try serializeNativeProjectDocument(doc))

        let settings = ExportSettings(format: .mp4, quality: .standard, fps: .fps30, resolution: .scale(.auto), customDimensions: nil)
        let done = expectation(description: "export finished")
        let outcome = Box<ExportOutcome?>(nil), percents = Box<[Double]>([]), started = Box(false)
        // As SessionPanels.startRender.
        var callbacks = RenderCallbacks { o, _ in outcome.update { $0 = o }; done.fulfill() }
        callbacks.started = { _ in started.update { $0 = true } }
        callbacks.progress = { p in percents.update { $0.append(p.percent) } }
        let run = try RenderRun.start(backend: backend, RenderRequest(projectId: project.id, document: doc, settings: settings,
                                      settingsJSON: .object(["format": .string("mp4"), "quality": .string("standard")])), callbacks)
        wait(for: [done], timeout: 180)
        guard case .completed(let path, let size, _)? = outcome.value else { return XCTFail("export did not complete: \(String(describing: outcome.value))") }
        XCTAssertTrue(started.value, "the Renders row is told the export is running")
        XCTAssertEqual(percents.value.last, 100, "progress reaches 100%")
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.outputPath))
        XCTAssertGreaterThan(size, 0)

        // Duration = the 2 s timeline, an H.264 video stream at the canvas size and a FLAC audio stream.
        let probe = try MediaProbe.probe(path: path)
        XCTAssertEqual(probe.duration ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(probe.video?.codec, "h264"); XCTAssertEqual(probe.audio?.codec, "flac")
        XCTAssertEqual(probe.video?.displayWidth, 96); XCTAssertEqual(probe.video?.displayHeight, 48)
        // The mixed sound is there (video tone + audio-only clip).
        let reader = try AudioSampleReader(path: path, sampleRate: 48_000, channels: 1)
        try reader.seek(to: 1)
        XCTAssertTrue(try reader.read(frames: 9600).contains { abs($0) > 0.03 }, "the export has audible sound")

        // The grade: +0.6 exposure lifts the mid-gray video well above its source 128, still neutral.
        let graded = try pixel(path, 1.0, 20, 36)
        XCTAssertGreaterThan(graded[0], 150, "graded \(graded)"); XCTAssertGreaterThan(graded[1], 150, "graded \(graded)")
        XCTAssertLessThan(abs(graded[0] - graded[2]), 12, "the grade keeps gray neutral: \(graded)")
        // Transform + opacity: the half-transparent blue still covers the top-right 32x16 corner only.
        let overlay = try pixel(path, 1.0, 80, 8)
        XCTAssertGreaterThan(overlay[2] - overlay[0], 60, "blue over the video at half opacity: \(overlay)")
        XCTAssertGreaterThan(overlay[0], 50, "the video shows through the half-opacity still: \(overlay)")
        XCTAssertLessThan(overlay[0], graded[0] - 30, "\(overlay) vs \(graded)")
        let beside = try pixel(path, 1.0, 40, 8)
        XCTAssertLessThan(abs(beside[0] - beside[2]), 12, "no blue outside the moved still: \(beside)")

        let history = try backend.renders(projectId: project.id)
        XCTAssertEqual(history.first?.status, "complete")
        backend.closeProject(id: project.id)
    }

    /// Without the app's frame renderer the Renders tab gets a clear reason before anything starts (its error banner).
    func testExportWithoutAFrameRendererFailsWithAReasonUpFront() throws {
        let installed = NativeExportFrames.defaultRenderer
        NativeExportFrames.defaultRenderer = nil
        defer { NativeExportFrames.defaultRenderer = installed }
        let backend = RuntimeDesktopBackend(userData: root + "/userData", durableWrite: NativeDurableWrite())
        let project = try backend.createProject(name: "No renderer", directory: nil)
        let settings = ExportSettings(format: .mp4, quality: .draft, fps: .fps30, resolution: .scale(.auto), customDimensions: nil)
        XCTAssertThrowsError(try RenderRun.start(backend: backend, RenderRequest(projectId: project.id, document: try document(), settings: settings,
                                                 settingsJSON: .object([:])), RenderCallbacks { _, _ in })) { error in
            XCTAssertEqual((error as? DesktopError)?.message, "Can't export: \(EXPORT_NO_FRAME_RENDERER_MESSAGE)")
        }
        backend.closeProject(id: project.id)
    }

    /// WebM is not an export the engine writes yet: refused before anything starts, with the formats.md message.
    func testWebmExportIsRefusedUpFront() throws {
        NativeExportFrames.defaultRenderer = PreviewExportFrames.factory
        let backend = RuntimeDesktopBackend(userData: root + "/userData", durableWrite: NativeDurableWrite())
        let project = try backend.createProject(name: "WebM", directory: nil)
        let settings = ExportSettings(format: .webm, quality: .draft, fps: .fps30, resolution: .scale(.auto), customDimensions: nil)
        XCTAssertThrowsError(try RenderRun.start(backend: backend, RenderRequest(projectId: project.id, document: try document(), settings: settings,
                                                 settingsJSON: .object([:])), RenderCallbacks { _, _ in })) { error in
            XCTAssertEqual((error as? DesktopError)?.message, WEBM_EXPORT_UNSUPPORTED_MESSAGE)
        }
        backend.closeProject(id: project.id)
    }
}
