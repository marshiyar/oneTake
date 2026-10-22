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
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

private func demoEditor() throws -> TimelineEditor { try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime()) }

/// Draws once on the deterministic measuring canvas so hit regions exist, then returns the centre of a region.
private func center(_ r: CanvasRect) -> CanvasPoint { CanvasPoint(r.x + r.width / 2, r.y + r.height / 2) }

final class PanelFitTests: XCTestCase {
    func testWideWindowKeepsDefaults() {
        let d = PanelFit.defaults(1440)
        XCTAssertEqual(d, PanelFit.Widths(left: 370, right: 409))
        let f = PanelFit.fit(1440, d)
        XCTAssertEqual(f.left, 370); XCTAssertEqual(f.right, 409); XCTAssertEqual(f.preview, 1440 - 370 - 409 - 2)
        XCTAssertFalse(f.autoCollapseLeft); XCTAssertFalse(f.autoCollapseRight)
    }
    func testNarrowWindowRailsAndReservesPreview() {
        let f = PanelFit.fit(800, PanelFit.Widths(left: 384, right: 424))
        XCTAssertTrue(f.autoCollapseLeft); XCTAssertFalse(f.autoCollapseRight)
        XCTAssertEqual(f.left, PanelFit.railWidth)
        XCTAssertGreaterThanOrEqual(f.preview, PanelFit.minPreviewWidth)
        let tiny = PanelFit.fit(600, PanelFit.Widths(left: 300, right: 300))
        XCTAssertTrue(tiny.autoCollapseRight); XCTAssertEqual(tiny.right, 0)
        let reopened = PanelFit.fit(800, PanelFit.Widths(left: 300, right: 300), reopened: .init(left: true))
        XCTAssertFalse(reopened.autoCollapseLeft); XCTAssertGreaterThanOrEqual(reopened.left, PanelFit.minLeft)
    }
    func testCapAndTimelineHeight() {
        XCTAssertEqual(PanelFit.fit(1000, PanelFit.Widths(left: 900, right: 280)).left, 400 - 0 >= 200 ? min(400, 1000 - 360 - 2 - 280) : 200)
        XCTAssertEqual(PanelFit.fitTimelineHeight(900, 5000), 700)
        XCTAssertEqual(PanelFit.fitTimelineHeight(900, 10), 100)
    }
}

final class PanelLayoutStateTests: XCTestCase {
    func testResizePersistsSettledWidthAndToggles() {
        let store = MemoryPanelPreferencesStore()
        let s = PanelLayoutState(store: store, viewportWidth: 1440)
        s.beginResize(.left, x: 100); s.moveResize(x: 150)
        XCTAssertNil(store.value.leftWidth, "a drag in flight is not persisted")
        s.endResize()
        XCTAssertEqual(store.value.leftWidth, 420)
        s.beginResize(.right, x: 1000); s.moveResize(x: 2000); s.endResize()
        XCTAssertEqual(store.value.rightWidth, PanelFit.minRight, "right seam drags the right-anchored panel")
        s.toggleLeft(); XCTAssertEqual(store.value.leftCollapsed, true); XCTAssertTrue(s.effectiveLeftCollapsed)
        s.setRightTab(.renders); XCTAssertEqual(store.value.rightPanelTab, .renders)
        let again = PanelLayoutState(store: store, viewportWidth: 1440)
        XCTAssertTrue(again.leftCollapsed); XCTAssertEqual(again.rightPanelTab, .renders); XCTAssertEqual(again.preferred.left, 420)
    }
    func testFileStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-panels-\(UUID().uuidString)/panel-layout.json")
        let store = FilePanelPreferencesStore(url: url)
        var p = PanelPreferences(); p.leftWidth = 250; p.sidebarTab = .assets; p.openInspectorGroup = "grade"
        store.save(p)
        XCTAssertEqual(store.load(), p)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), PanelPreferences())
    }
    /// The inspector group the user left open (or closing them all) is saved and reopened on the next launch;
    /// with nothing saved the Transform group opens.
    func testOpenInspectorGroupIsRememberedAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-panels-\(UUID().uuidString)/panel-layout.json")
        let first = RightPanel(layout: PanelLayoutState(store: FilePanelPreferencesStore(url: url)))
        XCTAssertEqual(first.inspector.openGroupId, "layout")
        first.inspector.toggleGroup("grade")
        XCTAssertEqual(FilePanelPreferencesStore(url: url).load().openInspectorGroup, "grade")
        let second = RightPanel(layout: PanelLayoutState(store: FilePanelPreferencesStore(url: url)))
        XCTAssertEqual(second.inspector.openGroupId, "grade")
        second.inspector.toggleGroup("grade")
        let third = RightPanel(layout: PanelLayoutState(store: FilePanelPreferencesStore(url: url)))
        XCTAssertEqual(third.inspector.openGroupId, "", "closing the open group is remembered too")
        third.inspector.openGroupId = "text"   // the timeline's reveal (double-click a text clip) opens a group too
        XCTAssertEqual(FilePanelPreferencesStore(url: url).load().openInspectorGroup, "text")
    }
    func testShellRegions() {
        let s = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let r = ShellRegions.compute(size: CanvasSize(1440, 500), layout: s)
        XCTAssertEqual(r.left.width, 370); XCTAssertEqual(r.leftSeam, CanvasRect(x: 370, y: 0, width: 1, height: 500)); XCTAssertEqual(r.preview.x, 371)
        XCTAssertEqual(r.rightSeam?.x, r.preview.maxX); XCTAssertEqual(r.right.x, r.preview.maxX + 1)
        XCTAssertEqual(r.right.maxX, 1440); XCTAssertEqual(r.right.width, 409)
        XCTAssertEqual(r.leftSeamHit?.width, 13); XCTAssertEqual(r.leftSeamHit?.x, 364); XCTAssertEqual(r.rightSeamHit?.x, r.rightSeam!.x - 6)
        s.toggleLeft()
        let railed = ShellRegions.compute(size: CanvasSize(1440, 500), layout: s)
        XCTAssertTrue(railed.leftRail); XCTAssertEqual(railed.left.width, 40); XCTAssertNil(railed.leftSeam); XCTAssertEqual(railed.preview.x, 41)
    }
}

final class InspectorPanelTests: XCTestCase {
    func makeInspector(select id: String) throws -> (InspectorPanel, TimelineEditor, PanelMeasureCanvas) {
        let editor = try demoEditor()
        let p = InspectorPanel(); p.editor = editor; p.selection = [id]; p.time = 1
        let c = PanelMeasureCanvas()
        p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        return (p, editor, c)
    }

    func testGroupsInTsOrderAndAccordion() throws {
        let (p, _, c) = try makeInspector(select: "clip:a")
        XCTAssertEqual(p.groups.map(\.title), ["Transform", "Style", "Grade", "Effects", "Audio FX", "Media"])
        XCTAssertEqual(p.openGroupId, "layout")
        XCTAssertTrue(c.drawnStrings.contains("Rotation"))
        let header = try XCTUnwrap(p.hits.rect { $0 == .group("media") })
        XCTAssertTrue(p.pointerDown(center(header)))
        XCTAssertEqual(p.openGroupId, "media")
        XCTAssertNil(p.hits.rect { $0 == .group("timing") }, "no clip timing group: the timeline moves and trims clips")
        let (audio, _, _) = try makeInspector(select: "clip:music")
        XCTAssertEqual(audio.groups.map(\.title), ["Audio FX", "Media"])
    }

