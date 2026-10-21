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
import MpvfxCanvas
import MpvfxShared
import MpvfxPlayer
@testable import MpvfxPanels
@testable import MpvfxDesktop

/// Issue #188 A4: the inspector's "Edit crop" and the stage toolbar's Crop are one crop session.
final class InspectorCropSessionTests: XCTestCase {
    var dirs: [String] = []
    var sessions: [EditorSession] = []

    override func tearDown() {
        sessions.removeAll()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    }

    func makeSession() throws -> (EditorSession, InspectorPanel) {
        let d = NSTemporaryDirectory() + "mpvfx-crop-session-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        _ = s.installShell(userData: d) {}
        sessions.append(s)
        let inspector = try XCTUnwrap(s.panels?.right.inspector)
        s.timeline.view.selection = ["clip:a"]; s.syncStage()
        inspector.selection = ["clip:a"]; inspector.openGroupId = "media"
        draw(inspector)
        return (s, inspector)
    }

    func draw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 360, height: 1400)) }

    func testEditCropAndTheStageToolbarStartTheSameSession() throws {
        let (s, p) = try makeSession()
        XCTAssertTrue(s.player.view.cropAvailable)
        try XCTUnwrap(p.button("crop:start")).action()
        XCTAssertTrue(s.player.view.cropActive, "Edit crop starts the stage's crop tool")
        draw(p)
        p.number("crop:left")?.commit("40")
        XCTAssertEqual(s.player.cropDraft?.left, 40, "the edge field moves the stage's draft")
        XCTAssertNil(s.editor.crop(clipId: "clip:a"), "nothing is saved before Apply")
        try XCTUnwrap(p.button("crop:cancel")).action()
        XCTAssertFalse(s.player.view.cropActive, "Cancel in the inspector ends the stage session")
        XCTAssertNil(s.editor.crop(clipId: "clip:a"))

        s.player.runCrop(.start)   // the stage toolbar's Crop (and the C key)
        draw(p)
        XCTAssertNotNil(p.button("crop:apply"), "the inspector shows the session the stage started")
        p.number("crop:left")?.commit("24")
        try XCTUnwrap(p.button("crop:apply")).action()
        XCTAssertFalse(s.player.view.cropActive)
        XCTAssertEqual(s.editor.crop(clipId: "clip:a")?.left, 24, "Apply saves the crop to the clip")
        draw(p)
        XCTAssertNotNil(p.button("crop:start"), "back to the one entry point")
    }

    /// Codex review: selecting another clip on the timeline ends the crop, so its edges never land on that clip.
    func testSelectingAnotherClipEndsTheCropSession() throws {
        let (s, p) = try makeSession()
        try XCTUnwrap(p.button("crop:start")).action()
        XCTAssertEqual(s.player.cropClipId, "clip:a")
        s.timeline.view.selection = ["clip:logo"]; s.syncStage()
        XCTAssertFalse(s.player.view.cropActive, "the crop on clip:a is cancelled")
        XCTAssertNil(s.player.cropClipId)
        p.selection = ["clip:logo"]; draw(p)
        XCTAssertNotNil(p.button("crop:start"), "the new clip shows the entry point, not the old session")
        XCTAssertNil(s.editor.crop(clipId: "clip:a")); XCTAssertNil(s.editor.crop(clipId: "clip:logo"))
    }
}
#endif
