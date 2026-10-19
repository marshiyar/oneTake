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

/// Transform group's Arc motion rows (switch, Auto-rotate, curviness per segment): each one, driven through its
/// inspector row, moves or turns the clip in the preview, export samples the same box and rotation, and its frames
/// change with it.
final class InspectorArcMotionAuditTests: XCTestCase {
    /// One video clip on a 200×100 canvas at 10 fps whose position is keyed at frames 0, 10 and 20 (straight segments).
    static let json = """
    {"schemaVersion":1,"id":"project:arc","revision":1,"frameRate":{"numerator":10,"denominator":1},
     "canvas":{"width":200,"height":100,"background":"#000000"},
     "assets":[{"id":"v","kind":"video","name":"v.mp4","source":"v.mp4","durationFrames":100}],
     "sequence":{"id":"s","name":"Main","tracks":[
      {"id":"tv","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"C","assetId":"v","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[
        {"schemaVersion":1,"id":"parameter:position","parameterId":"transform.position","valueType":"vec2",
         "frameRate":{"numerator":10,"denominator":1},"keyframes":[
          {"id":"a","frame":0,"value":{"x":0,"y":0},"outgoing":{"type":"linear"}},
          {"id":"b","frame":10,"value":{"x":60,"y":40},"outgoing":{"type":"linear"}},
          {"id":"c","frame":20,"value":{"x":120,"y":0},"outgoing":{"type":"linear"}}]}]}]}]}}
    """

    var engine: KeyframeRuntime!
    var editor: TimelineEditor!
    var inspector: InspectorPanel!

    override func setUpWithError() throws {
        engine = try KeyframeRuntime()
        editor = try TimelineEditor(json: Self.json, engine: engine)
        inspector = InspectorPanel(); inspector.editor = editor; inspector.selection = ["C"]; inspector.time = 0
    }

    func rows() -> [InspectorRow] { inspector.groups.flatMap(\.rows) }
    func toggleRow(_ key: String) -> InspectorRow.Toggle? {
        for r in rows() { if case .toggle(let t) = r.kind, t.key == key { return t } }
        return nil
    }
    func sliderRow(_ key: String) -> InspectorRow.Slider? {
        for r in rows() { if case .slider(let s) = r.kind, s.key == key { return s } }
        return nil
    }
    func path() -> ArcMotionPath? { editor.arcMotionPath(clipId: "C") }