    func testGradeHeaderBypassIsOneUndoableEdit() throws {
        let (p, editor, c) = try makeInspector(select: "clip:a")
        p.openGroupId = "grade"; c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        let toggle = try XCTUnwrap(p.hits.rect { $0 == .groupEnabled("grade") })
        let before = editor.colorGrading(clipId: "clip:a")?.enabled ?? true
        XCTAssertGreaterThanOrEqual(toggle.width, 24)
        XCTAssertTrue(p.pointerDown(center(toggle)))
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.enabled, !before)
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.enabled ?? true, before)
    }

    func testGradeAndEffectsBypassesPublishAccessibleSwitches() throws {
        let (p, editor, c) = try makeInspector(select: "clip:a")
        p.openGroupId = "grade"; c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        let controls = p.accessibilityControls
        XCTAssertEqual(Set(controls.map(\.label)), ["Grade enabled", "Effects enabled"])
        XCTAssertTrue(controls.allSatisfy { $0.frame.width >= 24 && $0.frame.height >= 24 })
        try XCTUnwrap(controls.first { $0.label == "Grade enabled" }).press()
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.enabled, false)
    }

    func testEffectsHeaderBypassPreservesAmounts() throws {
        let (p, editor, c) = try makeInspector(select: "clip:a")
        var grade = editor.colorGrading(clipId: "clip:a") ?? ColorGrading(); grade.effects["blur"] = 0.45
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade))
        p.openGroupId = "effects"; c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        let toggle = try XCTUnwrap(p.hits.rect { $0 == .groupEnabled("effects") })
        XCTAssertTrue(p.pointerDown(center(toggle)))
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.effectsEnabled, false)
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.effects["blur"], 0.45)
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        XCTAssertTrue(p.pointerDown(center(try XCTUnwrap(p.hits.rect { $0 == .groupEnabled("effects") }))))
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.effects["blur"], 0.45)
    }

    func testEffectsHeaderBypassPersistsOnANeutralGrade() throws {
        let (p, editor, c) = try makeInspector(select: "clip:a")
        XCTAssertNil(editor.colorGrading(clipId: "clip:a"))
        p.openGroupId = "effects"; c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        let toggle = try XCTUnwrap(p.hits.rect { $0 == .groupEnabled("effects") })
        XCTAssertTrue(p.pointerDown(center(toggle)))
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.effectsEnabled, false)
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        XCTAssertNotNil(p.hits.rect { $0 == .groupEnabled("effects") })
        XCTAssertTrue(c.drawnStrings.contains("off"))
    }

    /// The accordion entrance (hf-flat-group-enter, 120 ms ease-out): the toggled group and the one it closed
    /// animate while a host clock drives `tick`; nothing animates without one.
    func testAccordionEntranceRunsFor120ms() throws {
        let (p, _, _) = try makeInspector(select: "clip:a")
        p.toggleGroup("media")
        XCTAssertTrue(p.enteringGroups.isEmpty, "no host clock: no entrance")
        var asked = 0
        p.onAnimate = { asked += 1 }
        p.toggleGroup("layout")
        XCTAssertEqual(asked, 1); XCTAssertEqual(p.enteringGroups, ["layout", "media"])
        XCTAssertEqual(p.enterProgress, 0, accuracy: 1e-9)
        XCTAssertTrue(p.tick(0.06))
        XCTAssertGreaterThan(p.enterProgress, 0.5); XCTAssertLessThan(p.enterProgress, 0.9)   // ease-out: past halfway at half time
        XCTAssertFalse(p.tick(0.07))
        XCTAssertTrue(p.enteringGroups.isEmpty); XCTAssertEqual(p.enterProgress, 1)
        p.toggleGroup("layout")   // closing: only the closed header enters
        XCTAssertEqual(p.enteringGroups, ["layout"])
        XCTAssertEqual(InspectorPanel.easeOut(0), 0, accuracy: 1e-6); XCTAssertEqual(InspectorPanel.easeOut(1), 1, accuracy: 1e-6)
    }

    /// Tab / ⇧Tab walk the inspector's controls in order, Enter presses the focused one, a pointer press hides the ring,
    /// and Tab from a field commits it before moving on.
    func testKeyboardFocusWalksAndPresses() throws {
        let (p, editor, c) = try makeInspector(select: "clip:a")
        XCTAssertTrue(p.keyDown(EditorKey(.tab)))
        XCTAssertTrue(p.focus.visible); XCTAssertEqual(p.focus.current, .headerClear)
        var guardCount = 0
        while p.focus.current != .group("media"), guardCount < 200 { _ = p.keyDown(EditorKey(.tab)); guardCount += 1 }
        XCTAssertEqual(p.focus.current, .group("media"))
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(p.openGroupId, "media"); XCTAssertTrue(p.focus.visible)
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        _ = p.keyDown(EditorKey(.tab)); let next = p.focus.current
        _ = p.keyDown(EditorKey(.tab, shift: true))
        XCTAssertEqual(p.focus.current, .group("media")); XCTAssertNotEqual(next, .group("media"))
        _ = p.pointerDown(CanvasPoint(5, 1390))
        XCTAssertFalse(p.focus.visible)
        // A field: Enter focuses it, typing edits, Tab commits and moves on.
        p.toggleGroup("layout"); c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        p.focus.current = .field("x"); p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter))); XCTAssertTrue(p.isEditingText)
        for _ in 0..<5 { _ = p.keyDown(EditorKey(.backspace)) }
        for ch in "42" { _ = p.keyDown(EditorKey(.char(ch))) }
        XCTAssertTrue(p.keyDown(EditorKey(.tab)))
        XCTAssertFalse(p.isEditingText); XCTAssertEqual(editor.transform(clipId: "clip:a", time: 1).x, 42)
        XCTAssertNotEqual(p.focus.current, .field("x"))
    }

    /// The body's overlay scrollbar: shown only on overflow; dragging the thumb and pressing the track scroll.
    func testInspectorScrollbarDragAndTrack() throws {
        let (p, _, c) = try makeInspector(select: "clip:a")
        XCTAssertNil(p.hits.rect { $0 == .scrollbar }, "everything fits in 1400")
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 360))
        let zone = try XCTUnwrap(p.hits.rect { $0 == .scrollbar })
        let t0 = try XCTUnwrap(PanelScrollbar.thumb(track: p.bodyRect, offset: p.bodyScroll, content: p.bodyContentHeight))
        XCTAssertTrue(zone.contains(CanvasPoint(t0.midX, t0.midY)))
        XCTAssertEqual(p.bodyScroll, 0)
        _ = p.pointerDown(CanvasPoint(t0.midX, t0.midY))
        _ = p.pointerMove(CanvasPoint(t0.midX, t0.midY + 40))
        p.pointerUp(CanvasPoint(t0.midX, t0.midY + 40))
        XCTAssertGreaterThan(p.bodyScroll, 0)
        let dragged = p.bodyScroll
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 360))
        _ = p.pointerDown(CanvasPoint(t0.midX, p.bodyRect.maxY - 3))   // track press near the bottom pages there
        p.pointerUp(CanvasPoint(t0.midX, p.bodyRect.maxY - 3))
        XCTAssertGreaterThan(p.bodyScroll, dragged)
        XCTAssertEqual(p.bodyScroll, p.bodyMaxScroll, accuracy: 30)
    }

    func testTypingIntoAFieldEditsTheDocumentUndoably() throws {
        let (p, editor, c) = try makeInspector(select: "clip:a")
        let field = try XCTUnwrap(p.hits.rect { $0 == .field("x") })
        XCTAssertTrue(p.pointerDown(center(field)))
        XCTAssertTrue(p.isEditingText)
        for _ in 0..<5 { _ = p.keyDown(EditorKey(.backspace)) }
        for ch in "120" { _ = p.keyDown(EditorKey(.char(ch))) }
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(editor.transform(clipId: "clip:a", time: 1).x, 120)
        XCTAssertEqual(editor.undoStack.count, 1)
        editor.undo()
        XCTAssertNil(editor.transform(clipId: "clip:a", time: 1).x)
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
    }

    func testSliderCommitsOnceOnRelease() throws {
        let (p, editor, c) = try makeInspector(select: "clip:a")
        p.openGroupId = "style"; c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
        let track = try XCTUnwrap(p.hits.rect { $0 == .slider("opacity") })
        XCTAssertTrue(p.pointerDown(CanvasPoint(track.x + track.width * 0.8, track.y + 10)))
        _ = p.pointerMove(CanvasPoint(track.x + track.width * 0.5, track.y + 10))
        XCTAssertEqual(editor.undoStack.count, 0, "dragging previews, it does not commit")
        p.pointerUp(CanvasPoint(track.x + track.width * 0.5, track.y + 10))
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertEqual(editor.numberValue(clipId: "clip:a", TimelineEditor.opacityId, time: 1) ?? 0, 0.5, accuracy: 0.02)
    }

    func testKeyframeToggleAndTimelineTimingAndRate() throws {
        let (p, editor, _) = try makeInspector(select: "clip:a")
        let kf = try XCTUnwrap(p.hits.rect { $0 == .keyframe("x") })
        XCTAssertTrue(p.pointerDown(center(kf)))
        XCTAssertTrue(editor.isAnimated(clipId: "clip:a", TimelineEditor.positionId))
        let addr = try XCTUnwrap(editor.address(clipId: "clip:b"))
        XCTAssertTrue(editor.apply(.move(address: addr, destination: .init(trackId: addr.trackId, startFrame: 210))))
        XCTAssertEqual(editor.clip("clip:b")?.clip.startFrame, 210)
        XCTAssertTrue(editor.apply(.trimOut(address: try XCTUnwrap(editor.address(clipId: "clip:b")), endFrameExclusive: 270)))
        XCTAssertEqual(editor.clip("clip:b")?.clip.durationFrames, 60)
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:b", 2))
        XCTAssertEqual(editor.clip("clip:b")?.clip.durationFrames, 30)
        XCTAssertEqual(editor.playbackRate(clipId: "clip:b"), 2, accuracy: 1e-9)
    }

    func testAudioFxPresetAndEq() throws {
        let editor = try demoEditor()
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:music"]; p.openGroupId = "audio-fx"
        let c = PanelMeasureCanvas(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 2400))
        // The preset shelf opens from "Presets" (FxSection `picking`), the add shelf from "+ effect".
        XCTAssertTrue(p.pointerDown(center(try XCTUnwrap(p.hits.rect { $0 == .button("fx:presets") }))))
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 2400))
        let preset = try XCTUnwrap(p.hits.rect { $0 == .button("preset:voice-clean") })
        XCTAssertTrue(p.pointerDown(center(preset)))
        let chain = try XCTUnwrap(editor.clip("clip:music")?.clip.audioFxChain)
        XCTAssertTrue(chain.contains("voice-clean"))
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 2400))
        XCTAssertTrue(p.pointerDown(center(try XCTUnwrap(p.hits.rect { $0 == .button("fx:add") }))))
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 2400))
        let eq = try XCTUnwrap(p.hits.rect { $0 == .button("eq:add") })
        XCTAssertTrue(p.pointerDown(center(eq)))
        XCTAssertTrue(editor.clip("clip:music")!.clip.audioFxChain!.contains("fromEq"))
    }

    /// The timeline group header opens the bus rack: with no clip selected the inspector edits the group's own chain
    /// and volume; selecting a clip retires the bus.
    func testAudioGroupBusRackEditsTheGroupChain() throws {
        let editor = try demoEditor()
        let gid = try XCTUnwrap(editor.createAudioGroup(clipIds: ["clip:a", "clip:b"], label: "Video bus"))
        let p = InspectorPanel(); p.editor = editor; p.selection = []; p.audioGroupId = gid; p.openGroupId = "audio-fx"
        XCTAssertEqual(p.groups.map(\.id), ["audio-fx"])
        let c = PanelMeasureCanvas(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 2400))
        XCTAssertTrue(p.pointerDown(center(try XCTUnwrap(p.hits.rect { $0 == .button("fx:presets") }))))
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 2400))
        let preset = try XCTUnwrap(p.hits.rect { $0 == .button("preset:voice-clean") })
        XCTAssertTrue(p.pointerDown(center(preset)))
        XCTAssertTrue(try XCTUnwrap(editor.audioGroup(gid)?.fxChain).contains("voice-clean"))
        XCTAssertNil(editor.clip("clip:a")?.clip.audioFxChain)
        p.selection = ["clip:a"]; c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 2400))
        XCTAssertNil(p.audioGroupId)
    }

    func testLockedTrackShowsNoControls() throws {
        let editor = try demoEditor()
        XCTAssertTrue(editor.setTrackLocked("track:v1", true))
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]
        XCTAssertTrue(p.groups.allSatisfy { g in g.rows.count == 1 })
        XCTAssertFalse(editor.setParameter(clipId: "clip:a", TimelineEditor.opacityId, .number(0.2), time: 1))
    }
}

