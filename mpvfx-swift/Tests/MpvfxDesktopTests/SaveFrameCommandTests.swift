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
import MpvfxPanels
@testable import MpvfxDesktop

final class SaveFrameCommandTests: XCTestCase {
    final class CancelSave: NativeDialogs, @unchecked Sendable {
        var asked: [SaveDialogOptions] = []
        func showSave(_ options: SaveDialogOptions) async -> String? { asked.append(options); return nil }
        func showOpen(_ options: OpenDialogOptions) async -> [String] { [] }
        func showError(title: String, message: String) async {}
        func openPath(_ path: String) async {}
    }

    /// A3: the File command and shortcut work without selection, and cancellation cannot edit the project.
    func testShortcutOpensSaveFrameWithNoSelectionAndCancelLeavesDocumentUnchanged() throws {
        let root = NSTemporaryDirectory() + "mpvfx-frame-command-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let backend = RuntimeDesktopBackend(userData: root + "/user")
        let project = try backend.createProject(name: "My project", directory: root + "/My project")
        let session = try EditorSession(backend: backend, projectPath: project.directory)
        _ = session.installShell(userData: root + "/user") {}
        let dialogs = CancelSave()
        session.panels?.dialogs = dialogs
        let document = session.editor.document
        XCTAssertTrue(session.timeline.view.selection.isEmpty)
        XCTAssertTrue(session.commandKey(EditorKey(.char("e"), shift: true, ctrl: true)))
        let deadline = Date().addingTimeInterval(10)
        while dialogs.asked.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let options = try XCTUnwrap(dialogs.asked.first)
        XCTAssertEqual(options.title, "Save frame")
        XCTAssertEqual(options.defaultPath, "My project 00-00-00-00.jpg")
        XCTAssertEqual(options.filters, [.init(name: "JPEG image", extensions: ["jpg", "jpeg"])])
        XCTAssertEqual(session.editor.document, document)
        XCTAssertFalse(session.commandKey(EditorKey(.char("e"), ctrl: true)))
        let file = try XCTUnwrap(MenuModel.bar(for: .macOS).first { $0.label == "File" })
        let item = try XCTUnwrap(file.items.first { $0.command == .saveFrame })
        XCTAssertEqual(item.key, "e"); XCTAssertEqual(item.modifiers, [.command, .shift])
        XCTAssertTrue(shortcutSections.flatMap(\.hints).contains { $0.key == "⇧⌘E" && $0.label.contains("Save frame") })
    }
}
#endif
