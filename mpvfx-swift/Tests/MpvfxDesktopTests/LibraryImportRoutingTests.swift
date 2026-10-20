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
import MpvfxPanels
@testable import MpvfxDesktop

/// Runs the sidebar import command through the real dialogs/commands/backend/catalog path.
final class LibraryImportRoutingTests: XCTestCase {
    private actor ImportDialogs: NativeDialogs {
        let paths: [String]
        var requests: [OpenDialogOptions] = []
        init(paths: [String]) { self.paths = paths }
        func showOpen(_ options: OpenDialogOptions) async -> [String] { requests.append(options); return paths }
        func showSave(_ options: SaveDialogOptions) async -> String? { nil }
        func showError(title: String, message: String) async {}
        func openPath(_ path: String) async {}
    }

    private var roots: [String] = []
    private var backends: [RuntimeDesktopBackend] = []

    override func tearDown() async throws {
        for backend in backends { try await backend.close() }
        backends.removeAll()
        for root in roots { try FileManager.default.removeItem(atPath: root) }
        roots.removeAll()
    }

    @MainActor
    private func checkImport(linked: Bool, sameLibrary: Bool = false, standalone: Bool = false,
                             cancelled: Bool = false) async throws {
        let root = NSTemporaryDirectory() + "mpvfx-import-routing-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        roots.append(root)
        let backend = RuntimeDesktopBackend(userData: root + "/settings")
        backends.append(backend)
        let libraries = try XCTUnwrap(backend.libraries)
        let a = try await libraries.create(root: root + "/A.mpvfxlibrary")
        let b = try await libraries.create(root: root + "/B.mpvfxlibrary")
        var views = try await backend.libraryViews()
        let eventA = try XCTUnwrap(views.first { $0.id == a }?.events.first?.id)
        let eventB = try XCTUnwrap(views.first { $0.id == b }?.events.first?.id)
        let projectA = try await libraries.createProject(libraryId: a, eventId: eventA, name: "Open edit")
        _ = try await libraries.createProject(libraryId: b, eventId: eventB, name: "Other edit")
        // A different event in the same library must still associate the import with the open project.
        let targetLibrary = sameLibrary ? a : b
        try await libraries.createEvent(libraryId: targetLibrary, name: "Selected event")
        views = try await backend.libraryViews()
        let targetEvent = try XCTUnwrap(views.first { $0.id == targetLibrary }?.events.first { $0.name == "Selected event" }?.id)
        let projectDirectory = try XCTUnwrap(views.first { $0.id == a }?.projects.first { $0.id == projectA }?.directory)
        let session = try EditorSession(backend: backend, projectPath: standalone ? nil : projectDirectory)
        session.postToUI = { body in DispatchQueue.main.async(execute: DispatchWorkItem(block: body)) }
        defer { session.redraw = {}; session.postToUI = { _ in } }
        let panels = SessionPanels(session: session, layout: PanelLayoutState(store: MemoryPanelPreferencesStore()), userData: root + "/settings")
        panels.applyLibraries(views, currentProjectId: standalone ? nil : projectA)
        let original = try XCTUnwrap(session.project)
        let document = session.editor.document
        XCTAssertEqual(try backend.listMedia(projectId: original.id, query: nil), [])
        let source = root + "/frame.png"
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1ioAAAAASUVORK5CYII="))
        try png.write(to: URL(fileURLWithPath: source))
        let dialogs = ImportDialogs(paths: cancelled ? [] : [source])
        panels.dialogs = dialogs
        let completed = expectation(description: "sidebar import completed")
        session.redraw = {
            if !panels.left.library.busy {
                session.redraw = {}
                completed.fulfill()
            }
        }
        // This is the command emitted after selecting B without switching A's open project.
        panels.runLibrary(.importIntoEvent(libraryId: targetLibrary, eventId: targetEvent, linked: linked))
        XCTAssertTrue(panels.left.library.busy)
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertFalse(panels.left.library.busy)
        XCTAssertNil(panels.left.library.error)
        XCTAssertEqual(session.project, original, "Import must not switch or modify the open project")
        XCTAssertEqual(session.editor.document, document)
        let requests = await dialogs.requests
        XCTAssertEqual(requests, [OpenDialogOptions(title: linked ? "Link Media" : "Import Media into Library", directory: false, multiple: true)])
        views = try await backend.libraryViews()
        let target = try XCTUnwrap(views.first { $0.id == targetLibrary })
        let other = try XCTUnwrap(views.first { $0.id != targetLibrary })
        XCTAssertEqual(other.assets, [], "No media may land in the other library")
        XCTAssertEqual(target.assets.count, cancelled ? 0 : 1)
        let shouldAttach = sameLibrary && !standalone && !cancelled
        if !cancelled, let asset = target.assets.first {
            XCTAssertEqual(asset.name, "frame.png")
            XCTAssertEqual(asset.eventId, targetEvent)
            XCTAssertEqual(asset.mode, linked ? "linked" : "managed")
            XCTAssertTrue(asset.ready)
            XCTAssertTrue(asset.available)
            XCTAssertEqual(asset.projectIds, shouldAttach ? [original.id] : [], "Event-only imports must have no project placement")
        }
        let media = try backend.listMedia(projectId: original.id, query: nil)
        XCTAssertEqual(media.count, shouldAttach ? 1 : 0)
        if let file = media.first {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: original.directory).appendingPathComponent(file.path)), png)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source)), png)
    }

    func testManagedImportIntoBWhileAProjectRemainsOpen() async throws { try await checkImport(linked: false) }
    func testLinkedImportIntoBWhileAProjectRemainsOpen() async throws { try await checkImport(linked: true) }
    func testManagedImportInSameLibraryAttachesToOpenProject() async throws { try await checkImport(linked: false, sameLibrary: true) }
    func testLinkedImportInSameLibraryAttachesToOpenProject() async throws { try await checkImport(linked: true, sameLibrary: true) }
    func testManagedImportWhileStandaloneProjectRemainsOpen() async throws { try await checkImport(linked: false, standalone: true) }
    func testLinkedImportWhileStandaloneProjectRemainsOpen() async throws { try await checkImport(linked: true, standalone: true) }
    func testCancelledManagedImportLeavesBothLibrariesUnchanged() async throws { try await checkImport(linked: false, cancelled: true) }
    func testCancelledLinkedImportLeavesBothLibrariesUnchanged() async throws { try await checkImport(linked: true, cancelled: true) }
}
