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
import MpvfxRuntime

/// Answers dialogs from a script and records what was opened in the file manager.
private final class ScriptedDialogs: NativeDialogs, @unchecked Sendable {
    var saves: [String?] = [], opens: [[String]] = []
    var saveRequests: [SaveDialogOptions] = [], openRequests: [OpenDialogOptions] = [], opened: [String] = []
    /// Runs while the save dialog is "open": what another program does between the user's choice and the write.
    var whileSaving: (() -> Void)?
    func showSave(_ options: SaveDialogOptions) async -> String? {
        saveRequests.append(options); whileSaving?(); whileSaving = nil
        return saves.isEmpty ? nil : saves.removeFirst()
    }
    func showOpen(_ options: OpenDialogOptions) async -> [String] { openRequests.append(options); return opens.isEmpty ? [] : opens.removeFirst() }
    func showError(title: String, message: String) async {}
    func openPath(_ path: String) async { opened.append(path) }
}

final class LibraryCommandsTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "mpvfx-libcmd-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root) }

    private func run(_ b: RuntimeDesktopBackend, _ dialogs: NativeDialogs?, _ command: JSONObject) async throws -> JSONValue {
        try await LibraryCommands.dispatch(service: XCTUnwrap(b.libraries), backend: b, dialogs: dialogs, command: .object(command))
    }

    func testNewLibraryEventProjectRevealAndOpen() async throws {
        let b = RuntimeDesktopBackend(userData: root + "/userData")
        let dialogs = ScriptedDialogs()
        // Cancelled: nothing created.
        var r = try await run(b, dialogs, ["type": .string("create")])
        XCTAssertEqual(r["libraries"], .array([])); XCTAssertNil(r["projectId"])
        XCTAssertEqual(dialogs.saveRequests.first?.defaultPath, "Untitled.mpvfxlibrary")
        // New library: the extension is added and an "Untitled Project" opens in its first event.
        dialogs.saves = [root + "/Films"]
        r = try await run(b, dialogs, ["type": .string("create")])
        let projectId = try XCTUnwrap(r["projectId"]?.string)
        var views = try await b.libraryViews()
        let library = try XCTUnwrap(views.first)
        XCTAssertTrue(library.path.hasSuffix("/Films.mpvfxlibrary"), library.path)
        XCTAssertEqual(library.projects.map(\.id), [projectId])
        XCTAssertEqual(library.projects.first?.name, "Untitled Project")
        XCTAssertEqual(r["errors"], .array([]))
        // New event and new project in it.
        _ = try await run(b, dialogs, ["type": .string("event"), "libraryId": .string(library.id), "name": .string("Day 2")])
        views = try await b.libraryViews()
        let event = try XCTUnwrap(views.first?.events.first { $0.name == "Day 2" })
        r = try await run(b, dialogs, ["type": .string("project"), "libraryId": .string(library.id), "eventId": .string(event.id), "name": .string("B-roll")])
        let second = try XCTUnwrap(r["projectId"]?.string)
        views = try await b.libraryViews()
        XCTAssertEqual(Set(views.first?.projects.map(\.id) ?? []), [projectId, second])
        XCTAssertNoThrow(try b.openProject(path: try XCTUnwrap(views.first?.projects.first { $0.id == second }).directory))
        // Reveal in Finder / the file manager.
        _ = try await run(b, dialogs, ["type": .string("reveal"), "libraryId": .string(library.id)])
        XCTAssertEqual(dialogs.opened, [try b.libraries!.root(libraryId: library.id)])
        // Nothing to save before an export completes; unknown commands fail.
        do { _ = try await run(b, dialogs, ["type": .string("saveOutput"), "libraryId": .string(library.id), "jobId": .string("nope")]); XCTFail() }
        catch { XCTAssertEqual((error as? DesktopError)?.message, "Export is not complete") }
        do { _ = try await run(b, dialogs, ["type": .string("bogus")]); XCTFail() }
        catch { XCTAssertEqual((error as? DesktopError)?.message, "Unknown library command") }
        try await b.close()

        // Open Library in a fresh launch selects its first ready project.
        let other = RuntimeDesktopBackend(userData: root + "/other")
        dialogs.opens = [[library.path]]
        r = try await run(other, dialogs, ["type": .string("open")])
        XCTAssertTrue([projectId, second].contains(try XCTUnwrap(r["projectId"]?.string)))
        XCTAssertEqual(dialogs.openRequests.last, OpenDialogOptions(title: "Open Library", directory: true, multiple: false))
        try await other.close()
    }

    /// "Save to…" end to end (#40): a completed library export is copied to the path the save dialog returns; a
    /// cancelled dialog writes nothing; a name typed without the extension gets it and never replaces a file there;
    /// a path the dialog approved is replaced.
    func testSaveToCopiesACompletedLibraryExportWhereTheUserChose() async throws {
        let b = RuntimeDesktopBackend(userData: root + "/userData")
        let dialogs = ScriptedDialogs()
        dialogs.saves = [root + "/Films"]
        let created = try await run(b, dialogs, ["type": .string("create")])
        let projectId = try XCTUnwrap(created["projectId"]?.string)
        let views = try await b.libraryViews()
        let library = try XCTUnwrap(views.first)
        try await b.close()
        // A finished export as a library render records it: the file under renders/<project>/ and its catalog job.
        let jobId = UUID().uuidString.lowercased(), renders = library.path + "/renders/" + projectId
        try FileManager.default.createDirectory(atPath: renders, withIntermediateDirectories: true)
        try Data("encoded-fixture".utf8).write(to: URL(fileURLWithPath: renders + "/render-1.mp4"))
        let catalog = library.path + "/Catalog.sqlite"
        _ = try LibraryCatalog.command(catalog, "job", [jobId, projectId, "Snapshots/" + jobId])
        _ = try LibraryCatalog.command(catalog, "jobFinish", [jobId, "complete", "renders/\(projectId)/render-1.mp4", ""])

        let reopened = RuntimeDesktopBackend(userData: root + "/reopened")
        dialogs.opens = [[library.path]]
        _ = try await run(reopened, dialogs, ["type": .string("open")])
        let save: JSONObject = ["type": .string("saveOutput"), "libraryId": .string(library.id), "jobId": .string(jobId)]
        let out = root + "/Out", saved = out + "/Final cut.mp4"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        dialogs.saves = [nil]
        _ = try await run(reopened, dialogs, save)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), [], "cancelled: nothing written")
        XCTAssertEqual(dialogs.saveRequests.last?.defaultPath, "render-1.mp4")
        XCTAssertEqual(dialogs.saveRequests.last?.filters.first?.extensions, ["mp4"])

        dialogs.saves = [out + "/Final cut"]
        _ = try await run(reopened, dialogs, save)
        XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "encoded-fixture")

        try Data("keep me".utf8).write(to: URL(fileURLWithPath: saved))
        dialogs.saves = [out + "/Final cut"]
        do { _ = try await run(reopened, dialogs, save); XCTFail("expected an error") }
        catch {
            XCTAssertEqual((error as? DesktopError)?.message,
                           "A file named Final cut.mp4 already exists there. It was left unchanged; choose another name.")
        }
        XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "keep me")

        dialogs.saves = [saved]
        _ = try await run(reopened, dialogs, save)
        XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "encoded-fixture")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), ["Final cut.mp4"], "no staged copy left")

        // A file that appears at the extension-added path after the dialog closed was never approved: it is kept. (A
        // name the dialog returned with its extension was approved by the user and is replaced, as every save dialog
        // does.)
        let late = out + "/Late.mp4"
        dialogs.whileSaving = { FileManager.default.createFile(atPath: late, contents: Data("written meanwhile".utf8)) }
        dialogs.saves = [out + "/Late"]
        do { _ = try await run(reopened, dialogs, save); XCTFail("expected an error") }
        catch {
            XCTAssertEqual((error as? DesktopError)?.message,
                           "A file named Late.mp4 already exists there. It was left unchanged; choose another name.")
        }
        XCTAssertEqual(try String(contentsOfFile: late, encoding: .utf8), "written meanwhile")
        try await reopened.close()
    }
}
