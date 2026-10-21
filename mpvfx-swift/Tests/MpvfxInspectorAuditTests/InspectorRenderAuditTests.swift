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
import MpvfxAudio
import MpvfxAudioGraph
@testable import MpvfxPlayer
@testable import MpvfxRuntime

/// End-to-end audit of the inspector controls that are not color grading / stylize (those are the color engine's):
/// each test drives the real inspector row (the same closure a click or typed value runs), then checks what the
/// preview composites for the frame (PreviewCompositor drawing into a recording canvas), what the live audio graph
/// is built from (DocumentAudioGraph.inputs), and what export renders (the runtime's render document painted by the
/// export frame painter, and the mix inputs export builds), and asserts the edit really changed it.
/// Records drawing calls (what reached the preview canvas).
final class AuditCanvas: CanvasContext {
    enum Op: Equatable {
        case save, restore, translate(Double, Double), scale(Double, Double), rotate(Double), clip(CanvasPath)
        case fill(CanvasColor), stroke(CanvasColor, width: Double), image(rect: CanvasRect, opacity: Double)
    }
    var ops: [Op] = []
    func save() { ops.append(.save) }
    func restore() { ops.append(.restore) }
    func translate(_ dx: Double, _ dy: Double) { ops.append(.translate(dx, dy)) }
    func scale(_ sx: Double, _ sy: Double) { ops.append(.scale(sx, sy)) }
    func rotate(_ radians: Double) { ops.append(.rotate(radians)) }
    func clip(_ path: CanvasPath) { ops.append(.clip(path)) }
    func fill(_ path: CanvasPath, _ color: CanvasColor) { ops.append(.fill(color)) }
    func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) { ops.append(.stroke(color, width: style.width)) }
    func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {}
    func measureText(_ text: String, font: CanvasFont) -> CanvasSize { CanvasSize(Double(text.count) * 6, font.size) }
    func drawImage(_ image: CanvasImage, in rect: CanvasRect) { drawImage(image, in: rect, opacity: 1) }
    func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double) { ops.append(.image(rect: rect, opacity: opacity)) }
    var images: [(rect: CanvasRect, opacity: Double)] {
        ops.compactMap { if case let .image(r, o) = $0 { return (r, o) }; return nil }
    }
}

final class InspectorRenderAuditTests: XCTestCase {
    /// Canvas 200×100 at 10 fps; video clip V (frames 0–30 of v.mp4) and audio clip M (frames 0–30 of m.wav).
    static let json = """
    {"schemaVersion":1,"id":"project:audit","revision":1,"frameRate":{"numerator":10,"denominator":1},
     "canvas":{"width":200,"height":100,"background":"#000000"},
     "assets":[{"id":"v","kind":"video","name":"v.mp4","source":"v.mp4","durationFrames":100},
               {"id":"m","kind":"audio","name":"m.wav","source":"m.wav","durationFrames":100}],
     "sequence":{"id":"s","name":"Main","tracks":[
      {"id":"tv","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"V","assetId":"v","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
      {"id":"ta","kind":"audio","lane":{"authoredTrack":2,"displayTrack":1},"clips":[
       {"id":"M","assetId":"m","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """

    var engine: KeyframeRuntime!
    var editor: TimelineEditor!
    var inspector: InspectorPanel!
    let projectDir = "/audit"

    override func setUpWithError() throws {
        engine = try KeyframeRuntime()
        editor = try TimelineEditor(json: Self.json, engine: engine)
        inspector = InspectorPanel()
        inspector.editor = editor
        select("V")
    }

    func select(_ id: String, time: Double = 0) { inspector.selection = [id]; inspector.time = time }

    // MARK: Driving rows

    enum Found { case number(InspectorRow.Number), slider(InspectorRow.Slider), toggle(InspectorRow.Toggle),
                      segmented(InspectorRow.Segmented), button(InspectorRow.Button) }

