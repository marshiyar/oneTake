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
import MpvfxShared
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The colour swatches and the open picker (issue #189 A1, A5) at the right panel's size in a 1440×900 and a
/// 1280×800 window, dark and light. Set `MPVFX_SNAPSHOT_DIR` to also write `color-picker-<mode>-<w>x<h>.png`.
final class InspectorColorPickerSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func render(_ p: InspectorPanel, width: Double, height: Double, name: String) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(width), height: Int(height))
        p.draw(t.canvas, in: CanvasRect(x: 0, y: 0, width: width, height: height))
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name).png"), 0)
        }
        return t
    }

    func rgb(_ t: CairoImageTarget, _ x: Double, _ y: Double) -> (Int, Int, Int) {
        let p = t.pixel(Int(x), Int(y)); return (Int(p.r), Int(p.g), Int(p.b))
    }

    func testSwatchesAndPickerInBothModesAtBothWindowSizes() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            for (w, h) in [(1440.0, 900.0), (1280.0, 800.0)] {
                let width = PanelFit.fit(w, PanelFit.defaults(w)).right
                let editor = try TimelineEditor(json: InspectorColorPickerTests.json)
                let p = InspectorPanel(); p.editor = editor; p.selection = ["S"]; p.openGroupId = "style"
                let name = "color-picker-\(mode == .dark ? "dark" : "light")-\(Int(w))x\(Int(h))"
                _ = render(p, width: width, height: h, name: name + "-closed")
                let sw = try XCTUnwrap(p.hits.rect { $0 == .button("swatch:fill") }, name)
                XCTAssertTrue(p.pointerDown(CanvasPoint(sw.midX, sw.midY))); p.pointerUp(CanvasPoint(sw.midX, sw.midY))
                let t = render(p, width: width, height: h, name: name)
                let swatch = try XCTUnwrap(p.hits.rect { $0 == .button("swatch:fill") }, name)
                let (r, g, b) = rgb(t, swatch.midX, swatch.midY)
                XCTAssertTrue(abs(r - 0x22) <= 2 && abs(g - 0x44) <= 2 && abs(b - 0x66) <= 2, "\(name): the Fill swatch shows #224466, got \(r),\(g),\(b)")
                let sv = try XCTUnwrap(p.hits.rect { $0 == .custom("picker:sv", 0) }, name)
                XCTAssertLessThanOrEqual(sv.maxX, width, "\(name): the picker fits the panel")
                let (wr, wg, wb) = rgb(t, sv.x + 3, sv.y + 3)
                XCTAssertTrue(wr > 240 && wg > 240 && wb > 240, "\(name): the square's top-left is white, got \(wr),\(wg),\(wb)")
                let (kr, kg, kb) = rgb(t, sv.maxX - 3, sv.maxY - 3)
                XCTAssertTrue(kr < 12 && kg < 12 && kb < 12, "\(name): the square's bottom-right is black")
                for h: InspectorPanel.Hit in [.custom("picker:hue", 0), .custom("picker:alpha", 0), .button("picker:sample"), .button("picker:done")] {
                    let hr = try XCTUnwrap(p.hits.rect { $0 == h }, "\(name) \(h)")
                    XCTAssertGreaterThanOrEqual(hr.height, 24, "\(name): \(h) is a 24 pt target")
                }
            }
        }
    }

    /// No fill: the swatch is the checkerboard, two token greys alternating every 4 pt.
    func testNoFillSwatchIsACheckerboard() throws {
        let editor = try TimelineEditor(json: InspectorColorPickerTests.json)
        XCTAssertTrue(editor.setClipFill(clipId: "S", nil))
        let p = InspectorPanel(); p.editor = editor; p.selection = ["S"]; p.openGroupId = "style"
        let t = render(p, width: 409, height: 900, name: "color-swatch-none")
        let hit = try XCTUnwrap(p.hits.rect { $0 == .button("swatch:fill") })
        let box = hit.insetBy(4)   // the 16 pt swatch inside its 24 pt target
        let a = rgb(t, box.x + 2, box.y + 2), b = rgb(t, box.x + 6, box.y + 2)
        XCTAssertNotEqual(a.0, b.0, "neighbouring checker cells differ")
    }
}
#endif
