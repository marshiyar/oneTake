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
#if os(Linux)
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxPanels
import MpvfxTheme
@testable import MpvfxDesktop

/// The shell's flat layout (docs/DESIGN.md, rollout step 2), now laid out by the dock: panel groups edge to edge, each
/// with its 32 pt tab bar, 1 px seams where the black shell shows through, and the status line along the bottom of
/// the window. Set `MPVFX_SNAPSHOT_DIR` to also write the whole window (`editor-shell-dark.png`,
/// `editor-shell-light.png`) for review.
final class FlatShellTests: XCTestCase {
    static let size = CanvasSize(1440, 900)
    var dirs: [String] = []
    var sessions: [EditorSession] = []

    override func setUp() { Theme.setMode(.dark) }
    override func tearDown() {
        sessions.removeAll()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        Theme.setMode(.dark)
    }

    func makeSession() throws -> EditorSession {
        let d = NSTemporaryDirectory() + "mpvfx-flat-shell-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        _ = s.installShell(userData: d) {}
        sessions.append(s)
        return s
    }

    func render(_ s: EditorSession, _ name: String) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(Self.size.width), height: Int(Self.size.height))
        s.shell!.draw(t.canvas, size: Self.size)
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name).png"), 0)
        }
        return t
    }

    func assertPixel(_ t: CairoImageTarget, _ x: Double, _ y: Double, _ want: CanvasColor, _ what: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        let p = t.pixel(Int(x), Int(y))
        let w = (Int(want.r * 255 + 0.5), Int(want.g * 255 + 0.5), Int(want.b * 255 + 0.5))
        let ok = abs(Int(p.r) - w.0) <= 2 && abs(Int(p.g) - w.1) <= 2 && abs(Int(p.b) - w.2) <= 2
        XCTAssertTrue(ok, "\(what): pixel (\(x),\(y)) = rgb(\(p.r),\(p.g),\(p.b)), want \(want)", file: file, line: line)
    }

    /// The content frames at 1440×900 in the default dock layout: Media 369 | Preview 661 | Design 408 over the
    /// timeline, every group under its 32 pt tab bar; the timeline keeps its 360 pt content.
    func testFramesAreEdgeToEdgeWithOnePixelSeams() throws {
        let s = try makeSession()
        let router = try XCTUnwrap(s.shell)
        router.resized(Self.size)
        let f = router.relayout()
        XCTAssertEqual(f.dock, CanvasRect(x: 0, y: 0, width: 1440, height: 877))
        XCTAssertEqual(f.left, CanvasRect(x: 0, y: 32, width: 369, height: 452))
        XCTAssertEqual(f.preview, CanvasRect(x: 370, y: 32, width: 661, height: 452))
        XCTAssertEqual(f.right, CanvasRect(x: 1032, y: 32, width: 408, height: 452))
        XCTAssertEqual(f.renders, EditorShellFrames.zero, "Renders is behind the Design tab")
        XCTAssertEqual(f.previewTopBar, CanvasRect(x: 370, y: 32, width: 661, height: 36))
        XCTAssertEqual(f.player, CanvasRect(x: 370, y: 68, width: 661, height: 416))
        XCTAssertEqual(f.timeline, CanvasRect(x: 0, y: 517, width: 1440, height: 360))
        XCTAssertEqual(f.statusLine, CanvasRect(x: 0, y: 878, width: 1440, height: 22))
        // The seams keep a 13 pt pointer zone centred on the 1 px line.
        let seams = router.dock.geometry.splitters.map(\.hit)
        XCTAssertTrue(seams.contains(CanvasRect(x: 363, y: 0, width: 13, height: 484)), "\(seams)")
        XCTAssertTrue(seams.contains(CanvasRect(x: 0, y: 478, width: 1440, height: 13)), "\(seams)")
        // Fullscreen: the preview fills the window, no status line.
        s.player.view.isFullscreen = true
        let full = router.relayout()
        XCTAssertEqual(full.preview, CanvasRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(full.statusLine.height, 0)
        s.player.view.isFullscreen = false
    }

    /// The seams are the black shell; the panel corners are the panel itself (no rounded card, no gap), and the
    /// status line is the panel grey.
    func testSeamsAreTheShellAndPanelsMeetThem() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            let s = try makeSession()
            let t = render(s, "editor-shell-\(mode.rawValue)")
            let f = try XCTUnwrap(s.shell?.frames)
            let shell = PanelTheme.studioBg, panel = PanelTheme.panelBg
            assertPixel(t, f.left.maxX, 300, shell, "\(mode) left seam")
            assertPixel(t, f.preview.maxX, 300, shell, "\(mode) right seam")
            assertPixel(t, 700, f.preview.maxY, shell, "\(mode) timeline seam")
            assertPixel(t, 700, f.statusLine.y - 1, shell, "\(mode) seam above the status line")
            assertPixel(t, 0, 0, panel, "\(mode) left panel reaches the window corner")
            assertPixel(t, Self.size.width - 1, 0, panel, "\(mode) right panel reaches the window corner")
            assertPixel(t, f.left.maxX - 1, 300, panel, "\(mode) left panel reaches its seam")
            assertPixel(t, f.right.x, 300, panel, "\(mode) right panel starts right after its seam")
            assertPixel(t, Self.size.width - 2, Self.size.height - 2, panel, "\(mode) status line")
        }
    }

    /// The status line shows what the control under the pointer does, and the dock's own hints for the splitters.
    func testStatusLineHints() throws {
        let s = try makeSession()
        _ = render(s, "editor-shell-start")
        let router = try XCTUnwrap(s.shell), f = try XCTUnwrap(router.frames)
        XCTAssertNil(router.statusHint, "nothing under the pointer yet")
        router.pointerMove(x: f.left.maxX, y: 300)
        XCTAssertEqual(router.statusHint, DockView.splitterHint)
        router.pointerMove(x: 700, y: f.preview.maxY)
        XCTAssertEqual(router.statusHint, DockView.splitterHint)
        router.pointerMove(x: 700, y: f.timeline.y + f.timeline.height / 2)
        XCTAssertEqual(router.statusHint, EditorShellRouter.regionHints[.timeline])
        // The hint is drawn in the status line: muted ink over the panel grey near its left end.
        let t = render(s, "editor-shell-hints")
        var inked = false
        for x in 8..<200 { let p = t.pixel(x, Int(f.statusLine.y + f.statusLine.height / 2)); if p.r > 0x40 { inked = true; break } }
        XCTAssertTrue(inked, "the timeline hint is drawn")
        // The dock's chrome wins over the region's hint: the Design group's menu button.
        let strip = try XCTUnwrap(router.dock.geometry.frame(containing: "inspector")).strip
        let menu = DockTabBar.menuRect(strip)
        router.pointerMove(x: menu.cx, y: menu.cy)
        XCTAssertEqual(router.statusHint, DockView.menuHint)
        // A panel's own control wins over the region's hint: the media bin's panel menu button.
        let bin = try XCTUnwrap(s.panels?.left.hits.rect { $0 == .panelMenu })
        router.pointerMove(x: f.left.x + bin.cx, y: f.left.y + bin.cy)
        XCTAssertEqual(router.statusHint, "Panel menu")
    }
}
/// Centre of a rect (the panels module keeps its own `midX`, `midY` internal).
fileprivate extension CanvasRect {
    var cx: Double { x + width / 2 }
    var cy: Double { y + height / 2 }
}
#endif
