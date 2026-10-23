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
    import MpvfxBackend
    import MpvfxDesktopCore
    import MpvfxPanels
    import MpvfxShared
    import MpvfxTimeline
    import XCTest
    @testable import MpvfxDesktop

    internal final class SaveFrameCommandTests: XCTestCase {
        private final class CancelSave: NativeDialogs, @unchecked Sendable {
            internal var asked: [SaveDialogOptions] = []
            internal func showSave(_ options: SaveDialogOptions) async -> String? {
                asked.append(options)
                return nil
            }
            internal func showOpen(_: OpenDialogOptions) async -> [String] { [] }
            internal func showError(title _: String, message _: String) async {
                // Cancellation never presents an error in this test double.
            }
            internal func openPath(_: String) async {
                // Saving a still never opens a path in this test double.
            }
        }

        /// A3: the File command and shortcut work without selection, and cancellation cannot edit the project.
        internal func testShortcutOpensSaveFrameWithNoSelectionAndCancelLeavesDocumentUnchanged() throws {
            let root: String = NSTemporaryDirectory() + "mpvfx-frame-command-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: root) }
            let backend: RuntimeDesktopBackend = RuntimeDesktopBackend(userData: root + "/user")
            let project: DesktopProject = try backend.createProject(name: "My project", directory: root + "/My project")
            let session: EditorSession = try EditorSession(backend: backend, projectPath: project.directory)
            _ = session.installShell(userData: root + "/user") {
                // This command test does not run a shell redraw loop.
            }
            let dialogs: CancelSave = CancelSave()
            session.panels?.dialogs = dialogs
            let document: NativeProjectDocument = session.editor.document
            XCTAssertTrue(session.timeline.view.selection.isEmpty)
            XCTAssertTrue(session.commandKey(EditorKey(.char("e"), shift: true, ctrl: true)))
            let deadline: Date = Date().addingTimeInterval(10)
            while dialogs.asked.isEmpty && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let options: SaveDialogOptions = try XCTUnwrap(dialogs.asked.first)
            XCTAssertEqual(options.title, "Save frame")
            XCTAssertEqual(options.defaultPath, "My project 00-00-00-00.jpg")
            XCTAssertEqual(options.filters, [.init(name: "JPEG image", extensions: ["jpg", "jpeg"])])
            XCTAssertEqual(session.editor.document, document)
            XCTAssertFalse(session.commandKey(EditorKey(.char("e"), ctrl: true)))
            let file: Menu = try XCTUnwrap(MenuModel.bar(for: .macOS).first { $0.label == "File" })
            let item: MenuItem = try XCTUnwrap(file.items.first { $0.command == .saveFrame })
            XCTAssertEqual(item.key, "e")
            XCTAssertEqual(item.modifiers, [.command, .shift])
            XCTAssertTrue(
                shortcutSections.flatMap(\.hints).contains { $0.key == "⇧⌘E" && $0.label.contains("Save frame") }
            )
        }
    }
#endif
