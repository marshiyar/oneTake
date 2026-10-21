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
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import MpvfxPanels

/// Program scopes (issue #80): the Grade scopes in Program mode read the composited program frame at the playhead,
/// painted by the export painter from the frames the preview decoded, at 320 px, off the main thread.
final class ProgramScopeRendererTests: XCTestCase {
    struct ProgramFrameMissing: Error {}

    var dir: URL!
    override func setUpWithError() throws { dir = try TestMedia.scratch("program-scopes") }
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    /// A lossless 640×360 MOV of a smooth two-axis ramp (red across, green down, blue constant), `frames` long.
    func writeRamp(_ name: String, frames: Int = 12) throws -> String {
        let w = 640, h = 360
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            px[i] = UInt8(x * 255 / (w - 1)); px[i + 1] = UInt8(y * 255 / (h - 1)); px[i + 2] = 96
        } }
        let path = dir.appendingPathComponent(name).path
        let writer = try TestMedia.movWriter(path: path, width: w, height: h, fps: 30)
        for _ in 0..<frames { try writer.addVideo(px) }
        try writer.finish()
        return path
    }

    /// Two stacked clips on a 640×360 canvas at 30 fps: A (the ramp) under B (a solid at half opacity), each with its
    /// own grade, edited through the inspector's command (`TimelineEditor.setColorGrading`).
    func stackedDocument() throws -> NativeProjectDocument {
        _ = try writeRamp("ramp.mov")
        _ = try TestMedia.SolidVideo(width: 64, height: 36, fps: 30, segments: [([40, 160, 220], 0.4)])
            .write(to: dir.appendingPathComponent("solid.mov").path)
        let editor = try TimelineEditor(json: #"""
        {"schemaVersion":1,"id":"project:p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":640,"height":360,"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"video","name":"ramp.mov","source":"ramp.mov","durationFrames":12},
                   {"id":"asset:b","kind":"video","name":"solid.mov","source":"solid.mov","durationFrames":12}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"track:v2","kind":"video","lane":{"authoredTrack":2,"displayTrack":0},"clips":[
           {"id":"clip:b","assetId":"asset:b","startFrame":0,"durationFrames":12,"sourceInFrame":0,"muted":false,
            "staticParameters":{"visual.opacity":0.5},"effects":[],"parameterTracks":[]}]},
          {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":1},"clips":[
           {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":12,"sourceInFrame":0,"muted":false,
            "effects":[],"parameterTracks":[]}]}]}}
        """#)
        var a = ColorGrading(); a.adjust["exposure"] = 0.4; a.adjust["contrast"] = 0.3
        var b = ColorGrading(); b.adjust["saturation"] = -0.6; b.adjust["temperature"] = 0.5
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", a))
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:b", b))
        return editor.document
    }

    /// A compositor whose cache holds the exact frame of every layer at `time`, decoded at the stage's 640×360.
    func decodedCompositor(_ doc: NativeProjectDocument, time: Double) throws -> PreviewCompositor {
        let cx = PreviewCompositor()
        let comp = PreviewComposition(document: doc, projectDir: dir, engine: nil)
        cx.composition = comp
        let layers = comp.layers(at: time)
        XCTAssertEqual(layers.map(\.clipId), ["clip:a", "clip:b"], "A at the bottom, B over it")
        for layer in layers {
            XCTAssertNotNil(cx.decodeRawNow(layer, time: time, fps: comp.fps, size: PreviewDecodeSize(width: 640, height: 360)))
        }
        return cx
    }

    /// The newest program frame: one request, the queue drained, then the painted frame.
    func programFrame(_ r: ProgramScopeRenderer, at time: Double) throws -> CanvasImage {
        _ = r.frame(at: time)
        r.wait()
        guard case .ready(let image) = r.frame(at: time) else {
            XCTFail("the drained request is ready"); throw ProgramFrameMissing()
        }
        return image
    }

    // MARK: Acceptance

    /// Two stacked clips with different grades: the program scopes equal the scopes of the exported frame at that
    /// time (export at the canvas size, downscaled to the same 320 px), within 1 level per bin: along every scope's
    /// level axis the cumulative counts of one lie between those of the other shifted one level down and up.
    func testTwoStackedGradedClipsGiveTheScopesOfTheExportedFrame() throws {
        let doc = try stackedDocument()
        try [0.0, 0.2, 11.0 / 30].forEach { try assertProgramScopesMatchExport(doc, time: $0) }
    }

    /// The program frame's scopes against the scopes of the exported frame at `time` (see the test above).
    func assertProgramScopesMatchExport(_ doc: NativeProjectDocument, time: Double) throws {
        let cx = try decodedCompositor(doc, time: time)
        defer { cx.stopAll() }
        let program = try programFrame(ProgramScopeRenderer(compositor: cx), at: time)
        XCTAssertEqual([program.width, program.height], [320, 180])

        let export = try PreviewExportFrames(NativeExportFrameRequest(document: doc, projectDir: dir.path, width: 640, height: 360))
        let exported = CanvasImage(width: 640, height: 360, rgba: try export.frame(at: time))
        let reference = PresetPreviewRenderer.downscale(exported, fitting: 320, 320)
        let p = ColorScopes.analyze(program), e = ColorScopes.analyze(reference)
        assertWithinOneLevel(p.histogram, e.histogram, columns: 1, "histogram at \(time)")
        assertWithinOneLevel(p.waveform, e.waveform, columns: p.width, "waveform at \(time)")
        assertWithinOneLevel(p.parade, e.parade, columns: p.width * 3, "parade at \(time)")
        assertWithinOneLevel(Self.rows(p.vectorscope), Self.rows(e.vectorscope), columns: 1, "vectorscope Cr at \(time)")
        assertWithinOneLevel(Self.columns(p.vectorscope), Self.columns(e.vectorscope), columns: 1, "vectorscope Cb at \(time)")
        XCTAssertNotEqual(p.histogram, ColorScopes.analyze(try clipOnly(cx, time: time)).histogram,
                          "the program is not one clip's frame")
    }

    /// In Program mode the frame is the whole canvas downscaled to 320 px on its long side (portrait too), never upscaled.
    func testTheProgramFrameIsTheCanvasAt320PixelsOnItsLongSide() {
        XCTAssertEqual(ProgramScopeRenderer.outputSize(CanvasSize(1920, 1080), fitting: 320, 320).width, 320)
        XCTAssertEqual(ProgramScopeRenderer.outputSize(CanvasSize(1920, 1080), fitting: 320, 320).height, 180)
        XCTAssertEqual(ProgramScopeRenderer.outputSize(CanvasSize(1080, 1920), fitting: 320, 320).width, 180)
        XCTAssertEqual(ProgramScopeRenderer.outputSize(CanvasSize(1080, 1920), fitting: 320, 320).height, 320)
        XCTAssertEqual(ProgramScopeRenderer.outputSize(CanvasSize(200, 100), fitting: 320, 320).width, 200, "never upscaled")
    }

    /// A request never blocks the caller: it returns `.rendering` while the paint is held, and of several requests
    /// made before the queue runs only the newest is painted.
    func testOnlyTheNewestRequestIsPaintedOffTheCallersThread() throws {
        let doc = try stackedDocument()
        let cx = try decodedCompositor(doc, time: 0.2)
        defer { cx.stopAll() }
        let r = ProgramScopeRenderer(compositor: cx)
        var onMain: [Bool] = []
        let ready = expectation(description: "painted"); ready.assertForOverFulfill = false
        r.onReady = { onMain.append(Thread.isMainThread); ready.fulfill() }
        r.queue.suspend()
        let answers = [0.0, 0.1, 0.2].map { r.frame(at: $0) }
        r.queue.resume()
        XCTAssertEqual(answers.map(Self.isRendering), [true, true, true], "a request never waits for its paint")
        wait(for: [ready], timeout: 10)
        r.wait()
        XCTAssertEqual(r.painted, 1, "the two older requests were replaced before they ran")
        XCTAssertEqual(onMain, [false], "painted on the background queue")
        guard case .ready = r.frame(at: 0.2) else { return XCTFail("the newest request is the painted one") }
        guard case .rendering = r.frame(at: 0.0) else { return XCTFail("an older time is a new request") }
    }

    func testNoCompositionIsUnavailable() {
        guard case .unavailable = ProgramScopeRenderer(compositor: PreviewCompositor()).frame(at: 0) else { return XCTFail() }
    }

    // MARK: Helpers

    /// Clip A's frame alone, graded, at the program's size (what Clip mode would analyse).
    func clipOnly(_ cx: PreviewCompositor, time: Double) throws -> CanvasImage {
        let comp = try XCTUnwrap(cx.composition)
        let layer = try XCTUnwrap(comp.layers(at: time).first)
        let raw = try XCTUnwrap(cx.cache.frame(lane: layer.laneKey, frame: comp.frameIndex(at: time)))
        let graded = cx.graded(layer, raw, frame: comp.frameIndex(at: time), time: time, fps: comp.fps)
        return PresetPreviewRenderer.downscale(graded, fitting: 320, 320)
    }

    static func isRendering(_ state: ProgramScopeRenderer.State) -> Bool {
        guard case .rendering = state else { return false }
        return true
    }

    /// Vectorscope marginals: counts per Cr row and per Cb column (256 levels each).
    static func rows(_ v: [UInt32]) -> [UInt32] { (0..<256).map { y in (0..<256).reduce(0) { $0 &+ v[y * 256 + $1] } } }
    static func columns(_ v: [UInt32]) -> [UInt32] { (0..<256).map { x in (0..<256).reduce(0) { $0 &+ v[$1 * 256 + x] } } }

    /// `columns` runs of 256 levels each: within each run, the cumulative count of `a` at every level lies between
    /// the cumulative counts of `b` one level below and one level above (every sample moved by at most one level).
    func assertWithinOneLevel(_ a: [UInt32], _ b: [UInt32], columns: Int, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, what, file: file, line: line)
        guard a.count == b.count, a.count == columns * 256 else { return XCTFail("\(what): \(a.count) bins", file: file, line: line) }
        var worst: (column: Int, level: Int)?
        for col in 0..<columns where worst == nil {
            var ca = [UInt64](repeating: 0, count: 256), cb = ca, sa: UInt64 = 0, sb: UInt64 = 0
            for i in 0..<256 { sa += UInt64(a[col * 256 + i]); sb += UInt64(b[col * 256 + i]); ca[i] = sa; cb[i] = sb }
            for i in 0..<256 where ca[i] < cb[max(0, i - 1)] || ca[i] > cb[min(255, i + 1)] || sa != sb {
                worst = (col, i); break
            }
        }
        XCTAssertNil(worst.map { "\(what): column \($0.column) differs by more than one level at level \($0.level)" }, file: file, line: line)
    }
}
