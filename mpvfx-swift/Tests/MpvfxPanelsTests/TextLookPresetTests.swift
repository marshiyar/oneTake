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
import OneTakeKeyframes
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
@testable import MpvfxPanels

final class TextLookPresetTests: XCTestCase {
    func editor() throws -> TimelineEditor { try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime()) }

    func testEveryGroupHasAPlainDataRecipeAndNoUninstalledFontOrArtwork() {
        XCTAssertEqual(Set(TextLookPreset.all.map(\.group)), Set(TextLookPreset.Group.allCases))
        XCTAssertEqual(Set(TextLookPreset.all.map(\.id)).count, TextLookPreset.all.count)
        for look in TextLookPreset.all {
            XCTAssertNil(look.text.fontFamily)
            XCTAssertTrue(look.isAvailable(installedFamilies: []))
            XCTAssertGreaterThan(look.width, 0); XCTAssertGreaterThan(look.height, 0)
        }
    }

    func testEachRecipeCreatesEditablePersistedTextAtThePlayheadAndUndoesAsOneEdit() throws {
        for look in TextLookPreset.all {
            let e = try editor(), before = e.document
            let id = try XCTUnwrap(e.addTextLook(look, at: 2))
            let clip = try XCTUnwrap(e.clip(id)?.clip)
            XCTAssertEqual(clip.startFrame, 2 * e.fps)
            XCTAssertEqual(clip.text?.content, look.text.content)
            XCTAssertNil(e.document.assets.first { $0.id == clip.assetId }?.source, "no font/art resource is referenced without import")
            XCTAssertEqual(clip.text?.fontSize, max(8, min(2000, (e.document.canvas.height * look.fontHeight).rounded())))
            let saved = try serializeNativeProjectDocument(e.document, engine: e.engine)
            let reopened = try TimelineEditor(json: saved, engine: e.engine)
            XCTAssertEqual(reopened.clip(id)?.clip.text, clip.text)
            XCTAssertEqual(reopened.clip(id)?.clip.parameterTracks, clip.parameterTracks)
            XCTAssertTrue(e.setTextContent(clipId: id, "Editable words"))
            _ = e.undo(); XCTAssertEqual(e.clip(id)?.clip.text?.content, look.text.content)
            _ = e.undo(); XCTAssertEqual(e.document, before, "recipe, asset and every animation key undo together")
            XCTAssertFalse(e.canUndo)
        }
    }

    func testAnExplicitUnavailableFontOrInvalidTimeChangesNothing() throws {
        let e = try editor(), before = e.document
        var look = TextLookPreset.all[0]
        look.text.fontFamily = "Not an installed font"
        XCTAssertNil(e.addTextLook(look, at: 0, installedFamilies: ["Installed family"]))
        XCTAssertNil(e.addTextLook(TextLookPreset.all[0], at: .nan))
        XCTAssertEqual(e.document, before)
        XCTAssertFalse(e.canUndo)
    }

    func testAnimationsAreOrdinaryOpacityAndLayoutParameterTracks() throws {
        let e = try editor()
        let fade = try XCTUnwrap(e.addTextLook(try XCTUnwrap(TextLookPreset.preset("fade-title")), at: 0))
        let opacity = try XCTUnwrap(e.clip(fade)?.clip.parameterTracks.first)
        XCTAssertEqual(opacity.parameterId, TimelineEditor.opacityId)
        XCTAssertEqual(opacity.keyframes.map(\.value), [.number(0), .number(1), .number(1), .number(0)])
        let roll = try XCTUnwrap(e.addTextLook(try XCTUnwrap(TextLookPreset.preset("credits")), at: 0))
        let position = try XCTUnwrap(e.clip(roll)?.clip.parameterTracks.first)
        XCTAssertEqual(position.parameterId, "layout.top")
        XCTAssertEqual(position.keyframes.first?.value, .number(e.document.canvas.height))
        XCTAssertEqual(position.keyframes.last?.value, .number(-e.document.canvas.height * 0.9))
    }

    func panel() -> LeftSidebarPanel {
        let p = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore()))
        p.onAddTextLook = { _ in }
        return p
    }

    func testSidebarGroupsSearchAndMediaFiltersUseTheExistingKeyboardGrid() throws {
        let p = panel(), c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(364, 1800))
        XCTAssertEqual(p.sections.count, TextLookPreset.Group.allCases.count)
        for group in TextLookPreset.Group.allCases { XCTAssertTrue(c.drawnStrings.contains("Text · " + group.rawValue)) }
        p.searchQuery = "credits"
        XCTAssertEqual(p.sections.flatMap(\.tiles), [.textLook("credits")])
        p.searchQuery = ""; p.filter.kind = .audio
        XCTAssertTrue(p.sections.isEmpty)
        p.filter = MediaFilter()
        var added: [String] = []
        p.onAddTextLook = { added.append($0.id) }
        p.draw(c, size: CanvasSize(364, 1800))
        p.selected = .textLook("title"); p.focus.current = .tile(.textLook("title")); p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(added, ["title"])
        XCTAssertTrue(p.keyDown(EditorKey(.right)))
        XCTAssertNotEqual(p.selected, .textLook("title"))
    }

    func testClickAddsOnceAndDragCarriesARecipeWithoutAddingEarly() throws {
        let p = panel(), c = PanelMeasureCanvas()
        var added: [String] = []
        p.onAddTextLook = { added.append($0.id) }
        p.draw(c, size: CanvasSize(364, 1800))
        let r = try XCTUnwrap(p.hits.rect { $0 == .tile(.textLook("title")) })
        let point = CanvasPoint(r.midX, r.midY)
        XCTAssertTrue(p.pointerDown(point, time: 1)); p.pointerUp(point)
        XCTAssertEqual(added, ["title"])
        XCTAssertTrue(p.pointerDown(point, time: 2))
        _ = p.pointerMove(CanvasPoint(point.x + 10, point.y))
        XCTAssertEqual(p.draggingAssetId, TextLookPreset.dragPrefix + "title")
        p.pointerUp(CanvasPoint(500, point.y))
        XCTAssertEqual(added, ["title"], "the host adds a drag only after a valid drop")
        XCTAssertEqual(TextLookPreset.draggedPreset(try XCTUnwrap(p.lastDraggedAssetId))?.id, "title")
    }
}
