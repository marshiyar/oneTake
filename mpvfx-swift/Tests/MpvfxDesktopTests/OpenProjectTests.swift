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

/// Issue #31: Cmd/Ctrl+O opens any project folder through the native folder dialog, and the projects opened before
/// are offered again (File > Open Recent on macOS, the left sidebar's "Recent" everywhere).
final class OpenProjectTests: XCTestCase {
    /// The shells' folder dialog, answering with a fixed choice.
    final class ChosenFolder: NativeDialogs, @unchecked Sendable {
        let choice: [String]
        private(set) var asked: [OpenDialogOptions] = []
        init(_ choice: [String]) { self.choice = choice }
        func showSave(_ options: SaveDialogOptions) async -> String? { nil }
        func showOpen(_ options: OpenDialogOptions) async -> [String] { asked.append(options); return choice }
        func showError(title: String, message: String) async {}
        func openPath(_ path: String) async {}
    }

    var dirs: [String] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(atPath: d) } }

    func temporaryDirectory() throws -> String {
        let d = NSTemporaryDirectory() + "mpvfx-open-project-\(UUID().uuidString)"
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

    func testCtrlOOpensAChosenProjectFolderAndRecentsOfferTheOthers() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let setup = RuntimeDesktopBackend(userData: userData)
        let alpha = try setup.createProject(name: "Alpha", directory: root + "/Alpha")
        let beta = try setup.createProject(name: "Beta", directory: root + "/Elsewhere/Beta")
        let dialogs = ChosenFolder([beta.directory])
        let session = try launch(userData: userData, projectDirectory: alpha.directory, dialogs: dialogs)
        var errors: [String] = []
        session.onError = { title, message in errors.append("\(title): \(message)") }
        XCTAssertEqual(session.project?.directory, alpha.directory)

        XCTAssertTrue(session.commandKey(EditorKey(.char("o"), ctrl: true)))
        waitUntil("Ctrl+O opens the chosen folder") { session.project?.directory == beta.directory }
        XCTAssertEqual(dialogs.asked, [OpenDialogOptions(title: "Open Project", directory: true, multiple: false)])
        XCTAssertEqual(session.project?.content, beta.content)
        XCTAssertEqual(session.recentProjects.map(\.title), ["Alpha"], "the open project is left out of the recent list")
        waitUntil("the sidebar lists the recent projects") { session.panels?.left.library.recentProjects.map(\.name) == ["Alpha"] }

        // A folder without .studio/project.json is refused and the open project stays.
        session.openProject(path: root)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.hasPrefix("Could not open the project") == true, "\(errors)")
        XCTAssertEqual(session.project?.directory, beta.directory)

        // The sidebar's Recent list opens a project by its folder.
        session.panels?.runLibrary(.openRecentProject(alpha.directory))
        XCTAssertEqual(session.project?.directory, alpha.directory)
        waitUntil("the recent list follows the switch") { session.panels?.left.library.recentProjects.map(\.name) == ["Beta"] }

        session.clearRecentProjects()
        XCTAssertEqual(session.recentProjects, [])
    }

    /// A recent-list refresh started before a switch arrives after it: it was filtered for the project open then, so it is
    /// dropped instead of listing the project now open.
    func testAStaleRecentRefreshIsDropped() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let setup = RuntimeDesktopBackend(userData: userData)
        let alpha = try setup.createProject(name: "Alpha", directory: root + "/Alpha")
        let beta = try setup.createProject(name: "Beta", directory: root + "/Beta")
        let session = try launch(userData: userData, projectDirectory: alpha.directory, dialogs: nil)
        var held: [() -> Void] = []
        let lock = NSLock()
        session.postToUI = { body in lock.withLock { held.append(body) } }
        session.panels?.refreshRecents()   // filtered for Alpha: lists Beta
        waitUntil("the refresh finished in the background") { lock.withLock { !held.isEmpty } }
        let stale = lock.withLock { held.removeFirst() }

        session.postToUI = { body in DispatchQueue.main.async(execute: body) }
        session.openProject(path: beta.directory)
        waitUntil("the switch lists Alpha") { session.panels?.left.library.recentProjects.map(\.name) == ["Alpha"] }
        stale()
        XCTAssertEqual(session.panels?.left.library.recentProjects.map(\.name), ["Alpha"], "the open project is never listed")
    }

    func testCtrlOIsNotTakenWithoutADialog() throws {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let alpha = try RuntimeDesktopBackend(userData: userData).createProject(name: "Alpha", directory: root + "/Alpha")
        let session = try launch(userData: userData, projectDirectory: alpha.directory, dialogs: nil)
        XCTAssertFalse(session.commandKey(EditorKey(.char("o"), ctrl: true)))
    }
}
#endif
