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
/// A tile that did not settle to a picture: the test fails with what it showed instead.
struct TileNotReady: Error, CustomStringConvertible {
    let detail: String
    var description: String { "the tile never became ready: \(detail)" }
}

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
        guard case .ready(let img) = state else { throw TileNotReady(detail: "\(state)") }
        return img
    }

    func request(_ demo: InspectorPanel.TileDemo, w: Int = w, h: Int = h) -> EffectPreviewRequest {
        EffectPreviewRequest(key: demo.key, grade: demo.grade, pixelWidth: w, pixelHeight: h)
    }

    /// Channels of `a` that differ from `b` by more than 1, and the mean absolute difference.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> (over1: Int, mean: Double) {
        let d = zip(a, b).map { abs(Int($0) - Int($1)) }
        return (d.filter { $0 > 1 }.count, Double(d.reduce(0, +)) / Double(max(1, d.count)))
    }

    /// Keys of the demos whose 124x70 tile equals the plain sample picture (their effect does not show).
    func unchangedTiles(_ renderer: EffectPreviewRenderer, _ demos: [InspectorPanel.TileDemo]) throws -> [String] {
        let sample = EffectSampleImage.make(width: 124, height: 70).rgba
        return try demos.filter { try image(settled(renderer, request($0, w: 124, h: 70))).rgba == sample }.map(\.key)
    }

    /// Horizontal tenths of `img` holding at most 4 distinct colours (sampled every 4th pixel).
    static func flatBands(_ img: CanvasImage) -> [Int] {
        let bandH = img.height / 10
        return (0..<10).filter { band in
            var colours = Set<[UInt8]>()
            for y in (band * bandH)..<((band + 1) * bandH) { for x in stride(from: 0, to: img.width, by: 4) {
                let i = (y * img.width + x) * 4
                colours.insert(Array(img.rgba[i..<(i + 3)]))
            } }
            return colours.count <= 4
        }
    }

    /// The sizes the renderer did not refuse with `.invalidSize` of that size and a reason.
    func acceptedSizes(_ renderer: EffectPreviewRenderer, _ demo: InspectorPanel.TileDemo, _ sizes: [(Int, Int)]) -> [String] {
        sizes.filter { w, h in
            guard case .failed(let why) = renderer.preview(request(demo, w: w, h: h)) else { return true }
            return why != .invalidSize(width: w, height: h) || why.reason.isEmpty
        }.map { "\($0.0)x\($0.1)" }
    }

    /// Renders every demo at 124x70 until ready.
    func renderAll(_ renderer: EffectPreviewRenderer, _ demos: [InspectorPanel.TileDemo]) throws {
        for d in demos { _ = try image(settled(renderer, request(d, w: 124, h: 70))) }
    }

    /// The tile the production renderer (GPU where there is one) draws equals the CPU reference grade of the same
    /// sample picture, within the Metal/Vulkan parity tolerance for deterministic effects (`GradeDiff`, MpvfxColorTests).
    func testBlurTileEqualsTheCPUReference() throws {
        let demo = InspectorPanel.effectDemo(try XCTUnwrap(EffectSpecs.spec("blur")))
        let renderer = EffectPreviewRenderer()
        let tile = try image(settled(renderer, request(demo)))
        var reference = EffectSampleImage.make(width: Self.w, height: Self.h).rgba
        let grade = try XCTUnwrap(ColorGradeRenderer.forClip(ColorGradeParams(json: demo.grade), clipId: "", projectDir: nil))
        grade.apply(&reference, width: Self.w, height: Self.h, time: 0)
        XCTAssertEqual([tile.width, tile.height], [Self.w, Self.h])
        let diff = Self.difference(tile.rgba, reference)
        XCTAssertLessThanOrEqual(diff.over1, tile.rgba.count / 1000, "\(renderer.colorRenderer.backend) vs CPU: \(diff.over1) channels off by > 1")
        XCTAssertLessThan(diff.mean, 0.02, "\(renderer.colorRenderer.backend) vs CPU mean difference")
        XCTAssertNotEqual(tile.rgba, EffectSampleImage.make(width: Self.w, height: Self.h).rgba, "the blur changed the sample")
    }

    /// Every catalog effect and look, at the values it is added with, changes the sample picture.
    func testEveryCatalogTileShowsItsEffectOnTheSample() throws {
        let renderer = EffectPreviewRenderer(budgetBytes: 64 << 20)
        renderer.colorRenderer = CPUColorRenderer()
        let looks = EffectSpecs.families.flatMap(\.presets).compactMap(ColorGrading.preset).map { InspectorPanel.lookDemo($0) }
        XCTAssertEqual(try unchangedTiles(renderer, EffectSpecs.all.map { InspectorPanel.effectDemo($0) } + looks), [])
    }

    /// "Neutral" alone leaves the sample picture as drawn.
    func testTheNeutralLookLeavesTheSampleAsDrawn() throws {
        let renderer = EffectPreviewRenderer()
        let neutral = InspectorPanel.lookDemo(try XCTUnwrap(ColorGrading.preset("neutral")))
        XCTAssertEqual(try unchangedTiles(renderer, [neutral]), [neutral.key])
    }

    /// The sample picture is not flat: every tenth of it holds several colours, so any effect shows.
    func testTheSamplePictureHasDetailEverywhere() {
        XCTAssertEqual(Self.flatBands(EffectSampleImage.make(width: 320, height: 180)), [])
        XCTAssertEqual(EffectSampleImage.make(width: 0, height: 9).rgba, [], "no pixels for an empty size")
    }

    /// Hostile sizes fail with a typed reason at once; nothing is queued or cached for them.
    func testRefusedSizesFailTyped() throws {
        let renderer = EffectPreviewRenderer()
        let demo = InspectorPanel.effectDemo(try XCTUnwrap(EffectSpecs.spec("pixelate")))
        let sizes = [(0, 70), (-5, 70), (1, 1), (124, Int.min), (EffectPreviewRenderer.maxSide + 1, 70), (Int.max, Int.max)]
        XCTAssertEqual(acceptedSizes(renderer, demo, sizes), [])
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
        let rebuilt = (0..<20).map { _ in InspectorPanel.effectDemo(spec, base: base) }
        try renderAll(renderer, rebuilt)
        XCTAssertEqual(renderer.rendered, 1, "20 rebuilt copies of one grade render once")
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
        try renderAll(renderer, demos)
        renderer.wait()
        XCTAssertEqual(renderer.rendered, 5); XCTAssertEqual(ready, 5, "every finished tile asks for a redraw")
        XCTAssertLessThanOrEqual(renderer.bytes, renderer.budgetBytes)
        try renderAll(renderer, [demos[4]])
        XCTAssertEqual(renderer.rendered, 5, "the newest tile is still cached")
        renderer.reset()
        XCTAssertEqual(renderer.count, 0); XCTAssertEqual(renderer.bytes, 0)
    }
}
