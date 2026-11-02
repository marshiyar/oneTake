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
import MpvfxTimeline
import OneTakeKeyframes
#if canImport(CoreGraphics) && canImport(CoreText)
import CoreGraphics
#endif
@testable import MpvfxPanels

/// The Transitions browser (issues #459 and #268): the catalogue and its search, stars saved in the panel preferences,
/// Return, double click, arrow keys and drops applying a kind (each one undo step), and the tile drawing the user's own
/// two clips (a red-to-blue cut shows both colours).
final class TransitionBrowserTests: XCTestCase {
    /// Three touching clips on one track, with media on both sides of every cut.
    static let json = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":32,"background":"#000000"},
     "assets":[{"id":"a1","kind":"video","name":"One","source":"a.mov","durationFrames":300},
               {"id":"a2","kind":"video","name":"Two","source":"b.mov","durationFrames":300},
               {"id":"a3","kind":"video","name":"Three","source":"c.mov","durationFrames":300}],
     "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
       {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"C","assetId":"a3","startFrame":120,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """#

    private func make(selected: Set<String> = ["B"], favourites: [String] = []) throws -> (TransitionsPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: Self.json, engine: try KeyframeRuntime())
        let p = TransitionsPanel(favourites: favourites)
        p.editor = editor
        p.selection = { selected }
        return (p, editor)
    }

    private func draw(_ p: TransitionsPanel, _ size: CanvasSize = CanvasSize(320, 500)) -> PanelMeasureCanvas {
        let c = PanelMeasureCanvas()
        p.draw(c, size: size)
        return c
    }

    private func transitions(_ e: TimelineEditor) -> [NativeCutTransition] { e.document.sequence.tracks[0].cutTransitions }

    func testIsRegisteredUnderItsSavedIdOnTheLeft() throws {
        XCTAssertEqual(DockPanels.transitions, "transitions")
        let spec = try XCTUnwrap(DockRegistry.editor.spec("transitions"))
        XCTAssertEqual(spec.title, "Transitions")
        XCTAssertEqual(spec.defaultDock, .left)
        XCTAssertFalse(spec.startsClosed)
    }

    func testTheCatalogueGroupsEveryKindWithUniqueIdsAndMatchingKindsAndDirections() {
        XCTAssertEqual(Set(TransitionCatalog.all.map(\.id)).count, TransitionCatalog.all.count, "ids are unique")
        XCTAssertEqual(Set(TransitionCatalog.all.map(\.kind)), Set(NativeCutTransitionKind.allCases), "every kind the editor draws is offered")
        XCTAssertEqual(TransitionCatalog.all.filter { $0.kind == .wipe }.compactMap(\.direction), NativeTransitionDirection.allCases)
        XCTAssertEqual(TransitionCatalog.all.filter { $0.kind == .push }.compactMap(\.direction), NativeTransitionDirection.allCases)
        XCTAssertEqual(TransitionCatalog.all.filter { $0.kind == .dip }.compactMap(\.color), [NativeCutTransition.defaultDipColor, NativeCutTransition.whiteDipColor])
        XCTAssertEqual(TransitionCatalog.entry(id: "wipe:up")?.label, "Wipe up")
    }

    func testSearchFiltersByNameAndGroupIgnoringCaseAndSpaces() throws {
        XCTAssertEqual(TransitionCatalog.entries(matching: "").count, TransitionCatalog.all.count)
        XCTAssertEqual(TransitionCatalog.entries(matching: "  WIPE ").map(\.id), ["wipe:left", "wipe:right", "wipe:up", "wipe:down"])
        XCTAssertEqual(TransitionCatalog.entries(matching: "dip white").map(\.id), ["dip:white"])
        XCTAssertTrue(TransitionCatalog.entries(matching: "zzzz-no-such").isEmpty)
        let (p, _) = try make()
        p.setQuery("push")
        let c = draw(p)
        XCTAssertTrue(c.drawnStrings.contains("Push left"))
        XCTAssertFalse(c.drawnStrings.contains("Wipe left"))
        p.setQuery("nothing matches this")
        let none = draw(p)
        XCTAssertTrue(none.drawnStrings.contains("No transitions match"))
    }

    func testTypingInTheSearchFieldFiltersAndEscapeClears() throws {
        let (p, _) = try make()
        _ = draw(p)
        XCTAssertTrue(p.pointerDown(CanvasPoint(60, 20), shift: false))
        XCTAssertTrue(p.searchFocused)
        for ch in "dip" { XCTAssertTrue(p.keyDown(EditorKey(.char(ch)))) }
        XCTAssertEqual(p.entries.map(\.id), ["dip:black", "dip:white"])
        XCTAssertTrue(p.keyDown(EditorKey(.escape)))
        XCTAssertEqual(p.query, "")
    }

    // MARK: Favourites

    func testAStarMovesTheTransitionToTheTopAndIsSavedInThePanelPreferences() throws {
        let store = MemoryPanelPreferencesStore()
        let layout = PanelLayoutState(store: store)
        let (p, _) = try make()
        p.onFavouritesChange = { ids in layout.update { $0.favouriteTransitions = ids } }
        XCTAssertEqual(p.entries.first?.id, "dissolve")
        p.toggleFavourite(try XCTUnwrap(TransitionCatalog.entry(id: "push:up")))
        p.toggleFavourite(try XCTUnwrap(TransitionCatalog.entry(id: "wipe:left")))
        XCTAssertEqual(p.entries.prefix(2).map(\.id), ["push:up", "wipe:left"], "starred first, in the order starred")
        XCTAssertEqual(p.entries.filter { $0.id == "push:up" }.count, 1, "shown once")
        XCTAssertEqual(store.value.favouriteTransitions, ["push:up", "wipe:left"])
        _ = draw(p)
        XCTAssertEqual(p.group(of: p.entries[0]), "Favourites", "the starred ones form the first group")
        XCTAssertEqual(p.group(of: try XCTUnwrap(TransitionCatalog.entry(id: "push:down"))), "Push")
        // The next launch reads them back.
        let again = TransitionsPanel(favourites: PanelLayoutState(store: store).prefs.favouriteTransitions ?? [])
        XCTAssertEqual(again.favourites, ["push:up", "wipe:left"])
        again.toggleFavourite(try XCTUnwrap(TransitionCatalog.entry(id: "push:up")))
        XCTAssertEqual(again.favourites, ["wipe:left"], "the star toggles off")
    }

    func testFavouritesSurviveAFileRoundTripAndSkipIdsThisVersionDoesNotKnow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-fav-\(UUID().uuidString)/panel-layout.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FilePanelPreferencesStore(url: url)
        var prefs = PanelPreferences(); prefs.favouriteTransitions = ["wipe:down", "iris:centre", "wipe:down", "dissolve"]
        store.save(prefs)
        let loaded = try XCTUnwrap(FilePanelPreferencesStore(url: url).load().favouriteTransitions)
        XCTAssertEqual(loaded, ["wipe:down", "iris:centre", "wipe:down", "dissolve"], "stored as written")
        XCTAssertEqual(TransitionsPanel(favourites: loaded).favourites, ["wipe:down", "dissolve"], "unknown and repeated ids are skipped on read")
        let old = try JSONDecoder().decode(PanelPreferences.self, from: Data(#"{"openInspectorGroup":"grade"}"#.utf8))
        XCTAssertNil(old.favouriteTransitions, "an older preferences file still opens")
    }

    func testClickingTheStarTogglesItWithoutApplying() throws {
        let (p, e) = try make()
        _ = draw(p)
        var saved: [[String]] = []
        p.onFavouritesChange = { saved.append($0) }
        let tile = try XCTUnwrap(p.tiles.first)
        XCTAssertTrue(p.pointerDown(CanvasPoint(tile.star.midXForTest, tile.star.midYForTest), shift: false))
        XCTAssertEqual(saved, [["dissolve"]])
        XCTAssertTrue(transitions(e).isEmpty, "a star click is not an apply")
        XCTAssertTrue(e.undoStack.isEmpty)
    }

    // MARK: Applying

    func testReturnAppliesTheHighlightedKindToTheSelectedCutInOneUndoStep() throws {
        let (p, e) = try make(selected: ["A", "B"])
        _ = draw(p)
        p.setQuery("wipe right")
        XCTAssertTrue(p.keyDown(EditorKey(.enter)), "Return applies the first match")
        let t = try XCTUnwrap(transitions(e).first)
        XCTAssertEqual(t.kind, .wipe)
        XCTAssertEqual(t.direction, .right)
        XCTAssertEqual([t.fromClipId, t.toClipId], ["A", "B"])
        XCTAssertEqual(t.durationFrames, e.defaultTransitionFrames)
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(p.status, "Added Wipe right.")
        XCTAssertTrue(e.undo())
        XCTAssertTrue(transitions(e).isEmpty)
    }

    func testArrowKeysMoveTheHighlightAndReturnAppliesIt() throws {
        let (p, e) = try make(selected: ["C"])
        _ = draw(p)
        XCTAssertNil(p.highlighted)
        XCTAssertTrue(p.keyDown(EditorKey(.right)))
        XCTAssertEqual(p.highlighted, "dissolve")
        XCTAssertTrue(p.keyDown(EditorKey(.right)))
        XCTAssertEqual(p.highlighted, "dip:black")
        XCTAssertTrue(p.keyDown(EditorKey(.left)))
        XCTAssertEqual(p.highlighted, "dissolve")
        for _ in 0..<2 { XCTAssertTrue(p.keyDown(EditorKey(.down))) }
        let moved = try XCTUnwrap(p.highlighted)
        XCTAssertNotEqual(moved, "dissolve", "down moves to a later row")
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(transitions(e).count, 1)
        XCTAssertEqual(transitions(e).first?.toClipId, "C", "C is last: its cut is the one before it")
        XCTAssertEqual(e.undoStack.count, 1)
    }

    func testADoubleClickAppliesAndOneClickOnlyHighlights() throws {
        let (p, e) = try make()
        var t = 100.0
        p.now = { t }
        _ = draw(p, CanvasSize(320, 2400))   // tall enough to show every tile
        let tile = try XCTUnwrap(p.tiles.first(where: { $0.entry.id == "push:left" })).rect
        let at = CanvasPoint(tile.x + 6, tile.y + 6)
        XCTAssertTrue(p.pointerDown(at, shift: false))
        _ = p.pointerUp(at)
        XCTAssertEqual(p.highlighted, "push:left")
        XCTAssertTrue(transitions(e).isEmpty)
        t += 0.2
        XCTAssertTrue(p.pointerDown(at, shift: false))
        XCTAssertEqual(transitions(e).first?.kind, .push)
        XCTAssertEqual(e.undoStack.count, 1)
    }

    func testADropAppliesToTheNamedCutNotTheSelectedOne() throws {
        let (p, e) = try make(selected: ["A", "B"])
        let bc = try XCTUnwrap(e.allCuts.first { $0.fromClipId == "B" })
        let outcomes = p.apply(try XCTUnwrap(TransitionCatalog.entry(id: "dip:white")), to: bc)
        XCTAssertEqual(outcomes, [.applied(lengthFrames: 15, shortenedFrom: nil)])
        XCTAssertEqual(transitions(e).map(\.toClipId), ["C"])
        XCTAssertEqual(transitions(e).first?.color, NativeCutTransition.whiteDipColor)
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo())
        XCTAssertTrue(transitions(e).isEmpty)
    }

    func testWithNoCutSelectedNothingChangesAndTheStatusSaysWhatToSelect() throws {
        let (p, e) = try make(selected: [])
        XCTAssertEqual(p.apply(try XCTUnwrap(TransitionCatalog.entry(id: "dissolve"))), [])
        XCTAssertTrue(transitions(e).isEmpty)
        XCTAssertTrue(e.undoStack.isEmpty)
        XCTAssertTrue(try XCTUnwrap(p.status).hasPrefix("Select a clip next to a cut"))
    }

    func testDraggingATileIsReportedToTheHostAndKeptAfterRelease() throws {
        let (p, _) = try make()
        _ = draw(p)
        let tile = try XCTUnwrap(p.tiles.first).rect
        let start = CanvasPoint(tile.x + 10, tile.y + 10)
        XCTAssertTrue(p.pointerDown(start, shift: false))
        XCTAssertNil(p.draggingEntry)
        XCTAssertTrue(p.pointerMove(CanvasPoint(start.x + 30, start.y + 30)))
        XCTAssertEqual(p.draggingEntry?.id, "dissolve")
        XCTAssertTrue(p.pointerUp(CanvasPoint(start.x + 30, start.y + 30)))
        XCTAssertNil(p.draggingEntry)
        XCTAssertEqual(p.lastDraggedEntry?.id, "dissolve", "the host reads the dropped entry after the release")
    }

    // MARK: Tiles

    func testTheLoopRunsTenFramesOfLeadThenTheTransitionThenTenFramesOfTrail() {
        XCTAssertEqual(TransitionTile.progress(phase: 0, lengthFrames: 15), 0)
        XCTAssertEqual(TransitionTile.progress(phase: 9.9 / 35, lengthFrames: 15), 0, accuracy: 1e-9, "still before the transition")
        XCTAssertEqual(TransitionTile.progress(phase: 17.5 / 35, lengthFrames: 15), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TransitionTile.progress(phase: 25.1 / 35, lengthFrames: 15), 1, accuracy: 1e-9, "done, the trail frames follow")
        XCTAssertEqual(TransitionTile.loopSeconds(lengthFrames: 15), 35.0 / 30.0, accuracy: 1e-9)
    }

    func testHoveringATilePlaysItAndNothingPlaysOtherwise() throws {
        let (p, _) = try make()
        _ = draw(p)
        XCTAssertFalse(p.tick(0.1), "nothing hovered or highlighted: nothing plays")
        var asked = 0
        p.onAnimate = { asked += 1 }
        let tile = try XCTUnwrap(p.tiles.first).rect
        XCTAssertTrue(p.pointerMove(CanvasPoint(tile.x + 4, tile.y + 4)))
        XCTAssertEqual(p.hoveredId, "dissolve")
        XCTAssertEqual(asked, 1, "the host is asked to tick")
        XCTAssertTrue(p.tick(0.1))
        XCTAssertGreaterThan(p.phase, 0, "the hovered tile moves along its loop")
        XCTAssertTrue(p.pointerMove(CanvasPoint(2, 2)))
        XCTAssertNil(p.hoveredId)
        XCTAssertFalse(p.tick(0.1), "the pointer left: it stops")
    }

    #if canImport(CoreGraphics) && canImport(CoreText) || os(Linux)
    /// The straight RGBA8 of a `w` x `h` bitmap after `draw`.
    private func pixels(_ w: Int, _ h: Int, _ draw: (CanvasContext) -> Void) throws -> [UInt8] {
        #if canImport(CoreGraphics) && canImport(CoreText)
        let c = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: w, height: h))
        draw(c)
        let data = try XCTUnwrap(c.ctx.data).assumingMemoryBound(to: UInt8.self)
        let stride = c.ctx.bytesPerRow
        return (0..<h).flatMap { y in (0..<w * 4).map { data[y * stride + $0] } }
        #else
        let t = CairoImageTarget(width: w, height: h)
        draw(t.canvas)
        return t.straightRGBA()
        #endif
    }

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CanvasImage {
        CanvasImage(width: 4, height: 4, rgba: (0..<16).flatMap { _ in [r, g, b, 255] })
    }

    private func tile(_ id: String, _ progress: Double) throws -> [UInt8] {
        let entry = try XCTUnwrap(TransitionCatalog.entry(id: id))
        let rect = CanvasRect(x: 0, y: 0, width: 32, height: 18)
        return try pixels(32, 18) { c in
            TransitionTile.draw(c, rect, entry: entry, progress: progress, from: .image(solid(255, 0, 0)), to: .image(solid(0, 0, 255)))
        }
    }

    private func px(_ data: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * 32 + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    func testATileForARedToBlueCutContainsBothColours() throws {
        let dissolve = px(try tile("dissolve", 0.5), 16, 9)
        XCTAssertLessThanOrEqual(abs(dissolve.r - 128), 3)
        XCTAssertLessThanOrEqual(abs(dissolve.b - 128), 3, "half red, half blue")
        let start = px(try tile("dissolve", 0), 16, 9), end = px(try tile("dissolve", 1), 16, 9)
        XCTAssertEqual([start.r, start.b], [255, 0], "the outgoing clip before the transition")
        XCTAssertEqual([end.r, end.b], [0, 255], "the incoming clip after it")
        let wipe = try tile("wipe:left", 0.5)
        XCTAssertEqual(px(wipe, 4, 9).r, 255, "the old picture stays on the left")
        XCTAssertEqual(px(wipe, 28, 9).b, 255, "the new one comes in from the right")
        let push = try tile("push:left", 0.5)
        XCTAssertEqual(px(push, 4, 9).r, 255)
        XCTAssertEqual(px(push, 28, 9).b, 255)
        let down = try tile("wipe:down", 0.5)
        XCTAssertEqual(px(down, 16, 3).b, 255, "wipe down: the new picture grows from the top")
        XCTAssertEqual(px(down, 16, 15).r, 255)
        let dip = try tile("dip:black", 0.5)
        XCTAssertEqual(px(dip, 16, 9).r + px(dip, 16, 9).b, 0, "a dip is at its colour mid-way")
    }
    #endif
}

private extension CanvasRect {
    var midXForTest: Double { x + width / 2 }
    var midYForTest: Double { y + height / 2 }
}
