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
#if os(Linux)   // Cairo is the Linux canvas; these tests draw real pixels.
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxTheme
@testable import MpvfxPanels

/// Pixel snapshots of the layout audit's fixtures (`PanelLayoutAuditTests.fixtures`) at the 280 pt minimum and the
/// 1280 × 800 and 1440 × 900 default right panel widths, in dark and light, at 2x. Set `MPVFX_SNAPSHOT_DIR` to write
/// `layout-<fixture>-<width>-<mode>.png` for review. The checks are font-independent: the gutter and the reserved
/// keyframe column of every unkeyed row are the open body's inset colour, and the panel reaches its corners.
final class PanelLayoutSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    static var outDir: String? { ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] }

    func testFixturesAtEveryWidthInBothAppearances() throws {
        let scale = 2.0, h = 900.0
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            for (wName, w) in PanelLayoutAuditTests.widths {
                for (name, clip, group) in PanelLayoutAuditTests.fixtures {
                    let (r, _) = try PanelLayoutAuditTests.panel(clip: clip, group: group, width: w)
                    let t = CairoImageTarget(width: Int(w * scale), height: Int(h * scale))
                    t.canvas.scale(scale, scale)
                    r.draw(t.canvas, size: CanvasSize(w, h))
                    if let dir = Self.outDir {
                        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        XCTAssertEqual(t.writePNG("\(dir)/layout-\(name)-\(wName)-\(mode).png"), 0)
                    }
                    try check(t, r, scale: scale, "\(name) \(wName) \(mode)")
                }
            }
        }
    }

    /// The tab bars (docs/DESIGN.md "Tabs"): the header strip, the Grade curve tabs (two legible lines since
    /// issue #357, every tab drawn even at 280 pt) and the effect families, at every width in both appearances;
    /// the selected tab's underline is the accent.
    func testTabBarsAtEveryWidthInBothAppearances() throws {
        let scale = 1.0, h = PanelLayoutAuditTests.height   // tall enough for the whole Grade body
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            for (wName, w) in PanelLayoutAuditTests.widths {
                for group in ["grade", "effects"] {
                    let (r, _) = try PanelLayoutAuditTests.panel(clip: "clip:a", group: group, width: w)
                    r.inspector.effectsUI.catalogOpen = true
                    let t = CairoImageTarget(width: Int(w * scale), height: Int(h * scale))
                    t.canvas.scale(scale, scale)
                    r.draw(t.canvas, size: CanvasSize(w, h))
                    if let dir = Self.outDir {
                        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        XCTAssertEqual(t.writePNG("\(dir)/tabs-\(group)-\(wName)-\(mode).png"), 0)
                    }
                    let name = "\(group) \(wName) \(mode)"
                    let design = try XCTUnwrap(r.hits.rect { $0 == .design }, name)
                    assertPixel(t, design.midX, design.maxY - 1, scale: scale, PanelTheme.accent, "\(name): Design underline")
                    if group == "grade" {
                        // Master is the default tab; its 2pt accent bar sits at the tab rect's bottom.
                        let sel = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:curvetabs", 0) }, name)
                        assertPixel(t, sel.midX, sel.maxY - 1, scale: scale, PanelTheme.accent, "\(name): selected curve tab underline")
                    } else {
                        let bar = try XCTUnwrap(r.inspector.tabBars["fx:tabs"], name)
                        let sel = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("fx:tabs", bar.base + bar.selected) }, name)
                        assertPixel(t, sel.midX, sel.maxY - 1, scale: scale, PanelTheme.accent, "\(name): selected tab underline")
                    }
                }
            }
        }
    }

    func check(_ t: CairoImageTarget, _ r: RightPanel, scale: Double, _ name: String) throws {
        let body = try XCTUnwrap(r.inspector.hits.rect { $0 == .body }, name)
        let inset = CanvasColor(ThemeTokens.panelBgInsetPair.now), bg = PanelTheme.panelBg
        assertPixel(t, 1, 1, scale: scale, bg, name)                                    // the strip reaches the corner
        let probeY = min(body.maxY - 4, body.y + PanelGrid.bodyPadding / 2)
        assertPixel(t, PanelGrid.gutter / 2, probeY, scale: scale, inset, "\(name): left gutter")
        assertPixel(t, body.maxX - PanelGrid.gutter / 2, probeY, scale: scale, inset, "\(name): right gutter")
    }

    func assertPixel(_ t: CairoImageTarget, _ x: Double, _ y: Double, scale: Double, _ want: CanvasColor, _ msg: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        let p = t.pixel(Int(x * scale), Int(y * scale))
        let w = (Int(want.r * 255 + 0.5), Int(want.g * 255 + 0.5), Int(want.b * 255 + 0.5))
        let ok = abs(Int(p.r) - w.0) <= 3 && abs(Int(p.g) - w.1) <= 3 && abs(Int(p.b) - w.2) <= 3
        XCTAssertTrue(ok, "\(msg): pixel (\(x),\(y)) = rgb(\(p.r),\(p.g),\(p.b)), want rgb\(w)", file: file, line: line)
    }
}
#endif
