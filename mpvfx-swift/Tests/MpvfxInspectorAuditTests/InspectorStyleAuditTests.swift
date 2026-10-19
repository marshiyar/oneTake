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
@testable import MpvfxPlayer
@testable import MpvfxRuntime

/// Style group (Fill, Stroke, Shadow): each control, driven through its inspector row, changes the preview frame
/// and the export frame (InspectorRenderAuditTests.assertVisualEdit), checked on the exported pixels.
extension InspectorRenderAuditTests {
    func fills(_ c: AuditCanvas) -> [CanvasColor] { c.ops.compactMap { if case .fill(let col) = $0 { return col }; return nil } }
    func strokes(_ c: AuditCanvas) -> [(CanvasColor, Double)] { c.ops.compactMap { if case let .stroke(col, w) = $0 { return (col, w) }; return nil } }
    /// Box V into the canvas's left 100×100 square: the 2:1 picture leaves 25 px bands above and below it for the
    /// fill, and the canvas right of the box shows shadows.
    func boxed() { type("w", "100"); type("h", "100") }

    func testStyleFill() {
        boxed()
        assertVisualEdit("Fill", { type("fill", "#FF0000") }) { c in
            XCTAssertTrue(fills(c).contains(CanvasColor(r: 1, g: 0, b: 0)), "the box is filled red under the media")
        }
        XCTAssertEqual(editor.clip("V")?.clip.style?.fill, "#ff0000")
        XCTAssertEqual(exportRender().pixel(50, 10), [255, 0, 0, 255], "export fills the band around the picture")
        XCTAssertEqual(exportRender().pixel(50, 50), [200, 200, 200, 255], "the picture is drawn over the fill")
        type("fill", "not a colour")
        XCTAssertEqual(editor.clip("V")?.clip.style?.fill, "#ff0000", "an unreadable value is ignored")
        type("fill", "transparent")
        XCTAssertNil(editor.clip("V")?.clip.style, "transparent clears the fill (and the empty style)")
    }

    func testStyleStrokeWidth() {
        assertVisualEdit("Stroke width", { slide("strokeWidth", 4) }) { c in
            XCTAssertEqual(strokes(c).first?.1 ?? 0, 8, accuracy: 1e-9, "4 canvas px at the 2x view")
        }
        XCTAssertEqual(editor.clip("V")?.clip.style?.strokeStyle, "solid", "a width turns the style to solid")
        let f = exportRender()
        XCTAssertGreaterThan(f.pixel(100, 1)[0], f.pixel(100, 50)[0], "export draws the light default stroke along the box edge")
    }

    func testStyleStrokeStyle() {
        slide("strokeWidth", 4)
        assertVisualEdit("Stroke style", { pick("strokeStyle", "none") }) { c in XCTAssertTrue(strokes(c).isEmpty, "style none draws no stroke") }
        let f = exportRender()
        XCTAssertEqual(f.pixel(100, 1), f.pixel(100, 50), "no stroke in the export")
    }

    func testStyleStrokeColor() {
        slide("strokeWidth", 2)
        assertVisualEdit("Stroke color", { type("strokeColor", "00ff0080") }) { c in
            let col = strokes(c).first?.0
            XCTAssertEqual(col?.g ?? 0, 1, accuracy: 1e-9); XCTAssertEqual(col?.a ?? 0, 128.0 / 255, accuracy: 1e-9)
        }
        let edge = exportRender().pixel(100, 0)
        XCTAssertGreaterThan(Int(edge[1]) - Int(edge[0]), 40, "export strokes the edge half-transparent green: \(edge)")
    }

    func testStyleShadowPreset() {
        boxed()
        let plain = exportRender()
        assertVisualEdit("Shadow", { pick("shadow", "soft") }) { c in
            XCTAssertGreaterThan(fills(c).count, 1, "the soft shadow is drawn under the media")
        }
        XCTAssertEqual(editor.clip("V")?.clip.style?.shadows, NativeClipShadowPreset.soft.shadows)
        XCTAssertLessThan(exportRender().pixel(106, 60)[0], plain.pixel(106, 60)[0], "export darkens the canvas beside the box")
        pick("shadow", "glow")
        let glow = exportRender().pixel(101, 50)
        XCTAssertGreaterThan(Int(glow[1]), Int(glow[0]) + 10, "the glow's green ring hugs the box: \(glow)")
        pick("shadow", "none")
        XCTAssertNil(editor.clip("V")?.clip.style)
        XCTAssertEqual(exportRender(), plain, "no shadow, the plain export again")
    }

