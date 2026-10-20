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
// Library workflow tests (catalog on SQLite through LibraryCatalog.command, imports, projects, snapshots).
import Foundation
import XCTest
@testable import MpvfxShared
@testable import MpvfxRuntime

final class LibraryServiceTests: XCTestCase {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1ioAAAAASUVORK5CYII=")!
    var roots: [String] = []
    var services: [LibraryService] = []

    struct Fixture { let root, library: String; let engine: LibraryService; let libraryId, eventId, first, second, source: String }

    func service(_ root: String) -> LibraryService {
        let s = LibraryService(userData: PosixPath.join(root, "settings"), durableWrite: TestDurableWrite())
        services.append(s); return s
    }
    func fixture() async throws -> Fixture {
        let root = try makeMediaTempDir("mpvfx-library-test-"); roots.append(root)
        let library = PosixPath.join(root, "Film.mpvfxlibrary"), engine = service(root)
        let libraryId = try await engine.create(library)
        let eventId = await engine.views()[0].events[0].id
        let first = try await engine.createProject(libraryId, eventId, "Main Edit")
        let second = try await engine.createProject(libraryId, eventId, "Short Version")
        let source = PosixPath.join(root, "Khé¿.png")
        try Self.png.write(to: URL(fileURLWithPath: source))
        return Fixture(root: root, library: library, engine: engine, libraryId: libraryId, eventId: eventId, first: first, second: second, source: source)
    }
    override func tearDown() async throws {
        for s in services { await s.close() }
        services = []
        for r in roots { try? FileManager.default.removeItem(atPath: r) }
        roots = []
    }
    func read(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
    func assertThrows(_ body: () async throws -> Void, _ contains: String? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected an error", file: file, line: line) }
        catch { if let contains { XCTAssertTrue("\(error)".contains(contains), "\(error)", file: file, line: line) } }
    }

    func testKeepsOtherProjectsOpenWhenAnIncompleteProjectDocumentCannotBeRecovered() async throws {
        let f = try await fixture(), projectId = UUID().uuidString.lowercased()
        _ = try LibraryCatalog.command(PosixPath.join(f.library, "Catalog.sqlite"), "project", [projectId, f.eventId, "Incomplete"])
        let directory = PosixPath.join(f.library, "Projects", projectId, ".studio")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try write(PosixPath.join(directory, "project.json"), "partial document")
        await f.engine.close()
        let reopened = service(f.root)
        try await reopened.open(f.library)
        XCTAssertEqual(reopened.listProjects().count, 2)
        let v1 = await reopened.views()[0].projects.first { $0.id == projectId }!.state
        XCTAssertEqual(v1, .pending)
        XCTAssertEqual(String(decoding: try read(PosixPath.join(directory, "project.json")), as: UTF8.self), "partial document")
    }

    func testImportsLibraryMediaAbove500MiBThroughBoundedFilesystemIO() async throws {
        let f = try await fixture(), source = PosixPath.join(f.root, "large.wav"), size = 501 * 1024 * 1024
        var header = Data(count: 44)
        func put(_ s: String, _ at: Int) { header.replaceSubrange(at..<at + s.utf8.count, with: Array(s.utf8)) }
        func u32(_ v: Int, _ at: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { header.replaceSubrange(at..<at + 4, with: $0) } }
        func u16(_ v: Int, _ at: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { header.replaceSubrange(at..<at + 2, with: $0) } }
        put("RIFF", 0); u32(size - 8, 4); put("WAVEfmt ", 8); u32(16, 16); u16(1, 20); u16(2, 22); u32(48000, 24)
        u32(192000, 28); u16(4, 32); u16(16, 34); put("data", 36); u32(size - 44, 40)
        _ = FileManager.default.createFile(atPath: source, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: source))
        try handle.truncate(atOffset: UInt64(size)); try handle.seek(toOffset: 0); try handle.write(contentsOf: header); try handle.close()
        let result = try await f.engine.importForProject(f.first, [source])
        XCTAssertEqual(result.invalid, [])
        XCTAssertEqual(result.files.count, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: PosixPath.join(f.engine.resolveProject(f.first)!.dir, result.files[0]))
        XCTAssertEqual((attrs[.size] as! NSNumber).intValue, size)
        let v2 = await f.engine.views()[0].assets[0].mode
        XCTAssertEqual(v2, .managed)
    }

