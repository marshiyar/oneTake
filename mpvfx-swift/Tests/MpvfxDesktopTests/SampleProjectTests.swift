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
#if os(Linux)
import Foundation
import XCTest
import MpvfxBackend
import MpvfxDesktopCore
import MpvfxPanels
import MpvfxPlayer
import MpvfxRuntime
import MpvfxShared
import MpvfxTimeline
import OneTakeMedia
@testable import MpvfxDesktop

/// The sample project of docs/GETTING_STARTED.md (`samples/getting-started`) opens the way `MPVFX_PROJECT` opens it,
/// every file it uses imports, and the Renders tab exports it. Opening and exporting run on a copy, so the checkout
/// is never written.
///
/// `MPVFX_RECORD_SAMPLE_PROJECT=1 swift test --filter SampleProjectTests` makes the sample again: its pictures and
/// sound are drawn by the code below (the media engine's own H.264 and JPEG encoders), imported into a new project
/// through the backend, placed and graded through the editor, saved, and copied over the checked-in sample.
final class SampleProjectTests: XCTestCase {
    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples/getting-started").path
    static let width = 640, height = 360, fps = 30

    var dirs: [String] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(atPath: d) }; super.tearDown() }

    func temporaryDirectory() throws -> String {
        let d = NSTemporaryDirectory() + "mpvfx-sample-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    /// A copy of the sample, opened by a backend on fresh user data through the session the shells create.
    func openCopy() throws -> (root: String, backend: RuntimeDesktopBackend, session: EditorSession) {
        let root = try temporaryDirectory()
        let project = root + "/getting-started"
        try FileManager.default.copyItem(atPath: Self.sample, toPath: project)
        let backend = RuntimeDesktopBackend(userData: root + "/userData")
        let session = try EditorSession(backend: backend, projectPath: project)
        _ = session.installShell(userData: root + "/userData") {}
        return (root, backend, session)
    }

    func testTheSampleOpensWithEveryFileItUses() throws {
        let (_, _, session) = try openCopy()
        let doc = session.editor.document
        XCTAssertNotNil(session.project, "opened as a saved project, not the demo")
        XCTAssertEqual([doc.canvas.width, doc.canvas.height], [Double(Self.width), Double(Self.height)])
        XCTAssertEqual(session.editor.duration, 9, accuracy: 1e-9)
        XCTAssertEqual(doc.assets.map(\.kind), [.video, .video, .image, .audio])
        for asset in doc.assets {
            let source = try XCTUnwrap(asset.source, asset.name)
            XCTAssertFalse(source.hasPrefix("/"), "\(source) is inside the project")
            let kind = try XCTUnwrap(ImportFormats.kind(of: source), source)
            XCTAssertNoThrow(try ImportFormats.validate(session.absoluteMediaPath(source), name: asset.name, as: kind), source)
        }
        let clips = doc.sequence.tracks.flatMap(\.clips)
        XCTAssertEqual(clips.count, 4)
        let graded = clips.filter { session.editor.colorGrading(clipId: $0.id) != nil }
        XCTAssertEqual(graded.map { session.editor.colorGrading(clipId: $0.id)?.preset }, ["warm-daylight"], "the first clip only")
        let settings = ExportSettings(format: .mp4, quality: .standard, fps: .fps30, resolution: .scale(.auto), customDimensions: nil)
        let plan = planExport(doc, settings: settings)
        XCTAssertEqual(plan.issues, [])
        XCTAssertEqual(plan.notices, [], "every layer is drawn")
        XCTAssertFalse(session.isDirty, "opening changes nothing")
    }

    /// One second across the cut from the graded dawn clip to the tide clip (frames 105..<135), so the run stays short
    /// in a debug build; the whole sequence goes through the same RenderRun.
    func testTheRendersTabExportsTheSample() throws {
        NativeExportFrames.defaultRenderer = PreviewExportFrames.factory   // as main.swift installs it
        let (_, backend, session) = try openCopy()
        let project = try XCTUnwrap(session.project)
        let settings = ExportSettings(format: .mp4, quality: .standard, fps: .fps30, resolution: .scale(.auto), customDimensions: nil,
                                      range: ExportFrameRange(startFrame: 105, endFrame: 135))
        let done = expectation(description: "export finished")
        let outcome = Locked<ExportOutcome?>(nil)
        _ = try RenderRun.start(backend: backend, RenderRequest(projectId: project.id, document: session.editor.document, settings: settings,
                                settingsJSON: .object(["format": .string("mp4"), "quality": .string("standard")])),
                                RenderCallbacks { o, _ in outcome.set(o); done.fulfill() })
        wait(for: [done], timeout: 180)
        guard case .completed(let path, _, _)? = outcome.value else { return XCTFail("export did not complete: \(String(describing: outcome.value))") }
        let probe = try MediaProbe.probe(path: path)
        XCTAssertEqual(probe.duration ?? 0, 1, accuracy: 0.05)
        XCTAssertEqual(probe.video?.codec, "h264"); XCTAssertEqual(probe.audio?.codec, "flac")
        XCTAssertEqual(probe.video?.displayWidth, Self.width); XCTAssertEqual(probe.video?.displayHeight, Self.height)
        let reader = try AudioSampleReader(path: path, sampleRate: 48_000, channels: 1)
        XCTAssertTrue(try reader.read(frames: 48_000).contains { abs($0) > 0.02 }, "the music is in the export")

        // Top-left corner: the violet dawn sky before the cut, the much bluer tide after it.
        let frames = try VideoFrameReader(path: path)
        func corner(_ t: Double) throws -> [Int] { try frames.frame(at: t, width: Self.width, height: Self.height).rgba.prefix(3).map { Int($0) } }
        let dawn = try corner(0.2), tide = try corner(0.8)
        XCTAssertGreaterThan(tide[2] - tide[0], 60, "tide \(tide)")
        XCTAssertLessThan(dawn[2] - dawn[0], tide[2] - tide[0] - 40, "dawn \(dawn), tide \(tide)")
        backend.closeProject(id: project.id)
    }

    // MARK: Making the sample (MPVFX_RECORD_SAMPLE_PROJECT=1)

    func testRecordTheSample() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MPVFX_RECORD_SAMPLE_PROJECT"] == "1",
                          "set MPVFX_RECORD_SAMPLE_PROJECT=1 to make samples/getting-started again")
        let root = try temporaryDirectory()
        let drawn = root + "/drawn"
        try FileManager.default.createDirectory(atPath: drawn, withIntermediateDirectories: true)
        try Draw.video(drawn + "/dawn.mp4", seconds: 4, Draw.dawn)
        try Draw.video(drawn + "/tide.mp4", seconds: 3, Draw.tide)
        try Draw.card(drawn + "/card.jpg")
        try Draw.music(drawn + "/music.wav", seconds: 9)

        let userData = root + "/userData", projectDir = root + "/getting-started"
        let backend = RuntimeDesktopBackend(userData: userData)
        _ = try backend.createProject(name: "Getting started", directory: projectDir)
        let session = try EditorSession(backend: backend, projectPath: projectDir)
        _ = session.installShell(userData: userData) {}
        let project = try XCTUnwrap(session.project)
        let files = ["dawn.mp4", "tide.mp4", "card.jpg", "music.wav"]
        let paths = files.map { drawn + "/" + $0 }, projectId = project.id
        let done = expectation(description: "imported")
        let result = Locked<Result<DesktopMediaImport, Error>?>(nil)
        Task {
            do { result.set(.success(try await backend.importMedia(projectId: projectId, paths: paths, directory: nil))) }
            catch { result.set(.failure(error)) }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        let imported = try XCTUnwrap(result.value).get()
        XCTAssertEqual(imported.invalid, []); XCTAssertEqual(imported.notices, [])
        do {
            session.addImportedAssets(imported.media)
            let editor = session.editor
            XCTAssertTrue(editor.setCanvasSize(width: Double(Self.width), height: Double(Self.height)))
            func asset(_ file: String) -> String { editor.document.assets.first { $0.source == file }!.id }
            let dawn = editor.insertClip(assetId: asset("dawn.mp4"), at: 0)
            XCTAssertNotNil(editor.insertClip(assetId: asset("tide.mp4"), at: 4))
            XCTAssertNotNil(editor.insertClip(assetId: asset("card.jpg"), at: 7, durationFrames: 2 * Double(Self.fps)))
            XCTAssertNotNil(editor.insertClip(assetId: asset("music.wav"), at: 0))
            let warm = ColorGrading().applying(ColorGrading.preset("warm-daylight")!)
            XCTAssertTrue(editor.setColorGrading(clipId: dawn!, warm))
        }
        try session.save()
        backend.closeProject(id: project.id)

        let fm = FileManager.default
        if fm.fileExists(atPath: Self.sample) { try fm.removeItem(atPath: Self.sample) }
        try fm.createDirectory(atPath: Self.sample + "/.studio", withIntermediateDirectories: true)
        try fm.copyItem(atPath: projectDir + "/.studio/project.json", toPath: Self.sample + "/.studio/project.json")
        for file in files { try fm.copyItem(atPath: projectDir + "/" + file, toPath: Self.sample + "/" + file) }
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    func set(_ v: T) { lock.lock(); stored = v; lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
}

/// The sample's media, drawn here: two short 640x360 30 fps clips, an end card and a chord.
private enum Draw {
    static let w = SampleProjectTests.width, h = SampleProjectTests.height

    /// `seconds` of frames from `frame` (frame index, x, y -> RGB), H.264 in MP4 without sound.
    static func video(_ path: String, seconds: Int, _ frame: (Int, Int, Int) -> (Double, Double, Double)) throws {
        var config = MediaWriter.Config(container: .mp4, width: w, height: h)
        config.fpsNumerator = SampleProjectTests.fps
        config.audioRate = 0
        let writer = try MediaWriter(path: path, config: config)
        for n in 0..<(seconds * SampleProjectTests.fps) {
            var px = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let (r, g, b) = frame(n, x, y), i = (y * w + x) * 4
                    px[i] = byte(r); px[i + 1] = byte(g); px[i + 2] = byte(b)
                }
            }
            try writer.addVideo(px)
        }
        try writer.finish()
    }

    static func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    /// A sky going from violet to orange with a sun rising out of a dark sea.
    static func dawn(_ n: Int, _ x: Int, _ y: Int) -> (Double, Double, Double) {
        let t = Double(n) / 120, v = Double(y) / Double(h)
        let horizon = 0.68
        if v > horizon {
            let d = (v - horizon) / (1 - horizon)
            return (30 + 20 * t - 20 * d, 34 + 10 * t - 20 * d, 64 - 20 * d)
        }
        let sx = Double(w) * 0.5, sy = Double(h) * (horizon + 0.08 - 0.3 * t), r = 46.0
        let dist = ((Double(x) - sx) * (Double(x) - sx) + (Double(y) - sy) * (Double(y) - sy)).squareRoot()
        if dist < r { return (255, 226, 150) }
        let glow = max(0, 1 - (dist - r) / 160) * 0.5
        let up = v / horizon
        return (90 + 150 * up + 60 * glow, 60 + 70 * up * up + 50 * glow, 140 - 70 * up + 10 * glow)
    }

    /// Blue bands rolling across the frame.
    static func tide(_ n: Int, _ x: Int, _ y: Int) -> (Double, Double, Double) {
        let a = Double(x) / 37 + sin(Double(y) / 29 + Double(n) / 9) * 1.6 - Double(n) / 7
        let s = 0.5 + 0.5 * sin(a)
        return (20 + 40 * s, 80 + 90 * s, 140 + 100 * s)
    }

    /// The end card: a dark frame with a light ring in the middle, JPEG.
    static func card(_ path: String) throws {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let d = ((Double(x) - Double(w) / 2) * (Double(x) - Double(w) / 2) + (Double(y) - Double(h) / 2) * (Double(y) - Double(h) / 2)).squareRoot()
                let ring = max(0, 1 - abs(d - 80) / 10)
                let i = (y * w + x) * 4
                px[i] = byte(24 + 210 * ring); px[i + 1] = byte(24 + 200 * ring); px[i + 2] = byte(28 + 180 * ring)
            }
        }
        try ImageCodec.encodeJPEG(rgba: px, width: w, height: h, quality: 85).write(to: URL(fileURLWithPath: path))
    }

    /// An A minor chord that swells in and fades out, 16-bit mono WAV at 16 kHz.
    static func music(_ path: String, seconds: Int) throws {
        let rate = 16_000, n = seconds * rate
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(n * 2)
        for k in 0..<n {
            let t = Double(k) / Double(rate)
            let envelope = min(1, t / 1.5) * min(1, (Double(seconds) - t) / 2)
            let chord = [220.0, 261.63, 329.63].map { sin(2 * Double.pi * $0 * t) }.reduce(0, +) / 3
            var x = Int16(9000 * envelope * chord).littleEndian
            d.append(Data(bytes: &x, count: 2))
        }
        try d.write(to: URL(fileURLWithPath: path))
    }
}
#endif
