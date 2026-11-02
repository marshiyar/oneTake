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
@testable import MpvfxTimeline
@testable import MpvfxPanels

final class InspectorColorKeyTests: XCTestCase {
    struct MissingRow: Error { var key: String }

    func panel(select id: String = "clip:a") throws -> (RightPanel, TimelineEditor) {
        let (r, editor) = try InspectorMediaFitTests().panel(select: id)
        r.inspector.openGroupId = "clip-effects"
        return (r, editor)
    }

    func group(_ p: InspectorPanel) throws -> InspectorGroup {
        try XCTUnwrap(p.groups.first { $0.id == "clip-effects" })
    }

    func button(_ p: InspectorPanel, _ key: String) throws -> InspectorRow.Button {
        for row in try group(p).addressableRows {
            if case .buttons(let buttons) = row.kind, let button = buttons.first(where: { $0.key == key }) { return button }
        }
        throw MissingRow(key: key)
    }

    func number(_ p: InspectorPanel, _ key: String) throws -> InspectorRow.Number {
        for row in try group(p).addressableRows {
            if case .number(let number) = row.kind, number.key == key { return number }
        }
        throw MissingRow(key: key)
    }

    func toggle(_ p: InspectorPanel) throws -> InspectorRow.Toggle {
        for row in try group(p).addressableRows {
            if case .toggle(let toggle) = row.kind, toggle.key == "colorKey.enabled" { return toggle }
        }
        throw MissingRow(key: "colorKey.enabled")
    }

