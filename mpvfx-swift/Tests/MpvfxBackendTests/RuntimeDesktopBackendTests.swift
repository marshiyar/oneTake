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
import Foundation
import XCTest
import MpvfxBackend
import MpvfxDesktopCore
import OneTakeMedia
import MpvfxPlayer
@testable import MpvfxRuntime
import MpvfxShared

/// Test media written by our own code: PNG and WAV bytes, and MOVs (PNG frames + PCM) from the engine's MediaWriter.
private enum Media {
    static func solid(_ rgb: (UInt8, UInt8, UInt8), _ width: Int, _ height: Int) -> [UInt8] {
        [UInt8]((0..<(width * height)).flatMap { _ in [rgb.0, rgb.1, rgb.2, 255] })
    }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func le(_ v: UInt32, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    /// A 2×2 red PNG (colour type 6), image data in one stored deflate block (PNG 3rd ed., RFC 1950/1951).
    static func png() -> Data {
        let raw: [UInt8] = (0..<2).flatMap { _ in [0] + solid((255, 0, 0), 2, 1) }
        var a: UInt32 = 1, b: UInt32 = 0
        for x in raw { a = (a + UInt32(x)) % 65_521; b = (b + a) % 65_521 }
        let n = raw.count
        let z: [UInt8] = [0x78, 0x01, 1, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)] + raw + be32(b << 16 | a)
        func crc(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for x in bytes { c ^= UInt32(x); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 } }
            return c ^ 0xFFFF_FFFF
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { let t = Array(type.utf8) + body; return be32(UInt32(body.count)) + t + be32(crc(t)) }
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", be32(2) + be32(2) + [8, 6, 0, 0, 0])
            + chunk("IDAT", z) + chunk("IEND", []))
    }
    /// `seconds` of a 440 Hz tone at 48 kHz, silent where `silent` says.
    static func tone(_ seconds: Double, silent: (Double) -> Bool = { _ in false }) -> [Float] {
        (0..<Int(seconds * 48_000)).map { i in
            let t = Double(i) / 48_000
            return silent(t) ? 0 : 0.5 * Float(sin(2 * .pi * 440 * t))
        }
    }
    /// 16-bit mono PCM WAV at 48 kHz.
    static func wav(_ samples: [Float]) -> Data {
        let pcm = samples.flatMap { le(UInt32(UInt16(bitPattern: Int16(($0 * 32_767).rounded()))), 2) }
        let body: [UInt8] = Array("WAVEfmt ".utf8) + le(16, 4) + le(1, 2) + le(1, 2) + le(48_000, 4) + le(96_000, 4) + le(2, 2) + le(16, 2)
            + Array("data".utf8) + le(UInt32(pcm.count), 4) + pcm
        return Data(Array("RIFF".utf8) + le(UInt32(body.count), 4) + body)
    }
    /// `seconds` of one colour at 10 fps, 64×32, with stereo PCM of `audio` (mono, copied to both channels) when given.
    static func mov(_ path: String, _ rgb: (UInt8, UInt8, UInt8), seconds: Int, audio: [Float]? = nil) throws {
        var config = MediaWriter.Config(container: .mov, width: 64, height: 32)
        config.fpsNumerator = 10
        config.audioRate = audio == nil ? 0 : 48_000
        let writer = try MediaWriter(path: path, config: config)
        for _ in 0..<(seconds * 10) { try writer.addVideo(solid(rgb, 64, 32)) }
        if let audio { try writer.addAudio(audio.flatMap { [$0, $0] }) }
        try writer.finish()
    }
}

/// realpath(3); `URL.resolvingSymlinksInPath()` maps macOS `/private/var` back to `/var`.
private func realPath(_ path: String) -> String {
#if os(Windows)
    return (try? ProjectFS.realpath(path)) ?? path
#else
    guard let r = realpath(path, nil) else { return path }
    defer { free(r) }
    return String(cString: r)
#endif
}

final class RuntimeDesktopBackendTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        // The root is reached through a symlink, as macOS's /var is /private/var, so path comparisons that
        // skip realpath(3) fail on Linux too.
        let id = UUID().uuidString
        let real = NSTemporaryDirectory() + "mpvfx-real-" + id
        try FileManager.default.createDirectory(atPath: real + "/media", withIntermediateDirectories: true)
        root = NSTemporaryDirectory() + "mpvfx-backend-" + id
        try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: real)