    func testStyleFollowsAKeyframedClip() {
        boxed()
        guard case .number(let x)? = find("x"), let kf = x.keyframe else { return XCTFail("position has no keyframe button") }
        kf.toggle(); select("V", time: 2); type("x", "100"); select("V", time: 0)
        type("fill", "#0000ff"); slide("strokeWidth", 3); pick("shadow", "lift")
        // Halfway the box has moved 50 px right: its fill band and its shadow moved with it.
        let f = exportRender(at: 1)
        XCTAssertEqual(f.pixel(100, 10), [0, 0, 255, 255], "the fill band moved with the clip")
        XCTAssertEqual(f.pixel(20, 10), [128, 128, 128, 255], "nothing left behind")
        XCTAssertLessThan(f.pixel(156, 60)[0], 128, "the shadow follows the box")
        XCTAssertGreaterThan(fills(previewFrame(at: 1)).count, 1)
    }
}

/// Transform group's Layer order (layout.zIndex): restacks the clip in preview and export.
final class InspectorLayerOrderAuditTests: XCTestCase {
    /// Two full-canvas video clips: A on the top row (drawn on top), B below.
    static let json = """
    {"schemaVersion":1,"id":"project:z","revision":1,"frameRate":{"numerator":10,"denominator":1},
     "canvas":{"width":200,"height":100,"background":"#000000"},
     "assets":[{"id":"a","kind":"video","name":"a.mp4","source":"a.mp4","durationFrames":100},
               {"id":"b","kind":"video","name":"b.mp4","source":"b.mp4","durationFrames":100}],
     "sequence":{"id":"s","name":"Main","tracks":[
      {"id":"ta","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"A","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]},
      {"id":"tb","kind":"video","lane":{"authoredTrack":2,"displayTrack":1},"clips":[
       {"id":"B","assetId":"b","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
    """

    func testLayerOrderRestacksPreviewAndExport() throws {
        let engine = try KeyframeRuntime()
        let editor = try TimelineEditor(json: Self.json, engine: engine)
        let inspector = InspectorPanel(); inspector.editor = editor; inspector.selection = ["B"]; inspector.time = 0
        func order() -> [String] {
            PreviewComposition(document: editor.document, projectDir: URL(fileURLWithPath: "/z"), engine: engine, fileExists: { _ in true })
                .layers(at: 0.5).map(\.clipId)
        }
        /// The clip export draws on top: its frame (the runtime's render document through the export painter, A
        /// pictured red and B blue) at the canvas centre.
        func exportTop() throws -> String {
            let media = ["a": NativeMediaInfo(path: "/z/a.mp4", video: true, audio: false, duration: 10, natural: .init(width: 200, height: 100)),
                         "b": NativeMediaInfo(path: "/z/b.mp4", video: true, audio: false, duration: 10, natural: .init(width: 200, height: 100))]
            let doc = nativeExportPreparedDocument(try parseNativeProjectDocument(editor.document, engine: engine), media: media)
            let painter = try ExportFramePainter(composition: PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/z"), engine: engine,
                                                                                fileExists: { _ in true }), width: 200, height: 100, pad: CanvasColor(r: 0, g: 0, b: 0))
            let f = try painter.paint(time: 0.5) { layer, _, w, h in
                CanvasImage(width: w, height: h, rgba: Array((0..<(w * h)).map { _ in layer.clipId == "A" ? [UInt8(255), 0, 0, 255] : [0, 0, 255, 255] }.joined()))
            }
            return f.rgba[(50 * 200 + 100) * 4] == 255 ? "A" : "B"
        }
        XCTAssertEqual(order(), ["B", "A"], "bottom first: A (top row) draws on top")
        XCTAssertEqual(try exportTop(), "A", "export stacks the same way")
        var row: InspectorRow.Number?
        for g in inspector.groups { for r in g.rows { if case .number(let n) = r.kind, n.key == "layerOrder" { row = n } } }
        guard let row else { return XCTFail("no Layer order row") }
        XCTAssertEqual(row.text, "0")
        row.commit("5")
        XCTAssertEqual(order(), ["A", "B"], "B now draws on top")
        XCTAssertEqual(try exportTop(), "B", "export draws B last, on top")
        XCTAssertEqual(editor.clip("B")?.clip.staticParameters?["layout.zIndex"], .number(5))
    }
}
