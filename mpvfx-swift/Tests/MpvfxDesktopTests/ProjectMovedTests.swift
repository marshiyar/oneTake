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
import MpvfxTimeline
@testable import MpvfxDesktop

/// Issue #101: the open project's folder is moved or deleted. The session says so plainly with "Locate Folder…" and
/// "Keep Editing", stops autosaving into nothing, and "Locate Folder…" adopts the moved copy without losing the edits.
final class ProjectMovedTests: XCTestCase {
    /// The shells' folder dialog, answering with a fixed choice.
    final class ChosenFolder: NativeDialogs, @unchecked Sendable {
        var choice: [String]
        private(set) var asked: [OpenDialogOptions] = []
        init(_ choice: [String]) { self.choice = choice }
        func showSave(_ options: SaveDialogOptions) async -> String? { nil }
        func showOpen(_ options: OpenDialogOptions) async -> [String] { asked.append(options); return choice }
        func showError(title: String, message: String) async {}
        func openPath(_ path: String) async {}
    }

    /// What the session asked the shell: the moved-folder prompts, the external-change dialogs and the errors.
    final class Shell {
        var movedPrompts: [String] = []
        var conflicts = 0
        var errors: [String] = []
        var locate = false
        var keepMine = true
        var scheduled: [() -> Void] = []
        init(_ session: EditorSession) {
            // Weak: a session outlives its test (its watch still polls the folder tearDown removes).
            session.onProjectMoved = { [weak self] message, answer in
                guard let self else { return }
                movedPrompts.append(message); answer(locate)
            }
            session.onExternalConflict = { [weak self] answer in
                guard let self else { return }
                conflicts += 1; answer(keepMine)
            }
            session.onError = { [weak self] title, message in self?.errors.append("\(title): \(message)") }
            session.schedule = { [weak self] _, body in self?.scheduled.append(body); return {} }
        }
        /// Runs the autosave timers the session armed.
        func fireTimers() { let due = scheduled; scheduled = []; for body in due { body() } }
    }

