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
import Foundation
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import MpvfxTimeline
import MpvfxPanels
import OneTakeMedia
@testable import MpvfxPlayer
@testable import MpvfxRuntime

/// Records the text the preview draws (what reached the canvas) besides the other drawing calls.
final class TextAuditCanvas: CanvasContext {
    struct Run: Equatable { var text: String; var x, y: Double; var font: CanvasFont; var color: CanvasColor }
    var runs: [Run] = []
    var transforms: [String] = []
    func save() {}
    func restore() {}
    func translate(_ dx: Double, _ dy: Double) { transforms.append("t\(dx),\(dy)") }
    func scale(_ sx: Double, _ sy: Double) { transforms.append("s\(sx),\(sy)") }
    func rotate(_ radians: Double) { transforms.append("r\(radians)") }
    func clip(_ path: CanvasPath) {}
    func fill(_ path: CanvasPath, _ color: CanvasColor) {}
    func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {}
    func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {
        runs.append(Run(text: text, x: origin.x, y: origin.y, font: font, color: color))
    }
    /// Half an em per character, bold a little wider, so layout differences show without a real font.
    func measureText(_ text: String, font: CanvasFont) -> CanvasSize {
        CanvasSize(Double(text.count) * font.size * ((font.numericWeight ?? 400) >= 600 ? 0.6 : 0.5), font.size)
    }
    func drawImage(_ image: CanvasImage, in rect: CanvasRect) {}
    func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double) {}
}

/// A serif family the host has installed, for the font-family edit.
#if os(Windows)
private let serifFamilyOnThisHost = "Times New Roman"   // installed on every Windows; DejaVu is not
#else
private let serifFamilyOnThisHost = "DejaVu Serif"
#endif

/// Text group: each control, driven through its inspector row, changes the text the preview draws and the
/// frame export paints for the clip (the same layout, drawn by the same painter).
final class InspectorTextAuditTests: XCTestCase {
    /// Canvas 200×100 at 10 fps, a native media document with one text layer T (box 160×40 at 20,30) over 3 s.
    static let json = """
    {"schemaVersion":1,"mediaEngine":"native","id":"project:text","revision":1,"frameRate":{"numerator":10,"denominator":1},
     "canvas":{"width":200,"height":100,"background":"#000000"},
     "assets":[{"id":"t","kind":"element","name":"Text","durationFrames":30}],
     "sequence":{"id":"s","name":"Main","tracks":[
      {"id":"tv","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"T","assetId":"t","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],
        "staticParameters":{"layout.left":20,"layout.top":30,"layout.width":160,"layout.height":40},
        "text":{"content":"Hello world","fontSize":20,"color":"#ffffff"}}]}]}}
    """

    var engine: KeyframeRuntime!
    var editor: TimelineEditor!
    var inspector: InspectorPanel!
    var scratch: String!

