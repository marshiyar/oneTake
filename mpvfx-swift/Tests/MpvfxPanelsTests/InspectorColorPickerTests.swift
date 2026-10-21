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
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// Colour fields (issue #189): a swatch before every colour value, a picker under it (square, hue, alpha for Fill,
/// hex, recent colours, eyedropper), the format hint for a refused value, and values that round-trip unchanged.
final class InspectorColorPickerTests: XCTestCase {
    /// A shape clip S with a fill and a stroke, and a text clip T, on a 200×100 canvas.
    static let json = """
    {"schemaVersion":1,"id":"project:colors","revision":1,"frameRate":{"numerator":10,"denominator":1},
     "canvas":{"width":200,"height":100,"background":"#000000"},
     "assets":[{"id":"e","kind":"element","name":"Shape","durationFrames":30},{"id":"t","kind":"element","name":"Text","durationFrames":30}],
     "sequence":{"id":"s","name":"Main","tracks":[
      {"id":"tv","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"S","assetId":"e","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],
        "style":{"fill":"#224466","strokeWidth":2,"strokeStyle":"solid","strokeColor":"#ffffff"}},
       {"id":"T","assetId":"t","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],
        "text":{"content":"Hello","fontSize":20,"color":"#ffcc00"}}]}]}}
    """

    static let frame = CanvasRect(x: 0, y: 0, width: 360, height: 2000)