final class ColorGradingTests: XCTestCase {
    func testJsonRoundTripV2SaturationCurveFixture() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/saturation-curves-v2.json")
        let value = try JSONDecoder().decode(NativeJSONValue.self, from: Data(contentsOf: path))
        guard case .object(let object) = value else { return XCTFail("grade fixture must be an object") }
        let grade = ColorGrading(json: object)
        XCTAssertEqual(grade.version, 2)
        XCTAssertEqual(ColorGrading(json: grade.json), grade)
        for key in ColorGrading.deltaCurveKeys { XCTAssertFalse(grade.curve(key).isEmpty) }
        XCTAssertNil(ColorGrading(json: ["version": .number(2)]).json["curves"])
    }

    func testJsonRoundTripAndPreset() throws {
        var g = ColorGrading()
        g.adjust["contrast"] = 0.2
        g.wheels["midtones"] = .init(hue: 187, amount: 1, level: 0)
        g.curves["master"] = [[0, 0], [0.4, 0.6], [1, 1]]
        g.curves["lumaVsSaturation"] = [[0, 0], [0.7, -0.5], [1, -1]]
        g.curves["saturationVsSaturation"] = [[0, 1], [0.3, 0.5], [1, 0]]
        g.hueCurves["hueVsSaturation"] = [[120, 0.5]]
        g.secondaries = [.init()]
        g.lut = .init(src: "luts/film.cube", intensity: 0.7)
        let back = ColorGrading(json: g.json)
        XCTAssertEqual(back, g)
        let warm = try XCTUnwrap(ColorGrading.preset("warm-daylight"))
        let applied = g.applying(warm)
        XCTAssertEqual(applied.preset, "warm-daylight"); XCTAssertEqual(applied.adjustValue("temperature"), 0.18)
        XCTAssertEqual(applied.wheel("midtones").hue, 187, "a preset keeps wheels")
        XCTAssertEqual(ColorGrading.gradePresets.count, 13)
        XCTAssertFalse(ColorGrading().isAuthored)
    }
    func testMonotoneCurve() {
        let pts: [[Double]] = [[0, 0], [0.5, 0.8], [1, 1]]
        var last = -1.0
        for i in 0...20 { let v = ColorCurveMath.sample(pts, at: Double(i) / 20); XCTAssertGreaterThanOrEqual(v, last - 1e-12); last = v }
        XCTAssertEqual(ColorCurveMath.sample(pts, at: 0.5), 0.8, accuracy: 1e-9)
    }
    func testStoredOnClipUndoableAndCopy() throws {
        let editor = try demoEditor()
        var g = ColorGrading(); g.adjust["saturation"] = 0.3
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.adjustValue("saturation"), 0.3)
        XCTAssertEqual(editor.copyColorGrading(from: "clip:a", toAllProjectMedia: true), 2, "clip:b and the logo")
        editor.undo(); editor.undo()
        XCTAssertNil(editor.colorGrading(clipId: "clip:a"))
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", ColorGrading()), "neutral removes the effect")
        XCTAssertTrue(editor.clip("clip:a")!.clip.effects.isEmpty)
    }
    /// The preset grid reserves every row, the partial last one included (13 presets: 4 full rows + Deep Contrast),
    /// at the width it is drawn at, so the Amount row starts below the last tile however wide the panel is.
    func testPresetGridReservesItsPartialLastRow() throws {
        let tile = { (w: Double) in 2 + ((w - 8) / 3 - 2) * 9 / 16 + 27 }
        for width in [375.0, 520.0, 760.0] {
            for (count, rows) in [(13, 5), (7, 3), (1, 1), (12, 4), (5, 2)] {
                XCTAssertEqual(InspectorPanel.previewGridHeight(count: count, width: width), Double(rows) * tile(width) + Double(rows - 1) * 4,
                               accuracy: 1e-9, "\(count) presets at \(width)")
            }
        }
        XCTAssertEqual(InspectorPanel.previewGridHeight(count: 0, width: 375), 0)
        XCTAssertEqual(ColorGrading.gradePresets.count, 13)
        for panelW in [409.0, 520.0, 780.0] {
            let p = InspectorPanel(); p.editor = try demoEditor(); p.selection = ["clip:a"]; p.openGroupId = "grade"
            let c = PanelMeasureCanvas(); let rect = CanvasRect(x: 0, y: 0, width: panelW, height: 4000)
            p.draw(c, in: rect); c.reset(); p.draw(c, in: rect)   // the second layout knows the width
            let last = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:presets", 12) })
            let first = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:presets", 0) })
            let amount = try XCTUnwrap(p.hits.rect { $0 == .slider("grade:amount") })
            XCTAssertEqual(last.y, first.y + 4 * (first.height + 4), accuracy: 0.01, "Deep Contrast on the 5th row at \(panelW)")
            XCTAssertGreaterThan(amount.y, last.maxY, "Amount starts after the grid at \(panelW)")
        }
    }
    func testPasteGradeRequiresClipboardAndVisualSelection() throws {
        func pasteHit(_ p: InspectorPanel) -> CanvasRect? {
            let canvas = PanelMeasureCanvas()
            p.gradeClipboardRow().draw(canvas, CanvasRect(x: 0, y: 0, width: 360, height: 28), p)
            return p.hits.rect { $0 == .custom("grade:clipboard", 1) }
        }

        let editor = try demoEditor()
        let emptyClipboard = InspectorPanel()
        emptyClipboard.editor = editor; emptyClipboard.selection = ["clip:a"]
        emptyClipboard.onPasteGrade = { true }
        XCTAssertNil(pasteHit(emptyClipboard), "a wired callback does not imply that a grade is available")

        let audioOnly = InspectorPanel()
        audioOnly.editor = editor; audioOnly.selection = ["clip:music"]
        audioOnly.gradeClipboardAvailable = true; audioOnly.onPasteGrade = { true }
        XCTAssertNil(pasteHit(audioOnly), "an audio-only selection is not a grade target")

        let visual = InspectorPanel()
        visual.editor = editor; visual.selection = ["clip:music", "clip:a"]
        visual.gradeClipboardAvailable = true; visual.onPasteGrade = { true }
        XCTAssertNotNil(pasteHit(visual), "any visual clip in a mixed selection enables grade paste")
    }
    func testGradeUiWheelDragAndCurvePoint() throws {
        let editor = try demoEditor()
        // A contract 2 grade (saved before Lift / Gamma / Gain / Offset), which keeps its tonal wheels (issue #176).
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", ColorGrading(json: ["adjust": .object(["contrast": .number(0.1)])])))
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.openGroupId = "grade"
        let c = PanelMeasureCanvas(); let rect = CanvasRect(x: 0, y: 0, width: 380, height: 4000)
        p.draw(c, in: rect)
        XCTAssertTrue(c.drawnStrings.contains("Shadows")); XCTAssertTrue(c.drawnStrings.contains("Hue/Luma"))
        XCTAssertTrue(c.drawnStrings.contains("Add a color selection")); XCTAssertTrue(c.drawnStrings.contains("Custom LUT"))
        let wheel = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:wheels", 1) })
        XCTAssertTrue(p.pointerDown(CanvasPoint(wheel.maxX - 4, wheel.y + wheel.height / 2)))
        p.pointerUp(CanvasPoint(wheel.maxX - 4, wheel.y + wheel.height / 2))
        // wheelFromPointer: y up, hue counter-clockwise from +x, so the right edge is hue 0 (red in the
        // engine's HSV, red on the conic ring) and the top is 90.
        let w = try XCTUnwrap(editor.colorGrading(clipId: "clip:a")?.wheel("midtones"))
        XCTAssertEqual(min(w.hue, 360 - w.hue), 0, accuracy: 3); XCTAssertGreaterThan(w.amount, 0.8)
        c.reset(); p.draw(c, in: rect)
        let wheelTop = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:wheels", 1) })
        XCTAssertTrue(p.pointerDown(CanvasPoint(wheelTop.midX, wheelTop.y + 4))); p.pointerUp(CanvasPoint(wheelTop.midX, wheelTop.y + 4))
        XCTAssertEqual(try XCTUnwrap(editor.colorGrading(clipId: "clip:a")?.wheel("midtones")).hue, 90, accuracy: 3)
        c.reset(); p.draw(c, in: rect)
        let graph = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:curve", 0) })
        let pt = CanvasPoint(graph.x + graph.width * 0.5, graph.y + graph.height * 0.3)
        XCTAssertTrue(p.pointerDown(pt)); p.pointerUp(pt)
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.curve("master").count, 3)
        XCTAssertTrue(p.keyDown(EditorKey(.delete)))
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.curve("master").count, 2)
    }
}

