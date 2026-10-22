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
import MpvfxAudioGraph
import MpvfxCanvas
import MpvfxTimeline
@testable import MpvfxPanels

final class EffectsPanelTests: XCTestCase {
    private func make(selected: String? = "clip:a") throws -> (EffectsPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let p = EffectsPanel()
        p.editor = editor
        p.selectedClip = { selected }
        return (p, editor)
    }

    func testIsRegisteredUnderItsSavedId() {
        XCTAssertEqual(DockPanels.effects, "effects")
        XCTAssertEqual(DockRegistry.editor.title("effects"), "Effects")
    }

    func testListsTheVideoEffectsOfEffectSpecsAndTheAudioEffectsInGroups() {
        let video = EffectsCatalog.all.filter { $0.kind == .video }
        XCTAssertEqual(video.map(\.key), EffectSpecs.all.map(\.key))
        XCTAssertEqual(Set(video.map(\.group)), Set(EffectSpecs.families.map(\.label)))
        let audio = EffectsCatalog.all.filter { $0.kind == .audio }
        XCTAssertFalse(audio.isEmpty)
        XCTAssertTrue(audio.allSatisfy { $0.group.hasPrefix("Audio") })
        XCTAssertEqual(Set(EffectsCatalog.all.map(\.id)).count, EffectsCatalog.all.count, "ids are unique")
    }

