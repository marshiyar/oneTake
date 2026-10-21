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

/// The Grade scopes in the whole editor window at 1440 x 900, in dark and in light. Set `MPVFX_SNAPSHOT_DIR` to also
/// write `editor-scopes-dark.png` and `editor-scopes-light.png` for review.
final class ScopesWindowSnapshotTests: XCTestCase {
    static let size = CanvasSize(1440, 900)
    var dirs: [String] = []
    var sessions: [EditorSession] = []

    override func tearDown() {
        sessions.removeAll()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        Theme.setMode(.dark)
    }

    /// BT.471 100/0/75/0 bars over a black-to-white ramp: every scope has something to show.
    static func barsOverRamp(_ w: Int = 160, _ h: Int = 90) -> CanvasImage {
        let bars: [[UInt8]] = [[255, 255, 255], [191, 191, 0], [0, 191, 191], [0, 191, 0], [191, 0, 191], [191, 0, 0], [0, 0, 191], [0, 0, 0]]
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, v = UInt8(x * 255 / (w - 1))
            let c = y < h * 2 / 3 ? bars[x * bars.count / w] : [v, v, v]
            px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]
        } }
        return CanvasImage(width: w, height: h, rgba: px)
    }

    func openScopes(_ mode: ThemeMode) throws -> (EditorSession, RightPanel) {
        Theme.setMode(mode)
        let d = NSTemporaryDirectory() + "mpvfx-scopes-window-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        _ = s.installShell(userData: d) {}
        sessions.append(s)
        let right = try XCTUnwrap(s.panels?.right)
        s.timeline.view.selection = ["clip:a"]
        _ = render(s, nil)
        if right.inspector.openGroupId != "grade" { right.inspector.toggleGroup("grade") }
        right.inspector.grade.scopesOpen = true
        let frame = Self.barsOverRamp()
        right.inspector.scopeFrame = { _, _, _ in .ready(frame) }
        _ = render(s, nil)
        right.inspector.scopeWorker.wait()
        return (s, right)
    }

    func render(_ s: EditorSession, _ name: String?) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(Self.size.width), height: Int(Self.size.height))
        s.shell?.draw(t.canvas, size: Self.size)
        if let name, let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name).png"), 0)
        }
        return t
    }

    func testScopesInTheWindowAt1440x900InDarkAndLight() throws {
        for mode in [ThemeMode.dark, .light] {
            let (s, right) = try openScopes(mode)
            let t = render(s, "editor-scopes-\(mode.rawValue)")
            let row = try XCTUnwrap(right.inspector.hits.rect { $0 == .custom("grade:scopes", 0) }, "the Scopes row is on screen")
            let frames = try XCTUnwrap(s.shell?.frames)
            let tiles = ScopeLayout.tiles(right.inspector.grade.scopes.kinds, x: frames.right.x + 16,
                                          y: frames.right.y + row.y + 28 + 22 + 22 + 6, width: 377)
            XCTAssertEqual(tiles.map(\.kind), [.waveform, .vectorscope])
            for tile in tiles where tile.rect.maxY < frames.right.maxY {
                let p = t.pixel(Int(tile.rect.x + 3), Int(tile.rect.maxY - 3))
                XCTAssertLessThan(Int(p.r) + Int(p.g) + Int(p.b), 60, "\(mode) \(tile.kind): the scope ground is black")
            }
        }
    }
}
#endif