final class MediaBinTests: XCTestCase {
    /// Insert lands at the drop time; rename/delete go through the backend (RuntimeDesktopBackendTests).
    func testInsertAtTime() throws {
        let editor = try demoEditor()
        let id = try XCTUnwrap(editor.insertClip(assetId: "asset:logo", at: 2))
        XCTAssertEqual(editor.clip(id)?.clip.startFrame, 60)
    }

    /// Pressing a bin card and moving past the threshold starts an asset drag; the drop target reads the carried
    /// asset after release. A click without movement stays a click (double-click still adds at the playhead).
    func testBinCardDragCarriesTheAsset() throws {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        s.items = [.init(id: "media/b-roll.mp4", name: "b-roll.mp4", path: "media/b-roll.mp4", category: .video, duration: 4, used: false)]
        let c = PanelMeasureCanvas(); s.draw(c, size: CanvasSize(370, 800))
        let card = try XCTUnwrap(s.hits.rect { $0 == .tile(.media("media/b-roll.mp4")) })
        let p = center(card)
        XCTAssertTrue(s.pointerDown(p, time: 10))
        _ = s.pointerMove(CanvasPoint(p.x + 2, p.y))
        XCTAssertNil(s.draggingAssetId, "under the threshold")
        _ = s.pointerMove(CanvasPoint(p.x + 40, p.y + 300))
        XCTAssertEqual(s.draggingAssetId, "media/b-roll.mp4")
        s.pointerUp(CanvasPoint(p.x + 40, p.y + 300))
        XCTAssertNil(s.draggingAssetId)
        XCTAssertEqual(s.lastDraggedAssetId, "media/b-roll.mp4")
        var added: String?
        s.onAddAtPlayhead = { added = $0 }
        _ = s.pointerDown(p, time: 20); s.pointerUp(p); _ = s.pointerDown(p, time: 20.2); s.pointerUp(p)
        XCTAssertEqual(added, "media/b-roll.mp4")
        XCTAssertNil(s.lastDraggedAssetId)
    }

