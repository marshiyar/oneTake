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
import MpvfxTimeline
@testable import MpvfxPanels

/// Gestures on the dock through its public pointer and key entry points, resolved against a real draw (on the
/// font-independent measuring canvas, so they run on every OS).
final class DockViewTests: XCTestCase {
    let registry = DockRegistry.editor
    let bounds = CanvasRect(x: 0, y: 0, width: 1440, height: 877)
    var clock = 100.0
    var commits: [DockLayout] = []
    var painted: [DockPanelID] = []

    func makeView(_ layout: DockLayout? = nil) -> DockView {
        let v = DockView(layout: layout ?? DockDefaults.layout(registry), registry: registry)
        v.now = { [unowned self] in self.clock }
        v.onCommit = { [unowned self] in self.commits.append($0) }
        redraw(v)
        return v
    }

    func redraw(_ v: DockView) {
        painted = []
        v.draw(PanelMeasureCanvas(), in: bounds) { [unowned self] id, _, _ in self.painted.append(id) }
    }

    func tab(_ v: DockView, _ panel: DockPanelID) throws -> DockTabBar.Tab {
        try XCTUnwrap(v.tabs.values.joined().first { $0.panel == panel }, panel)
    }

    func frame(_ v: DockView, _ panel: DockPanelID) throws -> DockGroupFrame { try XCTUnwrap(v.geometry.frame(containing: panel), panel) }

    func center(_ r: CanvasRect) -> CanvasPoint { CanvasPoint(r.midX, r.midY) }

    /// Press on a panel's tab, move through `points`, release at the last one.
    func drag(_ v: DockView, _ panel: DockPanelID, through points: [CanvasPoint], swap: Bool = false) throws {
        let start = center(try tab(v, panel).rect)
        XCTAssertEqual(v.pointerDown(start), .handled)
        for p in points { v.pointerMove(p, swap: swap) }
        v.pointerUp(points.last ?? start)
        redraw(v)
    }

    // MARK: Drawing

    func testEveryGroupDrawsItsActivePanelsContentOnly() {
        _ = makeView()
        XCTAssertEqual(Set(painted), ["media", "preview", "inspector", "timeline"])
    }

    func testTargetsAreAtLeast24PointsAndPreviewAndTimelineHaveNoCloseButton() throws {
        let v = makeView()
        for t in v.tabs.values.joined() {
            XCTAssertGreaterThanOrEqual(t.rect.height, 24, t.panel)
            XCTAssertGreaterThanOrEqual(t.rect.width, 24, t.panel)
            if let c = t.close { XCTAssertEqual(c.width, 24); XCTAssertEqual(c.height, 24) }
        }
        XCTAssertNil(try tab(v, "preview").close)
        XCTAssertNil(try tab(v, "timeline").close)
        XCTAssertNotNil(try tab(v, "media").close)
        for f in v.geometry.groups { XCTAssertEqual(DockTabBar.menuRect(f.strip).width, 24) }
    }

    // MARK: Drag

    func testDraggingATabOntoAnotherGroupsTabBarStacksItThere() throws {
        let v = makeView()
        let strip = try frame(v, "inspector").strip
        let end = CanvasPoint(try tab(v, "renders").rect.maxX + 4, strip.midY)
        try drag(v, "media", through: [CanvasPoint(400, 300), end])
        XCTAssertEqual(v.layout.root.group(containing: "media")?.panels, ["inspector", "renders", "media"])
        XCTAssertEqual(v.layout.root.group(containing: "media")?.active, "media")
        XCTAssertEqual(commits.count, 1, "one commit per drop")
        XCTAssertEqual(v.focused, "media")
    }

    func testReorderingTabsWithinAGroup() throws {
        let v = makeView()
        let renders = try tab(v, "renders").rect
        try drag(v, "inspector", through: [CanvasPoint(renders.maxX - 2, renders.midY)])
        XCTAssertEqual(v.layout.root.group(containing: "inspector")?.panels, ["renders", "inspector"])
    }

    func testDraggingOntoAGroupsEdgeSplitsIt() throws {
        let v = makeView()
        let content = try frame(v, "preview").content
        try drag(v, "renders", through: [CanvasPoint(content.midX, content.maxY - 10)])
        let g = try frame(v, "renders").frame, p = try frame(v, "preview").frame
        XCTAssertEqual(g.x, p.x)
        XCTAssertGreaterThan(g.y, p.y, "renders sits below the preview")
        XCTAssertEqual(v.layout.root.group(containing: "inspector")?.panels, ["inspector"])
    }

