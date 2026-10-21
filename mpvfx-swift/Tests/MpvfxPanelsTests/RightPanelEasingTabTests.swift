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
import OneTakeKeyframes
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Keyframe Easing panel as the right panel's "Easing" tab: the tab, the inspector's "Easing…" button that
/// replaced the cramped Ease row (#154), the panel menu item, opening on given keys, and events reaching the panel.
final class RightPanelEasingTabTests: XCTestCase {
    let size = CanvasSize(409, 868)
    let rot = TimelineEditor.rotationId

    /// clip:a selected, rotation keyed 0° at 0 and 90° at 30 (30 fps).
    func make() throws -> (RightPanel, TimelineEditor, MemoryPanelPreferencesStore) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let a = try XCTUnwrap(e.parameterAddress(clipId: "clip:a", rot))
        for (f, v) in [(0.0, 0.0), (30, 90)] {
            XCTAssertTrue(e.applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: .number, frame: f, value: .number(v), baselineValue: .number(v))))))
        }
        let store = MemoryPanelPreferencesStore()
        let r = RightPanel(layout: PanelLayoutState(store: store, viewportWidth: 1440))
        r.inspector.editor = e; r.inspector.selection = ["clip:a"]; r.inspector.openGroupId = "layout"
        r.easing.editor = e; r.easing.clipId = "clip:a"
        r.draw(PanelMeasureCanvas(), size: size)
        return (r, e, store)
    }
    func ref(_ f: Double) -> TimelineKeyframeRef { TimelineKeyframeRef(clipId: "clip:a", parameterId: rot, frame: f) }
    func click(_ r: RightPanel, _ rect: CanvasRect) {
        let p = CanvasPoint(rect.midX, rect.midY)
        _ = r.pointerDown(p); r.pointerUp(p); r.draw(PanelMeasureCanvas(), size: size)
    }
    func easingButton(_ r: RightPanel) -> InspectorRow.Button? {
        for g in r.inspector.groups { for row in g.rows { if case .buttons(let bs) = row.kind, let b = bs.first(where: { $0.key == "openEasing" }) { return b } } }
        return nil
    }

    func testTheEasingTabSitsBetweenDesignAndRendersAndIsRemembered() throws {
        let (r, _, store) = try make()
        let c = PanelMeasureCanvas()
        r.draw(c, size: size)
        let labels = c.drawnStrings.filter { ["Design", "Easing", "Renders"].contains($0) }
        XCTAssertEqual(labels, ["Design", "Easing", "Renders"])
        click(r, try XCTUnwrap(r.hits.rect { $0 == .easing }))
        XCTAssertEqual(r.layout.rightPanelTab, .easing)
        XCTAssertEqual(store.value.rightPanelTab, .easing, "the open tab is saved like the others")
        XCTAssertNotNil(r.easing.hits.rect { $0 == .graph }, "the tab shows the panel")
    }

    func testTheInspectorShowsAnEasingButtonInsteadOfTheEaseRow() throws {
        let (r, _, _) = try make()
        var segmented: [String] = []
        for g in r.inspector.groups { for row in g.rows { if case .segmented(let s) = row.kind { segmented.append(s.key) } } }
        XCTAssertFalse(segmented.contains("easing"), "the cramped Ease row is gone (#154)")
        XCTAssertNil(r.inspector.hits.rect { if case .custom("ease:curve", _) = $0 { return true }; return false }, "and its curve graph")
        let b = try XCTUnwrap(easingButton(r))
        XCTAssertEqual(b.label, "Easing…")
        b.action()
        XCTAssertEqual(r.layout.rightPanelTab, .easing)
        XCTAssertEqual(r.easing.target?.refs, [ref(0)], "the panel opens on the inspector's key")
    }

    func testShowKeyframeEasingOpensThePanelOnTheKeys() throws {
        let (r, _, _) = try make()
        r.layout.setRightCollapsed(true)
        XCTAssertTrue(r.showKeyframeEasing(clipId: "clip:a", refs: [ref(30), ref(0)]))
        XCTAssertFalse(r.layout.effectiveRightCollapsed); XCTAssertEqual(r.layout.rightPanelTab, .easing)
        XCTAssertEqual(r.easing.selectedKeyframes, [ref(0), ref(30)]); XCTAssertEqual(r.easing.state.chosenProperty, rot)
        XCTAssertFalse(r.showKeyframeEasing(clipId: "clip:a", refs: [TimelineKeyframeRef(clipId: "clip:a", parameterId: "layout.zIndex", frame: 0)]),
                       "keys with no easing leave the panel as it was")
        let zIndex = TimelineKeyframeRef(clipId: "clip:a", parameterId: "layout.zIndex", frame: 0)
        XCTAssertTrue(r.showKeyframeEasing(clipId: "clip:a", refs: [zIndex, ref(30)]), "keys without easing are skipped, the rest open")
        XCTAssertEqual(r.easing.selectedKeyframes, [ref(30)])
    }

    func testThePanelMenuOpensKeyframeEasing() throws {
        let (r, _, _) = try make()
        click(r, try XCTUnwrap(r.hits.rect { $0 == .panelMenu }))
        XCTAssertTrue(r.dropdown.isOpen)
        r.dropdown.pick("keyframe-easing")
        XCTAssertEqual(r.layout.rightPanelTab, .easing)
    }

    func testPointerKeysAndWheelReachThePanel() throws {
        let (r, e, _) = try make()
        r.layout.setRightTab(.easing); r.draw(PanelMeasureCanvas(), size: size)
        var edits = 0; r.easing.onEdited = { edits += 1 }
        click(r, try XCTUnwrap(r.easing.hits.rect { $0 == .preset("hold") }))
        XCTAssertEqual(e.outgoing(ref(0)), .hold); XCTAssertEqual(edits, 1)
        click(r, try XCTUnwrap(r.easing.hits.rect { $0 == .preset("linear") }))
        click(r, try XCTUnwrap(r.easing.hits.rect { $0 == .field("outInfluence") }))
        XCTAssertTrue(r.isEditingText)
        for k in [EditorKey(.backspace), EditorKey(.backspace), EditorKey(.backspace), EditorKey(.backspace), EditorKey(.backspace),
                  EditorKey(.char("5")), EditorKey(.char("0")), EditorKey(.enter)] { XCTAssertTrue(r.keyDown(k)) }
        XCTAssertEqual(try XCTUnwrap(KeyframeEasing.sides(e, ref(0))).outInfluence, 0.5, accuracy: 1e-9)
        let g = try XCTUnwrap(r.easing.graphBox?.plot)
        XCTAssertTrue(r.scroll(CanvasPoint(g.midX, g.midY), dy: -1, zoom: true))
        XCTAssertGreaterThan(r.easing.state.zoom, 1, "⌘-scroll over the graph zooms")
    }

    func testThePickedPropertyHoldsWhileTheSelectionStaysTheSame() throws {
        let (r, e, _) = try make()
        XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: 0))
        r.easing.selectedKeyframes = [ref(0)]
        r.layout.setRightTab(.easing); r.draw(PanelMeasureCanvas(), size: size)
        click(r, try XCTUnwrap(r.easing.hits.rect { $0 == .property }))
        r.easing.dropdown.pick(TimelineEditor.positionId)
        r.easing.selectedKeyframes = [ref(0)]   // the host re-syncs the same timeline selection before each paint
        XCTAssertEqual(r.easing.target?.parameterId, TimelineEditor.positionId)
        r.easing.selectedKeyframes = [ref(30)]  // a new timeline selection takes over again
        XCTAssertEqual(r.easing.target?.parameterId, rot)
    }
}
