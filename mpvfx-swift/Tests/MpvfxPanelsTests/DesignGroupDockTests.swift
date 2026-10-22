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
@testable import MpvfxPanels

private func demoEditor() throws -> TimelineEditor { try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime()) }
private func mid(_ r: CanvasRect) -> CanvasPoint { CanvasPoint(r.midX, r.midY) }

/// Design-tab groups as dock panels (issue #414): drag out, never duplicated, reorder, layout round trip, undo.
final class DesignGroupDockTests: XCTestCase {
    let registry = DockRegistry.editor
    let size = CanvasRect(x: 0, y: 0, width: 360, height: 1400)

    func makeInspector(select id: String = "clip:a") throws -> (InspectorPanel, TimelineEditor) {
        let editor = try demoEditor()
        let p = InspectorPanel(); p.editor = editor; p.selection = [id]; p.time = 1
        p.draw(PanelMeasureCanvas(), in: size)
        return (p, editor)
    }

    func titles(_ p: InspectorPanel) -> [String] { p.groups.map(\.title) }

    // MARK: Ids and registry

    func testPanelIDsAreStableAndRegisteredClosedByDefault() {
        XCTAssertEqual(DesignGroups.panelIDs, ["design.transform", "design.style", "design.grade", "design.effects", "design.audio-fx", "design.media"])
        for id in DesignGroups.panelIDs {
            XCTAssertTrue(registry.contains(id), id)
            XCTAssertTrue(registry.isClosable(id), id)
        }
        let layout = DockDefaults.layout(registry)
        XCTAssertTrue(DesignGroups.panelIDs.allSatisfy { !layout.isOpen($0) }, "every group starts in the Design tab")
        XCTAssertEqual(layout.openPanels, ["media", "preview", "inspector", "renders", "history", "info", "timeline"])
    }

    func testDotsAreValidInsideAnIDOnly() {
        for ok in ["design.style", "a.b.c", "design.audio-fx"] { XCTAssertTrue(DockRegistry.isValidID(ok), ok) }
        for bad in [".a", "a.", "a..b", "a.B", "a/b"] { XCTAssertFalse(DockRegistry.isValidID(bad), bad) }
    }

    // MARK: Drag out, one place only