    override func setUpWithError() throws {
        engine = try KeyframeRuntime()
        editor = try TimelineEditor(json: Self.json, engine: engine)
        inspector = InspectorPanel()
        inspector.editor = editor
        inspector.selection = ["T"]; inspector.time = 0
        scratch = NSTemporaryDirectory() + "text-audit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }

    var text: NativeClipText { editor.clip("T")!.clip.text! }

    func row(_ key: String) -> InspectorRow.Kind? {
        for g in inspector.groups { for r in g.rows {
            switch r.kind {
            case .number(let n) where n.key == key: return r.kind
            case .segmented(let s) where s.key == key: return r.kind
            default: break
            }
        } }
        XCTFail("no inspector row \(key)"); return nil
    }
    func type(_ key: String, _ value: String) {
        guard case .number(let n)? = row(key) else { return XCTFail("\(key) is not a field") }
        n.commit(value)
    }
    func pick(_ key: String, _ option: String) {
        guard case .segmented(let s)? = row(key) else { return XCTFail("\(key) is not segmented") }
        s.select(option)
    }

    /// The text runs the preview composites at 0.5 s into a 400×200 view (2 view px per canvas px).
    func previewRuns() -> [TextAuditCanvas.Run] {
        let comp = PreviewComposition(document: editor.document, projectDir: URL(fileURLWithPath: "/text"), engine: engine, fileExists: { _ in true })
        let cx = PreviewCompositor(decodesMedia: false)
        cx.composition = comp
        let c = TextAuditCanvas()
        cx.draw(c, in: CanvasRect(x: 0, y: 0, width: 400, height: 200), time: 0.5, elements: [], context: FrameDrawContext())
        return c.runs
    }

    /// The frame export paints for the document at 0.5 s: the runtime's render document through the export painter
    /// (which lays the text out with the preview's text renderer on the engine's raster canvas).
    func exportPicture(file: StaticString = #filePath, line: UInt = #line) -> [UInt8] {
        do {
            let doc = nativeExportPreparedDocument(try parseNativeProjectDocument(editor.document, engine: engine), media: [:])
            let painter = try ExportFramePainter(composition: PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/text"), engine: engine),
                                                 width: 200, height: 100, pad: CanvasColor(r: 0, g: 0, b: 0))
            return try painter.paint(time: 0.5) { _, _, _, _ in nil }.rgba
        } catch { XCTFail("export refused the text clip: \(error)", file: file, line: line); return [] }
    }

    /// Asserts the edit changed the preview's text and the exported picture.
    func assertTextEdit(_ name: String, file: StaticString = #filePath, line: UInt = #line, _ edit: () -> Void,
                        check: ([TextAuditCanvas.Run]) -> Void = { _ in }) {
        let before = previewRuns(), exportBefore = exportPicture(file: file, line: line)
        edit()
        let after = previewRuns(), exportAfter = exportPicture(file: file, line: line)
        XCTAssertFalse(after.isEmpty, "\(name): the preview draws no text", file: file, line: line)
        XCTAssertNotEqual(after, before, "\(name): the preview text did not change", file: file, line: line)
        XCTAssertNotEqual(exportAfter, exportBefore, "\(name): the exported picture did not change", file: file, line: line)
        check(after)
    }

    // MARK: Group

    func testTextGroupComesFirstWithTheTSRows() {
        let groups = inspector.groups
        XCTAssertEqual(groups.first?.id, "text"); XCTAssertEqual(groups.first?.title, "Text")
        XCTAssertEqual(groups.first?.summary, "Hello world")
        XCTAssertFalse(groups.contains { $0.id == "media" }, "a text layer has no media")
        let keys = groups.first!.rows.compactMap { r -> String? in
            switch r.kind { case .number(let n): return n.key; case .segmented(let s): return s.key; default: return nil }
        }
        XCTAssertEqual(keys, ["textContent", "fontFamily", "fontSize", "fontWeight", "letterSpacing", "lineHeight", "textAlign", "textCase", "textColor"])
        XCTAssertFalse(previewRuns().isEmpty, "the preview draws the text")
    }

    // MARK: Controls

    /// An element layer without `text` (from an earlier version of the editor) is kept in the document but the
    /// preview composition skips it; the text layer still draws.
    func testAnUndrawnElementLayerIsSkippedByThePreview() throws {
        var doc = editor.document
        doc.assets.append(.init(id: "card", kind: .element, name: "Card", source: nil, durationFrames: 30))
        doc.sequence.tracks[0].clips.append(.fresh(id: "C", assetId: "card", startFrame: 0, durationFrames: 30))
        let parsed = try parseNativeProjectDocument(doc, engine: engine)
        XCTAssertTrue(parsed.isUndrawnElementClip(parsed.sequence.tracks[0].clips[1]))
        let comp = PreviewComposition(document: parsed, projectDir: URL(fileURLWithPath: "/text"), engine: engine, fileExists: { _ in true })
        XCTAssertEqual(comp.entries.map(\.clip.id), ["T"])
    }

    func testContent() {
        assertTextEdit("Content", { type("textContent", "Bye\\nnow") }) { runs in
            XCTAssertEqual(runs.map(\.text), ["Bye", "now"], "\\n breaks the line")
            XCTAssertGreaterThan(runs[1].y, runs[0].y)
        }
        XCTAssertEqual(text.content, "Bye\nnow")
    }

    func testFontFamily() {
        let family = serifFamilyOnThisHost
        assertTextEdit("Font", { type("fontFamily", family) }) { runs in XCTAssertEqual(runs.first?.font.family, family) }
        guard case .number(let n)? = row("fontFamily") else { return }
        n.reset?()
        XCTAssertNil(text.fontFamily, "reset falls back to the default font")
    }

    func testFontSize() {
        assertTextEdit("Size", { type("fontSize", "32") }) { runs in XCTAssertEqual(runs.first?.font.size ?? 0, 64, accuracy: 1e-9, "32 px at the 2x view") }
        XCTAssertEqual(text.fontSize, 32)
    }

    func testFontWeight() {
        assertTextEdit("Weight", { type("fontWeight", "Bold") }) { runs in XCTAssertEqual(runs.first?.font.numericWeight, 700) }
        XCTAssertEqual(text.fontWeight, 700)
        type("fontWeight", "300"); XCTAssertEqual(text.fontWeight, 300)
        type("fontWeight", "heavy-ish"); XCTAssertEqual(text.fontWeight, 300, "an unreadable weight is ignored")
    }

    func testLetterSpacing() {
        assertTextEdit("Letter spacing", { type("letterSpacing", "4px") }) { runs in
            XCTAssertEqual(runs.count, "Helloworld".count, "one run per character")
            XCTAssertEqual(runs[1].x - runs[0].x, 20 + 8, accuracy: 1e-9, "advance (10 canvas px) + 4 px spacing, at 2x")
        }
        XCTAssertEqual(text.letterSpacing, 4)
    }

    func testLineHeight() {
        type("textContent", "A\\nB")
        assertTextEdit("Line height", { type("lineHeight", "2") }) { runs in
            XCTAssertEqual(runs[1].y - runs[0].y, 80, accuracy: 1e-9, "2 × 20 px at 2x")
        }
        XCTAssertEqual(text.lineHeight, 2)
        type("lineHeight", "30px"); XCTAssertEqual(text.lineHeight, 1.5, "px divide by the font size")
        type("lineHeight", "normal"); XCTAssertNil(text.lineHeight)
    }

    func testAlign() {
        let left = previewRuns().first!.x
        assertTextEdit("Align", { pick("textAlign", "right") }) { runs in
            // Box 160 canvas px from x 20; "Hello world" is 11 × 10 = 110 px wide.
            XCTAssertEqual(runs.first!.x, (20 + 160 - 110) * 2, accuracy: 1e-9); XCTAssertGreaterThan(runs.first!.x, left)
        }
        pick("textAlign", "center")
        XCTAssertEqual(previewRuns().first!.x, (20 + 25) * 2, accuracy: 1e-9)
        XCTAssertEqual(text.align, "center")
    }

    func testJustifySpreadsWrappedLines() {
        // "aa bb" fits the 160 px box and the long word does not, so the first line ends well short of the edge in
        // any font: with words that nearly fill the line, justify moves glyphs by under a pixel and export can't tell.
        type("textContent", "aa bb wwwwwwwwwwww")
        assertTextEdit("Justify", { pick("textAlign", "justify") }) { runs in
            let firstLine = runs.filter { $0.y == runs[0].y }
            XCTAssertGreaterThan(firstLine.count, 1)
            XCTAssertEqual(firstLine.last!.x + Double(firstLine.last!.text.count) * 20, (20 + 160) * 2, accuracy: 1e-6, "the first line reaches the right edge")
        }
    }

    func testCase() {
        assertTextEdit("Case", { pick("textCase", "uppercase") }) { runs in XCTAssertEqual(runs.first?.text, "HELLO WORLD") }
        pick("textCase", "capitalize"); XCTAssertEqual(previewRuns().first?.text, "Hello World")
        pick("textCase", "none"); XCTAssertNil(text.textTransform)
    }

    func testItalic() {
        assertTextEdit("Style", { pick("textCase", "italic") }) { runs in XCTAssertEqual(runs.first?.font.italic, true) }
        XCTAssertEqual(text.fontStyle, "italic")
        pick("textCase", "normal"); XCTAssertNil(text.fontStyle)
    }

    func testColor() {
        assertTextEdit("Color", { type("textColor", "#ff0000") }) { runs in XCTAssertEqual(runs.first?.color, CanvasColor(r: 1, g: 0, b: 0)) }
        type("textColor", "not a colour"); XCTAssertEqual(text.color, "#ff0000", "an unreadable value is ignored")
    }

    func testTextFollowsTheTransform() {
        // The Transform group still moves the text layer; preview and export follow.
        let before = previewRuns().first!.x
        var x: InspectorRow.Number?
        for g in inspector.groups { for r in g.rows { if case .pair(_, let a, _) = r.kind, a.key == "x" { x = a } } }
        x?.commit("50")
        XCTAssertEqual(previewRuns().first!.x - before, 100, accuracy: 1e-9, "50 canvas px right at 2x")
    }

    // MARK: Editor

    func testAddTextClipIsOneUndoStep() throws {
        let undoBefore = editor.undoLabel
        guard let id = editor.addTextClip(at: 1) else { return XCTFail("no text clip") }
        XCTAssertEqual(editor.undoLabel, "Add text")
        let c = try XCTUnwrap(editor.clip(id)?.clip)
        XCTAssertEqual(c.text?.content, "Text"); XCTAssertEqual(c.startFrame, 10)
        XCTAssertEqual(editor.document.assets.first { $0.id == c.assetId }?.kind, .element)
        XCTAssertNoThrow(try parseNativeProjectDocument(editor.document), "a native media document accepts a text layer")
        _ = editor.undo()
        XCTAssertNil(editor.clip(id), "one undo removes the clip")
        XCTAssertFalse(editor.document.assets.contains { $0.id == c.assetId }, "and its asset")
        XCTAssertEqual(editor.undoLabel, undoBefore)
    }

    func testValidationKeepsAnElementWithoutTextAsAnUndrawnLayer() throws {
        let plain = Self.json.replacingOccurrences(of: ##""text":{"content":"Hello world","fontSize":20,"color":"#ffffff"}"##, with: ##""hidden":false"##)
        let kept = try parseNativeProjectDocument(try NativeJSONValue.parse(plain))
        XCTAssertTrue(kept.isUndrawnElementClip(kept.sequence.tracks[0].clips[0]), "an element without text is kept, not drawn")
        let bad = Self.json.replacingOccurrences(of: #""fontSize":20"#, with: #""fontSize":20,"align":"middle""#)
        XCTAssertThrowsError(try parseNativeProjectDocument(try NativeJSONValue.parse(bad)))
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json))
        let round = try JSONDecoder().decode(NativeProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(round.sequence.tracks[0].clips[0].text, NativeClipText(content: "Hello world", fontSize: 20, color: "#ffffff"))
    }

    // MARK: Real render

    /// Ink columns of a 200×100 RGB frame's row band (bright pixels).
    func inkColumns(_ f: [UInt8]) -> [Int] {
        var cols = Set<Int>()
        for y in 30..<70 { for x in 0..<200 where Int(f[(y * 200 + x) * 3]) > 128 { cols.insert(x) } }
        return cols.sorted()
    }

    func testExportRendersTheTextLikeThePreview() throws {
        NativeExportFrames.defaultRenderer = PreviewExportFrames.factory   // as main.swift installs it
        func render(_ name: String) throws -> [UInt8] {
            let out = "\(scratch!)/\(name).mov"
            try renderNativeTimeline(NativeTimelineRenderInput(project: editor.document, projectDir: scratch, outputPath: out, format: .mov,
                                                               quality: .high, keyframeEngine: engine))
            let rgba = try VideoFrameReader(path: out).frame(at: 0.5, width: 200, height: 100, fit: .stretch).rgba
            return stride(from: 0, to: rgba.count, by: 4).flatMap { (i: Int) -> [UInt8] in [rgba[i], rgba[i + 1], rgba[i + 2]] }
        }
        type("fontSize", "30"); type("fontWeight", "700"); type("textContent", "HI")
        let left = inkColumns(try render("left"))
        XCTAssertFalse(left.isEmpty, "white text shows in the export")
        XCTAssertGreaterThanOrEqual(left.first ?? 0, 18, "inside the box from x 20"); XCTAssertLessThan(left.last ?? 200, 100)
        pick("textAlign", "right")
        let right = inkColumns(try render("right"))
        XCTAssertGreaterThan(right.first ?? 0, 100, "right aligned: the ink moved to the right of the box")
        XCTAssertLessThanOrEqual(right.last ?? 999, 181)
    }
}
