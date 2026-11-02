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
// The library navigator's "Delete event…" and "Delete project…" (issue #40): they ask first, say what goes, and send
// the command only when confirmed.
import XCTest
@testable import MpvfxPanels

final class LibraryDeleteNavigatorTests: XCTestCase {
    private let size = CanvasSize(370, 900)
    private func center(_ r: CanvasRect) -> CanvasPoint { CanvasPoint(r.midX, r.midY) }

    /// A library with two events, three projects (two in the shown event) and two media items in the shown event.
    private func navigator(_ cmds: @escaping (LibraryNavCommand) -> Void) -> LeftSidebarPanel {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        s.library.available = true
        s.library.libraries = [.init(id: "L", name: "test",
            events: [.init(id: "E", name: "Media"), .init(id: "E2", name: "B-roll")],
            projects: [.init(id: "P", name: "Main", eventId: "E"), .init(id: "P2", name: "Short", eventId: "E"),
                       .init(id: "P3", name: "Other", eventId: "E2")],
            assets: [.init(id: "A", name: "a.png", kind: "image", eventId: "E"), .init(id: "B", name: "b.png", kind: "image", eventId: "E")])]
        s.library.currentProjectId = "P"
        s.onLibrary = cmds
        s.draw(PanelMeasureCanvas(), size: size)
        return s
    }
    private func pick(_ s: LeftSidebarPanel, _ value: String) throws {
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more })))
        s.dropdown.pick(value)
        s.draw(PanelMeasureCanvas(), size: size)
    }

    /// Picking Delete project… shows what is removed and sends nothing; Delete sends the command for the current project.
    func testDeleteProjectAsksFirstThenSendsTheCommand() throws {
        var cmds: [LibraryNavCommand] = []
        let s = navigator { cmds.append($0) }
        try pick(s, "deleteProject")
        XCTAssertEqual(cmds, [], "nothing is sent before the user confirms")
        let c = PanelMeasureCanvas()
        s.draw(c, size: size)
        XCTAssertTrue(c.drawnStrings.contains { $0.contains("Delete project") || $0.contains("Main") }, "the row names the project")
        XCTAssertTrue(c.drawnStrings.contains("Delete") && c.drawnStrings.contains("Cancel"))
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .deleteConfirm })))
        XCTAssertEqual(cmds, [.deleteProject(libraryId: "L", projectId: "P")])
        s.draw(PanelMeasureCanvas(), size: size)
        XCTAssertNil(s.hits.rect { $0 == .deleteConfirm }, "the row closes once confirmed")
    }

    /// Delete event… names the shown event with its project and media counts and sends its id when confirmed.
    func testDeleteEventNamesItsContentsAndSendsTheShownEvent() throws {
        var cmds: [LibraryNavCommand] = []
        let s = navigator { cmds.append($0) }
        try pick(s, "deleteEvent")
        let message = try XCTUnwrap(s.deleting?.message)
        XCTAssertTrue(message.contains("2 projects") && message.contains("2 media items"), message)
        XCTAssertEqual(cmds, [])
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .deleteConfirm })))
        XCTAssertEqual(cmds, [.deleteEvent(libraryId: "L", eventId: "E")])
    }

    /// Cancel, Escape, and opening a name row all drop the question without sending anything.
    func testCancelEscapeAndANameRowDropTheQuestion() throws {
        var cmds: [LibraryNavCommand] = []
        let s = navigator { cmds.append($0) }
        try pick(s, "deleteProject")
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .deleteCancel })))
        XCTAssertNil(s.deleting)
        try pick(s, "deleteEvent")
        XCTAssertNotNil(s.deleting)
        XCTAssertTrue(s.keyDown(EditorKey(.escape)))
        XCTAssertNil(s.deleting)
        try pick(s, "deleteProject")
        try pick(s, "renameProject")
        XCTAssertNil(s.deleting, "a name row replaces the question")
        XCTAssertNotNil(s.hits.rect { $0 == .createField })
        XCTAssertEqual(cmds, [])
    }

    /// The question's buttons are keyboard stops, and Enter on Delete confirms.
    func testDeleteButtonsAreKeyboardReachable() throws {
        var cmds: [LibraryNavCommand] = []
        let s = navigator { cmds.append($0) }
        try pick(s, "deleteProject")
        XCTAssertTrue(s.isFocusable(.deleteConfirm) && s.isFocusable(.deleteCancel))
        s.focus.current = .deleteConfirm; s.focus.visible = true
        XCTAssertTrue(s.keyDown(EditorKey(.enter)))
        XCTAssertEqual(cmds, [.deleteProject(libraryId: "L", projectId: "P")])
    }

    /// Delete needs a target and an idle library, and the last event of a library cannot be deleted.
    func testDeleteNeedsATargetAnIdleLibraryAndMoreThanOneEvent() throws {
        let s = navigator { _ in }
        func disabled(_ value: String) throws -> Bool {
            try XCTUnwrap((s.libraryOptions() + s.projectOptions()).first { $0.value == value }).disabled
        }
        XCTAssertFalse(try disabled("deleteEvent"))
        XCTAssertFalse(try disabled("deleteProject"))
        s.library.currentProjectId = nil
        XCTAssertTrue(try disabled("deleteProject"), "no project is open in the shown event")
        s.library.currentProjectId = "P"
        s.library.busy = true
        XCTAssertTrue(try disabled("deleteEvent"))
        XCTAssertTrue(try disabled("deleteProject"))
        s.library.busy = false
        s.library.libraries[0].events = [.init(id: "E", name: "Media")]
        XCTAssertTrue(try disabled("deleteEvent"), "a library keeps one event")
        s.startDelete("deleteEvent")
        XCTAssertNil(s.deleting)
    }
}
