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
import MpvfxTheme
import OneTakeKeyframes
#if os(macOS)
import CoreGraphics
import ImageIO
#endif
@testable import MpvfxTimeline
@testable import MpvfxPanels

final class EffectsEditorTests: XCTestCase {
    func fixture(_ key: String = "ascii") throws -> (RightPanel, TimelineEditor) {
        let panel = RightPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        let editor = try TimelineEditor(json: InspectorMediaFitTests.json, engine: KeyframeRuntime())
        panel.inspector.editor = editor
        panel.inspector.selection = ["clip:a"]
        let spec = try XCTUnwrap(EffectSpecs.spec(key))
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", EffectSpecs.adding(spec, to: ColorGrading())))
        panel.inspector.openGroupId = "effects"
        panel.inspector.effectsUI = EffectsUIState(clipId: "clip:a", catalogOpen: false, selectedKey: key)
        return (panel, editor)
    }

    func draw(_ panel: RightPanel) { panel.draw(PanelMeasureCanvas(), size: CanvasSize(409, 1400)) }
    func press(_ panel: RightPanel, _ id: String, _ part: Int = 0) throws {
        draw(panel)
        let rect = try XCTUnwrap(panel.inspector.hits.rect(where: { $0 == .custom(id, part) }))
        XCTAssertTrue(panel.pointerDown(CanvasPoint(rect.midX, rect.midY)))
    }

