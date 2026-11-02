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
import MpvfxShared
import MpvfxTheme
@testable import MpvfxTimeline
@testable import MpvfxPanels

#if os(Linux)   // Cairo is the Linux canvas; these tests draw real pixels.
/// The Transition group for the wipe (with an angle), iris and zoom-through kinds at the right panel's size in a
/// 1440×900 window, dark and light. Set `MPVFX_SNAPSHOT_DIR` to also write `transition-group-<mode>-<kind>-1440x900.png`.
final class InspectorTransitionKindsSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    /// Clip A's transition set to `kind` with the Transition group open. A wipe also gets an angle of 45.
    func panel(_ kind: NativeCutTransitionKind) throws -> InspectorPanel {
        var json = InspectorTransitionKindsTests.json
            .replacingOccurrences(of: #""kind":"dissolve""#, with: #""kind":"\#(kind.rawValue)""#)
        if kind == .wipe {
            json = json.replacingOccurrences(of: #""kind":"wipe""#, with: #""kind":"wipe","angle":45"#)
        }
        let editor = try TimelineEditor(json: json)
        let p = InspectorPanel(); p.editor = editor; p.selection = ["A"]; p.openGroupId = "transitions"
        return p
    }

    func render(_ p: InspectorPanel, width: Double, height: Double, name: String) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(width), height: Int(height))
        p.draw(t.canvas, in: CanvasRect(x: 0, y: 0, width: width, height: height))
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name).png"), 0)
        }
        return t
    }

    func ink(_ c: CanvasColor) -> (Int, Int, Int) { (Int(c.r * 255 + 0.5), Int(c.g * 255 + 0.5), Int(c.b * 255 + 0.5)) }

    func assertNear(_ t: CairoImageTarget, _ x: Double, _ y: Double, _ want: CanvasColor, _ what: String,
                    file: StaticString = #filePath, line: UInt = #line) {
        let p = t.pixel(Int(x), Int(y)), w = ink(want)
        let ok = abs(Int(p.r) - w.0) <= 3 && abs(Int(p.g) - w.1) <= 3 && abs(Int(p.b) - w.2) <= 3
        XCTAssertTrue(ok, "\(what): (\(x),\(y)) = rgb(\(p.r),\(p.g),\(p.b)), want \(w)", file: file, line: line)
    }

    /// Pixels inside `r` (clipped to the image) that differ from `bg` by more than 3 in any channel, from `straightRGBA()`.
    func inkCount(_ px: [UInt8], _ t: CairoImageTarget, in r: CanvasRect, bg: CanvasColor) -> Int {
        let b = ink(bg)
        let x0 = max(0, Int(r.x)), x1 = min(t.width, Int(r.maxX))
        let y0 = max(0, Int(r.y)), y1 = min(t.height, Int(r.maxY))
        guard x1 > x0, y1 > y0 else { return 0 }
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * t.width + x) * 4
                if abs(Int(px[i]) - b.0) > 3 || abs(Int(px[i + 1]) - b.1) > 3 || abs(Int(px[i + 2]) - b.2) > 3 { n += 1 }
            }
        }
        return n
    }

    func testTransitionKindsRenderInBothModes() throws {
        let win = (w: 1440.0, h: 900.0)
        let width = PanelFit.fit(win.w, PanelFit.defaults(win.w)).right
        let cases: [(kind: NativeCutTransitionKind, controls: [InspectorPanel.Hit])] = [
            (.wipe, [.field("transition:angle")]),
            (.iris, [.field("transition:centreX"), .slider("transition:softness")]),
            (.zoomThrough, [.slider("transition:strength")]),
        ]
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            for (kind, controls) in cases {
                let name = "transition-group-\(mode == .dark ? "dark" : "light")-\(kind.rawValue)-\(Int(win.w))x\(Int(win.h))"
                let p = try panel(kind)
                let t = render(p, width: width, height: win.h, name: name)
                let px = t.straightRGBA()

                // Not blank: the panel has ink somewhere other than its background.
                let whole = CanvasRect(x: 0, y: 0, width: width, height: win.h)
                XCTAssertGreaterThan(inkCount(px, t, in: whole, bg: PanelTheme.panelBg), 0, "\(name): the panel is not blank")

                // The Transition header sits on the panel background; the open body is the inset grey.
                let header = try XCTUnwrap(p.hits.rect { $0 == .group("transitions") }, name)
                assertNear(t, header.x + 4, header.midY, PanelTheme.panelBg, "\(name): the Transition header")
                let body = try XCTUnwrap(p.hits.rect { $0 == .body }, name)
                assertNear(t, body.x + 2, body.y + 2, PanelTheme.panelBgInset, "\(name): the open Transition body")
                XCTAssertGreaterThan(inkCount(px, t, in: body, bg: PanelTheme.panelBgInset), 0, "\(name): the Transition rows are drawn")

                // The Kind row and this kind's own option rows are drawn inside the panel.
                for control in [InspectorPanel.Hit.segment("transition:kind", kind.rawValue)] + controls {
                    let r = try XCTUnwrap(p.hits.rect { $0 == control }, "\(name): \(control) is drawn")
                    XCTAssertLessThanOrEqual(r.maxX, width, "\(name): \(control) fits the panel")
                    XCTAssertGreaterThan(inkCount(px, t, in: r, bg: PanelTheme.panelBgInset), 0, "\(name): \(control) is drawn")
                }
            }
        }
    }

    func testDarkAndLightRendersDiffer() throws {
        let width = PanelFit.fit(1440, PanelFit.defaults(1440)).right
        var renders: [[UInt8]] = []
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            let name = "transition-group-\(mode == .dark ? "dark" : "light")-wipe-1440x900"
            renders.append(render(try panel(.wipe), width: width, height: 900, name: name).straightRGBA())
        }
        XCTAssertEqual(renders[0].count, renders[1].count, "both renders are the same size")
        let differing = zip(renders[0], renders[1]).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        XCTAssertGreaterThan(differing, 0, "dark and light renders differ")
    }
}
#endif

/// The Transition group's title (drawn in the open header) reaches WCAG AA (4.5:1) on the panel background in both
/// modes. Measures the draw, so it runs on every platform.
final class InspectorTransitionGroupContrastTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func testTransitionGroupLabelReachesAAInBothModes() throws {
        func t(_ c: CanvasColor) -> ThemeColor { ThemeColor(r: c.r, g: c.g, b: c.b) }
        for mode in ThemeMode.allCases {
            Theme.setMode(mode)
            let editor = try TimelineEditor(json: InspectorTransitionKindsTests.json)
            let p = InspectorPanel(); p.editor = editor; p.selection = ["A"]; p.openGroupId = "transitions"
            let title = try XCTUnwrap(p.groups.first { $0.id == "transitions" }?.title, "\(mode): the Transition group exists")
            let c = PanelMeasureCanvas()
            p.draw(c, in: CanvasRect(x: 0, y: 0, width: PanelFit.fit(1440, PanelFit.defaults(1440)).right, height: 900))
            let labelColour = try XCTUnwrap(c.texts.last { $0.0 == title }?.3, "\(mode): \(title) is drawn")
            XCTAssertEqual(labelColour, PanelTheme.text0, "\(mode): the open group title uses text0")
            XCTAssertGreaterThanOrEqual(t(labelColour).contrast(t(PanelTheme.panelBg)), 4.5,
                                        "\(mode): the Transition group label reaches 4.5:1 on the panel background")
        }
    }
}