    var dirs: [String] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(atPath: d) } }

    func temporaryDirectory() throws -> String {
        let d = NSTemporaryDirectory() + "mpvfx-project-moved-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return (d as NSString).resolvingSymlinksInPath
    }

    /// The session the shells create, with the shell installed and UI work hopping through the main queue.
    func launch(userData: String, projectDirectory: String, dialogs: NativeDialogs?) throws -> EditorSession {
        let session = try EditorSession(backend: RuntimeDesktopBackend(userData: userData), projectPath: projectDirectory)
        session.postToUI = { body in DispatchQueue.main.async(execute: body) }
        _ = session.installShell(userData: userData) {}
        session.panels?.dialogs = dialogs
        return session
    }

    func waitUntil(_ what: String, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done(), what)
    }

    /// Lets work already posted to the main queue run (the session's UI hops), without waiting on time.
    func drainMain() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func documentText(_ dir: String) throws -> String {
        try String(contentsOfFile: dir + "/.studio/project.json", encoding: .utf8)
    }

    /// Halves the composition size: one undoable edit that makes the session dirty.
    func edit(_ session: EditorSession) {
        let c = session.editor.document.canvas
        XCTAssertTrue(session.editor.setCanvasSize(width: c.width / 2, height: c.height / 2))
    }

    /// Acceptance: a save into the vanished folder pauses autosave and shows one message with "Locate Folder…" and
    /// "Keep Editing", never the external-change dialog; the save error names the folder.
    func testASaveIntoTheVanishedFolderPausesAutosaveAndAsksOnce() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let created = try RuntimeDesktopBackend(userData: userData).createProject(name: "Film", directory: root + "/Film")
        let session = try launch(userData: userData, projectDirectory: created.directory, dialogs: nil)
        let shell = Shell(session)
        edit(session)
        try FileManager.default.moveItem(atPath: created.directory, toPath: root + "/Film moved")

        shell.fireTimers()   // the autosave armed by the edit writes into the vanished folder
        waitUntil("the failed autosave asks about the folder") { shell.movedPrompts.count == 1 }
        XCTAssertTrue(shell.movedPrompts[0].contains("The project folder \(created.directory) was moved or deleted"), "\(shell.movedPrompts)")
        XCTAssertTrue(session.projectFolderMissing)
        XCTAssertEqual(shell.conflicts, 0, "never the external-change dialog")
        XCTAssertEqual(shell.errors, [], "one message, not a second error box")

        // Autosave is paused: further edits arm no write that could ask again.
        edit(session)
        shell.fireTimers()
        drainMain()
        session.saveQueue.sync {}
        drainMain()
        XCTAssertEqual(shell.movedPrompts.count, 1, "autosave does not ask again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.directory), "nothing recreates the old folder")
        XCTAssertTrue(session.isDirty, "the edits are kept in memory")

        // Cmd/Ctrl+S asks again (the user chose to save), still without the conflict dialog or an error box.
        XCTAssertTrue(session.commandKey(EditorKey(.char("s"), ctrl: true)))
        XCTAssertEqual(shell.movedPrompts.count, 2)
        XCTAssertEqual(shell.conflicts, 0)
        XCTAssertEqual(shell.errors, [])
    }

    /// The watch reports the vanished folder by itself (within its one-second poll), before any save: the same prompt.
    func testTheWatchReportsAVanishedFolderWithTheSamePrompt() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let created = try RuntimeDesktopBackend(userData: userData).createProject(name: "Film", directory: root + "/Film")
        let session = try launch(userData: userData, projectDirectory: created.directory, dialogs: nil)
        let shell = Shell(session)
        try FileManager.default.removeItem(atPath: created.directory)
        waitUntil("the watch reports the missing folder") { shell.movedPrompts.count == 1 }
        XCTAssertTrue(session.projectFolderMissing)
        XCTAssertEqual(shell.conflicts, 0)
        XCTAssertEqual(shell.errors, [])
    }

    /// Acceptance: "Locate Folder…" on the moved copy adopts it and saves the in-memory document there, keeping the edits
    /// and the undo history, when the located document is the one last saved.
    func testLocateFolderAdoptsTheMovedCopyAndKeepsEditsAndUndo() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let created = try RuntimeDesktopBackend(userData: userData).createProject(name: "Film", directory: root + "/Film")
        let movedDir = root + "/Archive/Film"
        let dialogs = ChosenFolder([movedDir])
        let session = try launch(userData: userData, projectDirectory: created.directory, dialogs: dialogs)
        let shell = Shell(session)
        let width = session.editor.document.canvas.width
        edit(session)
        try FileManager.default.createDirectory(atPath: root + "/Archive", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: created.directory, toPath: movedDir)

        shell.locate = true
        XCTAssertTrue(session.commandKey(EditorKey(.char("s"), ctrl: true)))
        waitUntil("the session follows the located folder") { session.project?.directory == movedDir && !session.isDirty }
        XCTAssertEqual(dialogs.asked, [OpenDialogOptions(title: "Locate Project Folder", directory: true, multiple: false)])
        XCTAssertFalse(session.projectFolderMissing)
        XCTAssertEqual(session.editor.document.canvas.width, width / 2, "the edit is kept")
        XCTAssertEqual(session.editor.undoLabel, "Set composition size", "the undo history is kept")
        XCTAssertEqual(try documentText(movedDir), session.project?.content, "the in-memory document was saved in the new folder")
        XCTAssertTrue(try documentText(movedDir).contains("\(Int(width / 2))"))
        XCTAssertEqual(shell.conflicts, 0)
        XCTAssertEqual(shell.errors, [])

        // Saving and watching continue in the new folder.
        edit(session)
        XCTAssertTrue(session.commandKey(EditorKey(.char("s"), ctrl: true)))
        XCTAssertEqual(try documentText(movedDir), session.project?.content)
        XCTAssertEqual(session.recentProjects.map(\.directory), [], "the old folder left the recent list")
    }

    /// A failed autosave or a watch event about the old folder that arrives after "Locate Folder…" succeeded is stale: it
    /// neither pauses autosave again nor asks (review on #141).
    func testAFailureFromTheOldFolderDeliveredAfterRelocationIsIgnored() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let created = try RuntimeDesktopBackend(userData: userData).createProject(name: "Film", directory: root + "/Film")
        let movedDir = root + "/Film moved"
        let session = try launch(userData: userData, projectDirectory: created.directory, dialogs: nil)
        let shell = Shell(session)
        edit(session)
        try FileManager.default.moveItem(atPath: created.directory, toPath: movedDir)

        // Hold every UI hop: the autosave's failure (and any watch event) waits until after the relocation.
        let lock = NSLock()
        var held: [() -> Void] = []
        session.postToUI = { body in lock.withLock { held.append(body) } }
        shell.fireTimers()
        session.saveQueue.sync {}
        XCTAssertFalse(lock.withLock { held.isEmpty }, "the autosave result is held")

        session.postToUI = { body in DispatchQueue.main.async(execute: body) }
        session.locateProjectFolder(path: movedDir)
        XCTAssertEqual(session.project?.directory, movedDir)
        XCTAssertFalse(session.isDirty, "the relocation saved the edit in the new folder")

        for body in lock.withLock({ held }) { body() }
        drainMain()
        XCTAssertFalse(session.projectFolderMissing, "a stale failure does not pause autosave again")
        XCTAssertEqual(shell.movedPrompts, [], "nor does it ask")
        XCTAssertEqual(shell.errors, [])
        XCTAssertEqual(shell.conflicts, 0)
    }

    /// Acceptance: when the located document differs from the last saved one, the user gets the normal conflict choice.
    func testLocatingAChangedDocumentOffersTheConflictChoice() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let created = try RuntimeDesktopBackend(userData: userData).createProject(name: "Film", directory: root + "/Film")
        let movedDir = root + "/Film 2"
        let session = try launch(userData: userData, projectDirectory: created.directory, dialogs: ChosenFolder([movedDir]))
        let shell = Shell(session)
        edit(session)
        try FileManager.default.moveItem(atPath: created.directory, toPath: movedDir)
        let changed = try renamed(try documentText(movedDir), to: "Film (theirs)")
        try changed.write(toFile: movedDir + "/.studio/project.json", atomically: true, encoding: .utf8)

        shell.keepMine = false
        session.locateProjectFolder(path: movedDir)
        XCTAssertEqual(shell.conflicts, 1, "the normal external-change choice")
        XCTAssertEqual(session.project?.directory, movedDir)
        XCTAssertEqual(session.editor.document.sequence.name, "Film (theirs)", "Use the File on Disk loads the located document")
        XCTAssertEqual(try documentText(movedDir), changed, "nothing was written over it")
        XCTAssertEqual(shell.errors, [])
    }

    /// A folder that is not a project is refused; the session stays paused on the vanished one.
    func testLocatingAFolderThatIsNotAProjectIsRefused() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let created = try RuntimeDesktopBackend(userData: userData).createProject(name: "Film", directory: root + "/Film")
        let session = try launch(userData: userData, projectDirectory: created.directory, dialogs: nil)
        let shell = Shell(session)
        edit(session)
        try FileManager.default.removeItem(atPath: created.directory)
        XCTAssertTrue(session.commandKey(EditorKey(.char("s"), ctrl: true)))
        session.locateProjectFolder(path: root)
        XCTAssertEqual(shell.errors.count, 1)
        XCTAssertTrue(shell.errors.first?.hasPrefix("Could not use that folder") == true, "\(shell.errors)")
        XCTAssertTrue(session.projectFolderMissing)
        XCTAssertEqual(session.project?.directory, created.directory)
    }

    /// Acceptance: media paths resolve against the new folder after relocation (one image clip).
    func testMediaResolvesAgainstTheNewFolderAfterRelocation() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let backend = RuntimeDesktopBackend(userData: userData)
        let created = try backend.createProject(name: "Film", directory: root + "/Film")
        try FileManager.default.createDirectory(atPath: created.directory + "/media", withIntermediateDirectories: true)
        try Data("still".utf8).write(to: URL(fileURLWithPath: created.directory + "/media/still.png"))
        try backend.saveProject(id: created.id, content: try withOneImageClip(created.content))
        backend.closeProject(id: created.id)

        let movedDir = root + "/Moved Film"
        let session = try launch(userData: userData, projectDirectory: created.directory, dialogs: nil)
        let shell = Shell(session)
        XCTAssertEqual(session.compositor.composition?.entries.map(\.path), [created.directory + "/media/still.png"])
        try FileManager.default.moveItem(atPath: created.directory, toPath: movedDir)
        session.locateProjectFolder(path: movedDir)
        XCTAssertEqual(session.project?.directory, movedDir)
        XCTAssertEqual(session.compositor.composition?.entries.map(\.path), [movedDir + "/media/still.png"])
        XCTAssertEqual(session.absoluteMediaPath("media/still.png"), movedDir + "/media/still.png")
        XCTAssertEqual(shell.errors, [])
    }

    /// `content` with its sequence named `name`: an edit made to the moved copy outside the app.
    func renamed(_ content: String, to name: String) throws -> String {
        var doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        var sequence = try XCTUnwrap(doc["sequence"] as? [String: Any])
        sequence["name"] = name
        doc["sequence"] = sequence
        return String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)
    }

    /// The starter document with one image asset (natural size cached, so it is drawn at once) placed on a video track.
    func withOneImageClip(_ content: String) throws -> String {
        var doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        doc["assets"] = [["id": "asset:still", "kind": "image", "name": "still.png", "source": "media/still.png",
                          "durationFrames": 150, "width": 64, "height": 32]]
        var sequence = try XCTUnwrap(doc["sequence"] as? [String: Any])
        sequence["tracks"] = [["id": "track:v1", "kind": "video", "clips": [[
            "id": "clip:still", "assetId": "asset:still", "startFrame": 0, "durationFrames": 60, "sourceInFrame": 0, "muted": false,
            "playbackRate": ["numerator": 1, "denominator": 1], "staticParameters": [:] as [String: Any],
            "effects": [] as [Any], "parameterTracks": [] as [Any]]]]]
        doc["sequence"] = sequence
        return String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)
    }
}
#endif