    func testSelectPicksBrailleWithOneUndoAndEscapeDoesNotEdit() throws {
        let (panel, editor) = try fixture()
        let depth = editor.undoStack.count
        try press(panel, "fx:sel:asciiStyle")
        XCTAssertTrue(panel.dropdown.isOpen)
        XCTAssertEqual(panel.dropdown.options[4].label, "Braille")
        panel.dropdown.highlightSelected()
        for _ in 0..<4 { XCTAssertTrue(panel.dropdown.key(EditorKey(.down))) }
        XCTAssertEqual(editor.undoStack.count, depth, "navigation does not commit")
        XCTAssertTrue(panel.dropdown.key(EditorKey(.enter)))
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.effect("asciiStyle"), 4)
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.effect("asciiStyle"), 0)
        try press(panel, "fx:sel:asciiStyle")
        XCTAssertTrue(panel.dropdown.key(EditorKey(.down)))
        XCTAssertTrue(panel.dropdown.key(EditorKey(.escape)))
        XCTAssertFalse(panel.dropdown.isOpen)
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.effect("asciiStyle"), 0)
    }

    func testRemoveDeletesAllKeysAndReaddUsesDefaults() throws {
        let (panel, editor) = try fixture()
        var grade = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        grade.effects["asciiStyle"] = 4
        grade.bypassedEffects = ["ascii"]
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade))
        let depth = editor.undoStack.count
        try press(panel, "fx:head", 1)
        let removed = editor.colorGrading(clipId: "clip:a") ?? ColorGrading()
        XCTAssertTrue(removed.effects.keys.filter { $0.hasPrefix("ascii") }.isEmpty)
        XCTAssertFalse(removed.bypassedEffects.contains("ascii"))
        XCTAssertNil(removed.json["effects"])
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        panel.inspector.effectsUI.catalogOpen = true
        panel.inspector.effectsUI.catalogFamily = "Art"
        try press(panel, "fx:tiles", 0)
        let added = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        XCTAssertEqual(added.effects, EffectSpecs.applyDefaults["ascii"])
        XCTAssertTrue(added.bypassedEffects.isEmpty)
        XCTAssertTrue(editor.undo())
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.effects["asciiStyle"], 4)
    }

    func testRemoveDropsAnimatedMasterAndUndoRestoresIt() throws {
        let (panel, editor) = try fixture("blur")
        try XCTUnwrap(panel.inspector.slider("fx:blur")?.keyframe).stopwatch()
        XCTAssertTrue(editor.isAnimated(clipId: "clip:a", "grade.effects.blur"))
        let depth = editor.undoStack.count
        try press(panel, "fx:head", 1)
        XCTAssertFalse(editor.isAnimated(clipId: "clip:a", "grade.effects.blur"))
        XCTAssertEqual(editor.gradeShown(clipId: "clip:a", time: 0).effect("blur"), 0)
        XCTAssertNil(editor.colorGrading(clipId: "clip:a")?.effects["blur"])
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertTrue(editor.undo())
        XCTAssertTrue(editor.isAnimated(clipId: "clip:a", "grade.effects.blur"))
        XCTAssertEqual(editor.gradeShown(clipId: "clip:a", time: 0).effect("blur"), 0.45)
    }

    func testRemovingAPresetEffectDoesNotRestoreFallbackOrChangeOtherValues() throws {
        var grade = ColorGrading()
        grade = grade.applying(try XCTUnwrap(ColorGrading.preset("creator-camcorder")))
        let removed = EffectSpecs.removing(try XCTUnwrap(EffectSpecs.spec("tapeDamage")), from: grade)
        XCTAssertNil(removed.preset)
        XCTAssertEqual(removed.effect("tapeDamage"), 0)
        XCTAssertEqual(removed.adjustValue("contrast"), grade.adjustValue("contrast"))
        XCTAssertEqual(removed.effect("chromaBleed"), grade.effect("chromaBleed"))
        XCTAssertTrue(removed.effects.keys.filter { $0.hasPrefix("tape") }.isEmpty)
    }

    func testBypassHas24PointAccessibleTargetAndRoundTripsValues() throws {
        let (panel, editor) = try fixture()
        let grade = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        draw(panel)
        let control = try XCTUnwrap(panel.inspector.accessibilityControls.first { $0.label == "ASCII enabled" })
        XCTAssertGreaterThanOrEqual(control.frame.width, 24)
        XCTAssertGreaterThanOrEqual(control.frame.height, 24)
        try press(panel, "fx:active:ascii", 1)
        let bypassed = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        XCTAssertEqual(bypassed.effects, grade.effects)
        XCTAssertTrue(ColorGrading(json: bypassed.json).bypassedEffects.contains("ascii"))
        let tile = InspectorPanel.effectDemo(try XCTUnwrap(EffectSpecs.spec("ascii")), base: bypassed)
        XCTAssertFalse(ColorGrading(json: tile.grade).bypassedEffects.contains("ascii"), "tile uses the same add transaction")
        XCTAssertNotNil(panel.inspector.customRow("fx:active:ascii"))
        try press(panel, "fx:active:ascii", 1)
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a"), grade)
    }

    func testPaletteValidatesHexPreservesMiddleColorsAndResets() throws {
        let (panel, editor) = try fixture("monoScreen")
        var grade = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        grade.palette = ["#000000", "#123456", "#ffffff"]
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade))
        try XCTUnwrap(panel.inspector.number("fx:palette:ink")).commit("invalid")
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.palette, grade.palette)
        XCTAssertEqual(panel.inspector.colorFieldError, "fx:palette:ink")
        try XCTUnwrap(panel.inspector.number("fx:palette:ink")).commit("#11223344")
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.palette, grade.palette, "palette rejects alpha")
        try XCTUnwrap(panel.inspector.number("fx:palette:ink")).commit("#AaBBcc")
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.palette, ["#aabbcc", "#123456", "#ffffff"])
        try XCTUnwrap(panel.inspector.number("fx:palette:paper")).commit("#112233")
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.palette?.last, "#112233")
        try XCTUnwrap(panel.inspector.number("fx:palette:ink")?.reset)()
        XCTAssertNil(editor.colorGrading(clipId: "clip:a")?.palette)
        XCTAssertEqual(EffectSpecs.palette(try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))), ["#000000", "#ffffff"])
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.palette?.last, "#112233")
    }

    func testActiveRowsFollowShaderOrderAndExplainIt() throws {
        let (panel, editor) = try fixture("bloom")
        var grade = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        grade.effects["monoScreen"] = 1
        grade.effects["scanlines"] = 0.4
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade))
        let rows = try XCTUnwrap(panel.inspector.groups.first { $0.id == "effects" }).rows
        let ids = rows.compactMap { row -> String? in
            if case .custom(let custom) = row.kind, custom.id.hasPrefix("fx:active:") { return custom.id }
            return nil
        }
        XCTAssertEqual(ids, ["fx:active:monoScreen", "fx:active:bloom", "fx:active:scanlines"])
        XCTAssertTrue(rows.contains { if case .note("Effects apply in this order") = $0.kind { return true }; return false })
        XCTAssertEqual(Set(EffectSpecs.applicationOrder), Set(EffectSpecs.all.map(\.key)))
    }
    #if os(macOS)
    func testNativeEffectsCapturesWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let (panel, editor) = try fixture("bloom")
        var grade = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        grade.effects["halftone"] = 0.94
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade))
        for (name, mode) in [("dark", ThemeMode.dark), ("light", ThemeMode.light)] {
            Theme.setMode(mode)
            defer { Theme.setMode(.dark) }
            let canvas = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: 409, height: 900))
            panel.draw(canvas, size: CanvasSize(409, 900))
            let image = try XCTUnwrap(canvas.ctx.makeImage())
            let url = URL(fileURLWithPath: "\(directory)/effects-active-\(name)-native-panel.png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
    #endif

}
