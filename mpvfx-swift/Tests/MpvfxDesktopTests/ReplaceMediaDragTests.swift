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
import MpvfxCanvas
import MpvfxPanels
import MpvfxShared
@testable import MpvfxDesktop

final class ReplaceMediaDragTests: XCTestCase {
    var directories: [String] = []
    override func tearDown() { for d in directories { try? FileManager.default.removeItem(atPath: d) } }

    func make() throws -> (EditorSession, BinAssetDrag, String) {
        let dir = NSTemporaryDirectory() + "replace-media-\(UUID().uuidString)"
        directories.append(dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let backend = RuntimeDesktopBackend(userData: dir + "/user")
        let project = try backend.createProject(name: "Replace", directory: dir + "/project")
        try FileManager.default.createDirectory(atPath: project.directory + "/media", withIntermediateDirectories: true)
        try WavBytes.stereo(seconds: 2).write(to: URL(fileURLWithPath: project.directory + "/media/new.wav"))
        let s = try EditorSession(backend: backend, projectPath: project.directory)
        s.audio?.stop(); s.graphUpdater?.waitUntilIdle(); s.graphUpdater = nil
        s.postToUI = { DispatchQueue.main.async(execute: $0) }
        s.redraw = {}
        let shell = s.installShell(userData: dir + "/user") {}
        shell.resized(CanvasSize(1440, 900))
        let old = try XCTUnwrap(s.editor.addAsset(kind: .audio, name: "Old", source: "old.wav", durationFrames: 300))
        _ = try XCTUnwrap(s.editor.addAsset(kind: .audio, name: "New", source: "media/new.wav", durationFrames: 300))
        let clip = try XCTUnwrap(s.editor.insertClip(assetId: old, at: 0, durationFrames: 30))
        let panels = try XCTUnwrap(s.panels)
        panels.refreshMedia()
        let deadline = Date().addingTimeInterval(5)
        while panels.media.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(panels.media.contains { $0.path == "media/new.wav" })
        return (s, try XCTUnwrap(panels.assetDrag), clip)
    }

    /// A3: carry a real bin tile through pointer press/move/release into the drag's timeline drop path.
    func testOptionDropReplacesInsteadOfInsertingAndIsOneUndoStep() throws {
        let (s, drag, id) = try make()
        let panels = try XCTUnwrap(s.panels)
        let target = CairoImageTarget(width: 1440, height: 900)
        s.shell?.draw(target.canvas, size: CanvasSize(1440, 900))
        let card = try XCTUnwrap(panels.left.hits.rect { $0 == .tile(.media("media/new.wav")) })
        let p = CanvasPoint(card.x + card.width / 2, card.y + card.height / 2)
        let row = try XCTUnwrap(s.timeline.view.tracks.firstIndex { $0.clips.contains { $0.id == id } })
        let clip = try XCTUnwrap(s.timeline.view.tracks[row].clips.first { $0.id == id })
        let box = s.timeline.view.clipRect(track: row, clip)
        let landing = CanvasPoint(box.x + box.width / 2, box.y + box.height / 2 + TimelineToolbar.height)
        let before = s.editor.document, count = s.editor.undoStack.count
        let shell = try XCTUnwrap(s.shell), frames = try XCTUnwrap(shell.frames)
        shell.pointerDown(x: frames.left.x + p.x, y: frames.left.y + p.y, button: PointerButton.primary, modifiers: [])
        shell.pointerMove(x: frames.timeline.x + landing.x, y: frames.timeline.y + landing.y, modifiers: .alt)
        XCTAssertTrue(drag.isDragging(from: .left))
        shell.pointerUp(x: frames.timeline.x + landing.x, y: frames.timeline.y + landing.y)
        XCTAssertEqual(s.editor.clip(id)?.clip.assetId, s.editor.document.assets.first { $0.source == "media/new.wav" }?.id)
        XCTAssertEqual(s.editor.document.sequence.tracks.flatMap(\.clips).count, 1)
        XCTAssertEqual(s.editor.undoStack.count, count + 1)
        XCTAssertTrue(s.editor.undo()); XCTAssertEqual(s.editor.document, before)
    }

    func testTooShortBinReplacementShowsTheErrorAndDoesNotImportIt() throws {
        let (s, _, id) = try make()
        let panels = try XCTUnwrap(s.panels)
        var short = try XCTUnwrap(s.editor.document.assets.first { $0.source == "media/new.wav" })
        short.durationFrames = 1
        var d = s.editor.document
        let index = try XCTUnwrap(d.assets.firstIndex { $0.id == short.id })
        d.assets[index] = short
        s.editor.replaceDocument(d, inverse: .restoreDocument(s.editor.document))
        let before = s.editor.document, count = s.editor.undoStack.count
        panels.replaceMedia(path: "media/new.wav", clipId: id)
        XCTAssertEqual(s.editor.document, before)
        XCTAssertEqual(s.editor.undoStack.count, count)
        XCTAssertEqual(s.player.view.toast?.message, "Replacement media is too short: missing 29 source frames")
    }
}
#endif
