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
import MpvfxTheme
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// The shared tab bar (`PanelTabBar`, docs/DESIGN.md "Tabs"): it scales with overflow, keeps the selected tab
/// visible and marked, moves by keyboard, reports close and drag starts, and every hosting panel uses it.
final class PanelTabBarTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    static func tabs(_ labels: [String], closable: Bool = false) -> [PanelTab] {
        labels.enumerated().map { PanelTab(id: "t\($0.offset)", label: $0.element, closable: closable) }
    }

    static let strip = CanvasRect(x: 4, y: 0, width: 300, height: 32)

    func testTabsKeepTheirNaturalWidthWhileTheyFit() {
        let c = PanelMeasureCanvas(), t = Self.tabs(["Design", "Renders (3)"])
        let l = PanelTabBar(tabs: t, selected: "t0", style: .strip).layout(c, in: Self.strip)
        XCTAssertNil(l.overflow); XCTAssertTrue(l.hidden.isEmpty)
        XCTAssertEqual(l.slots.map(\.rect.x), [4, 4 + PanelTabBar.naturalWidth(c, t[0], style: .strip)])
        for s in l.slots { XCTAssertGreaterThanOrEqual(s.rect.width, PanelGrid.minTarget); XCTAssertEqual(s.rect.height, 32) }
    }

    func testOverflowKeepsTheSelectedTabVisibleAndHidesTheRestBehindOneButton() throws {
        let c = PanelMeasureCanvas(), t = Self.tabs(["Master", "Red", "Green", "Blue", "Hue vs hue", "Hue vs sat", "Hue vs luma"])
        let area = CanvasRect(x: 0, y: 0, width: 200, height: 32)
        for sel in t.map(\.id) {
            let l = PanelTabBar(tabs: t, selected: sel, style: .inline).layout(c, in: area)
            let button = try XCTUnwrap(l.overflow, sel)
            XCTAssertTrue(l.slots.contains { $0.tab.id == sel }, "\(sel) stays visible")
            XCTAssertEqual(Set(l.slots.map(\.tab.id)).union(l.hidden.map(\.id)), Set(t.map(\.id)), "every tab is shown or behind the button")
            XCTAssertLessThanOrEqual(button.maxX, area.maxX + 0.01)
            XCTAssertGreaterThanOrEqual(button.width, PanelGrid.minTarget); XCTAssertGreaterThanOrEqual(button.height, PanelGrid.minTarget)
            for s in l.slots { XCTAssertLessThanOrEqual(s.rect.maxX, button.x + 0.01, "tabs stop before the button") }
        }
    }

    func testArrowsHomeAndEndMoveTheSelection() {
        let t = Self.tabs(["A", "B", "C"])
        func key(_ code: EditorKey.Code) -> EditorKey { EditorKey(code) }
        XCTAssertEqual(PanelTabBar.tab(after: key(.right), from: "t0", in: t), "t1")
        XCTAssertEqual(PanelTabBar.tab(after: key(.right), from: "t2", in: t), "t0", "wraps")
        XCTAssertEqual(PanelTabBar.tab(after: key(.left), from: "t0", in: t), "t2", "wraps")
        XCTAssertEqual(PanelTabBar.tab(after: key(.home), from: "t1", in: t), "t0")
        XCTAssertEqual(PanelTabBar.tab(after: key(.end), from: "t1", in: t), "t2")
        XCTAssertNil(PanelTabBar.tab(after: key(.enter), from: "t1", in: t))
    }

    func testCloseButtonsAreTargetsInsideTheirTabAndWinTheHit() throws {
        let c = PanelMeasureCanvas(), t = Self.tabs(["Timeline", "Viewer"], closable: true)
        let l = PanelTabBar(tabs: t, selected: "t0", style: .strip).layout(c, in: Self.strip)
        let s = try XCTUnwrap(l.slots.first), x = try XCTUnwrap(s.close)
        XCTAssertEqual(PanelTabBar.part(at: CanvasPoint(x.midX, x.midY), in: l), .close("t0"))
        XCTAssertEqual(PanelTabBar.part(at: CanvasPoint(s.rect.x + 4, s.rect.midY), in: l), .tab("t0"))
        let rects = PanelTabBar.hitRects(l)
        for (r, _) in rects { XCTAssertGreaterThanOrEqual(r.width, PanelGrid.minTarget); XCTAssertGreaterThanOrEqual(r.height, PanelGrid.minTarget) }
        XCTAssertEqual(rects.map(\.1), [.tab("t0"), .close("t0"), .tab("t1"), .close("t1")])
    }

    func testADragStartsOnlyAfterTheThreshold() {
        var d = PanelTabDrag()
        d.press("t1", at: CanvasPoint(10, 10))
        XCTAssertNil(d.move(CanvasPoint(12, 11)), "a click wobble is not a drag")
        XCTAssertEqual(d.move(CanvasPoint(10, 15)), "t1")
        XCTAssertNil(d.move(CanvasPoint(10, 30)), "reported once")
        d.release()
        XCTAssertNil(d.move(CanvasPoint(40, 40)))
    }

    func testTheSelectedTabIsMarkedAndTheOthersAreReadable() {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            let c = PanelMeasureCanvas(), t = Self.tabs(["Design", "Renders"])
            let l = PanelTabBar(tabs: t, selected: "t1", style: .strip).layout(c, in: Self.strip)
            PanelTabBar(tabs: t, selected: "t1", style: .strip).draw(c, l, hovered: nil)
            let underline = c.fills.filter { $0.1 == PanelTheme.accent }
            XCTAssertEqual(underline.count, 1, "one underline, under the selected tab")
            let ink = Dictionary(uniqueKeysWithValues: c.texts.map { ($0.0, $0.3) })
            XCTAssertEqual(ink["Renders"], PanelTheme.text0)
            XCTAssertEqual(ink["Design"], PanelTheme.text2)
            let bg = ThemeTokens.panelBgPair.now, idle = ThemeTokens.textPairs[2].now
            XCTAssertGreaterThanOrEqual(idle.contrast(bg), 4.5, "\(mode): an idle tab label reaches 4.5:1")
        }
    }

    // MARK: The bars in the panels

    static func key(_ code: EditorKey.Code, shift: Bool = false) -> EditorKey { EditorKey(code, shift: shift) }

    /// The right panel's header is reached by Tab on the Design tab, before the inspector; the arrows switch tabs.
    func testTheRightPanelHeaderIsReachedByKeyboardAndArrowsSwitchTabs() throws {
        let (r, c) = try PanelLayoutAuditTests.panel(clip: "clip:a", group: "layout", width: 409)
        func redraw() { c.reset(); r.draw(c, size: CanvasSize(409, 900)) }
        XCTAssertTrue(r.keyDown(Self.key(.tab))); redraw()
        XCTAssertEqual(r.focus.current, .design, "the selected tab is the first stop")
        XCTAssertTrue(r.keyDown(Self.key(.tab))); XCTAssertEqual(r.focus.current, .hide, "the unselected Easing and Renders tabs are skipped")
        XCTAssertTrue(r.keyDown(Self.key(.tab))); XCTAssertEqual(r.focus.current, .panelMenu)
        XCTAssertTrue(r.keyDown(Self.key(.tab))); redraw()
        XCTAssertFalse(r.focus.visible); XCTAssertTrue(r.inspector.focus.visible, "Tab goes on into the inspector")
        XCTAssertTrue(r.keyDown(Self.key(.tab, shift: true))); redraw()
        XCTAssertEqual(r.focus.current, .panelMenu, "Shift+Tab from the inspector's first stop comes back to the header")
        XCTAssertTrue(r.keyDown(Self.key(.tab, shift: true))); XCTAssertTrue(r.keyDown(Self.key(.tab, shift: true)))
        XCTAssertEqual(r.focus.current, .design)
        XCTAssertTrue(r.keyDown(Self.key(.right))); redraw()
        XCTAssertEqual(r.layout.rightPanelTab, .easing); XCTAssertEqual(r.focus.current, .easing)
        XCTAssertTrue(r.keyDown(Self.key(.right))); redraw()
        XCTAssertEqual(r.layout.rightPanelTab, .renders); XCTAssertEqual(r.focus.current, .renders)
        XCTAssertEqual(r.focus.ringRect(r.hits), r.hits.rect { $0 == .renders })
        XCTAssertTrue(r.keyDown(Self.key(.home))); XCTAssertEqual(r.layout.rightPanelTab, .design)
    }

    func testTheSidebarStripIsReachedByKeyboard() {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(370, 900))
        var stops: [LeftSidebarPanel.Hit?] = []
        while s.keyDown(Self.key(.tab)) { stops.append(s.focus.current); c.reset(); s.draw(c, size: CanvasSize(370, 900)) }
        XCTAssertEqual(stops, [.tab(.assets), .hideSidebar, .panelMenu, .importMedia])   // drawn order: the strip, then the header's Import
    }

    /// The Grade curve tabs (issue #357): two legible lines, so every tab is drawn even at 280 pt and there is no
    /// overflow button. Every tab is its own Tab stop, and Enter on the focused tab selects it.
    func testCurveTabsAreAllVisibleAndEnterSelectsAtTheMinimumWidth() throws {
        let (r, _) = try PanelLayoutAuditTests.panel(clip: "clip:a", group: "grade", width: PanelFit.minRight)
        let p = r.inspector
        let count = InspectorPanel.curveTabs.count
        let tabs = (0..<count).compactMap { i in p.hits.rect { $0 == .custom("grade:curvetabs", i) } }
        XCTAssertEqual(tabs.count, count, "every curve tab is drawn")
        XCTAssertNil(p.hits.rect { $0 == .custom("grade:curvetabs", count) }, "no overflow button")
        let order = PanelFocus.order(p.hits) { p.isFocusable($0) }
        let tabStops = order.filter { if case .custom("grade:curvetabs", let i) = $0 { return i < count }; return false }
        XCTAssertEqual(tabStops, (0..<count).map { InspectorPanel.Hit.custom("grade:curvetabs", $0) })
        p.focus.current = .custom("grade:curvetabs", 1); p.focus.visible = true
        XCTAssertTrue(p.keyDown(Self.key(.enter)))
        XCTAssertEqual(p.grade.curveTab, InspectorPanel.curveTabs[1].key)
        p.focus.current = .custom("grade:curvetabs", 4); p.focus.visible = true
        XCTAssertTrue(p.keyDown(Self.key(.space)))
        XCTAssertEqual(p.grade.curveTab, InspectorPanel.curveTabs[4].key)
    }
}
