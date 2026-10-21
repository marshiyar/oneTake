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
#if os(Linux)   // Cairo is the Linux canvas; these tests read real pixels.
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxTheme
@testable import MpvfxPanels

/// The look and effect tiles (Grade presets, the Effects catalog) never show an empty 16:9 frame: they show a
/// picture, a "Rendering" caption, or a placeholder that names why there is no picture. Before this change the
/// Effects catalog drew only the frame's scrim (it had no preview at all) and the Grade presets did the same while
/// the clip had no decoded picture, so the owner saw blank tiles.
final class EffectTileFrameTests: XCTestCase {
    /// Pixels inside `r` (points) that differ from the frame's corner colour by more than 24 on a channel.
    static func inkPixels(_ t: CairoImageTarget, _ r: CanvasRect, scale: Double) -> Int {
        let x0 = Int((r.x + 2) * scale), y0 = Int((r.y + 2) * scale)
        let x1 = Int((r.maxX - 2) * scale), y1 = Int((r.maxY - 2) * scale)
        let bg = t.pixel(x0, y0)
        var ink = 0
        for y in y0..<y1 { for x in x0..<x1 {
            let p = t.pixel(x, y)
            if max(abs(Int(p.r) - Int(bg.r)), abs(Int(p.g) - Int(bg.g)), abs(Int(p.b) - Int(bg.b))) > 24 { ink += 1 }
        } }
        return ink
    }

    /// The 16:9 frame of tile `rect` (1px inside the border, full width, 9/16 of it tall).
    static func frame(of tile: CanvasRect) -> CanvasRect {
        CanvasRect(x: tile.x + 1, y: tile.y + 1, width: tile.width - 2, height: (tile.width - 2) * 9 / 16)
    }

    /// Draws `r` at 2x into a fresh target on the studio background.
    static func draw(_ r: RightPanel, h: Double) -> CairoImageTarget {
        let t = CairoImageTarget(width: 409 * 2, height: Int(h * 2))
        t.canvas.scale(2, 2)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 409, height: h), PanelTheme.studioBg)
        r.draw(t.canvas, size: CanvasSize(409, h))
        return t
    }

    func assertTilesDrawSomething(_ r: RightPanel, id: String, count: Int, h: Double, _ what: String) throws {
        let t = Self.draw(r, h: h)
        for i in 0..<count {
            let tile = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom(id, i) }, "\(what) tile \(i) drawn")
            XCTAssertGreaterThan(Self.inkPixels(t, Self.frame(of: tile), scale: 2), 40, "\(what) tile \(i): the 16:9 frame is blank")
        }
    }

    /// Every Effects catalog family, dark and light: no tile's frame is the flat scrim.
    func testEffectCatalogTileFramesAreNeverBlank() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode); defer { Theme.setMode(.dark) }
            for fam in EffectSpecs.families {
                let r = try PanelSnapshotTests.rightFixture(open: "effects", h: 1400)
                r.inspector.effectsUI = EffectsUIState(clipId: "clip:a", catalogOpen: true, catalogFamily: fam.label)
                let count = fam.presets.compactMap(ColorGrading.preset).count + fam.effects.count
                try assertTilesDrawSomething(r, id: "fx:tiles", count: count, h: 1400, "\(mode) \(fam.label)")
            }
        }
    }

    /// The Grade preset grid with a clip that has no picture to grade (no host frames): no tile is blank.
    func testGradePresetTileFramesAreNeverBlankWithoutAClipPicture() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode); defer { Theme.setMode(.dark) }
            let r = try PanelSnapshotTests.rightFixture(open: "grade", h: 1400)
            try assertTilesDrawSomething(r, id: "grade:presets", count: ColorGrading.gradePresets.count, h: 1400, "\(mode) grade")
        }
    }
}
#endif
