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
import XCTest
import MpvfxCanvas
import MpvfxShared
@testable import MpvfxTimeline

final class ClipIdentityTests: XCTestCase {
    func setup() throws -> (TimelineEditor, TimelineController) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let controller = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: editor)
        controller.viewport = CanvasSize(1000, 350)
        controller.view.selection = ["clip:a"]
        return (editor, controller)
    }

    func testRenameIsOneUndoStepAndTheClipLabelRoundTripsWithoutRenamingItsSource() throws {
        let (editor, _) = try setup()
        let assetNames = editor.document.assets.map(\.name), depth = editor.undoStack.count
        XCTAssertTrue(editor.renameClip("clip:a", name: "  Opening shot  "))
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertEqual(editor.tracks.flatMap(\.clips).first { $0.id == "clip:a" }?.name, "Opening shot")
        XCTAssertEqual(editor.document.assets.map(\.name), assetNames)
        let saved = try serializeNativeProjectDocument(editor.document)
        let reopened = try parseNativeProjectDocument(try NativeJSONValue.parse(saved))
        XCTAssertEqual(reopened.sequence.tracks.flatMap(\.clips).first { $0.id == "clip:a" }?.name, "Opening shot")
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clip("clip:a")?.clip.name)
        XCTAssertTrue(editor.redo())
        XCTAssertEqual(editor.clip("clip:a")?.clip.name, "Opening shot")
    }

    func testAnEmptyRenameRestoresTheAssetLabelAndLockedClipsRefuseRename() throws {
        let (editor, _) = try setup()
        XCTAssertTrue(editor.renameClip("clip:a", name: "Intro"))
        XCTAssertTrue(editor.renameClip("clip:a", name: "  "))
        XCTAssertNil(editor.clip("clip:a")?.clip.name)
        XCTAssertEqual(editor.tracks.flatMap(\.clips).first { $0.id == "clip:a" }?.name, "clip_001.mp4")
        let address = try XCTUnwrap(editor.address(clipId: "clip:a"))
        XCTAssertTrue(editor.setTrackLocked(address.trackId, true))
        XCTAssertFalse(editor.renameClip("clip:a", name: "Locked"))
        XCTAssertFalse(editor.setClipsHidden(["clip:a"], true))
        XCTAssertFalse(editor.isClipHidden("clip:a"))
    }

    func testRenameKeyboardCommitsOnceAndEscapeCancelsWithoutAnEdit() throws {
        let (editor, controller) = try setup()
        let depth = editor.undoStack.count
        XCTAssertTrue(controller.keyDown(EditorKey(.function(2))))
        XCTAssertNotNil(controller.view.clipRename)
        for ch in "Intro" { XCTAssertTrue(controller.keyDown(EditorKey(.char(ch)))) }
        XCTAssertEqual(editor.undoStack.count, depth, "typing is only a draft")
        XCTAssertTrue(controller.keyDown(EditorKey(.enter)))
        XCTAssertEqual(editor.clip("clip:a")?.clip.name, "Intro")
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertTrue(controller.keyDown(EditorKey(.function(2))))
        XCTAssertTrue(controller.keyDown(EditorKey(.char("x"))))
        XCTAssertTrue(controller.keyDown(EditorKey(.escape)))
        XCTAssertEqual(editor.clip("clip:a")?.clip.name, "Intro")
        XCTAssertEqual(editor.undoStack.count, depth + 1)
    }

    func testDisableKeyKeepsPlacementAndGreysTheTimelineModelInOneUndoStep() throws {
        let (editor, controller) = try setup()
        let original = try XCTUnwrap(editor.clip("clip:a")?.clip), depth = editor.undoStack.count
        XCTAssertTrue(controller.keyDown(EditorKey(.char("E"), shift: true)))
        let disabled = try XCTUnwrap(editor.clip("clip:a")?.clip)
        XCTAssertTrue(controller.keyDown(EditorKey(.char("E"), shift: true, isRepeat: true)))
        XCTAssertEqual(editor.undoStack.count, depth + 1, "holding the shortcut does not toggle repeatedly")
        XCTAssertEqual(disabled.hidden, true)
        XCTAssertEqual(disabled.startFrame, original.startFrame)
        XCTAssertEqual(disabled.durationFrames, original.durationFrames)
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertEqual(controller.view.tracks.flatMap(\.clips).first { $0.id == "clip:a" }?.hidden, true)
        XCTAssertFalse(editor.activeElements(at: 1).contains { $0.id == "clip:a" })
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clip("clip:a")?.clip.hidden)
        XCTAssertTrue(controller.keyDown(EditorKey(.char("E"), shift: true)))
        XCTAssertTrue(controller.keyDown(EditorKey(.char("E"), shift: true)))
        XCTAssertNil(editor.clip("clip:a")?.clip.hidden)
    }

    func testRenameAndDisableAreAvailableFromTheClipMenu() throws {
        let (editor, controller) = try setup()
        controller.openClipMenu("clip:a", x: 10, y: 10)
        let actions = controller.view.clipMenu?.entries.compactMap { entry -> TimelineClipMenu.Action? in
            if case .item(let item) = entry { return item.action }; return nil
        } ?? []
        XCTAssertTrue(actions.contains(.rename)); XCTAssertTrue(actions.contains(.disable))
        XCTAssertTrue(controller.runClipMenu(.disable, clipId: "clip:a"))
        XCTAssertTrue(editor.isClipHidden("clip:a"))
        XCTAssertTrue(controller.runClipMenu(.rename, clipId: "clip:a"))
        XCTAssertEqual(controller.view.clipRename?.clipId, "clip:a")
    }

    func testClipLabelRejectsBlankAndNonStringSavedValues() throws {
        let (editor, _) = try setup()
        for value in [NativeJSONValue.string(" "), .number(4), .bool(false)] {
            var input = try NativeJSONValue.from(editor.document)
            input["sequence"]?["tracks"]?[0]?["clips"]?[0]?["name"] = value
            XCTAssertTrue(validateNativeProjectDocument(input).contains { $0.path.hasSuffix(".name") })
        }
    }
}