    func find(_ key: String, file: StaticString = #filePath, line: UInt = #line) -> Found? {
        for g in inspector.groups { for r in g.addressableRows {
            switch r.kind {
            case .number(let n) where n.key == key: return .number(n)
            case .pair(_, let a, let b): if a.key == key { return .number(a) }; if b.key == key { return .number(b) }
            case .quad(let ns): if let n = ns.first(where: { $0.key == key }) { return .number(n) }
            case .slider(let s) where s.key == key: return .slider(s)
            case .toggle(let t) where t.key == key: return .toggle(t)
            case .segmented(let s) where s.key == key: return .segmented(s)
            case .buttons(let bs): if let b = bs.first(where: { $0.key == key }) { return .button(b) }
            case .subheader(_, let bs): if let b = bs.first(where: { $0.key == key }) { return .button(b) }
            default: break
            }
        } }
        XCTFail("no inspector row \(key)", file: file, line: line)
        return nil
    }

    func type(_ key: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .number(let n)? = find(key, file: file, line: line) else { return XCTFail("\(key) is not a number field", file: file, line: line) }
        n.commit(text)
    }
    func slide(_ key: String, _ position: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard case .slider(let s)? = find(key, file: file, line: line) else { return XCTFail("\(key) is not a slider", file: file, line: line) }
        s.commit(position)
    }
    func toggle(_ key: String, _ on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard case .toggle(let t)? = find(key, file: file, line: line) else { return XCTFail("\(key) is not a toggle", file: file, line: line) }
        t.set(on)
    }
    func press(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .button(let b)? = find(key, file: file, line: line) else { return XCTFail("\(key) is not a button", file: file, line: line) }
        b.action()
    }
    func pick(_ key: String, _ option: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .segmented(let s)? = find(key, file: file, line: line) else { return XCTFail("\(key) is not segmented", file: file, line: line) }
        s.select(option)
    }

    // MARK: What preview, live audio and export see

    /// Composites one preview frame at `time` exactly as the player does (PreviewCompositor.draw with the clip's
    /// decoded frame cached) into a 400×200 view, and returns the drawing operations.
    func previewFrame(at time: Double = 0.5) -> AuditCanvas {
        let comp = PreviewComposition(document: editor.document, projectDir: URL(fileURLWithPath: projectDir), engine: engine, fileExists: { _ in true })
        let cx = PreviewCompositor(decodesMedia: false)
        cx.composition = comp
        for l in comp.layers(at: time) {
            cx.cache.store(CanvasImage(width: 20, height: 10, rgba: [UInt8](repeating: 200, count: 20 * 10 * 4)), lane: l.laneKey, frame: comp.frameIndex(at: time))
        }
        let c = AuditCanvas()
        cx.draw(c, in: CanvasRect(x: 0, y: 0, width: 400, height: 200), time: time, elements: [], context: FrameDrawContext())
        return c
    }

    func audioInputs() -> DocumentAudioGraph.Inputs {
        DocumentAudioGraph.inputs(editor.document, duration: editor.duration, projectDir: URL(fileURLWithPath: projectDir), fileExists: { _ in true })
    }
    func audioTrack(_ id: String) -> DocumentAudioGraph.Inputs.Track? { audioInputs().tracks.first { $0.id == id } }