    func make(select id: String = "S", group: String = "style") throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: Self.json)
        let p = InspectorPanel(); p.editor = editor; p.selection = [id]; p.openGroupId = group
        redraw(p)
        return (p, editor)
    }

    func redraw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: Self.frame) }

    func rect(_ p: InspectorPanel, _ h: InspectorPanel.Hit, file: StaticString = #filePath, line: UInt = #line) throws -> CanvasRect {
        try XCTUnwrap(p.hits.rect { $0 == h }, "no hit \(h)", file: file, line: line)
    }

    func click(_ p: InspectorPanel, _ h: InspectorPanel.Hit, at fx: Double = 0.5, _ fy: Double = 0.5) throws {
        let r = try rect(p, h)
        let pt = CanvasPoint(r.x + fx * r.width, r.y + fy * r.height)
        XCTAssertTrue(p.pointerDown(pt)); p.pointerUp(pt); redraw(p)
    }

    func fill(_ e: TimelineEditor) -> String? { e.clip("S")?.clip.style?.fill }

    // MARK: A1 swatch

    func testA1EveryColourRowShowsASwatchWithA24PointTarget() throws {
        let (p, _) = try make()
        for (key, want) in [("fill", "#224466"), ("strokeColor", "#ffffff")] {
            XCTAssertEqual(p.number(key)?.swatch?.color, want, key)
            let r = try rect(p, .button("swatch:\(key)"))
            XCTAssertGreaterThanOrEqual(min(r.width, r.height), 24, key)
        }
        let (t, _) = try make(select: "T", group: "text")
        XCTAssertEqual(t.number("textColor")?.swatch?.color, "#ffcc00")
        XCTAssertGreaterThanOrEqual(min(try rect(t, .button("swatch:textColor")).width, try rect(t, .button("swatch:textColor")).height), 24)
    }

    func testA1NoFillShowsTheCheckerboardSwatch() throws {
        let (p, editor) = try make()
        XCTAssertTrue(editor.setClipFill(clipId: "S", nil)); redraw(p)
        XCTAssertEqual(p.number("fill")?.text, "transparent")
        let sw = try XCTUnwrap(p.number("fill")?.swatch)
        XCTAssertNil(sw.color, "none draws the checkerboard")
    }

    // MARK: A2 picker

    func testA2SwatchOpensThePickerWithItsParts() throws {
        let (p, _) = try make()
        try click(p, .button("swatch:fill"))
        XCTAssertEqual(p.colorPicker?.key, "fill")
        for id in ["picker:sv", "picker:hue", "picker:alpha"] { XCTAssertNotNil(p.hits.rect { $0 == .custom(id, 0) }, id) }
        XCTAssertNotNil(p.hits.rect { $0 == .field("picker:hex") })
        XCTAssertNotNil(p.hits.rect { $0 == .button("picker:sample") })
        XCTAssertNotNil(p.hits.rect { $0 == .button("picker:done") })
        XCTAssertEqual(p.number("picker:hex")?.text, "#224466")
        try click(p, .button("swatch:strokeColor"))
        XCTAssertEqual(p.colorPicker?.key, "strokeColor", "one picker at a time")
        XCTAssertNil(p.hits.rect { $0 == .custom("picker:alpha", 0) }, "Stroke color offers no alpha")
    }

    func testA2DragPicksOnReleaseAsOneUndoStep() throws {
        let (p, editor) = try make()
        try click(p, .button("swatch:fill"))
        let sv = try rect(p, .custom("picker:sv", 0))
        XCTAssertTrue(p.pointerDown(CanvasPoint(sv.x + 0.2 * sv.width, sv.y + 0.5 * sv.height)))
        _ = p.pointerMove(CanvasPoint(sv.x + 0.6 * sv.width, sv.y + 0.3 * sv.height))
        _ = p.pointerMove(CanvasPoint(sv.maxX + 50, sv.y - 50))   // past the corner: clamped to full saturation and value
        XCTAssertEqual(fill(editor), "#224466", "nothing is written while dragging")
        p.pointerUp(CanvasPoint(sv.maxX + 50, sv.y - 50)); redraw(p)
        let hue = try XCTUnwrap(PickerColor(hex: "#224466")).hue
        XCTAssertEqual(fill(editor), PickerColor(hue: hue, saturation: 1, value: 1).hex(allowAlpha: true))
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(fill(editor), "#224466", "the whole drag is one undo step")
        redraw(p)
        XCTAssertEqual(p.number("picker:hex")?.text, "#224466", "the open picker follows the undo")
    }

    func testA2KeyboardMovesTheFocusedSquareAndEscapeCloses() throws {
        let (p, editor) = try make()
        try click(p, .button("swatch:fill"))
        p.focus.current = .custom("picker:sv", 0); p.focus.visible = true
        let before = try XCTUnwrap(PickerColor(hex: "#224466"))
        XCTAssertTrue(p.keyDown(EditorKey(.right, shift: true)))
        XCTAssertEqual(try XCTUnwrap(p.colorPicker?.color.saturation), before.saturation + 0.1, accuracy: 1e-9)
        XCTAssertTrue(p.keyDown(EditorKey(.up)))
        XCTAssertEqual(try XCTUnwrap(p.colorPicker?.color.value), before.value + 0.01, accuracy: 1e-9)
        XCTAssertNotEqual(fill(editor), "#224466", "arrows write at once")
        XCTAssertTrue(p.keyDown(EditorKey(.enter)), "Enter on the square is swallowed")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(fill(editor), "#224466", "a run of arrows folds into one undo step")
        p.focus.current = .custom("picker:hue", 0)
        XCTAssertTrue(p.keyDown(EditorKey(.right)))
        XCTAssertEqual(try XCTUnwrap(p.colorPicker?.color.hue), before.hue + 3.6, accuracy: 1e-6)
        XCTAssertTrue(p.keyDown(EditorKey(.escape)))
        XCTAssertNil(p.colorPicker, "Escape closes the picker")
        XCTAssertEqual(p.focus.current, .button("swatch:fill"), "focus goes back to the swatch")
    }

    func testA2EveryPickerPartTakesTabFocus() throws {
        let (p, _) = try make()
        try click(p, .button("swatch:fill"))
        var seen: [InspectorPanel.Hit] = []
        for _ in 0..<60 { _ = p.keyDown(EditorKey(.tab)); if let c = p.focus.current { seen.append(c) } }
        for h: InspectorPanel.Hit in [.button("swatch:fill"), .custom("picker:sv", 0), .custom("picker:hue", 0), .custom("picker:alpha", 0),
                                      .field("picker:hex"), .button("picker:sample"), .button("picker:done")] {
            XCTAssertTrue(seen.contains(h), "\(h) takes focus")
        }
    }

    func testA2RecentColoursAndHexField() throws {
        let (p, editor) = try make()
        try click(p, .button("swatch:fill"))
        p.number("picker:hex")?.commit("#80FF00")
        XCTAssertEqual(fill(editor), "#80ff00")
        redraw(p)
        XCTAssertEqual(p.pickerRecentColors().first, "#80ff00", "a picked colour leads the recent colours")
        XCTAssertTrue(p.pickerRecentColors().contains("#ffffff"), "the project's own colours follow")
        let i = try XCTUnwrap(p.pickerRecentColors().firstIndex(of: "#ffcc00"))
        try click(p, .custom("picker:recent", i))
        XCTAssertEqual(fill(editor), "#ffcc00", "a recent colour applies with one click")
    }

    func testA2EyedropperSamplesTheStageFrame() throws {
        let (p, editor) = try make()
        // A 4×2 stage frame: red on the left half, blue on the right.
        var px = [UInt8](repeating: 255, count: 4 * 2 * 4)
        for y in 0..<2 { for x in 0..<4 { let i = (y * 4 + x) * 4; px[i] = x < 2 ? 255 : 0; px[i + 1] = 0; px[i + 2] = x < 2 ? 0 : 255 } }
        p.stageFrame = { _, _ in .ready(CanvasImage(width: 4, height: 2, rgba: px)) }
        try click(p, .button("swatch:fill"))
        try click(p, .button("picker:sample"))
        try click(p, .custom("picker:frame", 0), at: 0.1, 0.5)
        XCTAssertEqual(fill(editor), "#ff0000")
        try click(p, .custom("picker:frame", 0), at: 0.9, 0.5)
        XCTAssertEqual(fill(editor), "#0000ff")
        p.stageFrame = { _, _ in .unavailable }
        try click(p, .button("picker:sample"))
        XCTAssertNotNil(p.groups.flatMap(\.rows).first { if case .custom(let c) = $0.kind { return c.id == "picker:frameError" }; return false })
    }

    // MARK: A3 refused hex

    func testA3InvalidHexKeepsTheValueAndShowsTheHintUntilTheNextEdit() throws {
        let (p, editor) = try make()
        p.number("fill")?.commit("#22446")
        XCTAssertEqual(fill(editor), "#224466", "the old value stays")
        XCTAssertEqual(p.colorFieldError, "fill"); redraw(p)
        XCTAssertTrue(p.groups.flatMap(\.rows).contains { if case .custom(let c) = $0.kind { return c.id == "colorHint:fill" }; return false })
        XCTAssertEqual(InspectorPanel.colorFormatHint, "Enter a colour like #1A2B3C")
        XCTAssertFalse(editor.canUndo)
        p.number("fill")?.commit("#1A2B3C")
        XCTAssertNil(p.colorFieldError, "the next edit clears the hint")
        XCTAssertEqual(fill(editor), "#1a2b3c")
    }

    // MARK: A4 round trip

    func testA4PickedValuesRoundTripThroughProjectJson() throws {
        let (p, editor) = try make()
        try click(p, .button("swatch:fill"))
        let alpha = try rect(p, .custom("picker:alpha", 0))
        XCTAssertTrue(p.pointerDown(CanvasPoint(alpha.x + alpha.width / 2, alpha.midY))); p.pointerUp(CanvasPoint(alpha.x + alpha.width / 2, alpha.midY))
        let half = try XCTUnwrap(fill(editor))
        XCTAssertEqual(half.count, 9, "alpha below 1 writes #rrggbbaa: \(half)")
        XCTAssertTrue(half.hasPrefix("#224466"))
        p.number("picker:hex")?.commit("#224466"); redraw(p)
        XCTAssertEqual(fill(editor), "#224466", "opaque writes #rrggbb")
        p.number("picker:hex")?.commit("#22446680")
        let reloaded = try TimelineEditor(json: try serializeNativeProjectDocument(editor.document))
        XCTAssertEqual(reloaded.clip("S")?.clip.style?.fill, "#22446680", "unchanged through project.json")
        try click(p, .button("swatch:strokeColor"))
        p.number("picker:hex")?.commit("#33669980")
        XCTAssertEqual(editor.clip("S")?.clip.style?.strokeColor, "#336699", "no alpha where the renderer is not offered it")
    }

    func testA4OpeningAndClosingThePickerWritesNothing() throws {
        let (p, editor) = try make()
        try click(p, .button("swatch:fill"))
        try click(p, .button("picker:done"))
        XCTAssertNil(p.colorPicker)
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(fill(editor), "#224466")
    }

    func testA4HexToPickerAndBackIsExact() {
        for r in stride(from: 0, through: 255, by: 17) { for g in stride(from: 0, through: 255, by: 51) { for b in stride(from: 3, through: 255, by: 28) {
            let hex = String(format: "#%02x%02x%02x", r, g, b)
            XCTAssertEqual(PickerColor(hex: hex)?.hex(allowAlpha: true), hex)
        } } }
        XCTAssertEqual(PickerColor(hex: "#12345680")?.hex(allowAlpha: true), "#12345680")
        XCTAssertEqual(PickerColor(hex: "#12345680")?.hex(allowAlpha: false), "#123456")
        XCTAssertEqual(PickerColor(hex: "#abc")?.hex(allowAlpha: true), "#aabbcc")
        XCTAssertNil(PickerColor(hex: "#22446"))
        XCTAssertNil(PickerColor(hex: "red"))
    }

    func testA2TextColourPicksThroughTheTextGroup() throws {
        let (p, editor) = try make(select: "T", group: "text")
        try click(p, .button("swatch:textColor"))
        XCTAssertNil(p.hits.rect { $0 == .custom("picker:alpha", 0) }, "Text color offers no alpha")
        p.number("picker:hex")?.commit("#00ff88")
        XCTAssertEqual(editor.clip("T")?.clip.text?.color, "#00ff88")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.clip("T")?.clip.text?.color, "#ffcc00")
    }
}