    /// The timeline drop outline (isDragOver): a 1 px accent/60 line just inside the tracks area under
    /// the toolbar.
    func testTimelineDropOutlineMatchesTheTsOutline() {
        final class Rec: CanvasContext {
            var strokes: [(CanvasPath, CanvasColor, StrokeStyle)] = []; var clips: [CanvasPath] = []
            func save() {}; func restore() {}; func translate(_ dx: Double, _ dy: Double) {}; func scale(_ sx: Double, _ sy: Double) {}
            func rotate(_ radians: Double) {}; func clip(_ path: CanvasPath) { clips.append(path) }
            func fill(_ path: CanvasPath, _ color: CanvasColor) {}
            func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) { strokes.append((path, color, style)) }
            func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {}
            func measureText(_ text: String, font: CanvasFont) -> CanvasSize { .init(0, 0) }
            func drawImage(_ image: CanvasImage, in rect: CanvasRect) {}
        }
        let timeline = CanvasRect(x: 2, y: 540, width: 1436, height: 358)
        XCTAssertEqual(AssetDropOutline.tracksArea(timeline: timeline), CanvasRect(x: 2, y: 573, width: 1436, height: 325))
        let c = Rec()
        AssetDropOutline.draw(c, timeline: timeline)
        XCTAssertEqual(c.strokes.count, 1)
        XCTAssertEqual(c.strokes.first?.0, .rect(CanvasRect(x: 2.5, y: 573.5, width: 1435, height: 324)))
        XCTAssertEqual(c.strokes.first?.1, PanelTheme.accent.withAlpha(0.6))
        XCTAssertEqual(c.strokes.first?.2.width, 1)
        XCTAssertTrue(c.clips.isEmpty, "the flat timeline has no rounded corners to clip to")
    }

    func testSidebarCategoriesSearchAndMenu() throws {
        let store = MemoryPanelPreferencesStore()
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: store, viewportWidth: 1440))
        s.items = [
            .init(id: "v1", name: "b-roll.mp4", path: "media/b-roll.mp4", category: .video, duration: 92, used: false),
            .init(id: "v2", name: "CS146.mp4", path: "media/CS146.mp4", category: .video, duration: 336, used: true),
            .init(id: "a1", name: "music.wav", path: nil, category: .audio, duration: 30, used: false),
        ]
        XCTAssertEqual(s.categorized.map(\.0), [.video, .audio])
        XCTAssertEqual(s.categorized[0].1.map(\.id), ["v2", "v1"], "used first")
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(370, 800))
        XCTAssertFalse(c.drawnStrings.contains("Added"), "a clip in the timeline carries a check, not an Added badge")
        XCTAssertTrue(c.drawnStrings.contains("05:36"))
        XCTAssertTrue(c.drawnStrings.contains("Import")); XCTAssertTrue(c.drawnStrings.contains("Search media…"))
        var added: String?
        s.onAddAtPlayhead = { added = $0 }
        let card = try XCTUnwrap(s.hits.rect { $0 == .tile(.media("v1")) })
        XCTAssertTrue(s.secondaryClick(center(card)))
        c.reset(); s.draw(c, size: CanvasSize(370, 800))
        let item = try XCTUnwrap(s.hits.rect { $0 == .menuItem("v1", 0) })
        _ = s.pointerDown(center(item))
        XCTAssertEqual(added, "v1")
        let search = try XCTUnwrap(s.hits.rect { $0 == .search })
        _ = s.pointerDown(center(search))
        for ch in "cs1" { _ = s.keyDown(EditorKey(.char(ch))) }
        XCTAssertEqual(s.filteredItems.map(\.id), ["v2"])
        let hide = try XCTUnwrap(s.hits.rect { $0 == .hideSidebar })
        _ = s.pointerDown(center(hide))
        XCTAssertTrue(s.layout.effectiveLeftCollapsed)
    }

    /// The library lives in the header: the switcher shows "library ▸ event", the "…" menu runs the library
    /// commands, and the library's files and exports are grid sections (not text lists above the bin).
    func testLibraryNavigatorCommands() throws {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        s.library.available = true
        s.library.libraries = [.init(id: "L", name: "test", events: [.init(id: "E", name: "Media")], projects: [.init(id: "P", name: "jk", eventId: "E")],
                                     assets: [.init(id: "A", name: "clip.mp4", kind: "video", eventId: "E")], exports: [.init(id: "J", label: "jk", status: "complete")])]
        s.library.currentProjectId = "P"
        var cmds: [LibraryNavCommand] = []
        s.onLibrary = { cmds.append($0) }
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(370, 900))
        for t in ["test", "Media", "Library media", "clip.mp4", "Exports", "jk"] { XCTAssertTrue(c.drawnStrings.contains(t), "missing \(t)") }
        for t in ["Libraries", "New library", "New event", "Library media (1)", LeftSidebarPanel.revealLabel] {
            XCTAssertFalse(c.drawnStrings.contains(t), "\(t) is a menu item now, not a row")
        }
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more })))
        XCTAssertEqual(s.dropdown.options.map(\.label), ["New library…", "Open library…", "New event…", "Rename event…", "Import into Media…", "Copy files into the library",
                                                         "Link to the original files", LeftSidebarPanel.revealLabel, "jk", "New project…", "Rename project…", "Open project…",
                                                         "Open existing standalone project"])
        s.dropdown.pick("reveal")
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more })))
        s.dropdown.pick("newEvent")
        c.reset(); s.draw(c, size: CanvasSize(370, 900))
        for ch in "Day 2" { _ = s.keyDown(ch == " " ? EditorKey(.space) : EditorKey(.char(ch))) }
        _ = s.keyDown(EditorKey(.enter))
        XCTAssertEqual(cmds, [.reveal(libraryId: "L"), .createEvent(libraryId: "L", name: "Day 2")])
    }

    /// "Library exports": a completed export offers "Save to…", which asks the host to save that export; a failed or
    /// running one offers nothing, and while a library command runs the button is disabled (#40).
    func testLibraryExportsOfferSaveToForCompletedExportsOnly() throws {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        s.library.available = true
        s.library.libraries = [.init(id: "L", name: "test", events: [.init(id: "E", name: "Media")], projects: [.init(id: "P", name: "jk", eventId: "E")],
                                     exports: [.init(id: "J1", label: "render-1.mp4", status: "complete"),
                                               .init(id: "J2", label: "render-2.mp4", status: "failed"),
                                               .init(id: "J3", label: "J3", status: "rendering")])]
        s.library.currentProjectId = "P"
        var cmds: [LibraryNavCommand] = []
        s.onLibrary = { cmds.append($0) }
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(370, 900))
        XCTAssertTrue(s.secondaryClick(center(try XCTUnwrap(s.hits.rect { $0 == .tile(.export("J1")) }))))
        c.reset(); s.draw(c, size: CanvasSize(370, 900))
        XCTAssertTrue(c.drawnStrings.contains("Save to…"))
        XCTAssertNotNil(s.hits.rect { $0 == .tile(.export("J2")) })
        XCTAssertTrue(s.menuEntries(.export("J2")).isEmpty)
        XCTAssertTrue(s.menuEntries(.export("J3")).isEmpty)
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .menuItem("J1", 0) })))
        XCTAssertEqual(cmds, [.saveOutput(libraryId: "L", jobId: "J1")])
        s.library.busy = true
        c.reset(); s.draw(c, size: CanvasSize(370, 900))
        s.runPrimary(.export("J1"))
        XCTAssertEqual(cmds, [.saveOutput(libraryId: "L", jobId: "J1")], "disabled while a library command runs")
    }

    private func keys(_ text: String) -> [EditorKey] { text.map { $0 == " " ? EditorKey(.space) : EditorKey(.char($0)) } }
    private func typeKeys(_ s: LeftSidebarPanel, _ keys: [EditorKey]) { keys.forEach { _ = s.keyDown($0) } }

    private func renameNavigator(_ cmds: @escaping (LibraryNavCommand) -> Void) -> LeftSidebarPanel {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        s.library.available = true
        s.library.libraries = [.init(id: "L", name: "test", events: [.init(id: "E", name: "Media")],
                                     projects: [.init(id: "P", name: "jk", eventId: "E")])]
        s.library.currentProjectId = "P"
        s.onLibrary = cmds
        s.draw(PanelMeasureCanvas(), size: CanvasSize(370, 900))
        return s
    }

    /// "Rename event…" and "Rename project…" in the More menu open the name row on the current name; Enter sends the rename of
    /// the shown event or the current project with the trimmed name, and Escape sends nothing (#40).
    func testLibraryNavigatorRenamesTheShownEventAndTheCurrentProject() throws {
        var cmds: [LibraryNavCommand] = []
        let s = renameNavigator { cmds.append($0) }
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more })))
        s.dropdown.pick("renameEvent")
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(370, 900))
        XCTAssertEqual(c.drawnStrings.filter { $0 == "Rename" }.count, 1, "the name row's confirm")
        XCTAssertNotNil(s.hits.rect { $0 == .createField })
        XCTAssertTrue(s.isEditingText)
        typeKeys(s, Array(repeating: EditorKey(.backspace), count: 5) + keys("Day 2 ") + [EditorKey(.enter)])
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more })))
        s.dropdown.pick("renameProject")
        typeKeys(s, keys(" v2") + [EditorKey(.enter)])
        XCTAssertEqual(cmds, [.renameEvent(libraryId: "L", eventId: "E", name: "Day 2"),
                              .renameProject(libraryId: "L", projectId: "P", name: "jk v2")])
        s.draw(PanelMeasureCanvas(), size: CanvasSize(370, 900))
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more })))
        s.dropdown.pick("renameProject")
        _ = s.keyDown(EditorKey(.escape))
        XCTAssertFalse(s.isEditingText)
        XCTAssertEqual(cmds.count, 2, "Escape renames nothing")
    }

    /// The open Rename row keeps its target: switching the event picker before Enter still renames the event the row
    /// was opened for (Codex review on #146).
    func testRenameKeepsItsTargetWhenThePickerChanges() throws {
        var cmds: [LibraryNavCommand] = []
        let s = renameNavigator { cmds.append($0) }
        s.library.libraries[0].events.append(.init(id: "E2", name: "B-roll"))
        s.draw(PanelMeasureCanvas(), size: CanvasSize(370, 900))
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more })))
        s.dropdown.pick("renameEvent")
        s.draw(PanelMeasureCanvas(), size: CanvasSize(370, 900))
        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .switcher }))))
        s.dropdown.pick("event:E2")
        typeKeys(s, keys(" day") + [EditorKey(.enter)])
        XCTAssertEqual(cmds, [.renameEvent(libraryId: "L", eventId: "E", name: "Media day")])
    }

    /// While a library command runs the open name row cannot be sent (it would be dropped): Enter keeps the row and its
    /// draft, Rename is disabled, and once the library is idle Enter sends it (Codex review on #146).
    func testOpenNameRowWaitsWhileTheLibraryIsBusy() throws {
        var cmds: [LibraryNavCommand] = []
        let s = renameNavigator { cmds.append($0) }
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more })))
        s.dropdown.pick("renameProject")
        typeKeys(s, keys(" v2"))
        s.library.busy = true
        s.draw(PanelMeasureCanvas(), size: CanvasSize(370, 900))
        XCTAssertNil(s.hits.rect { $0 == .createConfirm }, "the row's Rename is disabled")
        typeKeys(s, [EditorKey(.enter)])
        XCTAssertEqual(cmds, [])
        XCTAssertTrue(s.isEditingText, "the row and its draft stay")
        s.library.busy = false
        typeKeys(s, [EditorKey(.enter)])
        XCTAssertEqual(cmds, [.renameProject(libraryId: "L", projectId: "P", name: "jk v2")])
    }

    /// Rename is offered only for something shown: no project rename without a current project in the shown event,
    /// and neither while a library command runs.
    func testLibraryNavigatorRenameNeedsATargetAndAnIdleLibrary() throws {
        let s = renameNavigator { _ in }
        s.library.currentProjectId = nil
        s.draw(PanelMeasureCanvas(), size: CanvasSize(370, 900))
        XCTAssertFalse(try XCTUnwrap(s.libraryOptions().first { $0.value == "renameEvent" }).disabled)
        XCTAssertTrue(try XCTUnwrap(s.projectOptions().first { $0.value == "renameProject" }).disabled)
        s.library.currentProjectId = "P"
        s.library.busy = true
        s.draw(PanelMeasureCanvas(), size: CanvasSize(370, 900))
        XCTAssertTrue(try XCTUnwrap(s.libraryOptions().first { $0.value == "renameEvent" }).disabled)
        XCTAssertTrue(try XCTUnwrap(s.projectOptions().first { $0.value == "renameProject" }).disabled)
    }

    /// "Open project…" asks for a folder; the recent projects are a group of the "…" menu and open the one picked.
    func testOpenProjectAndRecentProjects() throws {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        s.library.available = true
        s.library.isStandalone = true
        var cmds: [LibraryNavCommand] = []
        s.onLibrary = { cmds.append($0) }
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(370, 900))
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more })))
        XCTAssertTrue(s.dropdown.options.contains { $0.label == "Open project…" })
        XCTAssertFalse(s.dropdown.options.contains { $0.group == "Recent projects" }, "no recent projects: no Recent group")
        s.dropdown.pick("openProject")
        XCTAssertEqual(cmds, [.openProject])

        s.library.recentProjects = [.init(path: "/p/Alpha", name: "Alpha"), .init(path: "/q/Beta", name: "Beta")]
        c.reset(); s.draw(c, size: CanvasSize(370, 900))
        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .more }))))
        XCTAssertTrue(s.dropdown.isOpen)
        XCTAssertEqual(s.dropdown.options.filter { $0.group == "Recent projects" }.map(\.label), ["Alpha", "Beta"])
        s.dropdown.pick("recent:/q/Beta")
        XCTAssertEqual(cmds, [.openProject, .openRecentProject("/q/Beta")])
    }
}

