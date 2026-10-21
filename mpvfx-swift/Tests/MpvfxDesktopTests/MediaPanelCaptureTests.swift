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

/// The whole editor with a filled Media panel (a library with an event, library media, an export, and a bin of
/// portrait and landscape clips with long names), rendered through Cairo at the two target window sizes in dark
/// and light. Set `MPVFX_CAPTURE_DIR` to write `media-<MPVFX_CAPTURE_TAG>-<mode>-<w>x<h>.png` for review.
final class MediaPanelCaptureTests: XCTestCase {
    var dirs: [String] = []
    var sessions: [EditorSession] = []

    override func setUp() { Theme.setMode(.dark) }
    override func tearDown() {
        sessions.removeAll()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        Theme.setMode(.dark)
    }

    /// A frame `w`×`h` with a light subject on a dark ground, standing in for a decoded thumbnail.
    static func frame(w: Int, h: Int, ground: UInt8) -> CanvasImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let subject = abs(x - w / 2) < w / 4 && abs(y - h / 2) < h / 6
            let v: UInt8 = subject ? 0xD8 : ground
            px[i] = v; px[i + 1] = v; px[i + 2] = min(255, v + 0x18); px[i + 3] = 255
        } }
        return CanvasImage(width: w, height: h, rgba: px)
    }

    /// The panel as the owner's screenshot showed it: every clip on the timeline, long names, a standalone project.
    static func fill(_ left: LeftSidebarPanel) {
        let names = ["NUNCA MUDA QUICK BMW M3 EDIT (2).mp4", "NUNCA MUDA QUICK BMW M3 EDIT (3).mp4",
                     "NUNCA MUDA QUICK BMW M3 social media.mp4", "Su-57 edit - Brushed down by speed.mp4",
                     "Luffy gear five amv.mp4", "The Calculus Lecture Week 4.mp4", "b-roll street night.mov"]
        left.items = names.enumerated().map { i, n in
            MediaBinItem(id: "media/\(n)", name: n, path: "media/\(n)", category: .video, duration: [11, 11, 11, 39, 8, 54, 21][i], used: i < 6)
        } + [MediaBinItem(id: "media/poster.png", name: "poster.png", path: "media/poster.png", category: .images, duration: nil, used: false),
             MediaBinItem(id: "media/drive.wav", name: "drive.wav", path: "media/drive.wav", category: .audio, duration: 92.5, used: true)]
        let portrait = frame(w: 18, h: 32, ground: 0x30), wide = frame(w: 32, h: 18, ground: 0x14)
        left.thumbnail = { id in id.contains("NUNCA") || id.contains("Luffy") ? portrait : (id.hasSuffix(".wav") ? nil : wide) }
        var model = LibraryNavModel()
        model.available = true
        model.isStandalone = true
        model.libraries = [.init(id: "L", name: "Untitled.mpvfxlibrary", events: [.init(id: "E", name: "Media")], projects: [],
                                 assets: [.init(id: "A1", name: "NUNCA MUDA QUICK BMW M3 EDIT.mp4", kind: "video", eventId: "E"),
                                          .init(id: "A2", name: "Su-57 edit - Brushed down by speed.mp4", kind: "video", eventId: "E")],
                                 exports: [.init(id: "J1", label: "render-546cccc1-d7d8-473d-8eda-5f0c.mp4", status: "complete")])]
        model.recentProjects = [.init(path: "/p/Alpha", name: "Alpha")]
        left.library = model
        left.onLibrary = { _ in }
    }

    func render(_ s: EditorSession, _ size: CanvasSize) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(size.width), height: Int(size.height))
        s.shell!.draw(t.canvas, size: size)
        return t
    }

    func testEditorWithAFilledMediaPanelAtBothTargetSizesAndModes() throws {
        let tag = ProcessInfo.processInfo.environment["MPVFX_CAPTURE_TAG"] ?? "now"
        for size in [CanvasSize(1440, 900), CanvasSize(1280, 800)] {
            for mode in [ThemeMode.dark, .light] {
                Theme.setMode(mode)
                let d = NSTemporaryDirectory() + "mpvfx-media-capture-\(UUID().uuidString)"
                try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                dirs.append(d)
                let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
                _ = s.installShell(userData: d) {}
                s.redraw = {}
                sessions.append(s)
                _ = render(s, size)   // first paint starts the panels (they read the empty backend)
                let left = try XCTUnwrap(s.panels?.left)
                Self.fill(left)
                let t = render(s, size)
                let f = try XCTUnwrap(s.shell?.frames)
                XCTAssertGreaterThan(f.left.width, 200, "the Media panel is open at \(size)")
                XCTAssertFalse(left.hits.regions.isEmpty)
                if let dir = ProcessInfo.processInfo.environment["MPVFX_CAPTURE_DIR"] {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    XCTAssertEqual(t.writePNG("\(dir)/media-\(tag)-\(mode.rawValue)-\(Int(size.width))x\(Int(size.height)).png"), 0)
                }
            }
        }
    }
}
#endif