    func testAddAndRemoveEachRecordOneUndoStepAndNotifyTheHost() throws {
        let (r, editor) = try panel()
        let p = r.inspector
        let original = editor.document
        var edits = 0
        p.onEdited = { edits += 1 }
        let depth = editor.undoStack.count
        try button(p, "colorKey.add").action()
        XCTAssertEqual(editor.colorKey(clipId: "clip:a"), ColorKeySettings())
        XCTAssertTrue(editor.isColorKeyEnabled(clipId: "clip:a"))
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertEqual(editor.undoLabel, "Add color key")
        try button(p, "colorKey.remove").action()
        XCTAssertNil(editor.colorKey(clipId: "clip:a"))
        XCTAssertEqual(editor.undoStack.count, depth + 2)
        XCTAssertEqual(editor.undoLabel, "Remove color key")
        XCTAssertEqual(edits, 2)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.colorKey(clipId: "clip:a"), ColorKeySettings())
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, original)
    }

    func testToggleAndEachValueEditAreSingleUndoSteps() throws {
        let (r, editor) = try panel()
        let p = r.inspector
        try button(p, "colorKey.add").action()
        let original = editor.document
        let depth = editor.undoStack.count
        try toggle(p).set(false)
        XCTAssertFalse(editor.isColorKeyEnabled(clipId: "clip:a"))
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        try number(p, "colorKey.color").commit("#123456")
        XCTAssertEqual(editor.colorKey(clipId: "clip:a")?.color, [18.0 / 255, 52.0 / 255, 86.0 / 255])
        XCTAssertEqual(editor.undoStack.count, depth + 2)
        for (index, field) in ["similarity", "smoothness", "spill"].enumerated() {
            try number(p, "colorKey.\(field)").commit("25")
            XCTAssertEqual(editor.undoStack.count, depth + 3 + index)
        }
        let value = try XCTUnwrap(editor.colorKey(clipId: "clip:a"))
        XCTAssertEqual(value.similarity, 0.25)
        XCTAssertEqual(value.smoothness, 0.25)
        XCTAssertEqual(value.spill, 0.25)
        XCTAssertFalse(editor.isColorKeyEnabled(clipId: "clip:a"), "editing settings preserves the switch")
        for _ in 0..<5 { XCTAssertTrue(editor.undo()) }
        XCTAssertEqual(editor.document, original)
    }

    func testHexAcceptsShortAndLongFormsAndRejectsBadValuesWithoutHistory() throws {
        let (r, editor) = try panel()
        let p = r.inspector
        try button(p, "colorKey.add").action()
        XCTAssertEqual(try number(p, "colorKey.color").text, "#00ff00")
        try number(p, "colorKey.color").commit(" #aBc ")
        XCTAssertEqual(editor.colorKey(clipId: "clip:a")?.color, [170.0 / 255, 187.0 / 255, 204.0 / 255])
        XCTAssertEqual(try number(p, "colorKey.color").text, "#aabbcc")
        let original = editor.document
        let depth = editor.undoStack.count
        for bad in ["", "123456", "#12", "#1234", "#12345678", "#gg0000", "#12 345", "#１２３"] {
            try number(p, "colorKey.color").commit(bad)
        }
        for field in ["similarity", "smoothness", "spill"] {
            for bad in ["-1", "101", "nan", "inf", "bad"] { try number(p, "colorKey.\(field)").commit(bad) }
        }
        XCTAssertEqual(editor.document, original)
        XCTAssertEqual(editor.undoStack.count, depth)
    }

    func testDefaultsAreOmittedAndResetsRestoreTheDefaultTier() throws {
        let (r, editor) = try panel()
        let p = r.inspector
        try button(p, "colorKey.add").action()
        let fields = [("color", "#123456", "#00ff00"), ("similarity", "35", "10"),
                      ("smoothness", "45", "10"), ("spill", "55", "0")]
        for (field, custom, def) in fields {
            var row = try number(p, "colorKey.\(field)")
            XCTAssertEqual(row.tier, .default)
            XCTAssertEqual(row.text, def)
            XCTAssertNil(row.reset)
            let depth = editor.undoStack.count
            row.commit(custom)
            row = try number(p, "colorKey.\(field)")
            XCTAssertEqual(row.tier, .explicitCustom)
            try XCTUnwrap(row.reset)()
            XCTAssertEqual(editor.undoStack.count, depth + 2)
            row = try number(p, "colorKey.\(field)")
            XCTAssertEqual(row.tier, .default)
            XCTAssertNil(row.reset)
            row.commit(custom)
            try number(p, "colorKey.\(field)").commit(def)
            XCTAssertEqual(editor.undoStack.count, depth + 4)
        }
        let effect = try XCTUnwrap(editor.clip("clip:a")?.clip.effects.first { $0.effectId == TimelineEditor.colorKeyEffectId })
        XCTAssertEqual(Set(effect.parameters?.keys.map { $0 } ?? []), Set(["v", "kind"]))
    }

    func testViewDropdownAndPickCallTheCallbacksWithoutDocumentEdits() throws {
        let (r, editor) = try panel()
        let p = r.inspector
        try button(p, "colorKey.add").action()
        let original = editor.document
        let depth = editor.undoStack.count
        var views: [ColorKeyViewMode] = []
        var picks = 0
        p.onColorKeyViewChange = { views.append($0) }
        p.onPickKeyColor = { picks += 1 }
        r.draw(PanelMeasureCanvas(), size: CanvasSize(409, 2400))
        let field = try XCTUnwrap(p.hits.rect { $0 == .custom("colorKey.view", 0) })
        XCTAssertTrue(r.pointerDown(CanvasPoint(field.midX, field.midY)))
        XCTAssertTrue(r.dropdown.isOpen)
        XCTAssertEqual(r.dropdown.options.map(\.label), ["Result", "Matte", "Source"])
        r.dropdown.pick("matte")
        XCTAssertEqual(p.colorKeyView, .matte)
        try button(p, "colorKey.view.source").action()
        XCTAssertEqual(p.colorKeyView, .source)
        try button(p, "colorKey.view.result").action()
        XCTAssertEqual(views, [.matte, .source, .result])
        XCTAssertEqual(try button(p, "colorKey.pick").style, .chip)
        p.keyEyedropperActive = true
        XCTAssertEqual(try button(p, "colorKey.pick").style, .chipActive)
        try button(p, "colorKey.pick").action()
        XCTAssertEqual(picks, 1)
        XCTAssertEqual(editor.document, original)
        XCTAssertEqual(editor.undoStack.count, depth)
    }

    func testVideoAndImageHaveAddControlsAndAudioDoesNot() throws {
        let (video, _) = try panel()
        XCTAssertEqual(try button(video.inspector, "colorKey.add").label, "Add color key")
        let (image, _) = try panel()
        image.inspector.editor = try TimelineEditor(json: InspectorMediaFitTests.json.replacingOccurrences(of: "\"kind\":\"video\",\"name\":\"a.mp4\"", with: "\"kind\":\"image\",\"name\":\"a.png\""))
        XCTAssertEqual(try button(image.inspector, "colorKey.add").label, "Add color key")
        let (audio, _) = try panel(select: "clip:m")
        XCTAssertFalse(audio.inspector.groups.contains { $0.id == "clip-effects" })
    }

    func testKeyboardReachesTheControlsAndLayoutPassesAtEveryAuditedWidth() throws {
        let (r, _) = try panel()
        let p = r.inspector
        p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 2400))
        var seen: [InspectorPanel.Hit] = []
        for _ in 0..<100 {
            _ = p.keyDown(EditorKey(.tab))
            if let hit = p.focus.current { seen.append(hit) }
        }
        XCTAssertTrue(seen.contains(.button("colorKey.add")))
        try button(p, "colorKey.add").action()
        try number(p, "colorKey.similarity").commit("30")
        p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 2400))
        p.focus.current = nil
        seen = []
        for _ in 0..<100 {
            _ = p.keyDown(EditorKey(.tab))
            if let hit = p.focus.current { seen.append(hit) }
        }
        for hit: InspectorPanel.Hit in [.toggle("colorKey.enabled"), .field("colorKey.color"), .button("colorKey.pick"),
            .field("colorKey.similarity"), .field("colorKey.smoothness"), .field("colorKey.spill"),
            .custom("colorKey.view", 0), .button("colorKey.remove")] {
            XCTAssertTrue(seen.contains(hit), "Tab reaches \(hit)")
        }
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            defer { Theme.setMode(.dark) }
            for (_, width) in PanelLayoutAuditTests.widths {
                let canvas = PanelMeasureCanvas()
                r.draw(canvas, size: CanvasSize(width, 2400))
                XCTAssertEqual(PanelLayoutAuditTests.gridFailures(p, width: p.lastRect.width), [])
                let targets = PanelLayoutAuditTests.targets(r)
                XCTAssertEqual(PanelLayoutAuditTests.targetFailures(targets), [])
                XCTAssertEqual(PanelLayoutAuditTests.textFailures(PanelLayoutAuditTests.textBoxes(canvas), targets), [])
            }
        }
    }
}
