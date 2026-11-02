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

    /// "Save to…" (#40): a file already at the destination is kept and named in the error, unless the dialog approved
    /// replacing it; a folder that cannot be written is a typed error that names the file; no staged copy is left behind.
    func testSaveOutputKeepsAnExistingFileUnlessApprovedAndReportsAnUnwritableFolder() async throws {
        let f = try await fixture()
        let snapshot = try await f.engine.snapshot(f.first)!
        let output = PosixPath.join(try f.engine.outputDirectory(f.first)!, "output.mp4")
        try FileManager.default.createDirectory(atPath: PosixPath.join(f.library, "renders", f.first), withIntermediateDirectories: true)
        try write(output, "encoded-fixture")
        f.engine.trackExport(snapshot, { LibraryExportStatus(status: "complete", outputPath: output) })
        await f.engine.exportTrackingFinished()
        let destination = PosixPath.join(f.root, "saved.mp4")
        try write(destination, "keep me")
        await assertThrows({ try await f.engine.saveOutput(f.libraryId, snapshot.id, destination) },
                           "A file named saved.mp4 already exists there. It was left unchanged; choose another name.")
        XCTAssertEqual(String(decoding: try read(destination), as: UTF8.self), "keep me")
        try await f.engine.saveOutput(f.libraryId, snapshot.id, destination, replaceApproved: true)
        XCTAssertEqual(String(decoding: try read(destination), as: UTF8.self), "encoded-fixture")
        let missing = PosixPath.join(f.root, "no-such-folder", "saved.mp4")
        await assertThrows({ try await f.engine.saveOutput(f.libraryId, snapshot.id, missing) }, "Could not save the export as saved.mp4: ENOENT")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root).filter { $0.hasPrefix(".mpvfx-output-") }, [])
        XCTAssertEqual(String(decoding: try read(output), as: UTF8.self), "encoded-fixture", "the library's render is untouched")
    }

    /// Rename (#40): an event and a project take the trimmed new name in the catalog and keep it after a reopen; the
    /// project's identity, folder and document are unchanged.
    func testRenamesAnEventAndAProjectInTheCatalogOnly() async throws {
        let f = try await fixture()
        let dir = try XCTUnwrap(f.engine.resolveProject(f.first)).dir
        let document = try read(PosixPath.join(dir, ".studio/project.json"))
        try await f.engine.renameEvent(f.libraryId, f.eventId, "  Day 1 – interviews ")
        try await f.engine.renameProject(f.libraryId, f.first, "Director's cut")
        let view = await f.engine.views()[0]
        XCTAssertEqual(view.events.first { $0.id == f.eventId }?.name, "Day 1 – interviews")
        XCTAssertEqual(view.projects.first { $0.id == f.first }?.name, "Director's cut")
        XCTAssertEqual(view.projects.first { $0.id == f.second }?.name, "Short Version")
        XCTAssertEqual(f.engine.resolveProject(f.first), LibraryProjectEntry(id: f.first, title: "Director's cut", dir: dir))
        XCTAssertEqual(try read(PosixPath.join(dir, ".studio/project.json")), document)
        await f.engine.close()
        let reopened = service(f.root)
        try await reopened.open(f.library)
        let after = await reopened.views()[0]
        XCTAssertEqual(after.events.first { $0.id == f.eventId }?.name, "Day 1 – interviews")
        XCTAssertEqual(after.projects.first { $0.id == f.first }?.name, "Director's cut")
    }

    /// Rename refuses an empty or over-long name, a malformed id, an unknown id and an id from another library, and
    /// changes nothing when it does.
    func testRenameRefusesBadNamesAndUnknownIdsWithoutChangingTheCatalog() async throws {
        let f = try await fixture()
        let otherId = try await f.engine.create(PosixPath.join(f.root, "Other.mpvfxlibrary"))
        let views = await f.engine.views()
        let otherEvent = try XCTUnwrap(views.first { $0.id == otherId }?.events.first?.id)
        let otherProject = try await f.engine.createProject(otherId, otherEvent, "Other")
        let before = await f.engine.views().first { $0.id == f.libraryId }
        await assertThrows({ try await f.engine.renameProject(f.libraryId, f.first, "   ") }, "Enter a name (1–200 characters)")
        await assertThrows({ try await f.engine.renameEvent(f.libraryId, f.eventId, String(repeating: "x", count: 201)) }, "Enter a name")
        await assertThrows({ try await f.engine.renameEvent(f.libraryId, "not-an-id", "X") }, "Invalid library identity")
        await assertThrows({ try await f.engine.renameProject(f.libraryId, UUID().uuidString.lowercased(), "X") }, "Library project not found")
        await assertThrows({ try await f.engine.renameEvent(f.libraryId, UUID().uuidString.lowercased(), "X") }, "Library event not found")
        await assertThrows({ try await f.engine.renameProject(f.libraryId, otherProject, "X") }, "Library project not found")
        await assertThrows({ try await f.engine.renameEvent(f.libraryId, otherEvent, "X") }, "Library event not found")
        let after = await f.engine.views().first { $0.id == f.libraryId }
        XCTAssertEqual(after, before)
    }

    /// Delete project (#40): the catalog row, the project's folder, its export snapshot and its renders go; the other
    /// project, the library's media and the attached copy in the other project stay, also after a reopen.
    func testDeletesAProjectWithItsFilesAndExportsOnly() async throws {
        let f = try await fixture()
        let assetId = try await f.engine.import(f.libraryId, LibraryImportTarget(eventId: f.eventId), [f.source], .managed).files[0]
        _ = try await f.engine.attach(f.libraryId, f.first, assetId)
        let attached = try await f.engine.attach(f.libraryId, f.second, assetId)
        let first = try XCTUnwrap(f.engine.resolveProject(f.first)).dir, second = try XCTUnwrap(f.engine.resolveProject(f.second)).dir
        let snapshot = try await f.engine.snapshot(f.first)!
        try await f.engine.failSnapshot(snapshot, "stopped")
        let renders = PosixPath.join(f.library, "renders", f.first)
        try FileManager.default.createDirectory(atPath: renders, withIntermediateDirectories: true)
        try write(PosixPath.join(renders, "out.mp4"), "render")
        let original = PosixPath.join(f.library, "Media/Originals", assetId)
        try await f.engine.deleteProject(f.libraryId, f.first)
        let view = await f.engine.views()[0]
        XCTAssertEqual(view.projects.map(\.id), [f.second])
        XCTAssertEqual(view.assets.map(\.id), [assetId])
        XCTAssertEqual(view.jobs, [])
        XCTAssertNil(f.engine.resolveProject(f.first))
        for gone in [first, renders, snapshot.dir] { XCTAssertFalse(FileManager.default.fileExists(atPath: gone), gone) }
        for kept in [second, PosixPath.join(second, attached), original, f.source] { XCTAssertTrue(FileManager.default.fileExists(atPath: kept), kept) }
        await f.engine.close()
        let reopened = service(f.root)
        try await reopened.open(f.library)
        let after = await reopened.views()[0]
        XCTAssertEqual(after.projects.map(\.id), [f.second])
        await assertThrows({ try await reopened.deleteProject(f.libraryId, f.first) }, "Library project not found")
    }

    /// Delete event (#40): the event's projects, media records and managed copies go, with every placement of that media
    /// (also one in another event's project); a linked original is never touched, and the other event is unchanged.
    func testDeletesAnEventWithItsProjectsMediaAndPlacements() async throws {
        let f = try await fixture()
        try await f.engine.createEvent(f.libraryId, "Day 2")
        let events = await f.engine.views()[0].events
        let day2 = try XCTUnwrap(events.first { $0.id != f.eventId }?.id)
        let doomed = try await f.engine.createProject(f.libraryId, day2, "Day 2 cut")
        let managed = try await f.engine.import(f.libraryId, LibraryImportTarget(eventId: day2), [f.source], .managed).files[0]
        _ = try await f.engine.attach(f.libraryId, doomed, managed)
        let linked = try await f.engine.import(f.libraryId, LibraryImportTarget(eventId: day2), [f.source], .linked).files[0]
        _ = try await f.engine.attach(f.libraryId, f.first, managed)   // a project of the other event holds a copy
        let keptMedia = try await f.engine.import(f.libraryId, LibraryImportTarget(eventId: f.eventId), [f.source], .managed).files[0]
        let doomedDir = try XCTUnwrap(f.engine.resolveProject(doomed)).dir
        let managedDir = PosixPath.join(f.library, "Media/Originals", managed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedDir))
        try await f.engine.deleteEvent(f.libraryId, day2)
        let view = await f.engine.views()[0]
        XCTAssertEqual(view.events.map(\.id), [f.eventId])
        XCTAssertEqual(Set(view.projects.map(\.id)), [f.first, f.second])
        XCTAssertEqual(view.assets.map(\.id), [keptMedia])
        XCTAssertFalse(view.assets.contains { [managed, linked].contains($0.id) })
        for gone in [doomedDir, managedDir] { XCTAssertFalse(FileManager.default.fileExists(atPath: gone), gone) }
        for kept in [f.source, try XCTUnwrap(f.engine.resolveProject(f.first)).dir, PosixPath.join(f.library, "Media/Originals", keptMedia)] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept), kept)
        }
        await f.engine.close()
        let reopened = service(f.root)
        try await reopened.open(f.library)
        let after = await reopened.views()[0]
        XCTAssertEqual(after.events.map(\.id), [f.eventId])
        XCTAssertEqual(after.assets.map(\.id), [keptMedia])
    }

    /// Delete refuses an unknown id, an id from another library, the library's last event and anything with a running
    /// export, and changes nothing when it does; once the export has ended the delete goes through.
    func testDeleteRefusesUnknownIdsTheLastEventAndARunningExport() async throws {
        let f = try await fixture()
        let otherId = try await f.engine.create(PosixPath.join(f.root, "Other.mpvfxlibrary"))
        let others = await f.engine.views()
        let otherEvent = try XCTUnwrap(others.first { $0.id == otherId }?.events.first?.id)
        let otherProject = try await f.engine.createProject(otherId, otherEvent, "Other")
        let before = await f.engine.views().first { $0.id == f.libraryId }
        await assertThrows({ try await f.engine.deleteProject(f.libraryId, "not-an-id") }, "Invalid library identity")
        await assertThrows({ try await f.engine.deleteProject(f.libraryId, UUID().uuidString.lowercased()) }, "Library project not found")
        await assertThrows({ try await f.engine.deleteProject(f.libraryId, otherProject) }, "Library project not found")
        await assertThrows({ try await f.engine.deleteEvent(f.libraryId, UUID().uuidString.lowercased()) }, "Library event not found")
        await assertThrows({ try await f.engine.deleteEvent(f.libraryId, otherEvent) }, "Library event not found")
        await assertThrows({ try await f.engine.deleteEvent(f.libraryId, f.eventId) }, "at least one event")
        try await f.engine.createEvent(f.libraryId, "Day 2")
        let snapshot = try await f.engine.snapshot(f.first)!
        await assertThrows({ try await f.engine.deleteProject(f.libraryId, f.first) }, "export is still running")
        await assertThrows({ try await f.engine.deleteEvent(f.libraryId, f.eventId) }, "export is still running")
        let during = await f.engine.views().first { $0.id == f.libraryId }
        XCTAssertEqual(during?.projects, before?.projects)
        XCTAssertEqual(during?.events.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.dir))
        try await f.engine.failSnapshot(snapshot, "stopped")
        try await f.engine.deleteProject(f.libraryId, f.first)
        let after = await f.engine.views().first { $0.id == f.libraryId }
        XCTAssertEqual(after?.projects.map(\.id), [f.second])
        let untouched = await f.engine.views().first { $0.id == otherId }
        XCTAssertEqual(untouched?.projects.map(\.id), [otherProject])
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
