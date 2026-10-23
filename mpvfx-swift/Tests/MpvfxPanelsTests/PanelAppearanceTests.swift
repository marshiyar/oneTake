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
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxTheme
import MpvfxTimeline
@testable import MpvfxPanels

/// Light/dark switching of the panel tokens and the Shortcuts card's Appearance row.
final class PanelAppearanceTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func testPanelTokensFollowTheMode() {
        XCTAssertEqual(PanelTheme.panelBg, CanvasColor(hex: "#1D1D1D")!)         // dark = docs/DESIGN.md
        XCTAssertEqual(PanelStyle.popoverBackground, CanvasColor(hex: "#252525")!)
        XCTAssertEqual(TimelineTheme.default.rowBackground, CanvasColor(hex: "#1D1D1D")!)
        Theme.setMode(.light)
        XCTAssertEqual(PanelTheme.panelBg, CanvasColor(ThemeTokens.panelBgPair.light))
        XCTAssertEqual(PanelTheme.text0, CanvasColor(ThemeTokens.textPairs[0].light))
        XCTAssertEqual(PanelStyle.popoverBackground, CanvasColor(ThemeTokens.popoverPair.light))
        XCTAssertEqual(TimelineTheme.default.rowBackground, CanvasColor(ThemeTokens.timelineRowPair.light))   // a stored theme follows too
        XCTAssertEqual(PanelTheme.seamHover.a, 0.18, accuracy: 1e-9)
        XCTAssertLessThan(PanelTheme.seamHover.r, 0.1)                             // white/18 becomes ink/18
        XCTAssertEqual(PanelTheme.onAccent, CanvasColor(r: 1, g: 1, b: 1))        // fixed in both modes
        Theme.setMode(.dark)
        XCTAssertEqual(PanelTheme.panelBg, CanvasColor(hex: "#1D1D1D")!)
    }

    /// Grade curve lines (CurveGraph's per-tab colours): dark keeps the recorded hexes exactly; light draws every
    /// tab at 3:1 or better on the light graph (bg-panel-bg-inset under the graph's black/5 wash), and the grid
    /// wash and selected-point fill are dark ink, so nothing on the graph is white on white.
    func testCurveLinesReadInLightMode() {
        let old = ["master": "#e5e7eb", "red": "#fb7185", "green": "#4ade80", "blue": "#60a5fa",
                   "hueVsHue": "#f0abfc", "hueVsSaturation": "#facc15", "hueVsLuma": "#f8fafc",
                   "lumaVsSaturation": "#67e8f9", "saturationVsSaturation": "#fdba74"]
        XCTAssertEqual(InspectorPanel.curveTabs.map(\.key), ["master", "red", "green", "blue", "hueVsHue", "hueVsSaturation", "hueVsLuma",
                                                             "lumaVsSaturation", "saturationVsSaturation"])
        let inset = ThemeTokens.panelBgInsetPair.light, ink = ThemeTokens.stageScrim
        let graph = ThemeColor(r: inset.r * 0.95 + ink.r * 0.05, g: inset.g * 0.95 + ink.g * 0.05, b: inset.b * 0.95 + ink.b * 0.05)
        for t in InspectorPanel.curveTabs {
            XCTAssertEqual(CanvasColor(t.color.dark), CanvasColor(hex: old[t.key]!)!, "\(t.key) dark unchanged")
            XCTAssertGreaterThanOrEqual(t.color.light.contrast(graph), 3, "\(t.key) light line on the graph")
            XCTAssertGreaterThanOrEqual(t.color.light.contrast(ThemeTokens.panelBgPair.light), 3, "\(t.key) light line on panel-bg")
        }
        Theme.setMode(.light)
        XCTAssertGreaterThanOrEqual(ThemeColor(r: PanelTheme.white.r, g: PanelTheme.white.g, b: PanelTheme.white.b).contrast(graph), 3)   // selected point, grid ink
        XCTAssertGreaterThan(ThemeTokens.curvePointOutlinePair.light.contrast(ThemeTokens.whitePair.light), 3)   // outline vs selected fill
        Theme.setMode(.dark)
        XCTAssertEqual(PanelTheme.white, CanvasColor(r: 1, g: 1, b: 1))
    }

    func testShortcutsAppearanceRow() {
        let p = ShortcutsPanel()
        p.isOpen = true
        var picked: [ThemeAppearance] = []
        p.appearance = .system
        p.onAppearance = { picked.append($0) }
        let c = MeasureOnlyCanvas()
        let trigger = CanvasRect(x: 400, y: 900, width: 28, height: 28)
        let card = p.cardRect(c, trigger: trigger)
        // Row: 12 top + 13.5 title + 6 gap, 24 tall, three equal segments across width - 24.
        let y = card.y + 12 + 13.5 + 6 + 12, seg = (ShortcutsPanel.width - 24) / 3
        XCTAssertEqual(p.hitTest(c, CanvasPoint(card.x + 12 + seg * 1.5, y), trigger: trigger), .appearance(.light))
        p.pointerDown(c, CanvasPoint(card.x + 12 + seg * 2.5, y), trigger: trigger)
        XCTAssertEqual(picked, [.dark]); XCTAssertEqual(p.appearance, .dark)
        p.pointerDown(c, CanvasPoint(card.x + 12 + seg * 2.5, y), trigger: trigger)   // same choice: no callback
        XCTAssertEqual(picked, [.dark])
        p.appearance = nil                                                          // hidden when the host has no setting
        XCTAssertNotEqual(p.hitTest(c, CanvasPoint(card.x + 12 + seg * 1.5, y), trigger: trigger), .appearance(.light))
    }
}

/// Measures text roughly so layout runs without a real canvas.
private final class MeasureOnlyCanvas: CanvasContext {
    var deviceScale: Double { 1 }
    func save() {}; func restore() {}
    func translate(_ dx: Double, _ dy: Double) {}; func scale(_ sx: Double, _ sy: Double) {}; func rotate(_ radians: Double) {}
    func clip(_ path: CanvasPath) {}
    func fill(_ path: CanvasPath, _ color: CanvasColor) {}
    func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {}
    func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {}
    func measureText(_ text: String, font: CanvasFont) -> CanvasSize { CanvasSize(Double(text.count) * font.size * 0.55, font.size) }
    func drawImage(_ image: CanvasImage, in rect: CanvasRect) {}
}
