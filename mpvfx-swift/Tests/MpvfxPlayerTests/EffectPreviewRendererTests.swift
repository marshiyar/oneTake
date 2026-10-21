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
import MpvfxColor
import MpvfxShared
@testable import MpvfxPanels

/// Effects catalog and look tile demos: the built-in sample picture graded with each tile's grade, off the UI thread,
/// through the production colour renderer, with typed failures for what cannot render.
final class EffectPreviewRendererTests: XCTestCase {
    static let w = 248, h = 140   // a 2x catalog tile

    /// Asks like the panel's redraws do, waiting on the render queue (not on time) until the tile settles.
    func settled(_ r: EffectPreviewRenderer, _ req: EffectPreviewRequest) -> PresetPreviewState {
        var state = r.preview(req)
        for _ in 0..<3 {
            guard case .rendering = state else { break }
            r.wait()
            state = r.preview(req)
        }
        return state
    }

    func image(_ state: PresetPreviewState, file: StaticString = #filePath, line: UInt = #line) throws -> CanvasImage {
        guard case .ready(let img) = state else { XCTFail("not ready: \(state)", file: file, line: line); throw XCTSkip("not ready") }
        return img
    }

    func request(_ demo: InspectorPanel.TileDemo, w: Int = w, h: Int = h) -> EffectPreviewRequest {
        EffectPreviewRequest(key: demo.key, grade: demo.grade, pixelWidth: w, pixelHeight: h)
    }

    /// The tile the production renderer (GPU where there is one) draws equals the CPU reference grade of the same
    /// sample picture, within the Metal/Vulkan parity tolerance (`GradeDiff`, MpvfxColorTests).
    func testBlurTileEqualsTheCPUReference() throws {
        let spec = try XCTUnwrap(EffectSpecs.spec("blur"))
        let demo = InspectorPanel.effectDemo(spec)
        let renderer = EffectPreviewRenderer()
        let tile = try image(settled(renderer, request(demo)))
        var reference = EffectSampleImage.make(width: Self.w, height: Self.h).rgba
        let grade = try XCTUnwrap(ColorGradeRenderer.forClip(ColorGradeParams(json: demo.grade), clipId: "", projectDir: nil))
        grade.apply(&reference, width: Self.w, height: Self.h, time: 0)
        XCTAssertEqual([tile.width, tile.height], [Self.w, Self.h])
        var over1 = 0, sum = 0
        for (a, b) in zip(tile.rgba, reference) { let d = abs(Int(a) - Int(b)); sum += d; if d > 1 { over1 += 1 } }
        XCTAssertLessThanOrEqual(over1, tile.rgba.count / 1000, "\(renderer.colorRenderer.backend) vs CPU: \(over1) channels off by > 1")
        XCTAssertLessThan(Double(sum) / Double(tile.rgba.count), 0.02, "\(renderer.colorRenderer.backend) vs CPU mean difference")
        XCTAssertNotEqual(tile.rgba, EffectSampleImage.make(width: Self.w, height: Self.h).rgba, "the blur changed the sample")
    }

    /// Every catalog effect and look, at the values it is added with, changes the sample picture; "Neutral" alone
    /// leaves it as drawn.
    func testEveryCatalogTileShowsItsEffectOnTheSample() throws {
        let renderer = EffectPreviewRenderer(budgetBytes: 64 << 20)
        renderer.colorRenderer = CPUColorRenderer()
        let sample = EffectSampleImage.make(width: 124, height: 70).rgba
        let looks = EffectSpecs.families.flatMap(\.presets).compactMap(ColorGrading.preset).map { InspectorPanel.lookDemo($0) }
        let effects = EffectSpecs.all.map { InspectorPanel.effectDemo($0) }
        for demo in effects + looks {
            let tile = try image(settled(renderer, request(demo, w: 124, h: 70)))
            XCTAssertNotEqual(tile.rgba, sample, "\(demo.key) leaves the sample unchanged")
        }
        let neutral = try XCTUnwrap(ColorGrading.preset("neutral"))
        XCTAssertEqual(try image(settled(renderer, request(InspectorPanel.lookDemo(neutral), w: 124, h: 70))).rgba, sample)
    }

