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
import MpvfxDesktopCore

/// One library with one export job; records every `saveOutput` call and fails every other operation.
private final class OneExportLibrary: LibraryService, @unchecked Sendable {
    struct Save: Equatable { var libraryId, jobId, destination: String; var overwrite: Bool }
    let status: String, output: String
    var saves: [Save] = []
    init(status: String, output: String) { self.status = status; self.output = output }

    func views() async throws -> JSONValue {
        let job: JSONObject = ["id": .string("J"), "projectId": .string("P"), "status": .string(status), "output": .string(output)]
        return .array([.object(["id": .string("L"), "jobs": .array([.object(job)])])])
    }
    func create(root: String) async throws -> String { throw DesktopError.notImplemented("create") }
    func open(root: String) async throws -> String { throw DesktopError.notImplemented("open") }
    func createEvent(libraryId: String, name: String) async throws { throw DesktopError.notImplemented("createEvent") }
    func createProject(libraryId: String, eventId: String, name: String) async throws -> String { throw DesktopError.notImplemented("createProject") }
    func importMedia(libraryId: String, eventId: String, paths: [String], mode: String, projectId: String?) async throws -> [(String, String)] {
        throw DesktopError.notImplemented("importMedia")
    }
    func attach(libraryId: String, projectId: String, assetId: String) async throws -> String { throw DesktopError.notImplemented("attach") }
    func relink(libraryId: String, assetId: String, path: String) async throws { throw DesktopError.notImplemented("relink") }
    func root(libraryId: String) throws -> String { throw DesktopError.notImplemented("root") }
    func saveOutput(libraryId: String, jobId: String, destination: String, overwrite: Bool) async throws {
        saves.append(Save(libraryId: libraryId, jobId: jobId, destination: destination, overwrite: overwrite))
    }
}

/// Answers each save dialog with the next scripted path (nil = cancelled) and records what it was asked.
private final class SaveDialogScript: NativeDialogs, @unchecked Sendable {
    var answers: [String?]
    var asked: [SaveDialogOptions] = []
    init(_ answers: [String?]) { self.answers = answers }
    func showSave(_ options: SaveDialogOptions) async -> String? { asked.append(options); return answers.isEmpty ? nil : answers.removeFirst() }
    func showOpen(_ options: OpenDialogOptions) async -> [String] { [] }
    func showError(title: String, message: String) async {}
    func openPath(_ path: String) async {}
}

/// "Save to…" on a library export record (left sidebar, "Library exports"): the save dialog, then a copy of the
/// finished file at the chosen path. Issue #40.
final class LibrarySaveToTests: XCTestCase {
    private let output = "/films/Films.mpvfxlibrary/renders/P/render-1.mp4"

    private func saveTo(_ library: OneExportLibrary, _ dialogs: SaveDialogScript) async throws -> JSONValue {
        let command: JSONObject = ["type": .string("saveOutput"), "libraryId": .string("L"), "jobId": .string("J")]
        return try await LibraryCommands.dispatch(service: library, backend: NotImplementedBackend(), dialogs: dialogs, command: .object(command))
    }

    func testSaveToCopiesTheExportToThePathTheDialogApproved() async throws {
        let library = OneExportLibrary(status: "complete", output: output)
        let dialogs = SaveDialogScript(["/home/editor/Final cut.mp4"])
        let result = try await saveTo(library, dialogs)
        XCTAssertEqual(library.saves, [.init(libraryId: "L", jobId: "J", destination: "/home/editor/Final cut.mp4", overwrite: true)])
        XCTAssertEqual(dialogs.asked.first?.defaultPath, "render-1.mp4")
        XCTAssertEqual(dialogs.asked.first?.filters.first?.extensions, ["mp4"])
        XCTAssertEqual(result["errors"], .array([]))
    }

    /// GTK and the Windows item dialog return the name as typed: the export's extension is added, and because the dialog
    /// asked about replacing the typed name, not that path, an existing file there must be kept (overwrite false).
    func testSaveToAddsTheExtensionAndNeverReplacesAFileTheDialogDidNotAskAbout() async throws {
        let library = OneExportLibrary(status: "complete", output: output)
        _ = try await saveTo(library, SaveDialogScript(["/home/editor/Final cut"]))
        _ = try await saveTo(library, SaveDialogScript(["/home/editor/final.v2"]))
        XCTAssertEqual(library.saves, [
            .init(libraryId: "L", jobId: "J", destination: "/home/editor/Final cut.mp4", overwrite: false),
            .init(libraryId: "L", jobId: "J", destination: "/home/editor/final.v2.mp4", overwrite: false),
        ])
    }

    func testSaveToKeepsAnExtensionTypedInAnotherLetterCase() async throws {
        let library = OneExportLibrary(status: "complete", output: output)
        _ = try await saveTo(library, SaveDialogScript(["/home/editor/FINAL.MP4"]))
        XCTAssertEqual(library.saves, [.init(libraryId: "L", jobId: "J", destination: "/home/editor/FINAL.MP4", overwrite: true)])
    }

    func testSaveToCancelledOrEmptyWritesNothing() async throws {
        let library = OneExportLibrary(status: "complete", output: output)
        _ = try await saveTo(library, SaveDialogScript([nil]))
        _ = try await saveTo(library, SaveDialogScript([""]))
        XCTAssertEqual(library.saves, [])
    }

    func testSaveToRefusesAnExportThatIsNotCompleteWithoutOpeningTheDialog() async throws {
        await assertRefused(OneExportLibrary(status: "rendering", output: ""))
        await assertRefused(OneExportLibrary(status: "failed", output: ""))
        await assertRefused(OneExportLibrary(status: "interrupted", output: output))
        await assertRefused(OneExportLibrary(status: "complete", output: ""))
    }

    private func assertRefused(_ library: OneExportLibrary, line: UInt = #line) async {
        let dialogs = SaveDialogScript(["/home/editor/out.mp4"])
        do { _ = try await saveTo(library, dialogs); XCTFail("expected an error", line: line) }
        catch { XCTAssertEqual((error as? DesktopError)?.message, "Export is not complete", line: line) }
        XCTAssertEqual(dialogs.asked, [], line: line)
        XCTAssertEqual(library.saves, [], line: line)
    }
}