    /// Preview box origin and rotation at clip frame `f`.
    func preview(_ f: Double) throws -> (x: Double, y: Double, rotation: Double) {
        let comp = PreviewComposition(document: editor.document, projectDir: URL(fileURLWithPath: "/arc"), engine: engine, fileExists: { _ in true })
        let l = try XCTUnwrap(comp.layers(at: (f + 0.25) / 10).first)
        return (l.box.x, l.box.y, l.rotation)
    }
    /// Export's sample of the same frame.
    func export(_ f: Double) throws -> (x: Double, y: Double, rotation: Double) {
        let clip = try XCTUnwrap(editor.clip("C")?.clip)
        let fr = try ExportClipSampler(clip, canvasWidth: 200, canvasHeight: 100, engine: engine).frame(at: f)
        return (fr.left, fr.top, fr.rotation)
    }
    func assertSame(_ f: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let p = try preview(f), e = try export(f)
        XCTAssertEqual(p.x, e.x, accuracy: 1e-6, "x at frame \(f)", file: file, line: line)
        XCTAssertEqual(p.y, e.y, accuracy: 1e-6, "y at frame \(f)", file: file, line: line)
        XCTAssertEqual(p.rotation, e.rotation, accuracy: 1e-6, "rotation at frame \(f)", file: file, line: line)
    }
    /// Export's frames at 0.5 s and 1.5 s: the runtime's render document through the export painter (the clip a
    /// solid picture), so a change of path or turn shows in the pixels.
    func graph() throws -> [UInt8] {
        let media = ["v": NativeMediaInfo(path: "/arc/v.mp4", video: true, audio: false, duration: 10, natural: .init(width: 200, height: 100))]
        let doc = nativeExportPreparedDocument(try parseNativeProjectDocument(editor.document, engine: engine), media: media)
        let painter = try ExportFramePainter(composition: PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/arc"), engine: engine,
                                                                            fileExists: { _ in true }), width: 200, height: 100, pad: CanvasColor(r: 0, g: 0, b: 0))
        return try [0.5, 1.5].flatMap { t in
            try painter.paint(time: t) { _, _, w, h in CanvasImage(width: w, height: h, rgba: [UInt8](repeating: 200, count: w * h * 4)) }.rgba
        }
    }

    func testArcMotionSwitchCurvesThePathInPreviewAndExport() throws {
        let toggle = try XCTUnwrap(toggleRow("arcMotion"))
        XCTAssertFalse(toggle.on)
        XCTAssertNil(toggleRow("arcAutoRotate"), "auto-rotate shows only while arc motion is on")
        let straight = try preview(5)
        XCTAssertEqual(straight.x, 30, accuracy: 1e-6); XCTAssertEqual(straight.y, 20, accuracy: 1e-6)
        let before = try graph()
        toggle.set(true)
        XCTAssertEqual(path()?.segments, [.curve(curviness: 1), .curve(curviness: 1)])
        let curved = try preview(5)
        XCTAssertGreaterThan(hypot(curved.x - 30, curved.y - 20), 1, "the clip leaves the straight line")
        try assertSame(5); try assertSame(15)
        XCTAssertNotEqual(try graph(), before, "export follows the curve")
        XCTAssertTrue(try XCTUnwrap(toggleRow("arcMotion")).on)
        try XCTUnwrap(toggleRow("arcMotion")).set(false)
        XCTAssertEqual(path()?.segments, [nil, nil])
        XCTAssertEqual(try preview(5).x, 30, accuracy: 1e-6)
    }

    func testCurvinessReshapesOneSegment() throws {
        try XCTUnwrap(toggleRow("arcMotion")).set(true)
        let one = try preview(5), other = try preview(15)
        let slider = try XCTUnwrap(sliderRow("arcCurviness0"))
        XCTAssertEqual(slider.label, "Segment 1"); XCTAssertNotNil(sliderRow("arcCurviness1"))
        slider.commit(2)
        XCTAssertEqual(path()?.segments.first, .curve(curviness: 2))
        let two = try preview(5)
        XCTAssertGreaterThan(hypot(two.x - one.x, two.y - one.y), 0.5, "segment 1 bends further")
        try assertSame(5)
        XCTAssertEqual(try preview(15).x, other.x, accuracy: 1e-6, "segment 2 is untouched")
        slider.commit(9)
        XCTAssertEqual(path()?.segments.first, .curve(curviness: 3), "clamped to the slider's 0…3")
        try XCTUnwrap(sliderRow("arcCurviness0")).reset?()
        XCTAssertEqual(path()?.segments.first, .curve(curviness: 1))
    }

    func testAutoRotateTurnsTheClipAlongThePathInPreviewAndExport() throws {
        try XCTUnwrap(toggleRow("arcMotion")).set(true)
        XCTAssertEqual(try preview(5).rotation, 0, accuracy: 1e-9)
        let before = try graph()
        try XCTUnwrap(toggleRow("arcAutoRotate")).set(true)
        XCTAssertEqual(path()?.autoRotate, true)
        let p = try preview(5)
        XCTAssertGreaterThan(abs(p.rotation), 1, "the clip turns to the path tangent")
        try assertSame(5); try assertSame(12); try assertSame(18)
        XCTAssertNotEqual(try graph(), before, "export turns the clip too")
        try XCTUnwrap(toggleRow("arcAutoRotate")).set(false)
        XCTAssertEqual(try export(5).rotation, 0, accuracy: 1e-9)
    }

    func testFewerThanTwoKeyframesShowsTheNote() throws {
        let a = #"{"id":"a","frame":0,"value":{"x":0,"y":0},"outgoing":{"type":"linear"}}"#
        let json = Self.json.replacingOccurrences(of: a + ",", with: a)
            .replacingOccurrences(of: #"{"id":"b","frame":10,"value":{"x":60,"y":40},"outgoing":{"type":"linear"}},"#, with: "")
            .replacingOccurrences(of: #"{"id":"c","frame":20,"value":{"x":120,"y":0},"outgoing":{"type":"linear"}}"#, with: "")
        let one = try TimelineEditor(json: json, engine: engine)
        XCTAssertNil(one.arcMotionPath(clipId: "C"))
        inspector.editor = one
        XCTAssertNil(toggleRow("arcMotion"))
        XCTAssertTrue(rows().contains { if case .note(let s) = $0.kind { return s.contains("2 position keyframes") }; return false })
    }
}
