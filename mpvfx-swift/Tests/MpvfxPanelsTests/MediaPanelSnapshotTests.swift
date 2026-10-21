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
import MpvfxTimeline
@testable import MpvfxPanels

/// The Media panel's states drawn through Cairo at 280, 364 and 409 pt in dark and light. Each checks pixels that
/// do not depend on the installed fonts; with `MPVFX_CAPTURE_DIR` set it also writes
/// `media-panel-<state>-<mode>-<width>.png` (2x) for review.
final class MediaPanelSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    /// A `w`×`h` frame: a light subject on a dark ground.
    static func frame(w: Int, h: Int) -> CanvasImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, v: UInt8 = abs(x - w / 2) < w / 4 ? 0xE0 : 0x40
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
        } }
        return CanvasImage(width: w, height: h, rgba: px)
    }

    static func panel() -> LeftSidebarPanel {
        let s = MediaPanelFixture.panel()
        let portrait = frame(w: 18, h: 32), wide = frame(w: 32, h: 18)
        s.thumbnail = { id in id.contains("NUNCA") ? portrait : (id.hasSuffix(".png") || id.contains("Su-57") || id.contains("b-roll") ? wide : nil) }
        s.bars = { id in id.hasSuffix(".wav") ? (0..<24).map { Double(($0 * 7) % 10) / 10 } : nil }
        return s
    }

    static let states: [(String, (LeftSidebarPanel) -> Void)] = [
        ("rest", { _ in }),
        ("hover", { $0.hovered = .tile(.media("media/\(MediaPanelFixture.long)")) }),
        ("selected", { s in s.selected = .media("media/b-roll.mov") }),
        ("switcher", { s in s.openSwitcher() }),
        ("more", { s in s.openMoreMenu() }),
        ("filter", { s in s.filter = MediaFilter(kind: .video, usage: .notInTimeline); s.openFilterMenu() }),
        ("context", { s in _ = s.secondaryClick(CanvasPoint(60, 200)) }),
        ("focus", { s in for _ in 0..<3 { _ = s.keyDown(EditorKey(.tab)) } }),
        ("naming", { s in s.runMoreOption("newEvent") }),
        ("error", { s in s.library.error = "Could not open the library: permission denied"; s.library.busy = true }),
        ("library", { s in s.filter.kind = .library }),
        ("nomatch", { s in s.searchQuery = "zzz" }),
        ("empty", { s in s.items = []; s.library = LibraryNavModel() }),
    ]

    func render(_ name: String, width: Double, mode: ThemeMode, _ state: (LeftSidebarPanel) -> Void) -> (CairoImageTarget, LeftSidebarPanel) {
        Theme.setMode(mode)
        let s = Self.panel(), h = 900.0, scale = 2.0
        s.draw(PanelMeasureCanvas(), size: CanvasSize(width, h))
        state(s)
        let t = CairoImageTarget(width: Int(width * scale), height: Int(h * scale))
        t.canvas.scale(scale, scale)
        s.draw(t.canvas, size: CanvasSize(width, h))
        if let dir = ProcessInfo.processInfo.environment["MPVFX_CAPTURE_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/media-panel-\(name)-\(mode.rawValue)-\(Int(width)).png"), 0)
        }
        return (t, s)
    }

    func rgb(_ t: CairoImageTarget, _ p: CanvasPoint) -> (Int, Int, Int) {
        let px = t.pixel(Int(p.x * 2), Int(p.y * 2))
        return (Int(px.r), Int(px.g), Int(px.b))
    }

    func assertNear(_ got: (Int, Int, Int), _ hex: Int, tol: Int = 8, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let want = ((hex >> 16) & 255, (hex >> 8) & 255, hex & 255)
        XCTAssertTrue(abs(got.0 - want.0) <= tol && abs(got.1 - want.1) <= tol && abs(got.2 - want.2) <= tol,
                      "\(what): rgb\(got), want \(String(hex, radix: 16))", file: file, line: line)
    }

    func testEveryStateAtEveryWidthInBothModes() throws {
        for mode in ThemeMode.allCases { for w in [280.0, 364.0, 409.0] { for (name, state) in Self.states {
            let (t, s) = render(name, width: w, mode: mode, state)
            let bg = mode == .dark ? 0x1D1D1D : 0xFAFAFA
            assertNear(rgb(t, CanvasPoint(w - 2, 140)), bg, "\(name) \(mode) \(w): the panel's right margin is the panel")
            if name != "empty", let imp = s.hits.rect(where: { $0 == .importMedia }) {
                assertNear(rgb(t, CanvasPoint(imp.x + 3, imp.y + imp.height / 2)), mode == .dark ? 0x2F6FD6 : 0x1A5FCC, "\(name) \(mode) \(w): Import")
            }
        } } }
    }

    /// A portrait clip fills its 16:9 tile (the middle of the frame, cut), so the grid has no letterbox bars: the
    /// tile's left edge shows the frame's ground, not the tile's empty fill.
    func testPortraitMediaFillsTheTile() throws {
        let (t, s) = render("fill", width: 364, mode: .dark, { _ in })
        let tile = try XCTUnwrap(s.hits.rect { $0 == .tile(.media("media/\(MediaPanelFixture.long)")) })
        let thumbH = tile.width * MediaPanelMetrics.thumbAspect
        assertNear(rgb(t, CanvasPoint(tile.x + 3, tile.y + thumbH * 0.75)), 0x404040, "the frame reaches the tile's left edge")
        assertNear(rgb(t, CanvasPoint(tile.x + tile.width / 2, tile.y + thumbH * 0.75)), 0xE0E0E0, tol: 10, "the subject in the middle")
    }
}
#endif
