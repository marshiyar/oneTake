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
import MpvfxTimeline
import MpvfxCanvas
import MpvfxPanels
import MpvfxTheme
@testable import MpvfxDesktop

final class AutosaveFailureTests: XCTestCase {
    /// Mutable injection is locked because saves run on the session's worker queue.
    private final class FailingWrite: DurableWrite, @unchecked Sendable {
        let base = NativeDurableWrite()
        let lock = NSLock()
        private var error: DesktopError?
        private var failures = 0
        var failedWrites: Int { lock.withLock { failures } }
        func fail(_ error: DesktopError?) { lock.withLock { self.error = error } }
        func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
            let failure = lock.withLock { () -> DesktopError? in
                if error != nil { failures += 1 }
                return error
            }
            if let failure { throw failure }
            try base.write(data, to: path, tempName: tempName, preserveMode: preserveMode, beforeRename: beforeRename)
        }
        func syncDirectory(_ path: String) throws { try base.syncDirectory(path) }
    }

    private final class Run {
        let root = NSTemporaryDirectory() + "mpvfx-autosave-failure-\(UUID().uuidString)"
        let writer = FailingWrite()
        let backend: RuntimeDesktopBackend
        let session: EditorSession
        let lock = NSLock()
        var posted: [() -> Void] = []
        var timer: (() -> Void)?
        var errors: [String] = []
        var stateChanges = 0
        init() throws {
            backend = RuntimeDesktopBackend(userData: root + "/user", durableWrite: writer)
            let project = try backend.createProject(name: "My Film", directory: root + "/Film")
            session = try EditorSession(backend: backend, projectPath: project.directory)
            session.postToUI = { [weak self] body in
                guard let self else { return }
                self.lock.withLock { self.posted.append(body) }
            }
            session.schedule = { [weak self] delay, body in
                XCTAssertEqual(delay, EditorSession.autosaveDelay)
                self?.timer = body
                return { [weak self] in self?.timer = nil }
            }
            session.onError = { [weak self] _, message in self?.errors.append(message) }
            session.documentStateChanged = { [weak self] in self?.stateChanges += 1 }
            writer.fail(DesktopError(saveFailure: .diskFull, folder: project.directory))
        }
        deinit {
            session.saveQueue.sync {}
            if let id = session.project?.id { backend.closeProject(id: id) }
            try? FileManager.default.removeItem(atPath: root)
        }
        func edit() {
            let canvas = session.editor.document.canvas
            XCTAssertTrue(session.editor.setCanvasSize(width: canvas.width + 10, height: canvas.height))
        }
        func startSave() throws {
            let fire = try XCTUnwrap(timer, "a later edit schedules a retry")
            timer = nil
            fire()
            session.saveQueue.sync {}   // the write and posting finished; the UI callback is deliberately held
        }
        func deliver() {
            let bodies = lock.withLock { () -> [() -> Void] in defer { posted = [] }; return posted }
            for body in bodies { body() }
        }
        func autosave() throws { try startSave(); deliver() }
    }

    func testTenFailuresShowOnceKeepEditsAndRetryUntilSuccess() throws {
        let run = try Run(), s = run.session
        let saved = s.savedDocument
        let originalContent = s.project?.content
        let router = s.installShell(userData: run.root + "/user") {}
        XCTAssertEqual(s.windowTitle, "My Film — MpVFX")
        XCTAssertEqual(s.markedWindowTitle, s.windowTitle)
        for _ in 0..<10 {
            run.edit()
            let edited = s.editor.document, attempts = run.writer.failedWrites
            XCTAssertTrue(s.isDirty)
            XCTAssertEqual(s.markedWindowTitle, "• My Film — MpVFX")
            try run.autosave()
            XCTAssertGreaterThan(run.writer.failedWrites, attempts)
            XCTAssertEqual(s.editor.document, edited, "a failed save never replaces the in-memory edit")
            XCTAssertEqual(s.savedDocument, saved)
            XCTAssertEqual(s.project?.content, originalContent)
            XCTAssertEqual(run.errors.count, 1)
            XCTAssertEqual(router.saveFailureStatus(), "Not saved: The disk is full")
        }
        XCTAssertGreaterThan(run.stateChanges, 0, "native titles are notified of edits and save outcomes")
        run.writer.fail(nil)
        run.edit()
        try run.autosave()
        XCTAssertFalse(s.isDirty)
        XCTAssertNil(s.lastSaveError)
        XCTAssertNil(router.saveFailureStatus())
        XCTAssertEqual(s.markedWindowTitle, "My Film — MpVFX")
        XCTAssertEqual(s.savedDocument, s.editor.document)
        run.writer.fail(DesktopError(saveFailure: .readOnly, folder: try XCTUnwrap(s.project?.directory)))
        run.edit()
        try run.autosave()
        XCTAssertEqual(run.errors.count, 2, "a successful save rearms the next failure alert")
        XCTAssertEqual(s.saveFailureStatus, "Not saved: The folder is read-only")
    }

    func testExplicitSavesShareFailureStatusAndAlertStreak() throws {
        let run = try Run(), s = run.session
        run.edit()
        let document = s.editor.document
        for _ in 0..<3 { XCTAssertTrue(s.commandKey(EditorKey(.char("s"), ctrl: true))) }
        XCTAssertEqual(run.errors.count, 1)
        XCTAssertEqual(s.saveFailureStatus, "Not saved: The disk is full")
        XCTAssertEqual(s.editor.document, document)
        try run.autosave()
        XCTAssertEqual(run.errors.count, 1, "autosave must not repeat the explicit save's alert")
        run.writer.fail(nil)
        try s.save()
        XCTAssertNil(s.saveFailureStatus)
        XCTAssertFalse(s.isDirty)
        run.writer.fail(DesktopError(saveFailure: .diskFull, folder: try XCTUnwrap(s.project?.directory)))
        run.edit()
        try run.autosave()
        XCTAssertEqual(run.errors.count, 2)
    }

    func testStaleAutosaveFailureCannotUndoExplicitSaveSuccess() throws {
        let run = try Run(), s = run.session
        run.edit()
        try run.startSave()   // failure is waiting to be delivered
        run.writer.fail(nil)
        try s.save()
        run.deliver()
        XCTAssertNil(s.saveFailureStatus)
        XCTAssertFalse(s.isDirty)
        XCTAssertEqual(run.errors, [])
    }

    func testSavingAnOlderSnapshotKeepsNewerEditsDirty() throws {
        let run = try Run(), s = run.session
        run.writer.fail(nil)
        run.edit()
        let snapshot = s.editor.document
        try run.startSave()
        run.edit()
        let latest = s.editor.document
        run.deliver()
        XCTAssertEqual(s.savedDocument, snapshot)
        XCTAssertEqual(s.editor.document, latest)
        XCTAssertTrue(s.isDirty)
        XCTAssertEqual(s.markedWindowTitle, "• My Film — MpVFX")
        try run.autosave()
        XCTAssertFalse(s.isDirty)
    }

    func testAdoptingAProjectClearsFailureAndUpdatesTitle() throws {
        let run = try Run(), s = run.session
        run.edit()
        try run.autosave()
        run.writer.fail(nil)
        let next = try run.backend.createProject(name: "Next Film", directory: run.root + "/Next")
        try s.adoptProject(next)
        XCTAssertNil(s.saveFailureStatus)
        XCTAssertFalse(s.isDirty)
        XCTAssertEqual(s.windowTitle, "Next Film — MpVFX")
        XCTAssertEqual(s.markedWindowTitle, s.windowTitle)
    }

    func testFailureStatusOverridesHoverHintInBothThemes() throws {
        let run = try Run(), s = run.session
        run.edit()
        try run.autosave()
        let canvas = PanelMeasureCanvas()
        let rect = CanvasRect(x: 0, y: 0, width: 1440, height: ShellStatusLine.height)
        let previousMode = Theme.mode
        defer { Theme.setMode(previousMode) }
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            canvas.reset()
            ShellStatusLine.draw(canvas, rect, hint: "Drag to resize the panels", error: s.saveFailureStatus)
            XCTAssertEqual(canvas.drawnStrings, ["Not saved: The disk is full"])
            XCTAssertEqual(canvas.texts.first?.3, PanelTheme.danger)
        }
        run.writer.fail(nil)
        try s.save()
        canvas.reset()
        ShellStatusLine.draw(canvas, rect, hint: "Drag to resize the panels", error: s.saveFailureStatus)
        XCTAssertEqual(canvas.drawnStrings, ["Drag to resize the panels"])
        XCTAssertEqual(canvas.texts.first?.3, PanelTheme.text2)
    }
}
