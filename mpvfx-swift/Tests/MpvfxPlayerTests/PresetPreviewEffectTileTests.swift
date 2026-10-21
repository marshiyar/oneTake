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

/// Effects catalog tiles on the clip (issue #170): the clip's own frame graded with its grade plus the tile's effect,
/// through the same renderer, queue and budget as the Grade preset tiles. Shares the pattern-video clip of
/// `PresetPreviewRendererTests` (clip:a at 2 s, so its frames come from the renderer's own decode).
extension PresetPreviewRendererTests {
    /// Asks until the tile settles, waiting on the decode and render queues (not on time).
    func effectTile(_ r: PresetPreviewRenderer, _ demo: InspectorPanel.TileDemo, w: Int = 120, h: Int = 68) throws -> CanvasImage {
        for _ in 0..<20 {
            let req = EffectPreviewRequest(key: demo.key, grade: demo.grade, clipId: "clip:a", pixelWidth: w, pixelHeight: h)
            if case .ready(let img) = r.effectPreview(req, time: 0) {
                return img
            }
            r.wait()
        }
        XCTFail("\(demo.key) never became ready")
        throw XCTSkip("not ready")
    }

    /// A1: the blur tile equals `ColorGradeRenderer` applied to the same frame ("neutral" is inactive, so its tile is
    /// the clip's frame as decoded and downscaled), on the CPU reference renderer.
    func testEffectTileEqualsTheGradeRendererOnTheClipFrame() throws {
        let r = PresetPreviewRenderer(compositor: compositor)
        r.colorRenderer = CPUColorRenderer()
        let demo = InspectorPanel.effectDemo(try XCTUnwrap(EffectSpecs.spec("blur")), clipId: "clip:a")
        _ = try effectTile(r, demo)   // decodes the exact frame, so both tiles below grade the same one
        r.reset()
        let tile = try effectTile(r, demo)
        let frame = try ready(r, "neutral")
        var reference = frame.rgba
        let grade = try XCTUnwrap(ColorGradeRenderer.forClip(ColorGradeParams(json: demo.grade), clipId: "clip:a", projectDir: nil))
        grade.apply(&reference, width: frame.width, height: frame.height, time: 2)
        XCTAssertEqual([tile.width, tile.height], [frame.width, frame.height])
        XCTAssertEqual(tile.rgba, reference, "the tile is the clip frame with the blur, exactly")
        XCTAssertNotEqual(tile.rgba, frame.rgba)
    }

    /// The tile carries the clip's own grade: a different base grade gives a different tile for the same effect.
    func testEffectTileFollowsTheClipsGrade() throws {
        let r = PresetPreviewRenderer(compositor: compositor)
        let spec = try XCTUnwrap(EffectSpecs.spec("pixelate"))
        var warm = ColorGrading(); warm.adjust["temperature"] = 0.8
        let plain = try effectTile(r, InspectorPanel.effectDemo(spec, clipId: "clip:a"))
        let graded = try effectTile(r, InspectorPanel.effectDemo(spec, base: warm, clipId: "clip:a"))
        XCTAssertNotEqual(plain.rgba, graded.rgba)
    }

    /// A3: 18 effect tiles render off the caller's thread and the cache stays within its byte budget.
    func testEighteenEffectTilesStayWithinBudget() throws {
        let tileBytes = 120 * 68 * 4
        let r = PresetPreviewRenderer(compositor: compositor, budgetBytes: tileBytes * 4 + 100)
        let specs = Array(EffectSpecs.all.prefix(18))
        XCTAssertEqual(specs.count, 18, "the catalog has at least 18 effects")
        let tiles = try specs.map { try effectTile(r, InspectorPanel.effectDemo($0, clipId: "clip:a")) }
        XCTAssertEqual(tiles.count, 18)
        XCTAssertLessThanOrEqual(r.bytes, r.budgetBytes)
        XCTAssertLessThanOrEqual(r.count, 4)
    }

    /// Whether the blur tile for `clip` answers `.unavailable` (no picture: the host shows the sample picture).
    func blurTileIsUnavailable(_ clip: String?) throws -> Bool {
        let r = PresetPreviewRenderer(compositor: compositor)
        let demo = InspectorPanel.effectDemo(try XCTUnwrap(EffectSpecs.spec("blur")))
        let req = EffectPreviewRequest(key: demo.key, grade: demo.grade, clipId: clip, pixelWidth: 120, pixelHeight: 68)
        guard case .unavailable = r.effectPreview(req, time: 0) else { return false }
        return true
    }

    /// A clip that is not in the composition, or a request naming no clip, has no picture.
    func testEffectTileWithoutAClipIsUnavailable() throws {
        XCTAssertTrue(try blurTileIsUnavailable("clip:missing"), "a missing clip")
        XCTAssertTrue(try blurTileIsUnavailable(nil), "a request naming no clip")
    }
}
