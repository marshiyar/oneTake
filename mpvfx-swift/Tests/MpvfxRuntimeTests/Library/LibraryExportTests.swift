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
// Library export flow: snapshot -> renderNativeTimeline on the snapshot -> trackExport. Media made and checked with the
// media engine (MediaWriter, MediaProbe, VideoFrameReader).
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime

final class LibraryExportTests: XCTestCase {
    func testExportsTwoRealLibraryProjectsFromIsolatedRevisionsWhileTheirLiveMediaChanges() async throws {
        installAppExportFrames()
        let root = try makeMediaTempDir("mpvfx-library-export-")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let library = LibraryService(userData: PosixPath.join(root, "settings"), durableWrite: TestDurableWrite())
        let libraryId = try await library.create(PosixPath.join(root, "Film.mpvfxlibrary"))
        let eventId = await library.views()[0].events[0].id
        let first = try await library.createProject(libraryId, eventId, "Main")
        let second = try await library.createProject(libraryId, eventId, "Short")
        let source = PosixPath.join(root, "source.mp4")
        try TestMedia.write(TestVideo(tone: 440, container: .mp4), to: source)
        let imported = try await library.import(libraryId, eventId, [source], .managed)
        XCTAssertEqual(imported.invalid, [])
        let assetId = imported.files[0]
        for projectId in [first, second] {
            let path = try await library.attach(libraryId, projectId, assetId), dir = library.resolveProject(projectId)!.dir
            try Data("""
            {"schemaVersion":1,"mediaEngine":"native","id":"\(projectId)","revision":3,"frameRate":{"numerator":10,"denominator":1},\
            "canvas":{"width":64,"height":32,"background":"#000000"},"assets":[{"id":"\(assetId)","kind":"video","name":"Source","source":"\(path)","durationFrames":20}],\
            "sequence":{"id":"main","name":"Main","tracks":[{"id":"video","kind":"video","clips":[{"id":"clip","assetId":"\(assetId)","startFrame":0,\
            "durationFrames":\(projectId == first ? 10 : 5),"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
            """.utf8).write(to: URL(fileURLWithPath: PosixPath.join(dir, ".studio/project.json")))
        }
        XCTAssertEqual(Set(library.listProjects().map(\.id)), [first, second])
        for projectId in [first, second] {
            let snapshot = try await library.snapshot(projectId, settings: try NativeJSONValue.parse(#"{"format":"mp4","fps":30,"quality":"draft"}"#))!
            let outDir = try library.outputDirectory(projectId)!
            try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let output = PosixPath.join(outDir, "\(snapshot.id).mp4")
            let document = try parseNativeProjectDocument(NativeJSONValue.parse(String(decoding: try Data(contentsOf: URL(fileURLWithPath: PosixPath.join(snapshot.dir, ".studio/project.json"))), as: UTF8.self)))
            // Mutate the live project after the snapshot: the snapshot must not change.
            let dir = library.resolveProject(projectId)!.dir
            try Data("changed after snapshot".utf8).write(to: URL(fileURLWithPath: PosixPath.join(dir, document.assets[0].source!)))
            var live = document; live.sequence.tracks[0].clips = []
            try Data(jsJSONStringify(try NativeJSONValue.from(live)).utf8).write(to: URL(fileURLWithPath: PosixPath.join(dir, ".studio/project.json")))
            try renderNativeTimeline(.init(project: document, projectDir: snapshot.dir, outputPath: output, format: .mp4, outputFps: 30, quality: .draft))
            library.trackExport(snapshot, { LibraryExportStatus(status: "complete", outputPath: output) })
        }
        await library.close()
        let reopened = LibraryService(userData: PosixPath.join(root, "settings"), durableWrite: TestDurableWrite())
        try await reopened.open(PosixPath.join(root, "Film.mpvfxlibrary"))
        let jobs = await reopened.views()[0].jobs
        XCTAssertEqual(jobs.map { [$0.status, $0.error] }, [["complete", ""], ["complete", ""]])
        try jobs.forEach { job in
            let probe = try MediaProbe.probe(path: job.output)
            XCTAssertEqual(probe.video?.displayWidth, 64); XCTAssertEqual(probe.video?.displayHeight, 32)
            XCTAssertNotNil(probe.audio)
            XCTAssertEqual(probe.duration ?? 0, job.projectId == first ? 1 : 0.5, accuracy: 0.05)
            let rgb = try Exported(path: job.output).rgb(0.2)
            let i = (16 * 64 + 32) * 3
            XCTAssertGreaterThan(rgb[i], 220); XCTAssertLessThan(rgb[i + 1], 20)
        }
        await reopened.close()
    }
}