final class RightPanelTests: XCTestCase {
    /// RenderQueueItem: × asks "Delete?" / "Keep" first; Keep and leaving the row back out; Delete? deletes. The download
    /// icon and the thumbnail reveal a finished render; Recheck re-probes the bundled tools; the row shows "1h ago · 46 MB"
    /// and the render time, and a running render its stage, progress to one decimal and Cancel.
    func testRenderRowsDeleteConfirmAndMeta() throws {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        let r = RightPanel(layout: layout)
        r.now = { 10_000 }
        r.jobs = [.init(id: "a", name: "A.mp4", status: .complete, createdAt: 10_000.0 - 3700, sizeBytes: 48_200_000, durationMs: 42_000),
                  .init(id: "b", name: "B.mp4", status: .rendering, stage: "Encoding frames (4 workers)", progress: 0.375)]
        var actions: [RenderAction] = []
        r.onRender = { actions.append($0) }
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 700))
        XCTAssertTrue(c.drawnStrings.contains("1h ago · 46 MB")); XCTAssertTrue(c.drawnStrings.contains("42s"))
        XCTAssertTrue(c.drawnStrings.contains("Encoding frames")); XCTAssertTrue(c.drawnStrings.contains("37.5%"))
        XCTAssertTrue(c.drawnStrings.contains("Cancel")); XCTAssertTrue(c.drawnStrings.contains("Rendering…"))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .cancel("b") })))
        XCTAssertEqual(actions.last, .cancel("b"))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .reveal("a") })))
        XCTAssertEqual(actions.last, .reveal("a"))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .thumb("a") })))
        XCTAssertEqual(actions.last, .reveal("a"))
        // × → Delete? / Keep
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .confirmDelete("a") })))
        XCTAssertEqual(r.confirmingDelete, "a"); XCTAssertNotEqual(actions.last, .delete("a"))
        c.reset(); r.draw(c, size: CanvasSize(409, 700))
        XCTAssertTrue(c.drawnStrings.contains("Delete?")); XCTAssertTrue(c.drawnStrings.contains("Keep"))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .keep("a") })))
        XCTAssertNil(r.confirmingDelete)
        c.reset(); r.draw(c, size: CanvasSize(409, 700))
        XCTAssertFalse(c.drawnStrings.contains("Delete?"))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .confirmDelete("a") })))
        c.reset(); r.draw(c, size: CanvasSize(409, 700))
        _ = r.pointerMove(CanvasPoint(200, 30))   // pointer leaves the row
        XCTAssertNil(r.confirmingDelete)
        c.reset(); r.draw(c, size: CanvasSize(409, 700))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .confirmDelete("a") })))
        c.reset(); r.draw(c, size: CanvasSize(409, 700))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .delete("a") })))
        XCTAssertEqual(actions.last, .delete("a")); XCTAssertNil(r.confirmingDelete)
        // No jobs: the empty list, and Export stays available (the engine is built in, nothing to locate)
        r.jobs = []
        c.reset(); r.draw(c, size: CanvasSize(409, 700))
        XCTAssertTrue(c.drawnStrings.contains("No renders yet"))
        XCTAssertNotNil(r.hits.rect { $0 == .export })
        XCTAssertEqual(RightPanel.progressText(0.4), "40"); XCTAssertEqual(RightPanel.duration(ms: 65_000), "1m 5s")
        XCTAssertEqual(RightPanel.timeAgo(100, now: 130), "just now"); XCTAssertEqual(RightPanel.timeAgo(0, now: 600), "10m ago")
    }

    /// Renders tab keyboard focus: Tab reaches Export and Enter starts the render; ⇧Tab walks back.
    func testRendersKeyboardFocus() throws {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        let r = RightPanel(layout: layout)
        var actions: [RenderAction] = []
        r.onRender = { actions.append($0) }
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 600))
        XCTAssertTrue(r.keyDown(EditorKey(.tab)))
        XCTAssertEqual(r.focus.current, .renders, "Tab starts at the strip's selected tab: the tab bar is one stop (docs/DESIGN.md \"Tabs\")")
        var n = 0
        while r.focus.current != .export, n < 30 { _ = r.keyDown(EditorKey(.tab)); n += 1 }
        XCTAssertEqual(r.focus.current, .export)
        XCTAssertTrue(r.keyDown(EditorKey(.enter)))
        XCTAssertEqual(actions.last, .start(r.settings)); XCTAssertTrue(r.focus.visible)
        _ = r.keyDown(EditorKey(.tab, shift: true))
        XCTAssertEqual(r.focus.current, .quality)
        XCTAssertTrue(r.keyDown(EditorKey(.space))); XCTAssertTrue(r.dropdown.isOpen)
    }

    /// A long render list scrolls, and its overlay scrollbar thumb tracks the offset.
    func testRenderListScrollbar() throws {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        let r = RightPanel(layout: layout)
        r.jobs = (0..<20).map { .init(id: "\($0)", name: "R\($0).mp4", status: .complete, createdAt: 0) }
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 600))
        let zone = try XCTUnwrap(r.hits.rect { $0 == .listScrollbar })
        let t0 = try XCTUnwrap(PanelScrollbar.thumb(track: r.listRect, offset: r.listScroll, content: r.listRect.height + r.listMax))
        XCTAssertTrue(zone.contains(CanvasPoint(t0.midX, t0.midY)))
        XCTAssertTrue(r.scroll(CanvasPoint(200, r.listRect.midY), dy: 106))   // two wheel notches
        XCTAssertEqual(r.listScroll, 0, "a wheel step glides, it does not jump")
        while r.tick(1.0 / 60) {}
        XCTAssertEqual(r.listScroll, min(106, r.listMax), accuracy: 0.001)
        let t1 = try XCTUnwrap(PanelScrollbar.thumb(track: r.listRect, offset: r.listScroll, content: r.listRect.height + r.listMax))
        XCTAssertGreaterThan(t1.y, t0.y)
        r.jobs = [r.jobs[0]]; r.listScroll = 0
        c.reset(); r.draw(c, size: CanvasSize(409, 600))
        XCTAssertNil(r.hits.rect { $0 == .listScrollbar })
    }

    func testTabsRailAndExport() throws {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let r = RightPanel(layout: layout)
        r.jobs = [.init(id: "1", name: "Main.mp4", status: .complete, detail: "1920×1080")]
        var actions: [RenderAction] = []
        r.onRender = { actions.append($0) }
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 800))
        XCTAssertTrue(c.drawnStrings.contains("Design")); XCTAssertTrue(c.drawnStrings.contains("Renders (1)"))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .renders })))
        XCTAssertEqual(layout.rightPanelTab, .renders)
        c.reset(); r.draw(c, size: CanvasSize(409, 800))
        XCTAssertTrue(c.drawnStrings.contains("Export")); XCTAssertTrue(c.drawnStrings.contains("Hide finished"))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .format })))
        XCTAssertTrue(r.dropdown.isOpen)
        XCTAssertEqual(r.dropdown.options.map(\.label), ["MP4", "MOV (PNG, alpha)"])   // WebM is not offered
        let opt = r.dropdown.rect
        _ = r.pointerDown(CanvasPoint(opt.x + 20, opt.y + 4 + 24 * 1 + 10))   // MOV (PNG, alpha)
        XCTAssertEqual(r.settings.format, "mov")
        c.reset(); r.draw(c, size: CanvasSize(409, 800))
        XCTAssertTrue(c.drawnStrings.contains("MOV (PNG, alpha)"))
        XCTAssertNil(r.hits.rect { $0 == .quality }, "MOV frames are lossless: no quality choice")
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .export })))
        XCTAssertEqual(actions.first, .start(r.settings))
        _ = r.pointerDown(center(try XCTUnwrap(r.hits.rect { $0 == .hide })))
        XCTAssertTrue(layout.effectiveRightCollapsed)
        c.reset(); r.draw(c, size: CanvasSize(40, 800))
        XCTAssertNotNil(r.hits.rect { $0 == .show })
    }
}