    /// The sample picture is not flat: every tenth of it holds several colours, so any effect shows.
    func testTheSamplePictureHasDetailEverywhere() {
        let img = EffectSampleImage.make(width: 320, height: 180)
        for band in 0..<10 {
            var colours = Set<[UInt8]>()
            for y in (band * 18)..<(band * 18 + 18) { for x in stride(from: 0, to: 320, by: 4) {
                let i = (y * 320 + x) * 4
                colours.insert(Array(img.rgba[i..<(i + 3)]))
            } }
            XCTAssertGreaterThan(colours.count, 4, "band \(band) is nearly flat")
        }
        XCTAssertEqual(EffectSampleImage.make(width: 0, height: 9).rgba, [], "no pixels for an empty size")
    }

    /// Hostile sizes fail with a typed reason at once; nothing is queued or cached for them.
    func testRefusedSizesFailTyped() throws {
        let renderer = EffectPreviewRenderer()
        let demo = InspectorPanel.effectDemo(try XCTUnwrap(EffectSpecs.spec("pixelate")))
        for (w, h) in [(0, 70), (-5, 70), (1, 1), (124, Int.min), (EffectPreviewRenderer.maxSide + 1, 70), (Int.max, Int.max)] {
            guard case .failed(let why) = renderer.preview(request(demo, w: w, h: h)) else { XCTFail("\(w)x\(h) was accepted"); continue }
            XCTAssertEqual(why, .invalidSize(width: w, height: h))
            XCTAssertFalse(why.reason.isEmpty)
        }
        renderer.wait()
        XCTAssertEqual(renderer.count, 0)
        XCTAssertEqual(renderer.rendered, 0)
    }

    /// Every redraw rebuilds the tile's grade: the same grade built again is the same cached tile, so the tile
    /// settles instead of rendering on every draw (the grade's backing dictionary orders keys differently each time).
    func testTheSameGradeBuiltAgainIsACacheHit() throws {
        let renderer = EffectPreviewRenderer()
        renderer.colorRenderer = CPUColorRenderer()
        var base = ColorGrading(); base.adjust["contrast"] = 0.2; base.adjust["saturation"] = -0.3; base.effects["chromaBleed"] = 0.2
        let spec = try XCTUnwrap(EffectSpecs.spec("bloom"))
        _ = try image(settled(renderer, request(InspectorPanel.effectDemo(spec, base: base))))
        for _ in 0..<20 {
            guard case .ready = renderer.preview(request(InspectorPanel.effectDemo(spec, base: base))) else { return XCTFail("a rebuilt grade missed the cache") }
        }
        XCTAssertEqual(renderer.rendered, 1)
        XCTAssertEqual(EffectPreviewRenderer.gradeText(["a": .number(1), "b": .array([.bool(true), .null, .string("x")])]),
                       #"{a:1.0,b:[true,null,"x"]}"#)
    }

    /// A tile renders once; asking again is a cache hit. The cache stays within its budget; reset empties it.
    func testTilesRenderOnceAndStayWithinBudget() throws {
        let renderer = EffectPreviewRenderer(budgetBytes: 3 * 124 * 70 * 4)
        renderer.colorRenderer = CPUColorRenderer()
        var ready = 0
        renderer.onReady = { ready += 1 }
        let demos = EffectSpecs.all.prefix(5).map { InspectorPanel.effectDemo($0) }
        for d in demos { _ = try image(settled(renderer, request(d, w: 124, h: 70))) }
        renderer.wait()
        XCTAssertEqual(renderer.rendered, 5); XCTAssertEqual(ready, 5, "every finished tile asks for a redraw")
        XCTAssertLessThanOrEqual(renderer.bytes, renderer.budgetBytes)
        _ = try image(settled(renderer, request(demos[4], w: 124, h: 70)))
        XCTAssertEqual(renderer.rendered, 5, "the newest tile is still cached")
        renderer.reset()
        XCTAssertEqual(renderer.count, 0); XCTAssertEqual(renderer.bytes, 0)
    }
}
