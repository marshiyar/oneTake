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
import MpvfxShared
import MpvfxDesktopCore
@testable import MpvfxDesktop

final class RevealClipSourceTests: XCTestCase {
    private var dir: URL?
    var session: EditorSession?
    override func tearDown() {
        session?.audio?.stop()
        session = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    func make(source: String = "logo.png") throws -> EditorSession {
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        dir = fresh
        let demo = try EditorSession(projectPath: nil, demo: true)
        demo.audio?.stop()
        var doc = demo.editor.document
        let i = try XCTUnwrap(doc.assets.firstIndex { $0.id == "asset:logo" })
        doc.assets[i].source = source
        let file = fresh.appendingPathComponent("project.json")
        try JSONEncoder().encode(doc).write(to: file)
        let s = try EditorSession(projectPath: file.path)
        session = s
        s.audio?.stop()
        _ = s.installShell(userData: fresh.path) {}
        s.panels?.left.items = [.init(id: source, name: "logo.png", path: source, category: .images, duration: nil, used: true)]
        return s
    }

    func testRevealSelectsTheAssetAndReopensTheMediaPanelWithoutAnEdit() throws {
        let s = try make()
        let dir = try XCTUnwrap(dir)
        try Data([0]).write(to: dir.appendingPathComponent("logo.png"))
        let shell = try XCTUnwrap(s.shell), panels = try XCTUnwrap(s.panels)
        shell.close(DockPanels.media)
        panels.left.searchQuery = "hidden"
        panels.left.filter.kind = .audio
        let before = s.editor.document, undo = s.editor.undoStack.count, time = s.playback.currentTime
        s.timeline.onRevealSource?("clip:logo", false)
        XCTAssertEqual(panels.left.selected, .media("logo.png"))
        XCTAssertEqual(panels.left.searchQuery, "")
        XCTAssertTrue(panels.left.filter.isDefault)
        XCTAssertTrue(shell.dock.layout.isOpen(DockPanels.media))
        XCTAssertEqual(s.editor.document, before)
        XCTAssertEqual(s.editor.undoStack.count, undo)
        XCTAssertEqual(s.playback.currentTime, time)
    }

    func testFileManagerReceivesTheResolvedProjectRelativePath() throws {
        let s = try make()
        let dir = try XCTUnwrap(dir)
        try Data([0]).write(to: dir.appendingPathComponent("logo.png"))
        var shown: String?
        s.panels?.revealPath = { shown = $0 }
        s.revealClipSource(clipId: "clip:logo", inFileManager: true)
        XCTAssertEqual(shown, dir.appendingPathComponent("logo.png").path)
    }

    func testMissingFileHasATypedActionableErrorAndNeverOpensTheFileManager() throws {
        let s = try make()
        XCTAssertThrowsError(try s.clipSource(clipId: "clip:logo")) { error in
            XCTAssertEqual((error as? DesktopError)?.name, "SourceMissingError")
            XCTAssertTrue((error as? DesktopError)?.message.contains("restore the file") == true)
        }
        var opened = false, message = ""
        s.panels?.revealPath = { _ in opened = true }
        s.onError = { _, detail in message = detail }
        s.revealClipSource(clipId: "clip:logo", inFileManager: true)
        XCTAssertFalse(opened)
        XCTAssertTrue(message.contains("logo.png"))
    }

    func testAbsoluteSourcesAreKeptAndClipsWithoutSourcesAreRefused() throws {
        let s = try make(source: "/missing/logo.png")
        XCTAssertThrowsError(try s.clipSource(clipId: "clip:logo")) { error in
            XCTAssertTrue((error as? DesktopError)?.message.contains("/missing/logo.png") == true)
        }
        XCTAssertThrowsError(try s.clipSource(clipId: "clip:a")) { error in
            XCTAssertEqual((error as? DesktopError)?.name, "SourceUnavailableError")
        }
    }
}