/// The side panels' tab strips: the panel menu's actions, the hints the status line shows, and the Import media
/// button dropping its label when the strip is narrow.
final class PanelTabStripTests: XCTestCase {
    func testRightPanelMenu() throws {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let r = RightPanel(layout: layout)
        var actions: [RenderAction] = []
        r.onRender = { actions.append($0) }
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 800))
        let menu = try XCTUnwrap(r.hits.rect { $0 == .panelMenu })
        XCTAssertTrue(r.pointerMove(center(menu)))
        XCTAssertEqual(r.hint, "Panel menu")
        _ = r.pointerDown(center(menu))
        XCTAssertEqual(r.dropdown.options.map(\.label), ["Keyframe easing", "Hide panel"], "nothing finished to hide yet; Keyframe easing opens the Easing tab")
        r.dropdown.close()
        r.jobs = [.init(id: "1", name: "Main.mp4", status: .complete), .init(id: "2", name: "Next.mp4", status: .rendering)]
        c.reset(); r.draw(c, size: CanvasSize(409, 800))
        _ = r.pointerDown(center(menu))
        XCTAssertEqual(r.dropdown.options.map(\.label), ["Hide finished renders", "Keyframe easing", "Hide panel"])
        r.dropdown.pick("hideFinished")
        XCTAssertEqual(actions, [.hideFinished])
        _ = r.pointerDown(center(menu))
        r.dropdown.pick("hide")
        XCTAssertTrue(layout.effectiveRightCollapsed)
        c.reset(); r.draw(c, size: CanvasSize(40, 800))
        let show = try XCTUnwrap(r.hits.rect { $0 == .show })
        XCTAssertTrue(r.pointerMove(center(show)))
        XCTAssertEqual(r.hint, "Show the panel")
    }

    func testLeftPanelMenuAndNarrowImport() throws {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        var imports = 0
        s.onImport = { imports += 1 }
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(370, 800))
        XCTAssertTrue(c.drawnStrings.contains("Media")); XCTAssertTrue(c.drawnStrings.contains("Import"))
        let tab = try XCTUnwrap(s.hits.rect { $0 == .tab(.assets) })
        XCTAssertEqual(tab.y, 0); XCTAssertEqual(tab.height, PanelTabStrip.height)
        let menu = try XCTUnwrap(s.hits.rect { $0 == .panelMenu })
        _ = s.pointerDown(center(menu))
        XCTAssertEqual(s.dropdown.options.map(\.label), ["Import media…", "Add solid colour", "Add linear gradient", "Add radial gradient", "Hide panel"])
        s.dropdown.pick("import")
        XCTAssertEqual(imports, 1)
        let importButton = try XCTUnwrap(s.hits.rect { $0 == .importMedia })
        XCTAssertTrue(s.pointerMove(center(importButton)))
        XCTAssertEqual(s.hint, "Import media files into the project")
        // At 200 points with the library switcher beside it the label does not fit: the button keeps only its plus.
        s.onLibrary = { _ in }
        c.reset(); s.draw(c, size: CanvasSize(200, 800))
        XCTAssertFalse(c.drawnStrings.contains("Import"))
        XCTAssertEqual(try XCTUnwrap(s.hits.rect { $0 == .importMedia }).width, MediaPanelMetrics.control)
        _ = s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .panelMenu })))
        s.dropdown.pick("hide")
        XCTAssertTrue(s.layout.effectiveLeftCollapsed)
    }
}