    func testSearchFiltersByNameGroupAndKind() throws {
        XCTAssertEqual(EffectsCatalog.entries(matching: "").count, EffectsCatalog.all.count)
        XCTAssertEqual(EffectsCatalog.entries(matching: "blur").map(\.key), ["blur"])
        XCTAssertEqual(EffectsCatalog.entries(matching: "  BLUR ").map(\.key), ["blur"])
        XCTAssertTrue(EffectsCatalog.entries(matching: "retro").allSatisfy { $0.group == "Retro & glitch" })
        XCTAssertTrue(EffectsCatalog.entries(matching: "audio").allSatisfy { $0.kind == .audio })
        XCTAssertTrue(EffectsCatalog.entries(matching: "zzzz-no-such").isEmpty)
        let (p, _) = try make()
        p.setQuery("pixel")
        XCTAssertEqual(p.entries.map(\.key), ["pixelate"])
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(320, 400))
        XCTAssertTrue(c.drawnStrings.contains("Pixelate"))
        XCTAssertFalse(c.drawnStrings.contains("Blur"))
        p.setQuery("nothing matches this")
        c.reset(); p.draw(c, size: CanvasSize(320, 400))
        XCTAssertTrue(c.drawnStrings.contains("No effects match"))
    }

    func testTypingInTheSearchFieldFiltersAndEscapeClears() throws {
        let (p, _) = try make()
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(320, 400))
        XCTAssertTrue(p.pointerDown(CanvasPoint(60, 20), shift: false))
        XCTAssertTrue(p.searchFocused)
        for ch in "blu" { XCTAssertTrue(p.keyDown(EditorKey(.char(ch)))) }
        XCTAssertEqual(p.query, "blu")
        XCTAssertTrue(p.keyDown(EditorKey(.backspace)))
        XCTAssertEqual(p.query, "bl")
        XCTAssertTrue(p.keyDown(EditorKey(.escape)))
        XCTAssertEqual(p.query, "")
        XCTAssertFalse(EditorKey(.char("x")).command)
    }

    func testApplyByKeyAddsTheEffectAndUndoRemovesIt() throws {
        let (p, editor) = try make()
        let blur = try XCTUnwrap(EffectsCatalog.entries(matching: "blur").first)
        XCTAssertFalse(EffectSpecs.isActive(editor.gradeShown(clipId: "clip:a", time: 0), "blur"))
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(320, 400))
        p.setQuery("blur")
        XCTAssertTrue(p.keyDown(EditorKey(.enter)), "Return applies the first match")
        XCTAssertTrue(EffectSpecs.isActive(editor.gradeShown(clipId: "clip:a", time: 0), "blur"))
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertEqual(editor.undoLabel, "Add Blur")
        XCTAssertTrue(editor.undo())
        XCTAssertFalse(EffectSpecs.isActive(editor.gradeShown(clipId: "clip:a", time: 0), "blur"))
        _ = blur
    }

    func testApplyByDropPutsTheEffectOnTheNamedClipNotTheSelectedOne() throws {
        let (p, editor) = try make(selected: "clip:a")
        let pix = try XCTUnwrap(EffectsCatalog.entries(matching: "pixelate").first)
        XCTAssertEqual(p.apply(pix, toClip: "clip:b"), .applied(clipId: "clip:b"))
        XCTAssertTrue(EffectSpecs.isActive(editor.gradeShown(clipId: "clip:b", time: 0), "pixelate"))
        XCTAssertFalse(EffectSpecs.isActive(editor.gradeShown(clipId: "clip:a", time: 0), "pixelate"))
        editor.undo()
        XCTAssertFalse(EffectSpecs.isActive(editor.gradeShown(clipId: "clip:b", time: 0), "pixelate"))
    }

    func testDraggingATileIsReportedToTheHostAndKeptAfterRelease() throws {
        let (p, _) = try make()
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(320, 400))
        let tile = try XCTUnwrap(p.tiles.first).rect
        let start = CanvasPoint(tile.x + 10, tile.y + 10)
        XCTAssertTrue(p.pointerDown(start, shift: false))
        XCTAssertNil(p.draggingEntry)
        XCTAssertTrue(p.pointerMove(CanvasPoint(start.x + 30, start.y + 30)))
        XCTAssertEqual(p.draggingEntry, p.tiles.first?.entry)
        XCTAssertTrue(p.pointerUp(start))
        XCTAssertNil(p.draggingEntry)
        XCTAssertEqual(p.lastDraggedEntry, p.tiles.first?.entry)
    }

    func testDoubleClickApplies() throws {
        let (p, editor) = try make()
        var t = 100.0
        p.now = { t }
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(320, 400))
        let tile = try XCTUnwrap(p.tiles.first(where: { $0.entry.kind == .video })).rect
        let at = CanvasPoint(tile.x + 5, tile.y + 5)
        _ = p.pointerDown(at, shift: false)
        XCTAssertTrue(editor.undoStack.isEmpty, "one click only highlights")
        t += 0.2
        _ = p.pointerDown(at, shift: false)
        XCTAssertEqual(editor.undoStack.count, 1)
    }

    func testAudioEffectsGoOnSoundClipsAndVideoEffectsStayOffThem() throws {
        let (p, editor) = try make(selected: "clip:music")
        let video = try XCTUnwrap(EffectsCatalog.entries(matching: "blur").first)
        XCTAssertEqual(p.apply(video), .wrongKind("no picture"))
        XCTAssertTrue(editor.undoStack.isEmpty)
        let audio = try XCTUnwrap(EffectsCatalog.all.first { $0.kind == .audio && $0.key.hasPrefix("add:") })
        XCTAssertEqual(p.apply(audio), .applied(clipId: "clip:music"))
        let chain = try XCTUnwrap(editor.clip("clip:music")?.clip.audioFxChain)
        XCTAssertEqual(try AudioFx.parseChain(chain).nodes.count, 1)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clip("clip:music")?.clip.audioFxChain)
        let (q, _) = try make(selected: "clip:logo")
        XCTAssertEqual(q.apply(audio), .wrongKind("no sound"), "a still image has no sound")
    }

    func testWithoutAClipNothingChangesAndThePanelSaysWhy() throws {
        let (p, editor) = try make(selected: nil)
        let e = try XCTUnwrap(EffectsCatalog.all.first)
        XCTAssertEqual(p.apply(e), .noClip)
        XCTAssertEqual(p.apply(e, toClip: "clip:missing"), .noClip)
        XCTAssertTrue(editor.undoStack.isEmpty)
        XCTAssertNotNil(p.status)
    }

    func testTilesDrawAPreviewForEachVideoEffect() throws {
        let (p, _) = try make()
        var asked: [String] = []
        p.effectPreview = { asked.append($0.key); return .rendering }
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(320, 2000))
        XCTAssertTrue(asked.contains("fx:blur"))
        XCTAssertTrue(c.drawnStrings.contains("Blur"))
    }
}
