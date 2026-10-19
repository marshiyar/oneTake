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
import MpvfxColor
#if canImport(MpvfxMetal)
import MpvfxMetal
#endif

/// A slider drag: 100 grade changes in quick succession on a 1080p frame already decoded. Every change is drawn the
/// way the app draws it (edit, rebuild the composition, draw), and the display keeps redrawing between changes as
/// it does when graded frames arrive. Checks: draws never wait for a grade; the latency from each change to the first
/// draw that shows it (or a later value) has a p95 under the CI threshold; after the last change the preview settles
/// on exactly the last value; the frame cache is never flushed or re-decoded.
final class PreviewRapidGradeTests: XCTestCase {
    func testHundredRapidGradeChanges() throws {
        let (editor, cx, rect) = try PreviewEditLatencyTests.makeFixture(sourceWidth: 1920, sourceHeight: 1080)
        defer { cx.stopAll() }
        let canvas = PreviewEditLatencyTests.LastImageCanvas()
        var drawTimes: [Double] = []
        func draw() {
            let t0 = DispatchTime.now().uptimeNanoseconds
            cx.draw(canvas, in: rect, time: 0.5, elements: [], context: FrameDrawContext(backingScale: 1, isPlaying: false, speed: 1))
            drawTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        // Signature of each change's grade -> change index.
        var generation: [String: Int] = [:]
        var changedAt: [UInt64] = []
        var shownAt = [UInt64?](repeating: nil, count: 100)
        var newest = -1
        func observe() {
            guard let s = cx.lastShown.first, let sig = s.grade, let g = generation[sig], g > newest else { return }
            let t = now()
            for k in (newest + 1)...g where shownAt[k] == nil { shownAt[k] = t }
            newest = g
        }
        for i in 0..<100 {
            var g = editor.colorGrading(clipId: "clip:a") ?? ColorGrading()
            g.adjust["exposure"] = -1 + Double(i) * 0.02
            g.adjust["contrast"] = 0.2
            XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
            changedAt.append(now())
            cx.composition = PreviewComposition(document: editor.document, projectDir: nil, engine: nil, fileExists: { _ in true })
            generation[try XCTUnwrap(cx.composition?.entries.first?.grade).signature] = i
            draw(); observe()
            // About a 240 Hz pointer: keep redrawing for 4 ms before the next change.
            let until = now() + 4_000_000
            while now() < until { usleep(250); draw(); observe() }
        }
        // The CPU port in a debug build can take seconds per 1080p grade; give it room to settle.
        let cpu = cx.colorRenderer.backend == "cpu"
        let deadline = now() + UInt64(cpu ? 300 : 30) * 1_000_000_000
        while (newest < 99 || cx.lastShown.first?.gradeCurrent != true) && now() < deadline { usleep(250); draw(); observe() }
        XCTAssertEqual(newest, 99, "the last change reached the preview")

        // No stale frame: what is on screen is exactly the last value, marked current.
        draw()
        let last = try XCTUnwrap(cx.lastShown.first)
        let finalGrade = try XCTUnwrap(cx.composition?.entries.first?.grade)
        XCTAssertEqual(last.grade, finalGrade.signature)
        XCTAssertTrue(last.gradeCurrent)
        let raw = try XCTUnwrap(cx.cache.frame(lane: try XCTUnwrap(cx.composition?.layers(at: 0.5).first).laneKey, frame: 15))
        let expected = cx.grader.gradeNow(raw, grade: finalGrade, time: 15.0 / 30)
        XCTAssertEqual(canvas.image?.rgba, expected.rgba, "the drawn picture is the last value's grade")
        XCTAssertEqual(cx.cache.count, 1, "the decoded frame stays cached; edits never flush or re-decode")

        let latencies = (0..<100).compactMap { i in shownAt[i].map { Double($0 - changedAt[i]) / 1e6 } }.sorted()
        XCTAssertEqual(latencies.count, 100)
        let p50 = latencies[49], p95 = latencies[94]
        let draws = drawTimes.sorted()
        let drawP95 = draws[min(draws.count - 1, Int(Double(draws.count) * 0.95))]
        var extra = ""
        #if canImport(MpvfxMetal)
        if let m = cx.colorRenderer as? MetalColorRenderer { extra = ", GPU uploads skipped \(m.pipeline.uploadsSkipped)" }
        #endif
        print(String(format: "Rapid grade changes (100, 1080p, %@): latency p50 %.2f ms, p95 %.2f ms, max %.2f ms; draw p95 %.3f ms over %d draws; graded %d (CPU drafts %d), coalesced away %d%@",
                     cx.colorRenderer.backend, p50, p95, latencies.last!, drawP95, draws.count, cx.grader.finished, cx.grader.drafts, cx.grader.dropped, extra))
        // Generous CI threshold on Metal (the target on Apple silicon is one 60 Hz frame). The CPU port's speed depends
        // on the build and the machine, so its latency is only reported unless MPVFX_PREVIEW_P95_MS sets a bound.
        let threshold = ProcessInfo.processInfo.environment["MPVFX_PREVIEW_P95_MS"].flatMap(Double.init) ?? (cpu ? nil : 100)
        if let threshold { XCTAssertLessThan(p95, threshold, "p95 preview update latency") }
        XCTAssertLessThan(drawP95, cpu ? 100 : 16, "draws never wait for a grade")
    }
}