    func testSharesOneCatalogAssetAcrossTwoIndependentProjectViewsAndReopensTheirEdits() async throws {
        let f = try await fixture()
        let result = try await f.engine.import(f.libraryId, f.eventId, [f.source], .managed)
        XCTAssertEqual(result.invalid, [])
        let initial = try NativeJSONValue.parse(String(decoding: try read(PosixPath.join(f.engine.resolveProject(f.first)!.dir, ".studio/project.json")), as: UTF8.self)).objectValue!
        XCTAssertEqual(initial["id"]?.stringValue, f.first)
        XCTAssertEqual(initial["sequence"]?.objectValue?["tracks"]?.arrayValue?.count, 0)
        let assetId = result.files[0]
        let path = try await f.engine.attach(f.libraryId, f.first, assetId)
        _ = try await f.engine.attach(f.libraryId, f.second, assetId)
        let first = f.engine.resolveProject(f.first)!.dir, second = f.engine.resolveProject(f.second)!.dir
        try write(PosixPath.join(first, "notes.txt"), "Main edit saved")
        try FileManager.default.removeItem(atPath: PosixPath.join(first, path))
        XCTAssertEqual(try read(PosixPath.join(second, path)), Self.png)
        XCTAssertEqual(try read(f.source), Self.png)
        let v3 = await f.engine.views()[0].assets.count
        XCTAssertEqual(v3, 1)
        await f.engine.close()
        let reopened = service(f.root)
        await reopened.restore()
        XCTAssertEqual(reopened.listProjects().map(\.title), ["Main Edit", "Short Version"])
        XCTAssertEqual(String(decoding: try read(PosixPath.join(reopened.resolveProject(f.first)!.dir, "notes.txt")), as: UTF8.self), "Main edit saved")
        let again = try await reopened.attach(f.libraryId, f.first, assetId)
        XCTAssertEqual(again, path)
    }

    func testKeepsIdenticalFilenamesAsDistinctAssetsAndReportsPerFileFailures() async throws {
        let f = try await fixture()
        try FileManager.default.createDirectory(atPath: PosixPath.join(f.root, "other"), withIntermediateDirectories: false)
        let other = PosixPath.join(f.root, "other", "Khé¿.png")
        try (Self.png + Data("different".utf8)).write(to: URL(fileURLWithPath: other))
        let result = try await f.engine.import(f.libraryId, LibraryImportTarget(eventId: f.eventId, projectId: f.first), [f.source, PosixPath.join(f.root, "missing.png"), other], .managed)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(Set(result.files).count, 2)
        XCTAssertEqual(result.invalid.count, 1)
        let project = f.engine.resolveProject(f.first)!.dir
        XCTAssertEqual(try read(PosixPath.join(project, result.files[0])), Self.png)
        XCTAssertNotEqual(try read(PosixPath.join(project, result.files[1])), Self.png)
    }

