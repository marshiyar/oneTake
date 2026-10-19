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
import MpvfxShared
@testable import MpvfxRuntime

/// Media catalog, rename/delete with references, waveform peaks, recents and the document watcher.
final class ProjectMediaTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "mpvfx-projmedia-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    private func write(_ rel: String, _ text: String = "data", in dir: String) throws {
        let path = dir + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }

    /// A project whose document has `logo.png` placed once and `music.wav` as an unplaced asset.
    private func project() throws -> ProjectDocumentStore {
        let store = try ProjectDocumentStore.create(at: root + "/p", name: "P", durableWrite: TestDurableWrite())
        var doc = try ProjectDocuments.validate(store.savedContent)
        doc.assets = [NativeProjectAsset(id: "asset:logo", kind: .image, name: "logo.png", source: "media/logo.png", durationFrames: 150),
                      NativeProjectAsset(id: "asset:music", kind: .audio, name: "music.wav", source: "music.wav", durationFrames: 300)]
        let json = try NativeJSONValue.parse("""
        {"id":"track:v1","kind":"video","clips":[{"id":"clip:logo","assetId":"asset:logo","startFrame":0,"durationFrames":60,"sourceInFrame":0,"muted":false,"playbackRate":{"numerator":1,"denominator":1},"staticParameters":{},"effects":[],"parameterTracks":[]}]}
        """)
        doc.sequence.tracks = [try json.decode(NativeProjectTrack.self)]
        try store.save(try serializeNativeProjectDocument(doc))
        try write("media/logo.png", in: store.directory)
        try write("music.wav", in: store.directory)
        return store
    }

    func testCatalogListsMediaByCategoryUsedFirstAndSearchesNamesAndDescriptions() throws {
        let store = try project()
        let dir = store.directory
        try write("b-roll/beach.mp4", in: dir); try write("font/Inter.ttf", in: dir); try write("notes.txt", in: dir)
        try write("aaa.png", in: dir); try write("renders/out.mp4", in: dir); try write(".studio/cache.png", in: dir)
        try write(".mpvfx-import-x/tmp.png", in: dir); try write("lut.cube", in: dir)
        try write(".media/manifest.jsonl", "{\"path\":\"b-roll/beach.mp4\",\"description\":\"Sunset over the ocean\",\"duration\":12.5,\"width\":1920}\nnot json\n", in: dir)
        let doc = try ProjectDocuments.validate(store.savedContent)
        let all = ProjectMediaCatalog.list(dir, document: doc)
        XCTAssertEqual(all.map(\.path), ["music.wav", "media/logo.png", "aaa.png", "b-roll/beach.mp4", "font/Inter.ttf"])
        XCTAssertEqual(all.map(\.category), [.audio, .images, .images, .video, .fonts])
        XCTAssertEqual(all.map(\.used), [true, true, false, false, false])
        let beach = try XCTUnwrap(all.first { $0.name == "beach.mp4" })
        XCTAssertEqual(beach.description, "Sunset over the ocean"); XCTAssertEqual(beach.duration, 12.5); XCTAssertEqual(beach.width, 1920)
        XCTAssertEqual(ProjectMediaCatalog.list(dir, document: doc, query: "OCEAN").map(\.path), ["b-roll/beach.mp4"])
        XCTAssertEqual(ProjectMediaCatalog.list(dir, document: doc, query: "logo").map(\.path), ["media/logo.png"])
        XCTAssertEqual(ProjectMediaCatalog.list(dir, document: doc, query: "zzz"), [])
    }

    func testRenameMovesTheFileAndRepointsAssetsInOneSavedEdit() throws {
        let store = try project()
        let r = try store.renameMedia("media/logo.png", to: "brand/mark.png", content: store.savedContent)
        XCTAssertEqual(r.path, "brand/mark.png"); XCTAssertEqual(r.updatedAssets, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory + "/media/logo.png"))
        XCTAssertEqual(try String(contentsOfFile: store.directory + "/brand/mark.png", encoding: .utf8), "data")
        let asset = try XCTUnwrap(try ProjectDocuments.validate(r.content).assets.first { $0.id == "asset:logo" })
        XCTAssertEqual(asset.source, "brand/mark.png"); XCTAssertEqual(asset.name, "mark.png")
        XCTAssertEqual(try String(contentsOfFile: store.directory + "/.studio/project.json", encoding: .utf8), r.content)
        XCTAssertEqual(store.savedContent, r.content)
        // An unreferenced file renames with no document change.
        try write("extra.png", in: store.directory)
        XCTAssertEqual(try store.renameMedia("extra.png", to: "extra2.png", content: store.savedContent).updatedAssets, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/extra2.png"))
    }

    func testRenameRefusesExtensionChangesExistingTargetsMissingFilesAndMetadata() throws {
        let store = try project()
        func kind(_ body: () throws -> Any) -> ProjectMediaOperationError.Kind? {
            do { _ = try body(); return nil } catch { return (error as? ProjectMediaOperationError)?.kind }
        }
        XCTAssertEqual(kind { try store.renameMedia("media/logo.png", to: "media/logo.jpg", content: store.savedContent) }, .extensionChanged)
        XCTAssertEqual(kind { try store.renameMedia("media/logo.png", to: "music.wav", content: store.savedContent) }, .extensionChanged)
        try write("taken.png", in: store.directory)
        XCTAssertEqual(kind { try store.renameMedia("media/logo.png", to: "taken.png", content: store.savedContent) }, .exists)
        XCTAssertEqual(kind { try store.renameMedia("nope.png", to: "x.png", content: store.savedContent) }, .notFound)
        XCTAssertEqual(kind { try store.renameMedia("../x.png", to: "y.png", content: store.savedContent) }, .invalidPath)
        XCTAssertEqual(kind { try store.renameMedia(".studio/project.json", to: "y.json", content: store.savedContent) }, .protected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/media/logo.png"))
    }

    func testDeleteRefusesPlacedMediaUnlessUsagesGoTooAndKeepsARecoveryCopy() throws {
        let store = try project()
        XCTAssertThrowsError(try store.deleteMedia("media/logo.png", removeUsages: false, content: store.savedContent)) {
            let e = $0 as? ProjectMediaOperationError
            XCTAssertEqual(e?.kind, .inUse); XCTAssertEqual(e?.dependents, ["clip:logo"])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/media/logo.png"))
        let r = try store.deleteMedia("media/logo.png", removeUsages: true, content: store.savedContent)
        XCTAssertEqual(r.removedClips, 1); XCTAssertEqual(r.updatedAssets, 1)
        let doc = try ProjectDocuments.validate(r.content)
        XCTAssertEqual(doc.assets.map(\.id), ["asset:music"]); XCTAssertEqual(doc.sequence.tracks[0].clips, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory + "/media/logo.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/" + r.path))
        // An unplaced asset's file deletes without asking and drops the asset.
        let music = try store.deleteMedia("music.wav", removeUsages: false, content: store.savedContent)
        XCTAssertEqual(music.removedClips, 0); XCTAssertEqual(try ProjectDocuments.validate(music.content).assets, [])
    }

    func testMediaEditsSaveTheEditorsDocumentAndRefuseWhenTheDiskChanged() throws {
        let store = try project()
        var doc = try ProjectDocuments.validate(store.savedContent)
        doc.sequence.durationFrames = 999   // an unsaved edit in the editor
        let r = try store.renameMedia("music.wav", to: "song.wav", content: try serializeNativeProjectDocument(doc))
        XCTAssertEqual(try ProjectDocuments.validate(r.content).sequence.durationFrames, 999)
        try (store.savedContent.replacingOccurrences(of: "999", with: "1000")).write(toFile: store.directory + "/.studio/project.json", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.renameMedia("song.wav", to: "tune.wav", content: store.savedContent)) {
            XCTAssertEqual(($0 as? ProjectDocumentError)?.kind, .conflict)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/song.wav"))
    }

    func testWaveformPeaksAreNormalizedWindowMaxima() throws {
        XCTAssertEqual(WaveformPeaks.peaks([0, 0.5, -1, 0.25, 0.125, -0.25], bars: 3), [0.5, 1, 0.25])
        XCTAssertEqual(WaveformPeaks.peaks([0.1], bars: 4), [0, 0, 0, 1])
        XCTAssertEqual(WaveformPeaks.peaks([], bars: 2), [0, 0])
        let dir = root + "/w"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rate = 8000
        try TestMedia.wav(TestMedia.tone(seconds: 2, rate: rate, frequency: 220, amplitude: 0.5), rate: rate, channels: 1)
            .write(to: URL(fileURLWithPath: dir + "/tone.wav"))
        // Stereo: silent first second, a tone in the left channel only for the second one (the downmix keeps it).
        let half = TestMedia.tone(seconds: 1, rate: rate, frequency: 220, amplitude: 0.8)
        try TestMedia.wav([Float](repeating: 0, count: rate * 2) + half.flatMap { [$0, 0] }, rate: rate, channels: 2)
            .write(to: URL(fileURLWithPath: dir + "/late.wav"))
        let red = TestMedia.solid((255, 0, 0), width: 8, height: 8)
        try TestMedia.writeMOV(dir + "/silent.mov", frames: [red, red], width: 8, height: 8)
        let peaks = try WaveformPeaks.forProjectMedia(dir, "tone.wav")
        XCTAssertEqual(peaks.count, WaveformPeaks.defaultBars)
        XCTAssertEqual(peaks.max() ?? 0, 1, accuracy: 1e-9)
        let cache = try FileManager.default.contentsOfDirectory(atPath: dir + "/.waveform-cache")
        XCTAssertEqual(cache.count, 1); XCTAssertTrue(cache[0].hasPrefix("v3_tone.wav_"))
        // A second read is served from the cache file, not decoded again.
        let planted = [Double](repeating: 0.25, count: WaveformPeaks.defaultBars)
        try jsJSONStringify(.array(planted.map { .number($0) })).write(toFile: dir + "/.waveform-cache/" + cache[0], atomically: true, encoding: .utf8)
        XCTAssertEqual(try WaveformPeaks.forProjectMedia(dir, "tone.wav"), planted)
        XCTAssertEqual(try WaveformPeaks.forProjectMedia(dir, "tone.wav", cache: false), peaks)
        let coarse = try WaveformPeaks.forProjectMedia(dir, "tone.wav", bars: 100)
        XCTAssertGreaterThan(coarse.min() ?? 0, 0.9)   // a steady tone: every bar near the top
        let late = try WaveformPeaks.forProjectMedia(dir, "late.wav", bars: 10)
        XCTAssertEqual(late.count, 10)
        XCTAssertLessThan(late[0..<4].max() ?? 1, 0.01, "\(late)")   // the silent first second
        XCTAssertGreaterThan(late[6..<10].min() ?? 0, 0.9, "\(late)")
        XCTAssertThrowsError(try WaveformPeaks.forProjectMedia(dir, "silent.mov"))
        XCTAssertThrowsError(try WaveformPeaks.forProjectMedia(dir, "../escape.wav"))
    }

    func testProjectListAndRecentsPersistNewestFirst() throws {
        let projects = root + "/projects"
        let a = try ProjectDocumentStore.create(at: projects + "/A", name: "Alpha", durableWrite: TestDurableWrite())
        let b = try ProjectDocumentStore.create(at: projects + "/B", name: "Main", durableWrite: TestDurableWrite())
        try FileManager.default.createDirectory(atPath: projects + "/not-a-project", withIntermediateDirectories: true)
        let listed = ProjectCatalog.list(projects)
        XCTAssertEqual(Set(listed.map(\.directory)), [a.directory, b.directory])
        XCTAssertEqual(listed.first { $0.directory == a.directory }?.title, "Alpha")
        XCTAssertEqual(listed.first { $0.directory == b.directory }?.title, "B")   // default sequence name: folder name
        // Listed through a symlink (macOS /var is /private/var): directories still match the stores'.
        try FileManager.default.createSymbolicLink(atPath: root + "/linked", withDestinationPath: projects)
        XCTAssertEqual(Set(ProjectCatalog.list(root + "/linked").map(\.directory)), [a.directory, b.directory])

        let recents = RecentProjects(userData: root + "/user")
        try recents.add(a.directory); try recents.add(b.directory); try recents.add(a.directory)
        XCTAssertEqual(recents.list().map(\.directory), [a.directory, b.directory])
        XCTAssertEqual(RecentProjects(userData: root + "/user").list().map(\.directory), [a.directory, b.directory])
        try FileManager.default.removeItem(atPath: b.directory)
        XCTAssertEqual(RecentProjects(userData: root + "/user").list().map(\.directory), [a.directory])
        try recents.remove(a.directory)
        XCTAssertEqual(RecentProjects(userData: root + "/user").list(), [])
        for i in 0..<20 { try recents.add("/nowhere/\(i)") }
        let stored = try NativeJSONValue.parse(try String(contentsOfFile: root + "/user/recent-projects.json", encoding: .utf8))
        XCTAssertEqual(stored.arrayValue?.count, RecentProjects.limit)
    }

    func testWatcherReportsExternalEditsButNotItsOwnSaves() throws {
        let store = try ProjectDocumentStore.create(at: root + "/p", name: "P", durableWrite: TestDurableWrite())
        let seen = Box()
        let watcher = ProjectDocumentWatcher(store: store, interval: 3600) { seen.append($0) }
        defer { watcher.stop() }
        watcher.check()
        var doc = try ProjectDocuments.validate(store.savedContent)
        doc.sequence.durationFrames = 200
        try store.save(try serializeNativeProjectDocument(doc))
        watcher.check()
        XCTAssertEqual(seen.values, [])
        doc.sequence.durationFrames = 300
        let external = try serializeNativeProjectDocument(doc)
        try external.write(toFile: store.directory + "/.studio/project.json", atomically: true, encoding: .utf8)
        watcher.check(); watcher.check()
        XCTAssertEqual(seen.values, [external])
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func append(_ s: String) { lock.withLock { _values.append(s) } }
}
