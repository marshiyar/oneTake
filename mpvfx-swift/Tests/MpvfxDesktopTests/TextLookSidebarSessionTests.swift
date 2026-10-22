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
import MpvfxCanvas
import MpvfxPanels
import MpvfxTimeline
@testable import MpvfxDesktop

final class TextLookSidebarSessionTests: XCTestCase {
    func session() throws -> EditorSession {
        let session = try EditorSession(projectPath: nil, demo: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("text-look-session-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = session.installShell(userData: dir.path) {}
        session.playback.seek(2)
        return session
    }

    func testSidebarClickAddsAtThePlayheadAndSelectsTheEditableTextInspector() throws {
        let s = try session(), panels = try XCTUnwrap(s.panels)
        let before = s.editor.document
        panels.left.onAddTextLook?(try XCTUnwrap(TextLookPreset.preset("name-strap")))
        let id = try XCTUnwrap(s.timeline.view.selection.first)
        XCTAssertEqual(s.editor.clip(id)?.clip.startFrame, 2 * s.editor.fps)
        XCTAssertEqual(s.editor.clip(id)?.clip.text?.content, "YOUR NAME\nYour role")
        XCTAssertEqual(panels.right.inspector.selection, [id])
        XCTAssertEqual(panels.right.inspector.openGroupId, "text")
        _ = s.editor.undo(); XCTAssertEqual(s.editor.document, before)
        XCTAssertFalse(s.editor.canUndo)
    }

    func testARecipeDragDropsAtThePlayheadOnTheTimelineAndOutsideDropsDoNothing() throws {
        let s = try session(), panels = try XCTUnwrap(s.panels)
        let canvas = PanelMeasureCanvas()
        panels.left.draw(canvas, size: CanvasSize(364, 2200))
        let r = try XCTUnwrap(panels.left.hits.rect { $0 == .tile(.textLook("title")) })
        let at = CanvasPoint(r.x + r.width / 2, r.y + r.height / 2)
        func drag() {
            _ = panels.left.pointerDown(at)
            _ = panels.left.pointerMove(CanvasPoint(at.x + 10, at.y))
            panels.left.pointerUp(CanvasPoint(500, at.y))
        }
        let before = s.editor.document
        drag(); panels.assetDrag?.dragEnded(over: nil, local: .init(0, 0))
        XCTAssertEqual(s.editor.document, before)
        drag(); panels.assetDrag?.dragEnded(over: .timeline, local: .init(900, TimelineToolbar.height + 50))
        let id = try XCTUnwrap(s.timeline.view.selection.first)
        XCTAssertEqual(s.editor.clip(id)?.clip.startFrame, 2 * s.editor.fps, "the recipe drops at the playhead, not an arbitrary media offset")
        XCTAssertEqual(s.editor.clip(id)?.clip.text?.content, "Your title")
        _ = s.editor.undo(); XCTAssertEqual(s.editor.document, before)
    }
}