    func testDraggingToTheWindowEdgeDocksAlongIt() throws {
        let v = makeView()
        try drag(v, "inspector", through: [CanvasPoint(700, 400), CanvasPoint(700, bounds.maxY - 6)])
        let f = try frame(v, "inspector").frame
        XCTAssertEqual(f.x, 0)
        XCTAssertEqual(f.width, bounds.width, "a window-edge group spans the whole window")
        XCTAssertEqual(f.maxY, bounds.maxY)
    }

    func testOptionDropOnAnotherTabSwapsThePanels() throws {
        let v = makeView()
        let target = center(try tab(v, "renders").rect)
        try drag(v, "media", through: [CanvasPoint(500, 300), target], swap: true)
        XCTAssertEqual(v.layout.root.group(containing: "media")?.panels, ["inspector", "media"])
        XCTAssertEqual(v.layout.root.group(containing: "renders")?.panels, ["renders"])
    }

    func testTheDropZoneOverlayFollowsThePointer() throws {
        let v = makeView()
        XCTAssertEqual(v.pointerDown(center(try tab(v, "media").rect)), .handled)
        v.pointerMove(CanvasPoint(400, 300))
        let content = try frame(v, "preview").content
        v.pointerMove(CanvasPoint(content.midX, content.midY))
        XCTAssertEqual(v.drag?.preview?.target, .move(.stack(group: try frame(v, "preview").group.id, index: nil)))
        XCTAssertEqual(v.drag?.preview?.highlight, try frame(v, "preview").frame)
        v.pointerMove(CanvasPoint(content.x + 10, content.midY))
        XCTAssertEqual(v.drag?.preview?.target, .move(.split(group: try frame(v, "preview").group.id, edge: .left)))
        let strip = try frame(v, "inspector").strip
        v.pointerMove(CanvasPoint(strip.x + 2, strip.midY))
        XCTAssertNotNil(v.drag?.preview?.insertion, "between tabs the overlay shows the insertion bar")
        XCTAssertEqual(v.hint, DockView.dragHint)
        // Over its own lone tab nothing would change: no overlay.
        v.pointerMove(center(try tab(v, "media").rect))
        XCTAssertNil(v.drag?.preview)
    }

    func testEscapeCancelsADragAndTheLayoutStays() throws {
        let v = makeView()
        let before = v.layout
        XCTAssertEqual(v.pointerDown(center(try tab(v, "media").rect)), .handled)
        v.pointerMove(CanvasPoint(700, 400))
        XCTAssertNotNil(v.drag)
        XCTAssertTrue(v.keyDown(EditorKey(.escape)))
        v.pointerUp(CanvasPoint(700, 400))
        XCTAssertEqual(v.layout, before)
        XCTAssertEqual(commits, [])
    }

    func testAShortMoveIsAClickNotADrag() throws {
        let v = makeView()
        let r = try tab(v, "renders").rect
        XCTAssertEqual(v.pointerDown(center(r)), .handled)
        v.pointerMove(CanvasPoint(r.midX + 2, r.midY + 1))
        XCTAssertNil(v.drag)
        v.pointerUp(CanvasPoint(r.midX + 2, r.midY + 1))
        XCTAssertEqual(v.layout.root.group(containing: "renders")?.active, "renders", "the click shows the tab")
        XCTAssertEqual(v.layout.root.group(containing: "renders")?.panels, ["inspector", "renders"])
    }

    // MARK: Close and menu

    func testTheCloseButtonClosesThePanel() throws {
        let v = makeView()
        let close = try XCTUnwrap(try tab(v, "renders").close)
        XCTAssertEqual(v.pointerDown(center(close)), .handled)
        XCTAssertFalse(v.layout.isOpen("renders"))
        XCTAssertNotNil(v.layout.closed["renders"])
        XCTAssertEqual(commits.count, 1)
    }

    func testTheMenuButtonReportsItsGroupAndAnchor() throws {
        let v = makeView()
        var opened: (DockGroup, CanvasRect)?
        v.onMenu = { opened = ($0, $1) }
        let f = try frame(v, "timeline")
        XCTAssertEqual(v.pointerDown(center(DockTabBar.menuRect(f.strip))), .handled)
        XCTAssertEqual(opened?.0.panels, ["timeline"])
        XCTAssertEqual(opened?.1, DockTabBar.menuRect(f.strip))
    }

    // MARK: Splitters

