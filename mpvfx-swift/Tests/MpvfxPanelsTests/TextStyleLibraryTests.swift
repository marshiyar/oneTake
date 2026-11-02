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
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
import XCTest

@testable import MpvfxPanels

/// Issue #283: the per-user style library, the Style menu and its shortcuts.
internal final class TextStyleLibraryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("text-styles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func library(_ dir: URL, fail: Bool = false) -> TextStyleLibrary {
        TextStyleLibrary(path: dir.appendingPathComponent("text-styles.json").path) { data, path in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    private func style(_ id: String, _ name: String, size: Double = 48, color: String = "#ffffff") -> NativeTextStyle {
        NativeTextStyle(id: id, name: name, text: NativeClipText(content: "", fontSize: size, fontWeight: 700, color: color))
    }
    private func editor() throws -> (TimelineEditor, [String]) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        let ids = (0..<3).compactMap { editor.addTextClip(at: Double($0 * 6), content: "Words \($0)") }
        XCTAssertEqual(ids.count, 3)
        return (editor, ids)
    }
    private func panel(_ editor: TimelineEditor, selecting ids: [String], library: TextStyleLibrary?) -> InspectorPanel {
        let panel = InspectorPanel()
        panel.editor = editor
        panel.textStyleLibrary = library
        panel.selection = ids
        panel.openGroupId = "text"
        redraw(panel)
        return panel
    }
    private func redraw(_ panel: InspectorPanel) {
        panel.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 360, height: 2000))
    }
    private func open(_ panel: InspectorPanel) {
        panel.button("textStyle:menu")?.action()
        redraw(panel)
    }

    // MARK: The file

    internal func testSaveReplaceAndDeleteSurviveReopeningTheFile() throws {
        let dir = try directory()
        let first = library(dir)
        XCTAssertNil(first.loadError)
        try first.save(style("a", "Title"))
        try first.save(style("b", "Quote", size: 30))
        try first.save(style("a", "Bold title", size: 60))
        let reopened = library(dir)
        XCTAssertEqual(reopened.menuStyles.map(\.name), ["Bold title", "Quote"])
        XCTAssertEqual(reopened.menuStyles.first?.text?.fontSize, 60)
        try reopened.delete(id: "a")
        XCTAssertEqual(library(dir).menuStyles.map(\.id), ["b"])
    }

    internal func testA1CorruptFileIsReportedWithItsPathAndLeftUntouched() throws {
        let dir = try directory()
        let path = dir.appendingPathComponent("text-styles.json").path
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: URL(fileURLWithPath: path))
        let broken = library(dir)
        XCTAssertEqual(broken.loadError?.path, path)
        XCTAssertTrue(broken.loadError?.localizedDescription.contains(path) == true)
        XCTAssertTrue(broken.menuStyles.isEmpty)
        XCTAssertThrowsError(try broken.save(style("a", "Title"))) { XCTAssertEqual(($0 as? TextStyleLibraryError)?.path, path) }
        XCTAssertThrowsError(try broken.delete(id: "a"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), corrupt)
        // The menu still opens, with the reason in it, and a repaired file is picked up the next time it opens.
        let (editor, ids) = try editor()
        let panel = panel(editor, selecting: [ids[0]], library: broken)
        open(panel)
        XCTAssertNotNil(panel.button("textStyle:save"), "the rest of the menu is still there")
        XCTAssertTrue(panel.allRows().contains { if case .note(let text) = $0.kind { return text.contains(path) } else { return false } })
        try Data(#"{"version":1,"styles":[]}"#.utf8).write(to: URL(fileURLWithPath: path))
        broken.reload()
        XCTAssertNil(broken.loadError)
        try broken.save(style("a", "Title"))
    }

    internal func testFutureVersionAndDuplicateIdsAreRefusedAndKept() throws {
        let dir = try directory()
        let seed = library(dir)
        try seed.save(style("a", "A"))
        let one = try Data(contentsOf: URL(fileURLWithPath: seed.path))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: one) as? [String: Any])
        let styles = try XCTUnwrap(object["styles"] as? [Any])
        var duplicated = object
        duplicated["styles"] = styles + styles
        object["version"] = 2
        for broken in [object, duplicated] {
            let data = try JSONSerialization.data(withJSONObject: broken)
            try data.write(to: URL(fileURLWithPath: seed.path))
            let loaded = library(dir)
            XCTAssertNotNil(loaded.loadError, "\(broken)")
            XCTAssertThrowsError(try loaded.save(style("b", "B")))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: seed.path)), data)
        }
    }

    internal func testWriteFailureKeepsTheOldFileAndMemory() throws {
        let dir = try directory()
        let good = library(dir)
        try good.save(style("a", "Title"))
        let old = try Data(contentsOf: URL(fileURLWithPath: good.path))
        let failing = library(dir, fail: true)
        XCTAssertThrowsError(try failing.save(style("b", "Quote")))
        XCTAssertEqual(failing.menuStyles.map(\.id), ["a"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: good.path)), old)
    }

    internal func testNamesAreCheckedBeforeAnythingIsWritten() throws {
        let dir = try directory()
        let lib = library(dir)
        XCTAssertThrowsError(try lib.save(style("a", "   ")))
        XCTAssertThrowsError(try lib.save(style("a", String(repeating: "x", count: 121))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.path))
    }

    // MARK: Using a library style in a project

    internal func testA2FirstUseCopiesTheStyleIntoTheProjectAsOneUndoStep() throws {
        let (editor, ids) = try editor()
        let original = editor.document
        let count = editor.undoStack.count
        let quote = style("text-style:quote", "Quote", size: 72, color: "#ff0000")
        XCTAssertNil(editor.document.textStyles)
        XCTAssertTrue(editor.applyLibraryTextStyle(quote, clipIds: [ids[0], ids[2]]))
        XCTAssertEqual(editor.undoStack.count, count + 1)
        XCTAssertEqual(editor.document.textStyles?.map(\.id), ["text-style:quote"])
        XCTAssertEqual(editor.clipText(clipId: ids[0])?.fontSize, 72)
        XCTAssertEqual(editor.clipText(clipId: ids[2])?.color, "#ff0000")
        XCTAssertEqual(editor.clipText(clipId: ids[0])?.content, "Words 0")
        XCTAssertNotEqual(editor.clipText(clipId: ids[1])?.fontSize, 72)
        // The user later changes the library's copy: the project keeps its own.
        XCTAssertTrue(editor.applyLibraryTextStyle(style("text-style:quote", "Quote", size: 20), clipIds: [ids[1]]))
        XCTAssertEqual(editor.clipText(clipId: ids[1])?.fontSize, 72)
        XCTAssertTrue(editor.undo()); XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, original)
    }

    internal func testApplyingToALockedTrackChangesNothing() throws {
        let (editor, ids) = try editor()
        let trackId = try XCTUnwrap(editor.document.sequence.tracks.first { $0.clips.contains { $0.id == ids[0] } }?.id)
        XCTAssertTrue(editor.setTrackLocked(trackId, true))
        let locked = editor.document
        let count = editor.undoStack.count
        XCTAssertFalse(editor.applyLibraryTextStyle(style("text-style:quote", "Quote"), clipIds: [ids[0]]))
        XCTAssertEqual(editor.document, locked)
        XCTAssertEqual(editor.undoStack.count, count)
    }

    // MARK: The Style menu

    internal func testMenuListsLibraryThenProjectOnlyStylesAndAppliesOnClick() throws {
        let dir = try directory()
        let lib = library(dir)
        try lib.save(style("lib:1", "Lower third", size: 40))
        try lib.save(style("lib:2", "Quote", size: 30, color: "#ffcc00"))
        let (editor, ids) = try editor()
        XCTAssertTrue(editor.saveTextStyle(clipId: ids[0], styleId: "proj:1", name: "Only here"))
        let panel = panel(editor, selecting: [ids[1], ids[2]], library: lib)
        XCTAssertNil(panel.customRow("textStyle:pick:lib:1"), "closed menu draws no samples")
        open(panel)
        for id in ["lib:1", "lib:2", "proj:1"] { XCTAssertNotNil(panel.customRow("textStyle:pick:\(id)"), id) }
        XCTAssertEqual(panel.textStyleChoices(editor).map(\.id), ["lib:1", "lib:2", "proj:1"])
        let target = try XCTUnwrap(panel.hits.rect(where: { $0 == .custom("textStyle:pick:lib:2", 0) }))
        XCTAssertTrue(panel.press(.custom("textStyle:pick:lib:2", 0)), "\(target)")
        XCTAssertEqual(editor.clip(ids[1])?.1.textStyle?.styleId, "lib:2")
        XCTAssertEqual(editor.clip(ids[2])?.1.textStyle?.styleId, "lib:2")
        XCTAssertNil(editor.clip(ids[0])?.1.textStyle)
        XCTAssertEqual(editor.clipText(clipId: ids[2])?.color, "#ffcc00")
        XCTAssertEqual(editor.document.textStyles?.map(\.id), ["proj:1", "lib:2"])
        redraw(panel)
        XCTAssertEqual(panel.button("textStyle:menu")?.label, "Style: Quote")
    }

    internal func testSaveCurrentAsStyleWritesTheLibraryAndLinksTheLayer() throws {
        let dir = try directory()
        let lib = library(dir)
        let (editor, ids) = try editor()
        XCTAssertTrue(editor.setTextFontSize(clipId: ids[0], 96))
        let panel = panel(editor, selecting: [ids[0]], library: lib)
        let count = editor.undoStack.count
        open(panel)
        panel.number("textStyle:name")?.commit("Big title")
        panel.button("textStyle:save")?.action()
        XCTAssertEqual(editor.undoStack.count, count + 1)
        XCTAssertEqual(lib.menuStyles.map(\.name), ["Big title"])
        XCTAssertEqual(lib.menuStyles.first?.text?.fontSize, 96)
        XCTAssertEqual(lib.menuStyles.first?.text?.content, "")
        XCTAssertEqual(editor.clip(ids[0])?.1.textStyle?.styleId, lib.menuStyles.first?.id)
        XCTAssertEqual(library(dir).menuStyles.map(\.name), ["Big title"])
        // The same name twice is refused with the reason in the menu, and nothing changes.
        redraw(panel)
        panel.number("textStyle:name")?.commit("Big title")
        let before = editor.document
        XCTAssertFalse(panel.saveTextStyleFromLayer())
        XCTAssertEqual(editor.document, before)
        XCTAssertEqual(library(dir).menuStyles.count, 1)
    }

    internal func testUpdateDetachAndDeleteKeepTheProjectsCopy() throws {
        let dir = try directory()
        let lib = library(dir)
        let (editor, ids) = try editor()
        let panel = panel(editor, selecting: [ids[0]], library: lib)
        XCTAssertTrue(panel.saveTextStyleFromLayer())
        let styleId = try XCTUnwrap(lib.menuStyles.first?.id)
        XCTAssertTrue(editor.setTextFontSize(clipId: ids[0], 33))
        open(panel)
        panel.button("textStyle:update")?.action()
        XCTAssertEqual(lib.menuStyles.first?.text?.fontSize, 33)
        panel.button("textStyle:delete")?.action()
        XCTAssertTrue(lib.menuStyles.isEmpty)
        XCTAssertEqual(editor.document.textStyles?.map(\.id), [styleId], "the project keeps its copy")
        XCTAssertEqual(editor.clipText(clipId: ids[0])?.fontSize, 33, "layers keep their look")
        redraw(panel)
        panel.button("textStyle:detach")?.action()
        XCTAssertNil(editor.clip(ids[0])?.1.textStyle)
        XCTAssertEqual(editor.clipText(clipId: ids[0])?.fontSize, 33)
    }

    // MARK: Shortcuts

    internal func testA3ShortcutsApplyTheNthStyleAndSaveTheSelectedLayer() throws {
        let dir = try directory()
        let lib = library(dir)
        for n in 1...3 { try lib.save(style("lib:\(n)", "Style \(n)", size: Double(20 + n))) }
        let (editor, ids) = try editor()
        let panel = panel(editor, selecting: [ids[0]], library: lib)
        XCTAssertTrue(panel.canSaveTextStyle)
        XCTAssertTrue(panel.applyTextStyle(number: 2))
        XCTAssertEqual(editor.clipText(clipId: ids[0])?.fontSize, 22)
        XCTAssertFalse(panel.applyTextStyle(number: 4), "there is no fourth style")
        XCTAssertFalse(panel.applyTextStyle(number: 0))
        XCTAssertTrue(panel.saveTextStyleFromLayer())
        XCTAssertEqual(lib.menuStyles.last?.name, "Text style 4")
        XCTAssertTrue(panel.applyTextStyle(number: 4))
        panel.selection = []
        XCTAssertFalse(panel.canSaveTextStyle, "without a text layer ⌥⌘S stays scene splitting")
        XCTAssertFalse(panel.applyTextStyle(number: 1))
        panel.selection = [ids[0], ids[1]]
        XCTAssertFalse(panel.canSaveTextStyle, "one layer at a time")
        XCTAssertTrue(panel.applyTextStyle(number: 1))
        XCTAssertEqual(editor.clip(ids[1])?.1.textStyle?.styleId, "lib:1")
    }

    internal func testShortcutsCardListsTheTextStyleKeys() {
        let keys = shortcutSections.flatMap(\.hints).map(\.key)
        XCTAssertTrue(keys.contains("⌥⌘S") && keys.contains("⌥⌘1–9"), "\(keys)")
        XCTAssertEqual(shortcutSections.flatMap(\.hints).filter { $0.key == "⌥⌘S" }.count, 1)
    }

    // MARK: Samples

    internal func testSampleUsesTheStylesOwnValuesAndAPlateThatContrastsWithThem() throws {
        let white = try XCTUnwrap(TextStyleSample.text(style("a", "Title", size: 90, color: "#ffffff")))
        let block = TextStyleSample.block(white)
        XCTAssertEqual(block.text, "Title")
        XCTAssertEqual(block.font.size, TextStyleSample.maxFontSize, accuracy: 1e-9, "large styles shrink to the menu row")
        XCTAssertEqual(block.font.numericWeight, 700)
        XCTAssertEqual(block.color, CanvasColor(r: 1, g: 1, b: 1))
        let small = try XCTUnwrap(TextStyleSample.text(style("b", "Label", size: 12)))
        XCTAssertEqual(TextStyleSample.block(small).font.size, 12, accuracy: 1e-9, "small styles keep their size")
        XCTAssertNil(TextStyleSample.text({ var future = style("c", "Future"); future.version = 2; return future }()))
        XCTAssertLessThan(TextStyleSample.plate(for: CanvasColor(r: 1, g: 1, b: 1)).r, 0.5)
        XCTAssertGreaterThan(TextStyleSample.plate(for: CanvasColor(r: 0, g: 0, b: 0)).r, 0.5)
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

extension TextStyleLibraryTests {
    /// A4: the sample is painted with the text painter, so its pixels carry the style's colour on the plate.
    internal func testA4SampleRendersTheStylesColourWithTheTextPainter() throws {
        let canvas = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: 240, height: 36))
        let text = try XCTUnwrap(TextStyleSample.text(style("a", "Title", size: 90, color: "#ff0000")))
        TextStyleSample.draw(text, in: CanvasRect(x: 0, y: 0, width: 240, height: 36), on: canvas)
        let image = try XCTUnwrap(canvas.ctx.makeImage())
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = CFDataGetBytePtr(data)
        var red = 0, plate = 0
        let rowBytes = image.bytesPerRow
        for y in 0..<image.height {
            for x in 0..<image.width {
                let p = bytes! + y * rowBytes + x * 4
                if p[0] > 200, p[1] < 60, p[2] < 60 { red += 1 }
                if abs(Int(p[0]) - 240) < 8, abs(Int(p[1]) - 240) < 8, abs(Int(p[2]) - 240) < 8 { plate += 1 }
            }
        }
        XCTAssertGreaterThan(red, 40, "the glyphs are red")
        XCTAssertGreaterThan(plate, 2000, "red text sits on the light plate")
    }
}
#endif
