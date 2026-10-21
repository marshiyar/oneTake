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
@testable import MpvfxPanels

/// The panel menus (macOS Window > Panels, every group's ⋯ menu): what they list and what a pick does.
final class DockMenuTests: XCTestCase {
    let registry = DockRegistry.corePanels

    func testThePanelListHasEveryPanelInOrderWithACheckmarkOnTheOpenOnes() throws {
        var l = DockDefaults.layout(registry)
        try l.close("renders", registry: registry)
        let items = DockMenu.panels(l, registry)
        XCTAssertEqual(items.map(\.title), ["Media", "Preview", "Design", "Renders", "Timeline"])
        XCTAssertEqual(items.map(\.checked), [true, true, true, false, true])
        XCTAssertEqual(Set(items.map(\.key)).count, items.count, "keys are unique")
    }

    func testAGroupMenuClosesItsVisiblePanelAndListsItsOwnCommandsFirst() throws {
        let l = DockDefaults.layout(registry)
        let right = try XCTUnwrap(l.root.group(containing: "inspector"))
        let extra = DockMenuItem(title: "Hide finished renders", action: .extra("renders", "hide-finished"), section: "x")
        let design = DockMenu.groupMenu(right, layout: l, registry: registry, extras: [extra])
        XCTAssertEqual(design.first?.action, .close("inspector"))
        XCTAssertFalse(design.contains { $0.action == extra.action }, "another panel's command stays in its own menu")
        var renders = right
        renders.active = "renders"
        let menu = DockMenu.groupMenu(renders, layout: l, registry: registry, extras: [extra])
        XCTAssertEqual(menu.prefix(2).map(\.title), ["Close Renders", "Hide finished renders"])
        XCTAssertEqual(menu.prefix(2).map(\.section), [DockMenu.thisPanelSection, DockMenu.thisPanelSection])
        let timeline = try XCTUnwrap(l.root.group(containing: "timeline"))
        XCTAssertEqual(DockMenu.groupMenu(timeline, layout: l, registry: registry).first?.section, DockMenu.panelsSection,
                       "the timeline cannot be closed: no Close entry")
    }

    func testPickingAPanelTogglesItAndFocusesWhatItOpens() {
        let v = DockView(layout: DockDefaults.layout(registry), registry: registry)
        DockMenu.apply(.toggle("media"), to: v)
        XCTAssertFalse(v.layout.isOpen("media"))
        DockMenu.apply(.toggle("media"), to: v)
        XCTAssertTrue(v.layout.isOpen("media"))
        XCTAssertEqual(v.focused, "media")
        XCTAssertTrue(v.focusVisible)
        DockMenu.apply(.toggle("preview"), to: v)
        XCTAssertTrue(v.layout.isOpen("preview"), "the preview cannot be closed: a pick focuses it")
        XCTAssertEqual(v.focused, "preview")
        DockMenu.apply(.close("renders"), to: v)
        XCTAssertFalse(v.layout.isOpen("renders"))
        let before = v.layout
        DockMenu.apply(.extra("renders", "x"), to: v)
        XCTAssertEqual(v.layout, before)
    }
}
