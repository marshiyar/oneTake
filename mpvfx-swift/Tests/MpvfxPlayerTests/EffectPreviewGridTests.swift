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
import XCTest
import MpvfxPlayer
import MpvfxCanvas
import MpvfxTheme
import MpvfxTimeline
@testable import MpvfxPanels

/// The Effects catalog and the Grade presets wired to the production `EffectPreviewRenderer`, as the desktop session
/// wires them: after the queued renders finish and the panel redraws (what `onReady` makes the host do), every tile's
/// 16:9 frame shows the graded sample picture (not the scrim, not a placeholder), in dark and light.
final class EffectPreviewGridTests: XCTestCase {
    static var outDir: String? { ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] }

    func fixture(open group: String, renderer: EffectPreviewRenderer) throws -> RightPanel {
        let r = RightPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        r.inspector.editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        r.inspector.selection = ["clip:a"]
        if r.inspector.openGroupId != group { r.inspector.toggleGroup(group) }
        r.inspector.effectPreview = { renderer.preview($0) }
        return r
    }

    /// Draws at 2x, lets the renderer finish, and draws again; returns the settled frame.
    func drawSettled(_ r: RightPanel, _ renderer: EffectPreviewRenderer, h: Double) -> CairoImageTarget {
        for _ in 0..<3 { _ = draw(r, h: h); renderer.wait() }
        return draw(r, h: h)
    }

    func draw(_ r: RightPanel, h: Double) -> CairoImageTarget {
        let t = CairoImageTarget(width: 409 * 2, height: Int(h * 2))
        t.canvas.scale(2, 2)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 409, height: h), PanelTheme.studioBg)
        r.draw(t.canvas, size: CanvasSize(409, h))
        return t
    }

    /// Standard deviation of luma (0…255) over the tile's 16:9 frame, inside its border: 0 for the empty scrim, a few
    /// units for a text placeholder, tens for a picture (screens on black included).
    func lumaSpread(_ t: CairoImageTarget, _ tile: CanvasRect) -> Double {
        let f = CanvasRect(x: tile.x + 3, y: tile.y + 3, width: tile.width - 6, height: (tile.width - 2) * 9 / 16 - 4)
        var sum = 0.0, sq = 0.0, n = 0.0
        for y in Int(f.y * 2)..<Int(f.maxY * 2) { for x in Int(f.x * 2)..<Int(f.maxX * 2) {
            let p = t.pixel(x, y)
            let l = 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)
            sum += l; sq += l * l; n += 1
        } }
        let mean = sum / max(1, n)
        return (max(0, sq / max(1, n) - mean * mean)).squareRoot()
    }

    func assertPictures(_ r: RightPanel, _ t: CairoImageTarget, id: String, count: Int, _ what: String) throws {
        for i in 0..<count {
            let tile = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom(id, i) }, "\(what) tile \(i)")
            XCTAssertGreaterThan(lumaSpread(t, tile), 25, "\(what) tile \(i) does not show the sample picture")
        }
    }

    func write(_ t: CairoImageTarget, _ name: String) {
        guard let dir = Self.outDir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertEqual(t.writePNG("\(dir)/\(name)-2x.png"), 0)
    }

    func testEffectCatalogTilesShowTheGradedSample() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode); defer { Theme.setMode(.dark) }
            let renderer = EffectPreviewRenderer(budgetBytes: 32 << 20)
            for fam in EffectSpecs.families {
                let r = try fixture(open: "effects", renderer: renderer)
                r.inspector.effectsUI = EffectsUIState(clipId: "clip:a", catalogOpen: true, catalogFamily: fam.label)
                let t = drawSettled(r, renderer, h: 1400)
                write(t, "effects-catalog-\(fam.label.lowercased().filter(\.isLetter))-\(mode)")
                let count = fam.presets.compactMap(ColorGrading.preset).count + fam.effects.count
                try assertPictures(r, t, id: "fx:tiles", count: count, "\(mode) \(fam.label)")
            }
        }
    }

    /// The measure tells a placeholder from a picture: without a renderer the tiles show "No preview" and their spread
    /// stays far under the threshold the pictures pass.
    func testThePlaceholderIsNotMistakenForAPicture() throws {
        let r = try fixture(open: "effects", renderer: EffectPreviewRenderer())
        r.inspector.effectPreview = nil
        let t = draw(r, h: 1400)
        let tile = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("fx:tiles", 0) })
        XCTAssertLessThan(lumaSpread(t, tile), 16, "measured 12.2 for the placeholder; every picture tile measures over 25")
    }

    /// The demo clip has no picture, so the preset tiles fall back to the sample picture with each look.
    func testGradePresetTilesShowTheSampleWhenTheClipHasNoPicture() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode); defer { Theme.setMode(.dark) }
            let renderer = EffectPreviewRenderer(budgetBytes: 32 << 20)
            let r = try fixture(open: "grade", renderer: renderer)
            r.inspector.presetPreview = { _ in .unavailable }
            let t = drawSettled(r, renderer, h: 1400)
            write(t, "grade-presets-sample-\(mode)")
            try assertPictures(r, t, id: "grade:presets", count: ColorGrading.gradePresets.count, "\(mode) grade")
        }
    }
}
#endif
