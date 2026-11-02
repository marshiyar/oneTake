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
// Issue #175: the Grade group opens on its controls, every section folds, and the active look is the truth.
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

final class GradeSectionsTests: XCTestCase {
    static let sections = ["looks", "primary", "wheels", "curves", "secondary", "finish"]

    func rightPanel(width: Double = 1440, store: PanelPreferencesStore = MemoryPanelPreferencesStore()) throws -> RightPanel {
        let r = RightPanel(layout: PanelLayoutState(store: store, viewportWidth: width))
        r.inspector.editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        r.inspector.selection = ["clip:a"]
        if r.inspector.openGroupId != "grade" { r.inspector.toggleGroup("grade") }
        return r
    }

    func draw(_ r: RightPanel, width: Double = 409, height: Double = 4000) {
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(width, height)); c.reset(); r.draw(c, size: CanvasSize(width, height))
    }

    func header(_ r: RightPanel, _ id: String) -> CanvasRect? { r.inspector.hits.rect { $0 == .custom("grade:section:\(id)", 0) } }

    func click(_ r: RightPanel, _ rect: CanvasRect) {
        let p = CanvasPoint(rect.midX, rect.midY)
        XCTAssertTrue(r.inspector.pointerDown(p)); r.inspector.pointerUp(p)
    }

    func setGrade(_ r: RightPanel, _ g: ColorGrading) throws {
        XCTAssertTrue(try XCTUnwrap(r.inspector.editor).setColorGrading(clipId: "clip:a", g))
    }

    func shown(_ r: RightPanel) throws -> ColorGrading { try XCTUnwrap(r.inspector.editor).gradeShown(clipId: "clip:a", time: 0) }

    /// A1: at 1280x800 the right column is 364 wide and, under the status line (22), the timeline group (360 + its 32 tab
    /// strip), the panel's own tab strip (32) and the 48 clip header, its body is about 350 tall. Opening Grade puts Amount
    /// and the first Primary sliders inside it without scrolling. (The first four fit only with unstacked sliders; at this
    /// width each slider stacks its label over the track, 56 pt a row, so Exposure and Contrast fit.)
    func testA1AmountAndExposureAreInViewAt1280x800() throws {
        let width = PanelFit.fit(1280, PanelFit.defaults(1280)).right
        XCTAssertEqual(width, 364)
        let r = try rightPanel(width: 1280)
        // The dock gives the timeline group (360 + its tab strip) the share it has of the 1440x900 reference's container.
        let container = 800 - ShellStatusLine.height - PanelTheme.seamWidth
        let height = container * (1 - (360 + PanelTabStrip.height) / DockDefaults.referenceContainerHeight)
        draw(r, width: width, height: height)
        let body = r.inspector.bodyRect
        XCTAssertEqual(body.height, height - 32 - 48, accuracy: 1)
        for key in ["grade:amount", "grade:adj:exposure", "grade:adj:contrast"] {
            let rect = try XCTUnwrap(r.inspector.hits.rect { $0 == .slider(key) }, key)
            XCTAssertGreaterThanOrEqual(rect.y, body.y, key)
            XCTAssertLessThanOrEqual(rect.maxY, body.maxY, "\(key) is inside the body without scrolling")
        }
        let groupHeader = try XCTUnwrap(r.inspector.hits.rect { $0 == .group("grade") })
        XCTAssertEqual(groupHeader.y, body.y, accuracy: 1, "the Grade header sits at the body's top")
    }

    func testLooksStartClosedAndEveryOtherSectionOpen() throws {
        let r = try rightPanel()
        draw(r)
        for id in Self.sections { XCTAssertNotNil(header(r, id), id) }
        XCTAssertFalse(r.inspector.gradeSectionIsOpen("looks"))
        XCTAssertNil(r.inspector.hits.rect { $0 == .custom("grade:presets", 0) }, "no tiles while Looks is closed")
        for id in Self.sections.dropFirst() { XCTAssertTrue(r.inspector.gradeSectionIsOpen(id), id) }
        XCTAssertNotNil(r.inspector.hits.rect { $0 == .slider("grade:adj:exposure") })
    }

    /// A2 (mouse): a click on each header folds and unfolds its rows, so the group's content gets shorter and taller again.
    func testA2EachSectionFoldsWithTheMouse() throws {
        let r = try rightPanel()
        for id in Self.sections {
            draw(r)
            let wasOpen = r.inspector.gradeSectionIsOpen(id), before = r.inspector.bodyContentHeight
            click(r, try XCTUnwrap(header(r, id), id))
            draw(r)
            XCTAssertEqual(r.inspector.gradeSectionIsOpen(id), !wasOpen, "\(id) toggled")
            let after = r.inspector.bodyContentHeight
            if wasOpen { XCTAssertLessThan(after, before, "\(id) closed: its rows are gone") } else { XCTAssertGreaterThan(after, before, "\(id) opened") }
            click(r, try XCTUnwrap(header(r, id), id))
            draw(r)
            XCTAssertEqual(r.inspector.gradeSectionIsOpen(id), wasOpen, "\(id) toggled back")
            XCTAssertEqual(r.inspector.bodyContentHeight, before, accuracy: 0.5, "\(id) is back where it was")
        }
    }

    /// A2 (keyboard): the header is in the Tab order, named for a screen reader, and Enter and Space toggle it.
    func testA2EachSectionFoldsWithTheKeyboard() throws {
        let r = try rightPanel()
        for id in Self.sections {
            draw(r)
            let hit = InspectorPanel.Hit.custom("grade:section:\(id)", 0)
            let order = PanelFocus<InspectorPanel.Hit>.order(r.inspector.hits, r.inspector.isFocusable)
            XCTAssertTrue(order.contains(hit), "\(id) is reachable by Tab")
            XCTAssertNotNil(r.inspector.gradeSectionLabel("grade:section:\(id)"))
            for key in [EditorKey.Code.enter, .space] {
                draw(r)
                let was = r.inspector.gradeSectionIsOpen(id)
                r.inspector.focus.current = hit; r.inspector.focus.visible = true
                XCTAssertTrue(r.inspector.keyDown(EditorKey(key)), "\(id) \(key)")
                XCTAssertEqual(r.inspector.gradeSectionIsOpen(id), !was, "\(id) \(key)")
            }
        }
        XCTAssertEqual(r.inspector.gradeSectionLabel("grade:section:looks"), "Expand Looks")
        XCTAssertEqual(r.inspector.gradeSectionLabel("grade:section:primary"), "Collapse Primary")
    }

    /// A2 (persistence): the state survives a relaunch, and a panel-layout.json from before this change still loads.
    func testA2SectionStateIsKeptAcrossLaunches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grade-sections-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("panel-layout.json")
        let first = try rightPanel(store: FilePanelPreferencesStore(url: url))
        first.inspector.setGradeSection("looks", open: true)
        first.inspector.setGradeSection("curves", open: false)
        first.inspector.setGradeSection(InspectorPanel.lutSectionId, open: true)
        XCTAssertEqual(FilePanelPreferencesStore(url: url).load().gradeSections, ["looks": true, "curves": false, "lut": true])
        let second = try rightPanel(store: FilePanelPreferencesStore(url: url))
        XCTAssertTrue(second.inspector.gradeSectionIsOpen("looks"))
        XCTAssertFalse(second.inspector.gradeSectionIsOpen("curves"))
        XCTAssertTrue(second.inspector.gradeSectionIsOpen("primary"), "an untouched section keeps its default")
        XCTAssertEqual(second.inspector.grade.lutOpen, true)
        let old = try JSONDecoder().decode(PanelPreferences.self, from: Data(#"{"openInspectorGroup":"grade"}"#.utf8))
        XCTAssertNil(old.gradeSections)
        XCTAssertEqual(old.openInspectorGroup, "grade")
    }

    /// A3: a tile is active only while the grade still equals that look applied to the rest of the grade.
    func testA3AnEditedGradeShowsCustomAndNoTileActive() throws {
        let r = try rightPanel()
        r.inspector.setGradeSection("looks", open: true)
        let warm = try XCTUnwrap(ColorGrading.preset("warm-daylight"))
        try setGrade(r, ColorGrading().applying(warm))
        XCTAssertEqual(InspectorPanel.activeLook(try shown(r))?.id, "warm-daylight")
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 4000))
        XCTAssertTrue(c.drawnStrings.contains("Warm Daylight"))
        XCTAssertFalse(c.drawnStrings.contains("Custom"))

        var edited = try shown(r)
        edited.adjust["exposure"] = (edited.adjustValue("exposure") + 0.3)
        try setGrade(r, edited)
        XCTAssertNil(InspectorPanel.activeLook(try shown(r)), "any later edit of the look's own values")
        c.reset(); r.draw(c, size: CanvasSize(409, 4000))
        XCTAssertTrue(c.drawnStrings.contains("Custom"))

        var amount = ColorGrading().applying(warm); amount.intensity = 0.5
        XCTAssertNil(InspectorPanel.activeLook(amount), "Amount moved off the look's")
        var wheels = ColorGrading().applying(warm); wheels.wheels["shadows"] = ColorGrading.Wheel(hue: 200, amount: 0.3)
        XCTAssertEqual(InspectorPanel.activeLook(wheels)?.id, "warm-daylight", "wheels belong to the rest of the grade")
        XCTAssertEqual(InspectorPanel.activeLook(ColorGrading())?.id, "neutral", "an ungraded clip is Neutral")
    }

    /// A4: a look tile asks the host for `current grade.applying(look)`, the grade a click commits.
    func testA4ATilePreviewsExactlyWhatAClickApplies() throws {
        let r = try rightPanel()
        r.inspector.setGradeSection("looks", open: true)
        var base = ColorGrading()
        base.wheels["shadows"] = ColorGrading.Wheel(hue: 200, amount: 0.3)
        base.curves["master"] = [[0, 0], [0.5, 0.6], [1, 1]]
        base.secondaries = [.init()]
        try setGrade(r, base)
        var asked: [String: NativeJSONObject] = [:]
        r.inspector.effectPreview = { req in asked[req.key] = req.grade; return .rendering }
        draw(r)
        let index = try XCTUnwrap(ColorGrading.gradePresets.firstIndex { $0.id == "warm-daylight" })
        let previewed = try XCTUnwrap(asked["look:warm-daylight"], "the tile asked the host")
        let tile = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:presets", index) })
        click(r, tile)
        let applied = try shown(r)
        XCTAssertEqual(applied.json, previewed, "the tile showed the grade the click commits")
        XCTAssertFalse(applied.wheels.isEmpty && applied.curves.isEmpty, "the clip's wheels and curves are in the preview")
        XCTAssertEqual(InspectorPanel.activeLook(applied)?.id, "warm-daylight")
    }
}
