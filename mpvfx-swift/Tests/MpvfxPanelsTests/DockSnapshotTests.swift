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

/// The dock at the target window sizes (1440 × 900 and 1280 × 800, less the 23 pt status line) in dark and light:
/// the default layout, each drop overlay, a closed panel and a narrow window. Pixels asserted are font independent
/// (tab underline, seams, overlay tint, fills). `MPVFX_SNAPSHOT_DIR` also writes `dock-<state>-<mode>-<w>x<h>.png`.
final class DockSnapshotTests: XCTestCase {
    let registry = DockRegistry.editor
    override func tearDown() { Theme.setMode(.dark) }

    static let sizes: [(Double, Double)] = [(1440, 900), (1280, 800)]
    static let modes: [(String, ThemeMode)] = [("dark", .dark), ("light", .light)]

    /// Stand-in content: the preview's black stage, the panel's title elsewhere.
    static func paint(_ id: DockPanelID, _ c: CanvasContext, _ size: CanvasSize) {
        let r = CanvasRect(x: 0, y: 0, width: size.width, height: size.height)
        if id == DockPanels.preview { c.fillRect(r.insetBy(12), PanelTheme.neutral950); return }
        PanelDraw.text(c, id, in: CanvasRect(x: 12, y: 8, width: max(0, size.width - 24), height: 20), font: PanelTheme.font(11),
                       color: PanelTheme.text3)
    }

    func render(_ name: String, _ v: DockView, w: Double, h: Double, mode: String) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(w), height: Int(h))
        let dockH = h - ShellStatusLine.height - PanelTheme.seamWidth
        v.draw(t.canvas, in: CanvasRect(x: 0, y: 0, width: w, height: dockH), content: Self.paint)
        t.canvas.fillRect(CanvasRect(x: 0, y: dockH, width: w, height: h - dockH), PanelTheme.studioBg)
        ShellStatusLine.draw(t.canvas, CanvasRect(x: 0, y: dockH + 1, width: w, height: ShellStatusLine.height), hint: v.hint)
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            XCTAssertNoThrow(try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true))
            XCTAssertEqual(t.writePNG("\(dir)/dock-\(name)-\(mode)-\(Int(w))x\(Int(h)).png"), 0)
        }
        return t
    }

    func assertPixel(_ t: CairoImageTarget, _ p: CanvasPoint, _ want: CanvasColor, tol: Int = 6, _ what: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        let px = t.pixel(Int(p.x), Int(p.y))
        let w = [want.r, want.g, want.b].map { Int(($0 * 255).rounded()) }
        let ok = abs(Int(px.r) - w[0]) <= tol && abs(Int(px.g) - w[1]) <= tol && abs(Int(px.b) - w[2]) <= tol
        XCTAssertTrue(ok, "\(what) at \(p): rgb(\(px.r),\(px.g),\(px.b)), want \(w)", file: file, line: line)
    }

    static func blend(_ base: CanvasColor, _ top: CanvasColor, _ a: Double) -> CanvasColor {
        CanvasColor(r: base.r * (1 - a) + top.r * a, g: base.g * (1 - a) + top.g * a, b: base.b * (1 - a) + top.b * a, a: 1)
    }

    func forEachTarget(_ body: (Double, Double, String) throws -> Void) rethrows {
        for (mode, theme) in Self.modes {
            Theme.setMode(theme)
            for (w, h) in Self.sizes { try body(w, h, mode) }
        }
    }

    func testDefaultLayout() throws {
        try forEachTarget { w, h, mode in
            let v = DockView(layout: DockDefaults.layout(registry), registry: registry)
            let t = render("default", v, w: w, h: h, mode: mode)
            for f in v.geometry.groups {
                let active = try XCTUnwrap(v.tabs[f.group.id]?.first { $0.panel == f.group.active })
                assertPixel(t, CanvasPoint(active.rect.x + 3, f.strip.maxY - 1), PanelTheme.accent, "\(f.group.active) underline")
                assertPixel(t, CanvasPoint(f.content.maxX - 3, f.content.maxY - 3), PanelTheme.panelBg, "\(f.group.active) content")
            }
            for s in v.geometry.splitters { assertPixel(t, CanvasPoint(s.seam.midX, s.seam.midY), PanelTheme.studioBg, "seam") }
        }
    }

    /// Mid-drag over each kind of drop: a tab bar (insertion bar), a group edge (half the group), the window edge.
    func testDropOverlays() throws {
        try forEachTarget { w, h, mode in
            for (name, point) in try overlayPoints(w, h) {
                let v = DockView(layout: DockDefaults.layout(registry), registry: registry)
                v.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: w, height: h - 23)) { _, _, _ in }
                let start = try XCTUnwrap(v.tabs.values.joined().first { $0.panel == "media" }).rect
                XCTAssertEqual(v.pointerDown(CanvasPoint(start.midX, start.midY)), .handled)
                v.pointerMove(CanvasPoint(w / 2, h / 2))
                v.pointerMove(point)
                let preview = try XCTUnwrap(v.drag?.preview, name)
                let t = render("drag-\(name)", v, w: w, h: h, mode: mode)
                let r = preview.highlight
                let inside = CanvasPoint(r.maxX - 6, r.maxY - 6)
                let base = v.geometry.groups.first { $0.content.contains(inside) } != nil ? PanelTheme.panelBg : PanelTheme.studioBg
                assertPixel(t, inside, Self.blend(base, PanelTheme.accent, 0.18), tol: 8, "\(name) tint")
                assertPixel(t, CanvasPoint(r.x + 1, r.midY), PanelTheme.accent, tol: 8, "\(name) outline")
                if let bar = preview.insertion { assertPixel(t, CanvasPoint(bar.midX, bar.midY), PanelTheme.accent, "insertion bar") }
            }
        }
    }

    func overlayPoints(_ w: Double, _ h: Double) throws -> [(String, CanvasPoint)] {
        let g = DockGeometry.compute(DockDefaults.layout(registry), registry: registry, in: CanvasRect(x: 0, y: 0, width: w, height: h - 23))
        let right = try XCTUnwrap(g.frame(containing: "inspector")), centre = try XCTUnwrap(g.frame(containing: "preview"))
        return [("tabbar", CanvasPoint(right.strip.maxX - 40, right.strip.midY)),
                ("split", CanvasPoint(centre.content.midX, centre.content.maxY - 12)),
                ("window", CanvasPoint(w / 2, h - 23 - 8))]
    }

    func testClosedPanelAndNarrowWindow() throws {
        try forEachTarget { w, h, mode in
            var l = DockDefaults.layout(registry)
            try l.close("renders", registry: registry)
            try l.close("media", registry: registry)
            let v = DockView(layout: l, registry: registry)
            let t = render("closed", v, w: w, h: h, mode: mode)
            XCTAssertEqual(v.geometry.groups.count, 3)
            let right = try XCTUnwrap(v.geometry.frame(containing: "inspector"))
            assertPixel(t, CanvasPoint(right.content.maxX - 3, right.content.maxY - 3), PanelTheme.panelBg, "design content")
            let narrow = DockView(layout: DockDefaults.layout(registry), registry: registry)
            _ = render("narrow", narrow, w: 700, h: h, mode: mode)
            XCTAssertTrue(narrow.geometry.groups.allSatisfy { $0.frame.width > 0 })
        }
    }
}
#endif