    func testKeepsLinkedOriginalsExternalDetectsOfflineMediaAndVerifiesRelinking() async throws {
        let f = try await fixture()
        let result = try await f.engine.import(f.libraryId, f.eventId, [f.source], .linked)
        let assetId = result.files[0]
        let path = try await f.engine.attach(f.libraryId, f.first, assetId)
        let moved = PosixPath.join(f.root, "moved.png")
        try FileManager.default.moveItem(atPath: f.source, toPath: moved)
        let v4 = await f.engine.views()[0].assets[0].available
        XCTAssertEqual(v4, false)
        await assertThrows { _ = try await f.engine.attach(f.libraryId, f.second, assetId) }
        let wrong = PosixPath.join(f.root, "wrong.png")
        try write(wrong, "wrong")
        await assertThrows({ try await f.engine.relink(f.libraryId, assetId, wrong) }, "not the same media")
        try await f.engine.relink(f.libraryId, assetId, moved)
        let v5 = await f.engine.views()[0].assets[0].available
        XCTAssertEqual(v5, true)
        _ = try await f.engine.attach(f.libraryId, f.second, assetId)
        try FileManager.default.removeItem(atPath: PosixPath.join(f.engine.resolveProject(f.first)!.dir, path))
        XCTAssertEqual(try read(moved), Self.png)
    }

    func testOpensAMovedManagedLibraryWithoutOriginalSourcesOrOldAppSettings() async throws {
        let f = try await fixture()
        let files = try await f.engine.import(f.libraryId, f.eventId, [f.source], .managed).files
        await f.engine.close()
        try FileManager.default.removeItem(atPath: f.source)
        let moved = PosixPath.join(f.root, "Renamed.mpvfxlibrary")
        try FileManager.default.moveItem(atPath: f.library, toPath: moved)
        let fresh = service(PosixPath.join(f.root, "fresh"))
        try await fresh.open(moved)
        let path = try await fresh.attach(f.libraryId, f.first, files[0])
        XCTAssertEqual(try read(PosixPath.join(fresh.resolveProject(f.first)!.dir, path)), Self.png)
    }

    func testRejectsASecondWriterAndReleasesTheOSLockOnClose() async throws {
        let f = try await fixture()
        let second = service(PosixPath.join(f.root, "second"))
        await assertThrows({ try await second.open(f.library) }, "already open")
        await f.engine.close()
        let opened = try await second.open(f.library)
        XCTAssertEqual(opened, f.libraryId)
    }

