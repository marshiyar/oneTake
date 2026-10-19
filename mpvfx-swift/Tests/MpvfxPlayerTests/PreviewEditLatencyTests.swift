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
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import MpvfxPanels

/// Interactive latency of the preview: how long from an inspector edit (the editor command a slider calls) to a
/// preview draw that shows it, with a 1080p frame already decoded. Each edit is measured the way the app sees it:
/// edit the document, rebuild the preview composition from it, then draw until the drawn picture is the edited one
/// (draws are retried every 0.2 ms, as the app redraws when a frame is ready). The numbers are printed for the
/// lane's before/after report; the asserts only check that every edit lands.
final class PreviewEditLatencyTests: XCTestCase {
    final class LastImageCanvas: CanvasContext {
        var image: CanvasImage?, rect: CanvasRect?, opacity = 1.0, clipPath: String = ""
        func save() {}
        func restore() {}
        func translate(_ dx: Double, _ dy: Double) {}
        func scale(_ sx: Double, _ sy: Double) {}
        func rotate(_ radians: Double) {}
        func clip(_ path: CanvasPath) { clipPath += "\(path)" }
        func fill(_ path: CanvasPath, _ color: CanvasColor) {}
        func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {}
        func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {}
        func measureText(_ text: String, font: CanvasFont) -> CanvasSize { CanvasSize(Double(text.count) * 6, font.size) }
        func drawImage(_ image: CanvasImage, in rect: CanvasRect) { drawImage(image, in: rect, opacity: 1) }
        func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double) { self.image = image; self.rect = rect; self.opacity = opacity }
    }

    /// A 1920x1080 canvas with one video clip; its frame 15 is already in the preview cache (no decoder).
    static func makeFixture(sourceWidth: Int, sourceHeight: Int) throws -> (TimelineEditor, PreviewCompositor, CanvasRect) {
        let editor = try TimelineEditor(json: #"""
        {"schemaVersion":1,"id":"project:l","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"video","name":"m.mkv","source":"/tmp/mpvfx-latency-media.mkv","durationFrames":30}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
           {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#)
        let cx = PreviewCompositor(decodesMedia: false, cacheBudgetBytes: 1 << 30)
        cx.composition = PreviewComposition(document: editor.document, projectDir: nil, engine: nil, fileExists: { _ in true })
        let layer = try XCTUnwrap(cx.composition?.layers(at: 0.5).first)
        var px = [UInt8](repeating: 255, count: sourceWidth * sourceHeight * 4)
        for y in 0..<sourceHeight { for x in 0..<sourceWidth {
            let i = (y * sourceWidth + x) * 4
            px[i] = UInt8(x * 255 / sourceWidth); px[i + 1] = UInt8(y * 255 / sourceHeight); px[i + 2] = UInt8((x + y) % 256)
        } }
        cx.cache.store(CanvasImage(width: sourceWidth, height: sourceHeight, rgba: px), lane: layer.laneKey, frame: 15)
        return (editor, cx, CanvasRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    /// A cheap fingerprint of a drawn picture (64 sampled pixels, its size, placement and crop).
    static func fingerprint(_ c: LastImageCanvas) -> [UInt8] {
        guard let img = c.image else { return [] }
        var out: [UInt8] = [UInt8(img.width & 255), UInt8(img.height & 255)] + Array(c.clipPath.utf8)
        if let r = c.rect { out += Array(String(format: "%.3f,%.3f", r.x, r.y).utf8) }
        for k in 0..<64 {
            let x = (k * 37 + 11) % img.width, y = (k * 53 + 7) % img.height
            let i = (y * img.width + x) * 4
            out += img.rgba[i..<i + 3]
        }
        return out
    }

    struct Stats: CustomStringConvertible {
        var ms: [Double]
        func pct(_ p: Double) -> Double { let s = ms.sorted(); return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        var description: String { String(format: "p50 %.2f ms, p95 %.2f ms, max %.2f ms (n=%d)", pct(0.5), pct(0.95), ms.max() ?? 0, ms.count) }
    }

    /// Runs `edits` edits; `done(canvas)` says whether the latest draw shows edit `i`.
    func measure(_ name: String, edits: Int = 20, source: (Int, Int) = (1920, 1080),
                 edit: (TimelineEditor, Int) -> Void, shows: (LastImageCanvas, Int, [UInt8]) -> Bool) throws -> Stats {
        let (editor, cx, rect) = try Self.makeFixture(sourceWidth: source.0, sourceHeight: source.1)
        defer { cx.stopAll() }
        let canvas = LastImageCanvas()
        func draw() { canvas.clipPath = ""; cx.draw(canvas, in: rect, time: 0.5, elements: [], context: FrameDrawContext(backingScale: 1, isPlaying: false, speed: 1)) }
        var times: [Double] = []
        for i in -2..<edits {        // two warm-up edits
            draw()
            let before = Self.fingerprint(canvas)
            let t0 = DispatchTime.now().uptimeNanoseconds
            edit(editor, i)
            cx.composition = PreviewComposition(document: editor.document, projectDir: nil, engine: nil, fileExists: { _ in true })
            var ok = false
            while DispatchTime.now().uptimeNanoseconds - t0 < 10_000_000_000 {
                draw()
                if shows(canvas, i, before) { ok = true; break }
                usleep(200)
            }
            XCTAssertTrue(ok, "\(name): edit \(i) never reached the preview")
            if i >= 0 { times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
        }
        let s = Stats(ms: times)
        print("Preview edit latency, \(name): \(s)")
        return s
    }

    func gradeEdit(_ change: @escaping (inout ColorGrading, Int) -> Void) -> (TimelineEditor, Int) -> Void {
        { editor, i in
            var g = editor.colorGrading(clipId: "clip:a") ?? ColorGrading()
            change(&g, i)
            XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        }
    }
    /// A graded edit shows when the drawn picture changes (each edit alternates between two clearly different looks).
    let pictureChanged: (LastImageCanvas, Int, [UInt8]) -> Bool = { c, _, before in fingerprint(c) != before }

    func testEditToPreviewLatency() throws {
        // A benchmark for the GPU path: on the CPU port (Linux) a debug build grades 1080p in seconds, so the sweep only
        // runs there when asked for.
        if PreviewCompositor(decodesMedia: false).colorRenderer.backend == "cpu", ProcessInfo.processInfo.environment["MPVFX_PREVIEW_BENCH"] != "1" {
            throw XCTSkip("CPU port: set MPVFX_PREVIEW_BENCH=1 to run the preview latency sweep")
        }
        var report: [String] = []
        func run(_ name: String, source: (Int, Int) = (1920, 1080), _ edit: @escaping (TimelineEditor, Int) -> Void,
                 _ shows: @escaping (LastImageCanvas, Int, [UInt8]) -> Bool) throws {
            report.append("\(name): \(try measure(name, source: source, edit: edit, shows: shows))")
        }
        try run("grade exposure", gradeEdit { g, i in g.adjust["exposure"] = i % 2 == 0 ? 0.4 : -0.4 }, pictureChanged)
        try run("grade temperature", gradeEdit { g, i in g.adjust["temperature"] = i % 2 == 0 ? 0.6 : -0.6 }, pictureChanged)
        try run("grade saturation", gradeEdit { g, i in g.adjust["saturation"] = i % 2 == 0 ? 0.7 : -0.7 }, pictureChanged)
        try run("effect kuwahara", gradeEdit { g, i in g.effects["kuwahara"] = i % 2 == 0 ? 1 : 0.4 }, pictureChanged)
        try run("effect crosshatch", gradeEdit { g, i in g.effects["crosshatch"] = i % 2 == 0 ? 1 : 0.3 }, pictureChanged)
        try run("grade exposure, 4K source", source: (3840, 2160), gradeEdit { g, i in g.adjust["exposure"] = i % 2 == 0 ? 0.4 : -0.4 }, pictureChanged)
        // Position is a vec2: an x edit carries y too (an x alone is not a position command).
        try run("position x", { e, i in XCTAssertTrue(e.applyTransform(clipId: "clip:a", time: 0.5, ClipTransform(x: Double(10 + i), y: 0))) },
                pictureChanged)
        try run("opacity", { e, i in _ = e.setParameter(clipId: "clip:a", "visual.opacity", .number(i % 2 == 0 ? 0.5 : 0.8), time: 0.5) },
                { c, i, _ in abs(c.opacity - (i % 2 == 0 ? 0.5 : 0.8)) < 1e-6 })
        try run("crop", { e, i in _ = e.setCrop(clipId: "clip:a", NativeClipCrop(top: i % 2 == 0 ? 20 : 60, right: 0, bottom: 0, left: 0)) },
                pictureChanged)
        // Graded clip + transform edit: the grade must not be redone for a move.
        try run("position x on a kuwahara clip", { e, i in
            if i == -2 { var g = ColorGrading(); g.effects["kuwahara"] = 1; _ = e.setColorGrading(clipId: "clip:a", g) }
            XCTAssertTrue(e.applyTransform(clipId: "clip:a", time: 0.5, ClipTransform(x: Double(10 + i), y: 0)))
        }, pictureChanged)
        print("Preview edit latency (1080p canvas):\n  " + report.joined(separator: "\n  "))
    }
}
