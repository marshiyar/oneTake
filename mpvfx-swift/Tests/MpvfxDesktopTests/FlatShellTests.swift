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

/// The shell's flat layout (docs/DESIGN.md, rollout step 2): panels edge to edge, 1 px seams where the black shell
/// shows through, and the status line along the bottom of the window. Set `MPVFX_SNAPSHOT_DIR` to also write the
/// whole window (`editor-shell-dark.png`, `editor-shell-light.png`) for review.
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

    /// The frames at 1440×900 with the default widths (370 | 409) and the default 360 pt timeline.
    func testFramesAreEdgeToEdgeWithOnePixelSeams() {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let f = EditorShellFrames.compute(size: Self.size, layout: layout, timelineHeight: 360, fullscreen: false)
        XCTAssertEqual(f.left, CanvasRect(x: 0, y: 0, width: 370, height: 516))
        XCTAssertEqual(f.preview, CanvasRect(x: 371, y: 0, width: 659, height: 516))
        XCTAssertEqual(f.right, CanvasRect(x: 1031, y: 0, width: 409, height: 516))
        XCTAssertEqual(f.previewTopBar, CanvasRect(x: 371, y: 0, width: 659, height: 36))
        XCTAssertEqual(f.player, CanvasRect(x: 371, y: 36, width: 659, height: 480))
        XCTAssertEqual(f.timelineDivider, CanvasRect(x: 0, y: 516, width: 1440, height: 1))
        XCTAssertEqual(f.timeline, CanvasRect(x: 0, y: 517, width: 1440, height: 360))
        XCTAssertEqual(f.statusLine, CanvasRect(x: 0, y: 878, width: 1440, height: 22))
        // The seams keep a 13 pt pointer zone centred on the 1 px line.
        XCTAssertEqual(f.leftSeamHit, CanvasRect(x: 364, y: 0, width: 13, height: 516))
        XCTAssertEqual(f.rightSeamHit, CanvasRect(x: 1024, y: 0, width: 13, height: 516))
        XCTAssertEqual(f.timelineDividerHit, CanvasRect(x: 0, y: 512, width: 1440, height: 10))
        // A collapsed panel is a 40 pt rail followed by the same seam.
        layout.toggleLeft()
        let railed = EditorShellFrames.compute(size: Self.size, layout: layout, timelineHeight: 360, fullscreen: false)
        XCTAssertTrue(railed.leftRail)
        XCTAssertEqual(railed.left.width, 40); XCTAssertEqual(railed.preview.x, 41); XCTAssertNil(railed.leftSeamHit)
        // Fullscreen: the preview fills the window, no status line.
        let full = EditorShellFrames.compute(size: Self.size, layout: layout, timelineHeight: 360, fullscreen: true)
        XCTAssertEqual(full.preview, CanvasRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(full.statusLine.height, 0)
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
            assertPixel(t, 700, f.timelineDivider.y, shell, "\(mode) timeline seam")
            assertPixel(t, 700, f.statusLine.y - 1, shell, "\(mode) seam above the status line")
            assertPixel(t, 0, 0, panel, "\(mode) left panel reaches the window corner")
            assertPixel(t, Self.size.width - 1, 0, panel, "\(mode) right panel reaches the window corner")
            assertPixel(t, f.left.maxX - 1, 300, panel, "\(mode) left panel reaches its seam")
            assertPixel(t, f.right.x, 300, panel, "\(mode) right panel starts right after its seam")
            assertPixel(t, Self.size.width - 2, Self.size.height - 2, panel, "\(mode) status line")
        }
    }

    /// The status line shows what the control under the pointer does, and the shell's own hints for the seams.
    func testStatusLineHints() throws {
        let s = try makeSession()
        _ = render(s, "editor-shell-start")
        let router = try XCTUnwrap(s.shell), f = try XCTUnwrap(router.frames)
        XCTAssertNil(router.statusHint, "nothing under the pointer yet")
        router.pointerMove(x: f.left.maxX, y: 300)
        XCTAssertEqual(router.statusHint, EditorShellRouter.seamHint)
        router.pointerMove(x: 700, y: f.timelineDivider.y)
        XCTAssertEqual(router.statusHint, EditorShellRouter.dividerHint)
        router.pointerMove(x: 700, y: f.timeline.y + f.timeline.height / 2)
        XCTAssertEqual(router.statusHint, EditorShellRouter.regionHints[.timeline])
        // The hint is drawn in the status line: muted ink over the panel grey near its left end.
        let t = render(s, "editor-shell-hints")
        var inked = false
        for x in 8..<200 { let p = t.pixel(x, Int(f.statusLine.y + f.statusLine.height / 2)); if p.r > 0x40 { inked = true; break } }
        XCTAssertTrue(inked, "the timeline hint is drawn")
        // A panel's own control wins over the region's hint: the right panel's menu button.
        let menu = try XCTUnwrap(s.panels?.right.hits.rect { $0 == .panelMenu })
        router.pointerMove(x: f.right.x + menu.x + menu.width / 2, y: f.right.y + menu.y + menu.height / 2)
        XCTAssertEqual(router.statusHint, "Panel menu")
    }
}
#endif