    /// What export renders for the document: its frame at `time` (the runtime's render document, painted by the
    /// export painter at the canvas size, on a mid-grey canvas so dark shadows show, every layer a 200-grey 2:1
    /// picture contained in its decode size with clear bars, as the decoder returns it) and the inputs of its mix.
    struct ExportRender: Equatable {
        var frame: [UInt8]
        var audio: DocumentAudioGraph.Inputs?
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * 200 + x) * 4; return Array(frame[i..<i + 4]) }
    }
    var exportMedia: [String: NativeMediaInfo] {
        ["v": NativeMediaInfo(path: "\(projectDir)/v.mp4", video: true, audio: true, duration: 10, natural: .init(width: 200, height: 100)),
         "m": NativeMediaInfo(path: "\(projectDir)/m.wav", video: false, audio: true, duration: 10)]
    }
    static func containedPicture(_ w: Int, _ h: Int) -> CanvasImage {
        let r = PreviewPainter.containRect(imageWidth: 200, imageHeight: 100, in: CanvasRect(x: 0, y: 0, width: Double(w), height: Double(h)))
        let px = (0..<(w * h)).flatMap { i -> [UInt8] in
            let x = Double(i % w) + 0.5, y = Double(i / w) + 0.5
            return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height ? [200, 200, 200, 255] : [0, 0, 0, 0]
        }
        return CanvasImage(width: w, height: h, rgba: px)
    }
    func exportRender(at time: Double = 0.5, file: StaticString = #filePath, line: UInt = #line) -> ExportRender {
        do {
            let checked = try parseNativeProjectDocument(editor.document, engine: engine)
            try assertNativeTimelineSupported(checked)
            var doc = nativeExportPreparedDocument(checked, media: exportMedia)
            doc.canvas.background = "#808080"
            let comp = PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: projectDir), engine: engine, fileExists: { _ in true })
            let painter = try ExportFramePainter(composition: comp, width: 200, height: 100, pad: CanvasColor(r: 0, g: 0, b: 0))
            let frame = try painter.paint(time: time) { _, _, w, h in Self.containedPicture(w, h) }
            let all = DocumentAudioGraph.inputs(doc, duration: sequenceEndFrame(doc) / 10, projectDir: URL(fileURLWithPath: projectDir), fileExists: { _ in true })
            return ExportRender(frame: frame.rgba, audio: exportAudioInputs(all, doc, media: exportMedia))
        } catch { XCTFail("export refused the edited document: \(error)", file: file, line: line); return ExportRender(frame: [], audio: nil) }
    }

    /// Asserts the edit changed the composited preview frame and the export frame.
    func assertVisualEdit(_ name: String, at time: Double = 0.5, file: StaticString = #filePath, line: UInt = #line,
                          _ edit: () -> Void, check: (AuditCanvas) -> Void = { _ in }) {
        let before = previewFrame(at: time).ops, exportBefore = exportRender(at: time, file: file, line: line)
        edit()
        let after = previewFrame(at: time)
        XCTAssertNotEqual(after.ops, before, "\(name): the preview frame did not change", file: file, line: line)
        XCTAssertNotEqual(exportRender(at: time, file: file, line: line).frame, exportBefore.frame, "\(name): the export frame did not change", file: file, line: line)
        check(after)
    }

    // MARK: Transform

    func testPositionX() {
        assertVisualEdit("Position X", { type("x", "50") }) { c in XCTAssertEqual(c.images.first?.rect.x, 100, "x 50 canvas px = 100 view px") }
    }

    func testPositionY() {
        assertVisualEdit("Position Y", { type("y", "-25") }) { c in XCTAssertEqual(c.images.first?.rect.y, -50) }
    }

    func testWidth() {
        assertVisualEdit("Width", { type("w", "100") }) { c in XCTAssertEqual(c.images.first?.rect.width, 200, "box 100 wide -> 200 view px") }
    }

    func testHeight() {
        assertVisualEdit("Height", { type("h", "50") }) { c in XCTAssertEqual(c.images.first?.rect.height, 100) }
    }

    func testRotation() {
        assertVisualEdit("Rotation", { type("rotation", "30") }) { c in
            XCTAssertTrue(c.ops.contains(.rotate(30 * .pi / 180)), "rotated about the box centre")
        }
    }

    func testScale() {
        assertVisualEdit("Scale", { type("scale", "50") }) { c in XCTAssertTrue(c.ops.contains(.scale(0.5, 0.5))) }
    }

    func testPositionKeyframeAndEasing() {
        // Key x=0 at 0 s, x=100 at 2 s; Hold keeps the first value until the second key.
        guard case .number(let x)? = find("x"), let kf = x.keyframe else { return XCTFail("position has no keyframe button") }
        kf.toggle()
        select("V", time: 2)
        type("x", "100")
        select("V", time: 0)
        let linear = previewFrame(at: 1).images.first?.rect.x
        XCTAssertEqual(linear ?? 0, 100, accuracy: 1, "halfway: x 50 canvas px")
        assertVisualEdit("Keyframe easing", at: 1, { pick("easing", "hold") }) { c in
            XCTAssertEqual(c.images.first?.rect.x ?? -1, 0, accuracy: 0.5, "hold keeps x 0 until the next key")
        }
    }

    // MARK: Style

    func testOpacity() {
        assertVisualEdit("Opacity", { slide("opacity", 50) }) { c in XCTAssertEqual(c.images.first?.opacity ?? 0, 0.5, accuracy: 1e-9) }
        XCTAssertEqual(Int(exportRender().pixel(100, 50)[0]), 164, accuracy: 1, "export draws the clip at half opacity over the canvas")
    }

    // MARK: Crop

    func testCrop() {
        press("crop:start")
        pick("crop:links", "sides")
        assertVisualEdit("Crop left", { type("crop:left", "20") }) { c in
            XCTAssertTrue(c.ops.contains { if case .clip = $0 { return true }; return false }, "the cropped box clips the picture")
        }
        XCTAssertEqual(exportRender().pixel(10, 50), [128, 128, 128, 255], "export shows the canvas where the left edge is cropped away")
    }

    // MARK: Clip timing (on the timeline)
    // The inspector has no timing group (removed on purpose): moving, trimming and splitting are timeline gestures.
    // These drive the real TimelineController pointer gestures and check preview, live audio and export follow.

    /// A timeline over the audit document at 100 px/s; row 0 is the video track.
    func timeline() -> TimelineController {
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: editor)
        c.viewport = CanvasSize(1266, 300); c.setZoom(pixelsPerSecond: 100)
        return c
    }
    func tx(_ t: Double) -> Double { 264 + 100 * t }
    var videoRowY: Double { TimelineLayout.rowTop(0) + 20 }
    func drag(_ c: TimelineController, from x0: Double, to x1: Double) {
        c.pointerDown(x: x0, y: videoRowY); c.pointerMove(x: x0 + (x1 - x0) / 2, y: videoRowY)
        c.pointerMove(x: x1, y: videoRowY); c.pointerUp(x: x1, y: videoRowY)
    }

    func testTimelineMoveMovesTheClip() {
        let c = timeline()
        assertVisualEdit("Move", at: 0.5, { drag(c, from: tx(1.5), to: tx(2.5)) }) { c in XCTAssertTrue(c.images.isEmpty, "nothing at 0.5 s once the clip starts at 1 s") }
        XCTAssertEqual(editor.clip("V")?.clip.startFrame, 10)
        XCTAssertEqual(audioTrack("V")?.start ?? 0, 1, accuracy: 1e-9, "its sound moves too")
    }

    func testTimelineTrimEndShortensTheClip() {
        let c = timeline()
        assertVisualEdit("Trim end", at: 2.5, { drag(c, from: tx(3) - 3, to: tx(2)) }) { c in XCTAssertTrue(c.images.isEmpty) }
        XCTAssertEqual(editor.clip("V")?.clip.durationFrames, 20)
        XCTAssertEqual(audioTrack("V")?.end ?? 0, 2, accuracy: 1e-9)
    }

    func testTimelineTrimStartMovesTheInPoint() {
        let c = timeline()
        assertVisualEdit("Trim start", at: 0.5, { drag(c, from: tx(0) + 3, to: tx(1)) }) { c in XCTAssertTrue(c.images.isEmpty) }
        XCTAssertEqual(editor.clip("V")?.clip.startFrame, 10)
        XCTAssertEqual(editor.clip("V")?.clip.sourceInFrame, 10, "the in point follows the trimmed start")
    }

    func testTimelineRazorSplitsTheClip() {
        let c = timeline()
        let export0 = exportRender(at: 2)
        c.tool = .razor
        c.pointerMove(x: tx(1.5), y: videoRowY); c.pointerDown(x: tx(1.5), y: videoRowY); c.pointerUp(x: tx(1.5), y: videoRowY)
        let clips = editor.document.sequence.tracks.first { $0.id == "tv" }?.clips ?? []
        XCTAssertEqual(clips.map(\.startFrame).sorted(), [0, 15])
        XCTAssertEqual(PreviewComposition(document: editor.document, projectDir: nil, engine: engine, fileExists: { _ in true }).layers(at: 2).count, 1,
                       "the right half still plays")
        XCTAssertEqual(exportRender(at: 2).frame, export0.frame, "the right half still exports")
        XCTAssertNotEqual(exportRender(at: 2).audio, export0.audio, "export mixes two segments")
    }

    // MARK: Media: rate, volume, mute

    func testRate() {
        let comp0 = PreviewComposition(document: editor.document, projectDir: nil, engine: engine, fileExists: { _ in true })
        let src0 = comp0.layers(at: 1)[0].sourceTime(at: 1)
        let export0 = exportRender()
        slide("rate", 200)
        let comp = PreviewComposition(document: editor.document, projectDir: nil, engine: engine, fileExists: { _ in true })
        guard let l = comp.layers(at: 1).first else { return XCTFail("clip gone after the rate change") }
        XCTAssertEqual(l.rate, 2, "preview plays the source twice as fast")
        XCTAssertNotEqual(l.sourceTime(at: 1), src0)
        XCTAssertEqual(audioTrack("V")?.stem.rate, 2, "live audio follows the rate")
        XCTAssertEqual(exportRender().audio?.tracks.first { $0.id == "V" }?.stem.rate, 2, "export retimes the clip's sound")
        XCTAssertNotEqual(exportRender(), export0)
    }

    func testVolume() {
        let export0 = exportRender()
        slide("volume", AudioGainFader.position(gain: 0.5))
        XCTAssertEqual(audioTrack("V")?.volume ?? 1, 0.5, accuracy: 1e-3, "live mix gain")
        XCTAssertNotEqual(exportRender().audio, export0.audio, "export mix gain")
        XCTAssertEqual(exportRender().audio?.tracks.first { $0.id == "V" }?.volume ?? 1, 0.5, accuracy: 1e-3)
    }

    func testVideoSoundToggle() {
        let export0 = exportRender()
        toggle("muted", false)   // "Play video sound" off
        XCTAssertEqual(audioTrack("V")?.muted, true, "live mix drops it")
        XCTAssertNotEqual(exportRender().audio, export0.audio, "export leaves its audio out")
        XCTAssertEqual(exportRender().audio?.tracks.first { $0.id == "V" }?.muted, true)
    }

    func testAudioClipMute() {
        select("M")
        let export0 = exportRender()
        toggle("muted", true)
        XCTAssertEqual(audioTrack("M")?.muted, true)
        XCTAssertNotEqual(exportRender().audio, export0.audio)
    }

    // MARK: Audio FX

    func testAudioFxPresetAndEq() throws {
        select("M")
        guard let preset = AudioFxPresets.families.lazy.flatMap({ AudioFxPresets.byFamily($0) }).first else { return XCTFail("no presets") }
        press("preset:\(preset.id)")
        XCTAssertNotNil(audioTrack("M")?.fxChain, "the live graph gets the chain")
        XCTAssertTrue(exportNeedsAudioGraph(editor.document), "export mixes through the FX graph")
        let chain = audioTrack("M")?.fxChain
        press("eq:add")
        XCTAssertNotEqual(audioTrack("M")?.fxChain, chain, "EQ joins the chain")
        guard let band = inspector.groups.flatMap(\.addressableRows).compactMap({ r -> String? in
            if case .slider(let s) = r.kind, s.key.hasPrefix("eq:") { return s.key }; return nil }).first else { return XCTFail("no EQ band") }
        let withEq = audioTrack("M")?.fxChain
        slide(band, 6)
        XCTAssertNotEqual(audioTrack("M")?.fxChain, withEq, "band gain reaches the chain")
    }
}
