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

/// The Media group (issue #188) at the right panel's size in a 1440×900 and a 1280×800 window, dark and light.
/// Set `MPVFX_SNAPSHOT_DIR` to also write `media-group-<mode>-<w>x<h>.png`.
final class InspectorMediaSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    static let windows: [(w: Double, h: Double)] = [(1440, 900), (1280, 800)]

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

    func testMediaGroupInBothModesAtBothWindowSizes() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            for win in Self.windows {
                let width = PanelFit.fit(win.w, PanelFit.defaults(win.w)).right
                let editor = try TimelineEditor(json: InspectorMediaGroupTests.json())
                let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:v"]; p.openGroupId = "media"
                let name = "media-group-\(mode == .dark ? "dark" : "light")-\(Int(win.w))x\(Int(win.h))"
                let t = render(p, width: width, height: win.h, name: name)
                let chip = try XCTUnwrap(p.hits.rect { $0 == .button("crop:start") }, name)
                XCTAssertGreaterThanOrEqual(chip.height, 24, name)
                assertNear(t, chip.x + 3, chip.midY, PanelTheme.panelInput, "\(name): the Edit crop button is a raised button")
                let sound = try XCTUnwrap(p.hits.rect { $0 == .toggle("muted") }, name)
                XCTAssertLessThanOrEqual(sound.maxX, width, "\(name): the Sound switch fits the panel")
                XCTAssertNotNil(p.hits.rect { $0 == .field("mediaStart") }, "\(name): Media start is focusable")
            }
        }
    }

    /// Every control the Media group draws is at least 24 pt in both directions (WCAG 2.2 SC 2.5.8), except the
    /// slider tracks, whose keyboard and target work is issue #174.
    func testMediaGroupTargetsAreAtLeast24Points() throws {
        let editor = try TimelineEditor(json: InspectorMediaGroupTests.json())
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:v"]; p.openGroupId = "media"
        _ = render(p, width: 409, height: 900, name: "media-group-targets")
        for key in ["crop:start"] {
            let r = try XCTUnwrap(p.hits.rect { $0 == .button(key) }, key)
            XCTAssertGreaterThanOrEqual(min(r.width, r.height), 24, key)
        }
        for key in ["muted", "keepPitch"] {
            let r = try XCTUnwrap(p.hits.rect { $0 == .toggle(key) }, key)
            XCTAssertGreaterThanOrEqual(min(r.width, r.height), 24, key)
        }
        let start = try XCTUnwrap(p.hits.rect { $0 == .field("mediaStart") })
        XCTAssertGreaterThanOrEqual(min(start.width, start.height), 24, "mediaStart")
    }

    /// Tab reaches Edit crop, the Sound switch and Media start; Space on the focused Sound switch flips it.
    func testMediaGroupIsKeyboardOperable() throws {
        let editor = try TimelineEditor(json: InspectorMediaGroupTests.json())
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:v"]; p.openGroupId = "media"
        _ = render(p, width: 409, height: 900, name: "media-group-keys")
        var seen: [InspectorPanel.Hit] = []
        for _ in 0..<40 {
            XCTAssertTrue(p.keyDown(EditorKey(.tab)))
            if let cur = p.focus.current { seen.append(cur) }
            if p.focus.current == .toggle("muted") { break }
        }
        XCTAssertTrue(seen.contains(.button("crop:start")), "Edit crop takes focus")
        XCTAssertTrue(seen.contains(.field("mediaStart")), "Media start takes focus")
        XCTAssertEqual(p.focus.current, .toggle("muted"))
        XCTAssertTrue(p.keyDown(EditorKey(.space)))
        XCTAssertEqual(editor.clip("clip:v")?.clip.muted, true, "Space switches Sound off")
    }
}
#endif
