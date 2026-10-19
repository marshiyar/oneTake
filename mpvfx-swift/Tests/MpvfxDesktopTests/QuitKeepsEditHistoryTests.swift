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

/// Issue #27: the undo history is written on a worker after every edit, so an edit made just before quitting
/// must still reach `<userData>/edit-history/` before the app exits. The quit runs through the same lifecycle and
/// save barrier the shells use, answered by the shells' prepareClose call (`flushForClose`); the relaunch is a new
/// backend and session on the same user data and project.
final class QuitKeepsEditHistoryTests: XCTestCase {
    /// The shells' EditorSaveChannel, answering synchronously instead of through the toolkit's main-loop hop.
    final class SessionCloseChannel: EditorSaveChannel {
        let session: EditorSession
        var barrier: SaveBarrier?
        init(_ session: EditorSession) { self.session = session }
        var isLoading: Bool { false }
        func prepareClose(id: String) { barrier?.closePrepared(id: .string(id), error: session.flushForClose().map { .string($0) } ?? .null) }
        func cancelClose(id: String) {}
    }

    var dirs: [String] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(atPath: d) } }

    func temporaryDirectory() throws -> String {
        let d = NSTemporaryDirectory() + "mpvfx-quit-history-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    /// One app run on `userData`: the session the shells create for `projectDirectory`, with its shell installed.
    func launch(userData: String, projectDirectory: String) throws -> (RuntimeDesktopBackend, EditorSession) {
        let backend = RuntimeDesktopBackend(userData: userData)
        let session = try EditorSession(backend: backend, projectPath: projectDirectory)
        _ = session.installShell(userData: userData) {}
        return (backend, session)
    }

    func testAnEditMadeJustBeforeQuittingIsOfferedByUndoAfterRelaunch() throws {
        let userData = try temporaryDirectory()
        let projectDirectory = try temporaryDirectory() + "/Quit"
        _ = try RuntimeDesktopBackend(userData: userData).createProject(name: "Quit", directory: projectDirectory)

        let (backend, session) = try launch(userData: userData, projectDirectory: projectDirectory)
        // The session's own store and file, with each write held until a closer waits for it: without the wait
        // at quit the write is still held when the app quits, so the check below cannot pass by winning a race.
        let projectId = try XCTUnwrap(session.project?.id)
        let store = FileTimelineHistoryStore(directory: URL(fileURLWithPath: userData).appendingPathComponent("edit-history"))
        let release = DispatchSemaphore(value: 0)
        let held = TimelineHistoryPersister { h in release.wait(); store.save(projectId: projectId, h) }
        held.onWait = { release.signal() }
        session.editHistory = held
        defer { release.signal(); held.waitUntilIdle() }   // a held write never outlives the test
        let before = session.editor.document.canvas
        XCTAssertTrue(session.editor.setCanvasSize(width: before.width / 2, height: before.height / 2))
        XCTAssertEqual(session.editor.undoLabel, "Set composition size")

        // Quit at once, as File > Quit or SIGTERM does: lifecycle -> save barrier -> prepareClose.
        let channel = SessionCloseChannel(session)
        let host = NativeSaveBarrierHost(editor: channel) { _, _ in {} }
        let barrier = SaveBarrier(host: host)
        channel.barrier = barrier
        var actions: [ShellAction] = []
        var historyAtQuit: String?
        let lifecycle = ShellLifecycle(barrier: barrier) { action in
            actions.append(action)
            // The shells close the backend and exit right after .destroyWindowAndQuit (the only action asserted
            // below): what is not on disk when it is performed is lost.
            historyAtQuit = store.load(projectId: projectId)?.undo.last?.label
        }
        lifecycle.windowCreated()
        lifecycle.quitRequested()
        XCTAssertEqual(actions, [.destroyWindowAndQuit])
        XCTAssertEqual(historyAtQuit, "Set composition size", "the history file holds the edit when the app quits")
        backend.closeProject(id: projectId)

        let (_, relaunched) = try launch(userData: userData, projectDirectory: projectDirectory)
        XCTAssertEqual(relaunched.editor.document.canvas.width, before.width / 2, "the project itself was saved")
        XCTAssertEqual(relaunched.editor.undoLabel, "Set composition size", "Undo offers the edit made just before quitting")
        XCTAssertTrue(relaunched.editor.undo())
        XCTAssertEqual(relaunched.editor.document.canvas.width, before.width)
    }
}
#endif