/// A render setting saved before WebM was withdrawn still names it: the panel shows it as unavailable and Export
/// passes it on, so the backend refuses it with the engine's message (RenderExportEndToEndTests).
final class RightPanelWithdrawnFormatTests: XCTestCase {
    func testSavedWebMShowsAsNotSupported() throws {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        let r = RightPanel(layout: layout)
        r.settings.format = "webm"
        r.hovered = .formatInfo   // the format popover names it too, with what to do instead
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 800))
        XCTAssertEqual(c.drawnStrings.filter { $0 == "WebM (not supported yet)" }.count, 2)   // select + popover title
        XCTAssertTrue(c.drawnStrings.contains { $0.contains("cannot write WebM yet") })
        XCTAssertNil(r.hits.rect { $0 == .quality })
    }
}

/// Side-panel scrolling feel (PanelScroller): trackpad deltas 1:1, wheel line steps glide 140 ms ease-out, ends clamp
/// softly, the overlay scrollbar shows while scrolling and fades at rest.
final class PanelScrollerTests: XCTestCase {
    func testPreciseDeltasMapOneToOneAndClamp() {
        var s = PanelScroller()
        s.scroll(by: 37.5, precise: true, max: 500)
        XCTAssertEqual(s.offset, 37.5); XCTAssertFalse(s.gliding)
        for _ in 0..<10 { s.scroll(by: 2.25, precise: true, max: 500) }   // momentum-phase trickle, never multiplied
        XCTAssertEqual(s.offset, 60, accuracy: 1e-9)
        s.scroll(by: 10_000, precise: true, max: 500); XCTAssertEqual(s.offset, 500)
        s.scroll(by: -10_000, precise: true, max: 500); XCTAssertEqual(s.offset, 0)
    }

    func testWheelStepGlidesToItsTarget() {
        var s = PanelScroller()
        s.scroll(by: 53, precise: false, max: 500)
        XCTAssertEqual(s.offset, 0); XCTAssertEqual(s.target, 53); XCTAssertTrue(s.gliding)
        s.tick(0.035)
        XCTAssertGreaterThan(s.offset, 0); XCTAssertLessThan(s.offset, 53)
        let quarter = s.offset
        s.tick(0.035)
        XCTAssertGreaterThan(s.offset, quarter)
        XCTAssertGreaterThan(s.offset, 53 * 0.6, "ease-out: most of the way by mid-glide")
        s.scroll(by: 53, precise: false, max: 500)   // a second notch mid-glide adds to the target
        XCTAssertEqual(s.target, 106)
        var last = s.offset, frames = 0
        while s.gliding && frames < 100 { s.tick(1.0 / 60); XCTAssertGreaterThanOrEqual(s.offset, last); last = s.offset; frames += 1 }
        XCTAssertEqual(s.offset, 106, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(Double(frames), (PanelScroller.glideDuration * 60).rounded(.up) + 1)
    }

    func testWheelClampsWithoutOvershootOrSnap() {
        var s = PanelScroller()
        s.scroll(by: 80, precise: true, max: 100)
        s.scroll(by: 53, precise: false, max: 100)
        XCTAssertEqual(s.target, 100)
        var samples: [Double] = []
        while s.gliding { s.tick(1.0 / 60); samples.append(s.offset) }
        XCTAssertTrue(samples.allSatisfy { $0 <= 100 })
        XCTAssertGreaterThan(samples.count, 2, "eases into the end over several frames")
        XCTAssertEqual(s.offset, 100)
        s.scroll(by: 53, precise: false, max: 100)
        XCTAssertFalse(s.gliding); XCTAssertEqual(s.offset, 100)
        s.clamp(max: 40); XCTAssertEqual(s.offset, 40); XCTAssertEqual(s.target, 40)
    }

    func testScrollbarFadesInWhileScrollingAndOutAtRest() {
        var s = PanelScroller()
        XCTAssertEqual(s.barOpacity, 0)
        s.scroll(by: 10, precise: true, max: 100)
        XCTAssertEqual(s.barOpacity, 1)
        s.tick(PanelScroller.holdDuration); XCTAssertEqual(s.barOpacity, 1)
        s.tick(PanelScroller.fadeDuration / 2); XCTAssertEqual(s.barOpacity, 0.5, accuracy: 0.01)
        XCTAssertFalse(s.tick(PanelScroller.fadeDuration)); XCTAssertEqual(s.barOpacity, 0)
    }

    func testInspectorBodyScrollIsPreciseOrGliding() throws {
        let p = InspectorPanel(); p.editor = try demoEditor(); p.selection = ["clip:a"]; p.time = 1
        let c = PanelMeasureCanvas()
        p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 300))
        XCTAssertGreaterThan(p.bodyMaxScroll, 60)
        var asked = 0
        p.onAnimate = { asked += 1 }
        XCTAssertTrue(p.scroll(CanvasPoint(100, 200), dy: 12, precise: true))
        XCTAssertEqual(p.bodyScroll, 12)
        XCTAssertTrue(p.scroll(CanvasPoint(100, 200), dy: 53))
        XCTAssertEqual(p.bodyScroll, 12); XCTAssertGreaterThan(asked, 0)
        while p.tick(1.0 / 60) {}
        XCTAssertEqual(p.bodyScroll, 65, accuracy: 1e-9)
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 300))
        XCTAssertEqual(p.bodyScroll, 65, accuracy: 1e-9, "a redraw keeps the offset")
    }
}