    func testDraggingAHeaderOutRemovesTheGroupFromTheDesignTabAndOpensItsPanel() throws {
        let (p, _) = try makeInspector()
        XCTAssertEqual(titles(p), ["Transform", "Style", "Grade", "Effects", "Audio FX", "Media"])
        var events: [InspectorPanel.GroupDragEvent] = []
        p.onGroupDrag = { events.append($0) }
        let header = try XCTUnwrap(p.hits.rect { $0 == .group("style") })
        let open = p.openGroupId
        XCTAssertTrue(p.pointerDown(mid(header)))
        XCTAssertTrue(p.pointerMove(CanvasPoint(header.midX + 10, header.midY)))
        XCTAssertEqual(p.openGroupId, open, "a drag is not a click: the accordion stays")
        XCTAssertTrue(p.pointerMove(CanvasPoint(-80, header.midY)))
        p.pointerUp(CanvasPoint(-80, header.midY))
        XCTAssertEqual(events, [.moved("design.style", CanvasPoint(-80, header.midY)), .dropped("design.style", CanvasPoint(-80, header.midY))])

        // The host drops it into the dock: the panel opens, the Design tab drops the group.
        let view = DockView(layout: DockDefaults.layout(registry), registry: registry)
        view.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 1440, height: 877)) { _, _, _ in }
        let design = try XCTUnwrap(view.geometry.frame(containing: "inspector"))
        view.beginExternalDrag("design.style", at: CanvasPoint(design.content.midX, design.content.maxY - 4))
        XCTAssertNotNil(view.drag?.preview, "the overlay shows where it lands")
        view.pointerMove(CanvasPoint(design.content.midX, design.content.maxY - 6))
        view.pointerUp(CanvasPoint(design.content.midX, design.content.maxY - 6))
        XCTAssertEqual(view.layout.detachedDesignPanels, ["design.style"])
        p.syncDock(view.layout)
        p.draw(PanelMeasureCanvas(), in: size)
        XCTAssertEqual(titles(p), ["Transform", "Grade", "Effects", "Audio FX", "Media"])
    }

    func testNeverTwoCopiesTheDetachedPanelHoldsTheGroupTheTabLost() throws {
        let (tab, editor) = try makeInspector()
        tab.detachedPanels = ["design.grade", "design.audio-fx"]
        let grade = InspectorPanel(); grade.pinnedPanel = "design.grade"; grade.follow(tab)
        let audio = InspectorPanel(); audio.pinnedPanel = "design.audio-fx"; audio.follow(tab)
        let all = Set(["layout", "style", "grade", "effects", "clip-effects", "audio-fx", "media"])
        var seen: [String] = tab.groups.map(\.id)
        for panel in [grade, audio] { seen += panel.groups.map(\.id) }
        XCTAssertEqual(seen.count, Set(seen).count, "no group in two places")
        XCTAssertTrue(Set(seen).isSubset(of: all))
        XCTAssertEqual(grade.groups.map(\.id), ["grade"])
        XCTAssertEqual(audio.groups.map(\.id), ["audio-fx"])
        XCTAssertFalse(tab.groups.map(\.id).contains("grade"))
        XCTAssertNotNil(editor.clip("clip:a"))
        // No row key of a detached group is addressable from the Design tab.
        let c = PanelMeasureCanvas()
        grade.draw(c, in: size)
        XCTAssertNil(grade.hits.rect { $0 == .group("layout") })
        XCTAssertNotNil(grade.hits.rect { $0 == .group("grade") })
    }

    func testEveryPanelShowsAllItsGroupsOpen() throws {
        let (tab, _) = try makeInspector()
        let fx = InspectorPanel(); fx.pinnedPanel = "design.effects"; fx.follow(tab)
        XCTAssertEqual(fx.groups.map(\.id), ["effects"])   // clip effects appear once the clip has other effects
        let media = InspectorPanel(); media.pinnedPanel = "design.media"; media.follow(tab)
        let c = PanelMeasureCanvas()
        media.draw(c, in: size)
        XCTAssertTrue(c.drawnStrings.contains("Volume"), "the rows draw without opening an accordion header")
    }

    // MARK: Same rows, live, one undo step

    func testEditsFromTheDetachedPanelGoThroughUndoAndReachTheDesignTabsDocument() throws {
        let (tab, editor) = try makeInspector()
        tab.detachedPanels = ["design.transform"]
        let panel = InspectorPanel(); panel.pinnedPanel = "design.transform"; panel.follow(tab)
        var refreshed = 0
        panel.onEdited = { refreshed += 1 }
        panel.draw(PanelMeasureCanvas(), in: size)
        let field = try XCTUnwrap(panel.hits.rect { $0 == .field("x") })
        XCTAssertTrue(panel.pointerDown(mid(field)))
        for _ in 0..<5 { _ = panel.keyDown(EditorKey(.backspace)) }
        for ch in "75" { _ = panel.keyDown(EditorKey(.char(ch))) }
        XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
        XCTAssertEqual(editor.transform(clipId: "clip:a", time: 1).x, 75)
        XCTAssertEqual(editor.undoStack.count, 1, "one named undo step")
        XCTAssertEqual(editor.undoLabel, "Edit transform")
        XCTAssertGreaterThan(refreshed, 0)
        editor.undo()
        XCTAssertNotEqual(editor.transform(clipId: "clip:a", time: 1).x, 75)
    }

    func testTheDetachedPanelFollowsTheSelectionLive() throws {
        let (tab, _) = try makeInspector(select: "clip:a")
        let panel = InspectorPanel(); panel.pinnedPanel = "design.audio-fx"; panel.follow(tab)
        XCTAssertEqual(panel.groups.map(\.id), ["audio-fx"])
        tab.selection = ["clip:music"]; panel.follow(tab)
        XCTAssertEqual(panel.groups.map(\.id), ["audio-fx"])
        tab.selection = []; panel.follow(tab)
        XCTAssertTrue(panel.groups.isEmpty)
        let c = PanelMeasureCanvas()
        panel.draw(c, in: size)
        XCTAssertTrue(c.drawnStrings.contains("Nothing here for this selection."))
    }

    // MARK: Dock back, close, reopen

    func testDockingBackRestoresTheOriginalOrder() throws {
        var layout = DockDefaults.layout(registry)
        try layout.moveToPanel("design.style", registry: registry)
        try layout.moveToPanel("design.grade", registry: registry)
        XCTAssertEqual(layout.detachedDesignPanels, ["design.style", "design.grade"])
        try layout.returnToDesign("design.style", registry: registry)
        let (p, _) = try makeInspector()
        p.syncDock(layout)
        XCTAssertEqual(titles(p), ["Transform", "Style", "Effects", "Audio FX", "Media"], "Grade is still out; Style is back in its slot")
        try layout.returnToDesign("design.grade", registry: registry)
        p.syncDock(layout)
        XCTAssertEqual(titles(p), ["Transform", "Style", "Grade", "Effects", "Audio FX", "Media"])
    }

    func testDroppingADetachedPanelOnTheDesignTabReturnsIt() throws {
        var layout = DockDefaults.layout(registry)
        try layout.moveToPanel("design.media", registry: registry)
        let view = DockView(layout: layout, registry: registry)
        view.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 1440, height: 877)) { _, _, _ in }
        let tab = try XCTUnwrap(view.tabs.values.joined().first { $0.panel == "design.media" })
        let design = try XCTUnwrap(view.geometry.frame(containing: "inspector"))
        XCTAssertEqual(view.pointerDown(mid(tab.rect)), .handled)
        let target = CanvasPoint(design.content.midX, design.content.midY)
        view.pointerMove(target)
        view.pointerUp(target)
        XCTAssertFalse(view.layout.isOpen("design.media"), "docked back = the Design tab shows it again")
        XCTAssertTrue(view.layout.detachedDesignPanels.isEmpty)
    }

    func testClosingThePanelReturnsTheGroupAndTheWindowMenuReopensIt() throws {
        var layout = DockDefaults.layout(registry)
        try layout.moveToPanel("design.effects", registry: registry)
        XCTAssertEqual(layout.root.group(containing: "design.effects").map { $0.panels }, ["design.effects"], "its own panel under the Design tab's")
        try layout.close("design.effects", registry: registry)
        XCTAssertTrue(layout.detachedDesignPanels.isEmpty)
        try layout.open("design.effects", registry: registry)
        XCTAssertEqual(layout.detachedDesignPanels, ["design.effects"], "reopened from the Window menu")
        XCTAssertEqual(registry.specs.filter { DesignGroups.isDesignPanel($0.id) }.count, 6, "the menu lists all six")
    }

    func testLayoutRoundTripKeepsDetachedGroups() throws {
        var layout = DockDefaults.layout(registry)
        try layout.moveToPanel("design.audio-fx", registry: registry)
        try layout.dock("design.grade", at: .window(.left), registry: registry)
        let file = DockFile(workspaces: [DockFile.defaultWorkspace: layout])
        let data = try DockCodec.encode(file)
        let back = try DockCodec.decode(data, registry: registry).get()
        let restored = try XCTUnwrap(back.file.workspaces[DockFile.defaultWorkspace])
        XCTAssertEqual(restored, layout)
        XCTAssertEqual(restored.detachedDesignPanels, ["design.audio-fx", "design.grade"])
    }

    func testAnOpenDesignPanelAndAMissingOneRepairQuietly() throws {
        var layout = DockDefaults.layout(registry)
        layout.repair(registry: registry)
        XCTAssertTrue(layout.detachedDesignPanels.isEmpty)
        XCTAssertThrowsError(try layout.dock("design.nope", at: .window(.left), registry: registry))
        XCTAssertThrowsError(try layout.dock("design.style", at: .stack(group: "gone", index: nil), registry: registry))
        XCTAssertTrue(layout.detachedDesignPanels.isEmpty, "a refused drop changes nothing")
    }

    // MARK: Reorder inside the Design tab

    func testDraggingAHeaderAboveAnotherReordersAndSaves() throws {
        let store = MemoryPanelPreferencesStore()
        let state = PanelLayoutState(store: store)
        let (p, _) = try makeInspector()
        p.layout = state
        let media = try XCTUnwrap(p.hits.rect { $0 == .group("media") })
        let style = try XCTUnwrap(p.hits.rect { $0 == .group("style") })
        XCTAssertTrue(p.pointerDown(mid(media)))
        XCTAssertTrue(p.pointerMove(CanvasPoint(media.midX, style.y + 4)))
        XCTAssertEqual(p.groupDrag?.slotBefore, "design.style")
        p.pointerUp(CanvasPoint(media.midX, style.y + 4))
        p.draw(PanelMeasureCanvas(), in: size)
        XCTAssertEqual(titles(p), ["Transform", "Media", "Style", "Grade", "Effects", "Audio FX"])
        XCTAssertEqual(store.value.designGroupOrder?.first, "design.transform")
        XCTAssertEqual(store.value.designGroupOrder?.prefix(3).map { $0 }, ["design.transform", "design.media", "design.style"])
        // A new session restores the order.
        let right = RightPanel(layout: PanelLayoutState(store: store))
        XCTAssertEqual(right.inspector.designOrder, store.value.designGroupOrder)
    }

    func testEscapeCancelsAHeaderDrag() throws {
        let (p, _) = try makeInspector()
        var events: [InspectorPanel.GroupDragEvent] = []
        p.onGroupDrag = { events.append($0) }
        let header = try XCTUnwrap(p.hits.rect { $0 == .group("grade") })
        _ = p.pointerDown(mid(header))
        _ = p.pointerMove(CanvasPoint(-50, header.midY))
        XCTAssertTrue(p.keyDown(EditorKey(.escape)))
        p.pointerUp(CanvasPoint(-50, header.midY))
        XCTAssertEqual(events.last, .cancelled("design.grade"))
        XCTAssertNil(p.groupDrag)
        XCTAssertNil(p.designOrder)
    }

    func testAPlainClickStillTogglesTheAccordion() throws {
        let (p, _) = try makeInspector()
        let header = try XCTUnwrap(p.hits.rect { $0 == .group("media") })
        XCTAssertTrue(p.pointerDown(mid(header)))
        p.pointerUp(mid(header))
        XCTAssertEqual(p.openGroupId, "media")
    }

    // MARK: Keyboard menu

    func testTheHeaderMenuOffersMoveToPanelAndReturnToDesign() throws {
        let (tab, _) = try makeInspector()
        var requests: [InspectorPanel.GroupMenuRequest] = []
        tab.onGroupMenu = { requests.append($0) }
        var moved: [DockPanelID] = [], returned: [DockPanelID] = []
        tab.onMoveToPanel = { moved.append($0) }; tab.onReturnToDesign = { returned.append($0) }
        // Keyboard: Tab to the ⋯ of Media's header, Enter.
        var guardCount = 0
        while tab.focus.current != .groupMenu("media"), guardCount < 200 { _ = tab.keyDown(EditorKey(.tab)); guardCount += 1 }
        XCTAssertEqual(tab.focus.current, .groupMenu("media"))
        XCTAssertTrue(tab.keyDown(EditorKey(.enter)))
        let menu = try XCTUnwrap(requests.last)
        XCTAssertEqual(menu.items.map(\.title), ["Move to Panel"])
        menu.items[0].run()
        XCTAssertEqual(moved, ["design.media"])

        let panel = InspectorPanel(); panel.pinnedPanel = "design.media"; panel.follow(tab)
        panel.draw(PanelMeasureCanvas(), in: size)
        let button = try XCTUnwrap(panel.hits.rect { $0 == .groupMenu("media") })
        XCTAssertTrue(panel.pointerDown(mid(button)))
        let back = try XCTUnwrap(requests.last)
        XCTAssertEqual(back.items.map(\.title), ["Return to Design"])
        back.items[0].run()
        XCTAssertEqual(returned, ["design.media"])
        XCTAssertNil(tab.hits.rect { $0 == .groupMenu("text") }, "Text is not a detachable group")
    }
}
