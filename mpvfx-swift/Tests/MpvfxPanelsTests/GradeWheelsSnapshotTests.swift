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
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// The colour wheels (issue #176) in the right panel at its size in a 1440x900 window (409x900), dark and light,
/// scrolled so the wheels are on screen. Set `MPVFX_SNAPSHOT_DIR` to write the PNGs.
final class GradeWheelsSnapshotTests: XCTestCase {
    func render(_ mode: ThemeMode) throws -> (CairoImageTarget, RightPanel) {
        Theme.setMode(mode)
        let r = RightPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        var g = ColorGrading()
        g.balance["lift"] = .init(hue: 210, amount: 0.4, level: -0.2); g.balance["gain"] = .init(hue: 40, amount: 0.6, level: 0.3)
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        r.inspector.editor = editor; r.inspector.selection = ["clip:a"]
        r.inspector.toggleGroup("grade")
        let size = CanvasSize(409, 900)
        r.draw(PanelMeasureCanvas(), size: CanvasSize(409, 5000))   // the whole body, to find where the wheels sit
        let wheel = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:balance", 0) })
        r.draw(PanelMeasureCanvas(), size: size)
        r.inspector.bodyScroll = max(0, wheel.y - 200)
        let t = CairoImageTarget(width: 409, height: 900)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 409, height: 900), PanelTheme.studioBg)
        r.draw(t.canvas, size: size)
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/grade-wheels-\(mode == .dark ? "dark" : "light")-1440x900.png"), 0)
        }
        return (t, r)
    }

    func testWheelsDrawInDarkAndLight() throws {
        defer { Theme.setMode(.dark) }
        for mode in [ThemeMode.dark, .light] {
            let (t, r) = try render(mode)
            let wheel = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:balance", 0) })
            XCTAssertGreaterThan(wheel.y, 40, "the wheel is on screen"); XCTAssertLessThan(wheel.maxY, 900)
            let centre = t.pixel(Int(wheel.midX), Int(wheel.midY))
            XCTAssertEqual(Int(centre.r), 128, accuracy: 6, "the wheel's grey centre"); XCTAssertEqual(Int(centre.g), 128, accuracy: 6)
            // The ring at hue 0 (right edge, inside the rim) is red in both modes.
            let ring = t.pixel(Int(wheel.maxX - 6), Int(wheel.midY))
            XCTAssertGreaterThan(Int(ring.r) - Int(ring.b), 100, "red at hue 0: \(ring)")
            let level = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:balance", 10) })
            let track = t.pixel(Int(level.x + 3), Int(level.midY))
            let bg = t.pixel(Int(level.x + 3), Int(level.y + 1))
            XCTAssertNotEqual([track.r, track.g, track.b], [bg.r, bg.g, bg.b], "the level track shows (\(mode))")
        }
    }
}
#endif
