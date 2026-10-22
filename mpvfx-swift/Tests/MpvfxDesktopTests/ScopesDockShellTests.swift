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

final class ScopesDockShellTests: XCTestCase {
    var dirs: [String] = []
    var sessions: [EditorSession] = []
    override func tearDown() {
        for s in sessions { s.audio?.stop() }
        sessions.removeAll()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    }

    func session(_ dir: String) throws -> (EditorSession, EditorShellRouter, ScopesPanel) {
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        sessions.append(s)
        let router = s.installShell(userData: dir) {}
        let panel = try XCTUnwrap(s.shellInputs.compactMap { ($0 as? DockedPanelInput)?.panel as? ScopesPanel }.first)
        router.draw(PanelMeasureCanvas(), size: CanvasSize(1440, 900))
        return (s, router, panel)
    }

    func userData() throws -> String {
        let dir = NSTemporaryDirectory() + "mpvfx-docked-scopes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir
    }

    func testScopesOpensFromTheWindowMenuAndReadsTheProgramWithNoClipSelected() throws {
        let (s, router, panel) = try session(try userData())
        XCTAssertTrue(s.timeline.view.selection.isEmpty)
        XCTAssertEqual(router.windowMenuPanels.first { $0.id == DockPanels.scopes }?.checked, false)
        XCTAssertNotNil(router.panes[.of(DockPanels.scopes)])
        router.togglePanelFromMenu(DockPanels.scopes)
        XCTAssertTrue(router.dock.layout.isOpen(DockPanels.scopes))
        XCTAssertEqual(router.windowMenuPanels.first { $0.id == DockPanels.scopes }?.checked, true)
        let frame = try XCTUnwrap(panel.programFrame)
        var ready = false
        let until = Date().addingTimeInterval(5)
        while Date() < until {
            if case .ready(let image) = frame(160, 90) {
                XCTAssertGreaterThan(image.width, 0); XCTAssertGreaterThan(image.height, 0)
                ready = true; break
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertTrue(ready, "the real program painter returns a frame independently of inspector selection")
    }

    func testScopeKindRestoresInANewShellWithoutChangingTheProject() throws {
        let dir = try userData()
        let (s, _, panel) = try session(dir)
        let original = s.editor.document
        XCTAssertTrue(panel.select(.histogram))
        let (_, _, reopened) = try session(dir)
        XCTAssertEqual(reopened.mode, .histogram)
        XCTAssertEqual(s.editor.document, original)
        XCTAssertFalse(s.editor.canUndo)
    }
}