#if os(Windows)
        root = root.replacingOccurrences(of: "\\", with: "/")   // the backend reports paths in "/" form
#endif
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: realPath(root))
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func backend() -> RuntimeDesktopBackend {
        RuntimeDesktopBackend(userData: root + "/userData", durableWrite: NativeDurableWrite())
    }
    private func withDuration(_ content: String, _ frames: Double) throws -> String {
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(content))
        doc.sequence.durationFrames = frames
        return try serializeNativeProjectDocument(doc)
    }

    func testCreateOpenSaveRoundTripAcrossLaunches() async throws {
        let b = backend()
        let created = try b.createProject(name: "Trip / Edit", directory: nil)
        XCTAssertEqual(created.directory, realPath(b.projectsDir + "/Trip - Edit"))
        XCTAssertEqual(try b.openProject(path: created.directory), created)   // already open: same id
        let saved = try withDuration(created.content, 240)
        try b.saveProject(id: created.id, content: saved)
        try await b.close()
        XCTAssertThrowsError(try b.saveProject(id: created.id, content: saved))

        let relaunched = backend()
        let reopened = try relaunched.openProject(path: created.directory + "/.studio/project.json")
        XCTAssertEqual(reopened.content, saved)
        XCTAssertEqual(reopened.id, created.id)
        // A second project with the same name gets its own folder.
        let second = try relaunched.createProject(name: "Trip / Edit", directory: nil)
        XCTAssertTrue(second.directory.hasSuffix("Trip - Edit 2"))
        XCTAssertNotEqual(second.id, reopened.id)
        try await relaunched.close()
    }

    func testSaveConflictIsReportedAndTheFileKept() throws {
        let b = backend()
        let p = try b.createProject(name: "P", directory: root + "/elsewhere/P")
        let external = try withDuration(p.content, 10)
        try external.write(toFile: p.directory + "/.studio/project.json", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try b.saveProject(id: p.id, content: try withDuration(p.content, 20))) {
            XCTAssertEqual(($0 as? DesktopError)?.name, "ConflictError")
        }
        XCTAssertEqual(try String(contentsOfFile: p.directory + "/.studio/project.json", encoding: .utf8), external)
        XCTAssertEqual(try b.reloadProject(id: p.id).content, external)
    }

    func testDefaultProjectIsCreatedOnceAndReopened() throws {
        let b = backend()
        let first = try b.openDefaultProject()
        XCTAssertEqual(first.id, STANDALONE_PROJECT_ID)
        XCTAssertEqual(try b.openDefaultProject(), first)
        XCTAssertEqual(try backend().openDefaultProject().content, first.content)
        XCTAssertThrowsError(try b.openProject(path: root + "/media"))
    }

    func testImportCopiesMediaIntoTheProjectWithStreamFacts() async throws {
        try Media.mov(root + "/media/clip.mov", (255, 0, 0), seconds: 2)
        try Media.wav(Media.tone(1)).write(to: URL(fileURLWithPath: root + "/media/tone.wav"))
        try Media.png().write(to: URL(fileURLWithPath: root + "/media/logo.png"))
        try "x".write(toFile: root + "/media/notes.txt", atomically: false, encoding: .utf8)
        try "not a gif".write(toFile: root + "/media/anim.gif", atomically: false, encoding: .utf8)
        let b = backend()
        let p = try b.createProject(name: "Import", directory: nil)
        let names = ["clip.mov", "tone.wav", "logo.png", "notes.txt", "anim.gif"]
        let r = try await b.importMedia(projectId: p.id, paths: names.map { root + "/media/" + $0 }, directory: nil)
        XCTAssertEqual(r.media.map(\.path), ["clip.mov", "tone.wav", "logo.png"])
        XCTAssertEqual(r.media.map(\.kind), ["video", "audio", "image"])
        XCTAssertEqual(r.media[0].duration, 2, accuracy: 0.05)
        XCTAssertEqual(r.media[0].width, 64); XCTAssertEqual(r.media[0].height, 32)
        XCTAssertEqual(r.media[1].duration, 1, accuracy: 0.05)
        XCTAssertEqual(r.media[2].width, 2)
        XCTAssertEqual(r.invalid.map(\.name), ["notes.txt", "anim.gif"])
        // GIF imports (formats.md v1); a file named .gif that is not one is refused by the probe.
        XCTAssertEqual(r.invalid.last?.reason, "This file format is not supported yet: .gif.")
        XCTAssertEqual(r.notices, [])
        XCTAssertEqual(r.media.filter { !FileManager.default.fileExists(atPath: p.directory + "/" + $0.path) }.map(\.path), [])
        // Importing the same file again never overwrites the first copy.
        let again = try await b.importMedia(projectId: p.id, paths: [root + "/media/logo.png"], directory: nil)
        XCTAssertEqual(again.media.map(\.path), ["logo (2).png"])
        try await b.close()
    }

    func testImportFilesReturnsTheRuntimeShape() async throws {
        try Media.png().write(to: URL(fileURLWithPath: root + "/media/a.png"))
        let b = backend()
        let p = try b.createProject(name: "Shape", directory: nil)
        let json = try await b.importFiles(projectId: p.id, paths: [root + "/media/a.png", root + "/media/missing.png"], directory: "assets")
        XCTAssertEqual(json["files"], .array([.string("assets/a.png")]))
        XCTAssertEqual(json["invalid"]?.array?.first?["name"], .string("missing.png"))
        do { _ = try await b.importFiles(projectId: "nope", paths: [], directory: nil); XCTFail("expected an error") }
        catch { XCTAssertEqual((error as? DesktopError)?.message, "Project not found") }
    }

    func testLibraryProjectImportsThroughTheLibrary() async throws {
        try Media.png().write(to: URL(fileURLWithPath: root + "/media/a.png"))
        let b = backend()
        let libraries = try XCTUnwrap(b.libraries)
        let libraryId = try await libraries.create(root: root + "/Lib.mpvfxlibrary")
        let views = try await libraries.views()
        let library = try XCTUnwrap(views.array?.first { $0["id"]?.string == libraryId })
        let eventId = try XCTUnwrap(library["events"]?.array?.first?["id"]?.string)
        let projectId = try await libraries.createProject(libraryId: libraryId, eventId: eventId, name: "Cut")
        let p = try b.openProject(path: try libraries.root(libraryId: libraryId) + "/Projects/" + projectId)
        XCTAssertEqual(p.id, projectId)
        let r = try await b.importMedia(projectId: p.id, paths: [root + "/media/a.png"], directory: nil)
        XCTAssertEqual(r.invalid, [])
        let path = try XCTUnwrap(r.media.first?.path)
        XCTAssertTrue(path.hasPrefix("assets/") && path.hasSuffix("/a.png"), path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.directory + "/" + path))
        let after = try await libraries.views()
        XCTAssertEqual(after.array?.first?["assets"]?.array?.count, 1)
        try await b.close()
    }

    func testProjectsAndRecentsListAcrossLaunches() async throws {
        let b = backend()
        let a = try b.createProject(name: "Alpha", directory: nil)
        let elsewhere = try b.createProject(name: "Beta", directory: root + "/outside/Beta")
        XCTAssertEqual(Set(b.listProjects().map(\.directory)), [a.directory])   // only the projects folder (no library open)
        XCTAssertEqual(b.recentProjects().map(\.directory), [elsewhere.directory, a.directory])
        b.closeProject(id: elsewhere.id)
        XCTAssertThrowsError(try b.saveProject(id: elsewhere.id, content: elsewhere.content))
        try await b.close()
        let again = backend()
        XCTAssertEqual(again.recentProjects().map(\.title), ["Beta", "Alpha"])
        try again.forgetRecentProject(directory: elsewhere.directory)
        XCTAssertEqual(again.recentProjects().map(\.title), ["Alpha"])
    }

    func testMediaPanelOperationsThroughTheBackend() async throws {
        // 2 s with sound muted from 0.5 s to 1.5 s.
        try Media.mov(root + "/media/talk.mov", (255, 0, 0), seconds: 2, audio: Media.tone(2) { $0 >= 0.5 && $0 < 1.5 })
        let b = backend()
        let p = try b.createProject(name: "Media", directory: nil)
        let imported = try await b.importMedia(projectId: p.id, paths: [root + "/media/talk.mov"], directory: nil)
        XCTAssertEqual(imported.media.map(\.path), ["talk.mov"])
        XCTAssertEqual(try b.listMedia(projectId: p.id, query: nil).map(\.path), ["talk.mov"])
        XCTAssertEqual(try b.listMedia(projectId: p.id, query: "nothing"), [])
        let streams = try await b.mediaStreams(projectId: p.id, source: "talk.mov")
        XCTAssertTrue(streams.hasVideo && streams.hasAudio)
        let peaks = try await b.waveform(projectId: p.id, source: "talk.mov", bars: 100)
        XCTAssertEqual(peaks.count, 100)
        XCTAssertLessThan(peaks[50], 0.01)    // the muted middle second
        let frames = try await b.videoFrames(projectId: p.id, request: DesktopVideoFramesRequest(source: "talk.mov", frameCount: 3, width: 64, height: 32))
        XCTAssertEqual(frames.jpegFrames.count, 3)
        XCTAssertEqual(Array(frames.jpegFrames[0].prefix(2)), [0xFF, 0xD8])   // JPEG
        let picture = try ImageCodec.decode(frames.jpegFrames[1])
        XCTAssertEqual(picture.width, 64); XCTAssertEqual(picture.height, 32)
        XCTAssertGreaterThan(picture.rgba[(16 * 64 + 32) * 4], 200, "the red clip")
        let pauses = try await b.silences(projectId: p.id, source: "talk.mov", sourceStart: 0, sourceDuration: 2)
        XCTAssertEqual(pauses.count, 1)
        // The muted second, kept a little inside its edges (as SilenceAnalysisTests: 1...2 s gives ~1.15...1.85 s).
        XCTAssertGreaterThan(pauses.first?.start ?? 0, 0.55); XCTAssertLessThan(pauses.first?.start ?? 1, 0.75)
        XCTAssertGreaterThan(pauses.first?.end ?? 0, 1.25); XCTAssertLessThan(pauses.first?.end ?? 2, 1.45)
        let renamed = try b.renameMedia(projectId: p.id, from: "talk.mov", to: "clips/talk.mov", content: p.content)
        XCTAssertEqual(renamed.path, "clips/talk.mov")
        XCTAssertEqual(try b.listMedia(projectId: p.id, query: nil).map(\.path), ["clips/talk.mov"])
        let deleted = try b.deleteMedia(projectId: p.id, path: "clips/talk.mov", removeUsages: false, content: renamed.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.directory + "/" + deleted.path))
        XCTAssertEqual(try b.listMedia(projectId: p.id, query: nil), [])
        try await b.close()
    }

    func testWatchReportsAnEditMadeOutsideTheApp() throws {
        let b = backend()
        let p = try b.createProject(name: "Watched", directory: nil)
        let changed = expectation(description: "external change")
        try b.watchProject(id: p.id) { _ in changed.fulfill() }
        let external = try withDuration(p.content, 77)
        Thread.sleep(forTimeInterval: 0.1)
        try external.write(toFile: p.directory + "/.studio/project.json", atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 5)
        b.closeProject(id: p.id)
    }

    func testRenderHistoryListsRecordsAndDeletesExports() throws {
        let b = backend()
        let p = try b.createProject(name: "Renders", directory: nil)
        XCTAssertEqual(try b.rendersDirectory(projectId: p.id), root + "/userData/renders")
        XCTAssertEqual(try b.renders(projectId: p.id), [])
        let first = try b.renderOutputPath(projectId: p.id, jobId: "job-1", format: "mp4")
        XCTAssertEqual(first, root + "/userData/renders/job-1.mp4")
        try Data(repeating: 1, count: 10).write(to: URL(fileURLWithPath: first))
        try b.recordRender(projectId: p.id, jobId: "job-1", failed: false, durationMs: 1234.4)
        let second = try b.renderOutputPath(projectId: p.id, jobId: "job-2", format: "webm")
        try Data(repeating: 2, count: 20).write(to: URL(fileURLWithPath: second))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: second)
        let list = try b.renders(projectId: p.id)
        XCTAssertEqual(list.map(\.id), ["job-2", "job-1"])
        XCTAssertEqual(list.map(\.size), [20, 10])
        XCTAssertEqual(list[1].durationMs, 1234); XCTAssertEqual(list[1].status, "complete")
        XCTAssertThrowsError(try b.renderOutputPath(projectId: p.id, jobId: "../x", format: "mp4"))
        XCTAssertThrowsError(try b.renderOutputPath(projectId: p.id, jobId: "ok", format: "avi"))
        try b.deleteRender(projectId: p.id, id: "job-1")
        XCTAssertEqual(try b.renders(projectId: p.id).map(\.id), ["job-2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/userData/renders/job-1.meta.json"))
    }

    func testDuplicateMediaNamesCopiesLikeTheFileBrowser() throws {
        let b = backend()
        let p = try b.createProject(name: "Dup", directory: nil)
        try FileManager.default.createDirectory(atPath: p.directory + "/clips", withIntermediateDirectories: true)
        try "v".write(toFile: p.directory + "/clips/a.mp4", atomically: false, encoding: .utf8)
        XCTAssertEqual(try b.duplicateMedia(projectId: p.id, path: "clips/a.mp4"), "clips/a (copy).mp4")
        XCTAssertEqual(try b.duplicateMedia(projectId: p.id, path: "clips/a.mp4"), "clips/a (copy 2).mp4")
        XCTAssertEqual(try b.duplicateMedia(projectId: p.id, path: "clips/a (copy).mp4"), "clips/a (copy 3).mp4")
        XCTAssertEqual(try String(contentsOfFile: p.directory + "/clips/a (copy 3).mp4", encoding: .utf8), "v")
        XCTAssertThrowsError(try b.duplicateMedia(projectId: p.id, path: "clips/missing.mp4"))
        XCTAssertThrowsError(try b.duplicateMedia(projectId: p.id, path: ".studio/project.json"))
    }

    func testTypedLibraryViewsAndLibraryAssetMedia() async throws {
        try Media.mov(root + "/media/shot.mov", (0, 0, 255), seconds: 1, audio: Media.tone(1))
        let b = backend()
        let libraries = try XCTUnwrap(b.libraries)
        let libraryId = try await libraries.create(root: root + "/Lib.mpvfxlibrary")
        var views = try await b.libraryViews()
        var view = try XCTUnwrap(views.first { $0.id == libraryId })
        let eventId = try XCTUnwrap(view.events.first?.id)
        try await libraries.createEvent(libraryId: libraryId, name: "Shoot Day")
        let projectId = try await libraries.createProject(libraryId: libraryId, eventId: eventId, name: "Cut")
        let invalid = try await libraries.importMedia(libraryId: libraryId, eventId: eventId, paths: [root + "/media/shot.mov"], mode: "managed", projectId: nil)
        XCTAssertTrue(invalid.isEmpty)
        views = try await b.libraryViews()
        view = try XCTUnwrap(views.first { $0.id == libraryId })
        XCTAssertTrue(view.events.contains { $0.name == "Shoot Day" })
        XCTAssertEqual(view.events.count, 2)
        let project = try XCTUnwrap(view.projects.first { $0.id == projectId })
        XCTAssertTrue(project.ready)
        XCTAssertNotNil(try? b.openProject(path: project.directory))
        let asset = try XCTUnwrap(view.assets.first)
        XCTAssertEqual(asset.kind, "video"); XCTAssertEqual(asset.mode, "managed"); XCTAssertTrue(asset.available); XCTAssertEqual(asset.projectIds, [])
        let streams = try await b.libraryAssetStreams(libraryId: libraryId, assetId: asset.id)
        XCTAssertEqual(streams.duration, 1, accuracy: 0.1); XCTAssertTrue(streams.hasVideo)
        let frames = try await b.libraryAssetFrames(libraryId: libraryId, assetId: asset.id,
                                                   request: DesktopVideoFramesRequest(source: "", frameCount: 2, width: 64, height: 32))
        XCTAssertEqual(frames.jpegFrames.count, 2)
        let peaks = try await b.libraryAssetWaveform(libraryId: libraryId, assetId: asset.id, bars: 50)
        XCTAssertEqual(peaks.count, 50)
        _ = try await libraries.attach(libraryId: libraryId, projectId: projectId, assetId: asset.id)
        views = try await b.libraryViews()
        view = try XCTUnwrap(views.first { $0.id == libraryId })
        XCTAssertEqual(view.assets.first?.projectIds, [projectId])
        XCTAssertEqual(view.exports, [])
        // A library project's exports go to the library's renders folder.
        let opened = try b.openProject(path: project.directory)
        XCTAssertEqual(realPath(try b.rendersDirectory(projectId: opened.id)), realPath(view.path + "/renders/" + projectId))
        // Library exports render from a snapshot and land in the library's exports list.
        let source = try await b.beginExport(projectId: opened.id, settings: .object(["format": .string("mp4")]))
        let snapshotId = try XCTUnwrap(source.snapshotId)
        XCTAssertNotEqual(source.directory, opened.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.directory + "/.studio/project.json"))
        let output = try b.renderOutputPath(projectId: opened.id, jobId: snapshotId, format: "mp4")
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: output))
        b.trackExport(source) { DesktopExportStatus(status: "complete", outputPath: output) }
        await b.library.exportTrackingFinished()
        let finished = try await b.libraryViews()
        let exports = try XCTUnwrap(finished.first { $0.id == libraryId }).exports
        XCTAssertEqual(exports.map(\.status), ["complete"])
        XCTAssertEqual(exports.first?.projectId, projectId)
        XCTAssertEqual(realPath(exports.first?.output ?? ""), realPath(output))
        let standalone = try b.createProject(name: "Solo", directory: nil)
        let direct = try await b.beginExport(projectId: standalone.id, settings: .object([:]))
        XCTAssertEqual(direct, DesktopExportSource(directory: standalone.directory))
        try await b.close()
    }

    /// The Renders tab's pipeline: a real export lands in the renders folder and shows up in the render history.
    func testRenderRunExportsAFileThatAppearsInTheRenderHistory() throws {
        NativeExportFrames.defaultRenderer = PreviewExportFrames.factory   // as main.swift installs it
        let b = backend()
        let p = try b.createProject(name: "Render", directory: nil)
        try Media.mov(p.directory + "/red.mov", (255, 0, 0), seconds: 1)
        let document = try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"render","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"red","kind":"video","name":"red","source":"red.mov","durationFrames":10}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"c","assetId":"red","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
        """#))
        let settings = ExportSettings(format: .mp4, quality: .draft, fps: .fps30, resolution: .scale(.auto), customDimensions: nil)
        let done = expectation(description: "render finished")
        let outcomeBox = OutcomeBox()
        var request = RenderRequest(projectId: p.id, document: document, settings: settings, settingsJSON: .object(["format": .string("mp4")]))
        request.jobId = "render-test"
        let run = try RenderRun.start(backend: b, request, RenderCallbacks { outcome, _ in outcomeBox.set(outcome); done.fulfill() })
        XCTAssertEqual(run.outputPath, root + "/userData/renders/render-test.mp4")
        wait(for: [done], timeout: 60)
        guard case .completed(let path, let size, _)? = outcomeBox.value else { return XCTFail("\(String(describing: outcomeBox.value))") }
        XCTAssertEqual(realPath(path), realPath(run.outputPath))
        XCTAssertGreaterThan(size, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.outputPath))
        let history = try b.renders(projectId: p.id)
        XCTAssertEqual(history.map(\.id), ["render-test"])
        XCTAssertEqual(history.first?.status, "complete")
        XCTAssertNotNil(history.first?.durationMs)
        XCTAssertGreaterThan(history.first?.size ?? 0, 0)
        b.closeProject(id: p.id)
    }

    /// A render cancelled straight away leaves no file and no history entry.
    func testRenderRunCancelLeavesNothingBehind() throws {
        NativeExportFrames.defaultRenderer = PreviewExportFrames.factory   // as main.swift installs it
        let b = backend()
        let p = try b.createProject(name: "Cancel", directory: nil)
        try Media.mov(p.directory + "/red.mov", (255, 0, 0), seconds: 1)
        let document = try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"render","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"red","kind":"video","name":"red","source":"red.mov","durationFrames":10}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"c","assetId":"red","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
        """#))
        let settings = ExportSettings(format: .mp4, quality: .draft, fps: .fps30, resolution: .scale(.auto), customDimensions: nil)
        let done = expectation(description: "render finished")
        let outcomeBox = OutcomeBox()
        var request = RenderRequest(projectId: p.id, document: document, settings: settings, settingsJSON: .object([:]))
        request.jobId = "render-cancel"
        let run = try RenderRun.start(backend: b, request, RenderCallbacks { outcome, _ in outcomeBox.set(outcome); done.fulfill() })
        run.cancel()
        wait(for: [done], timeout: 60)
        XCTAssertEqual(outcomeBox.value, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.outputPath))
        XCTAssertEqual(try b.renders(projectId: p.id), [])
        b.closeProject(id: p.id)
    }

    func testInstalledFontFamiliesAreSortedAndUnique() {
        let fonts = backend().installedFontFamilies()
        XCTAssertEqual(fonts, Array(Set(fonts)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testPublishingIsNotSupported() async {
        do { try await backend().openCrosspost(projectId: "x", filename: "y"); XCTFail("expected an error") }
        catch { XCTAssertEqual((error as? DesktopError)?.name, "NotSupportedError") }
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: ExportOutcome?
    func set(_ o: ExportOutcome) { lock.lock(); outcome = o; lock.unlock() }
    var value: ExportOutcome? { lock.lock(); defer { lock.unlock() }; return outcome }
}