    func testDraggingASplitterResizesLiveAndCommitsOnRelease() throws {
        let v = makeView()
        let s = try XCTUnwrap(v.geometry.splitters.first { $0.axis == .row && $0.index == 0 })
        XCTAssertEqual(v.pointerDown(center(s.seam)), .handled)
        XCTAssertEqual(v.cursor(at: center(s.seam)), .columnResize)
        v.pointerMove(CanvasPoint(s.seam.midX + 50, s.seam.midY))
        redraw(v)
        XCTAssertEqual(try frame(v, "media").frame.width, 369 + 50, accuracy: 1)
        XCTAssertEqual(commits.count, 0, "no commit mid-drag")
        v.pointerUp(CanvasPoint(s.seam.midX + 50, s.seam.midY))
        XCTAssertEqual(commits.count, 1)
    }

    func testDoubleClickingASplitterResetsIt() throws {
        let v = makeView()
        var s = try XCTUnwrap(v.geometry.splitters.first { $0.axis == .column })
        XCTAssertEqual(v.pointerDown(center(s.seam)), .handled)
        v.pointerMove(CanvasPoint(s.seam.midX, s.seam.midY - 120))
        v.pointerUp(CanvasPoint(s.seam.midX, s.seam.midY - 120))
        redraw(v)
        s = try XCTUnwrap(v.geometry.splitters.first { $0.axis == .column })
        clock += 1
        _ = v.pointerDown(center(s.seam)); v.pointerUp(center(s.seam))
        clock += 0.2
        _ = v.pointerDown(center(s.seam)); v.pointerUp(center(s.seam))
        redraw(v)
        XCTAssertEqual(try frame(v, "timeline").frame.height, 360 + PanelTabStrip.height, accuracy: 1)
    }

    // MARK: Keyboard, focus, content

    func testCommandShiftWClosesTheFocusedPanelButNotThePreview() throws {
        let v = makeView()
        _ = v.pointerDown(center(try tab(v, "inspector").rect)); v.pointerUp(center(try tab(v, "inspector").rect))
        XCTAssertTrue(v.keyDown(EditorKey(.char("W"), shift: true, meta: true)))
        XCTAssertFalse(v.layout.isOpen("inspector"))
        redraw(v)
        _ = v.pointerDown(center(try frame(v, "preview").content))
        XCTAssertEqual(v.focused, "preview")
        XCTAssertFalse(v.keyDown(EditorKey(.char("w"), shift: true, ctrl: true)), "the preview cannot be closed")
        XCTAssertTrue(v.layout.isOpen("preview"))
    }

    func testCtrlTabCyclesPanelFocusAndShowsTheRing() throws {
        let v = makeView()
        XCTAssertEqual(v.focused, "timeline")
        XCTAssertTrue(v.keyDown(EditorKey(.tab, ctrl: true)))
        XCTAssertEqual(v.focused, "media", "after the last panel, the first")
        XCTAssertTrue(v.focusVisible)
        XCTAssertTrue(v.keyDown(EditorKey(.tab, shift: true, ctrl: true)))
        XCTAssertEqual(v.focused, "timeline")
        v.focus("renders", visible: true)
        XCTAssertEqual(v.layout.root.group(containing: "renders")?.active, "renders", "focusing a hidden tab shows it")
        _ = v.pointerDown(CanvasPoint(700, 300))
        XCTAssertFalse(v.focusVisible, "a pointer press hides the ring")
    }

    func testAPressInContentReportsThePanelAndItsLocalPoint() throws {
        let v = makeView()
        let c = try frame(v, "preview").content
        XCTAssertEqual(v.pointerDown(CanvasPoint(c.x + 10, c.y + 20)), .content("preview", local: CanvasPoint(10, 20)))
        XCTAssertEqual(v.focused, "preview")
        XCTAssertEqual(v.contentRect(of: "preview"), c)
        XCTAssertNil(v.contentRect(of: "renders"), "behind the Design tab")
    }

    func testHintsNameWhatIsUnderThePointer() throws {
        let v = makeView()
        v.pointerMove(center(try tab(v, "media").rect))
        XCTAssertEqual(v.hint, DockView.tabHint)
        v.pointerMove(center(try XCTUnwrap(try tab(v, "media").close)))
        XCTAssertEqual(v.hint, DockView.closeHint)
        v.pointerMove(center(try XCTUnwrap(v.geometry.splitters.first).seam))
        XCTAssertEqual(v.hint, DockView.splitterHint)
        v.pointerMove(center(try frame(v, "preview").content))
        XCTAssertNil(v.hint)
    }

    func testSetLayoutReplacesItWithoutACommit() throws {
        let v = makeView()
        var other = DockDefaults.layout(registry)
        try other.close("media", registry: registry)
        v.setLayout(other)
        XCTAssertEqual(v.layout, other)
        XCTAssertEqual(commits, [])
    }
}