    func testRecoversACatalogedStagedImportAndInterruptedExportAfterRestart() async throws {
        let f = try await fixture(), assetId = UUID().uuidString.lowercased()
        let stage = PosixPath.join(f.library, "Staging", assetId)
        try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: false)
        try Self.png.write(to: URL(fileURLWithPath: PosixPath.join(stage, "frame.png")))
        _ = try LibraryCatalog.command(PosixPath.join(f.library, "Catalog.sqlite"), "asset",
            [assetId, f.eventId, "frame.png", "image", "managed", "Media/Originals/\(assetId)/frame.png", sha256Hex(Self.png)])
        let snapshot = try await f.engine.snapshot(f.first)
        XCTAssertNotNil(snapshot)
        await f.engine.close()
        let reopened = service(f.root)
        try await reopened.open(f.library)
        let view = await reopened.views()[0]
        XCTAssertEqual(view.assets[0].state, .ready)
        XCTAssertEqual(view.jobs[0].status, "interrupted")
        XCTAssertEqual(try read(PosixPath.join(f.library, "Media/Originals", assetId, "frame.png")), Self.png)
    }

    func testSnapshotsProjectFilesAndMediaIndependentlyFromSubsequentModifications() async throws {
        let f = try await fixture()
        let files = try await f.engine.import(f.libraryId, LibraryImportTarget(eventId: f.eventId, projectId: f.first), [f.source], .managed).files
        let project = f.engine.resolveProject(f.first)!.dir, path = files[0]
        let original = try read(PosixPath.join(project, ".studio/project.json"))
        let snapshot = try await f.engine.snapshot(f.first)!
        try write(PosixPath.join(project, ".studio/project.json"), "new edit")
        try write(PosixPath.join(project, path), "changed view")
        XCTAssertEqual(try read(PosixPath.join(snapshot.dir, ".studio/project.json")), original)
        XCTAssertEqual(try read(PosixPath.join(snapshot.dir, path)), Self.png)
        let asset = await f.engine.views()[0].assets[0]
        let other = try await f.engine.attach(f.libraryId, f.second, asset.id)
        XCTAssertEqual(try read(PosixPath.join(f.engine.resolveProject(f.second)!.dir, other)), Self.png)
    }

    func testPersistsExportCompletionAndRefusesToOverwriteAnExistingDestination() async throws {
        let f = try await fixture()
        let snapshot = try await f.engine.snapshot(f.first)!
        let output = PosixPath.join(try f.engine.outputDirectory(f.first)!, "output.mp4")
        try FileManager.default.createDirectory(atPath: PosixPath.join(f.library, "renders", f.first), withIntermediateDirectories: true)
        try write(output, "encoded-fixture")
        f.engine.trackExport(snapshot, { LibraryExportStatus(status: "complete", outputPath: output) })
        await f.engine.close()
        let reopened = service(f.root)
        try await reopened.open(f.library)
        let v6 = await reopened.views()[0].jobs[0].status
        XCTAssertEqual(v6, "complete")
        let destination = PosixPath.join(f.root, "saved.mp4")
        try await reopened.saveOutput(f.libraryId, snapshot.id, destination)
        XCTAssertEqual(String(decoding: try read(destination), as: UTF8.self), "encoded-fixture")
        try write(destination, "keep me")
        await assertThrows { try await reopened.saveOutput(f.libraryId, snapshot.id, destination) }
        XCTAssertEqual(String(decoding: try read(destination), as: UTF8.self), "keep me")
    }

    func testRejectsProjectAndAssetIdentitiesFromAnotherLibrary() async throws {
        let f = try await fixture()
        let otherId = try await f.engine.create(PosixPath.join(f.root, "Other.mpvfxlibrary"))
        let event = await f.engine.views().first { $0.id == otherId }!.events[0].id
        let otherProject = try await f.engine.createProject(otherId, event, "Other")
        let files = try await f.engine.import(f.libraryId, f.eventId, [f.source], .managed).files
        await assertThrows({ _ = try await f.engine.attach(f.libraryId, otherProject, files[0]) }, "not found")
        await assertThrows { _ = try await f.engine.createProject(f.libraryId, event, "Wrong event") }
    }

    /// Clipboard media: the shell writes the bytes to a file and calls importForProject.
    func testRoutesClipboardMediaIntoTheSameCatalog() async throws {
        let f = try await fixture()
        let dir = PosixPath.join(f.root, "clipboard"); try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        let file = PosixPath.join(dir, "clipboard.png"); try Self.png.write(to: URL(fileURLWithPath: file))
        let result = try await f.engine.importForProject(f.first, [file])
        XCTAssertEqual(result.invalid, [])
        XCTAssertEqual(result.files.count, 1)
        let v7 = await f.engine.views()[0].assets[0].name
        XCTAssertEqual(v7, "clipboard.png")
    }

    func testRejectsSymbolicLinksDuringExportRatherThanCapturingExternalMutableFiles() async throws {
        let f = try await fixture()
        try FileManager.default.createSymbolicLink(atPath: PosixPath.join(f.engine.resolveProject(f.first)!.dir, "outside.png"), withDestinationPath: f.source)
        await assertThrows({ _ = try await f.engine.snapshot(f.first) }, "symbolic link")
        let v8 = await f.engine.views()[0].jobs.count
        XCTAssertEqual(v8, 0)
    }

    func testDoesNotOverwriteAnExistingLibraryOrProjectStorage() async throws {
        let f = try await fixture()
        await assertThrows { _ = try await f.engine.create(f.library) }
        let attrs = try FileManager.default.attributesOfItem(atPath: PosixPath.join(f.library, "Catalog.sqlite"))
        XCTAssertGreaterThan((attrs[.size] as! NSNumber).intValue, 0)
        XCTAssertEqual(f.engine.listProjects().count, 2)
    }
}
