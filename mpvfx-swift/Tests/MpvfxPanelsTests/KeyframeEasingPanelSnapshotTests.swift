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
import OneTakeKeyframes
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Keyframe Easing panel in a 1440 × 900 window, dark and light: as the right panel's tab (409 pt) and docked
/// under the timeline (full width, 300 pt). Checks colours at font-independent geometry; `MPVFX_SNAPSHOT_DIR` also
/// writes the PNGs (`keyframe-easing-<layout>-<mode>-<n>x.png`) for review.
final class KeyframeEasingPanelSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    static let window = CanvasSize(1440, 900)
    static let layouts: [(name: String, rect: CanvasRect)] = [
        // The right panel's default width at 1440 pt (PanelFit: 28.4 % of the window, 409 pt).
        ("tab", CanvasRect(x: 1031, y: 32, width: 409, height: 868)),
        ("docked", CanvasRect(x: 0, y: 600, width: 1440, height: 300)),
    ]

    /// clip:a with rotation eased in & out from 0° to 90° over 30 frames and position keyed; the first rotation key selected.
    func panel() throws -> KeyframeEasingPanel {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        for t in [0.0, 2, 4] { XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: t)) }
        let a = try XCTUnwrap(e.parameterAddress(clipId: "clip:a", TimelineEditor.rotationId))
        for (f, v) in [(0.0, 0.0), (30, 90)] {
            XCTAssertTrue(e.applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: .number, frame: f, value: .number(v), baselineValue: .number(v))))))
        }
        let key = TimelineKeyframeRef(clipId: "clip:a", parameterId: TimelineEditor.rotationId, frame: 0)
        XCTAssertTrue(e.setOutgoing([(key, .cubicBezier(.init(x1: 0.42, y1: 0, x2: 0.58, y2: 1)))]))
        let p = KeyframeEasingPanel()
        p.editor = e; p.clipId = "clip:a"; p.selectedKeyframes = [key]; p.time = 0.5
        return p
    }

    func render(_ p: KeyframeEasingPanel, _ name: String, _ rect: CanvasRect, scale: Double) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(Self.window.width * scale), height: Int(Self.window.height * scale))
        t.canvas.scale(scale, scale)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: Self.window.width, height: Self.window.height), PanelTheme.studioBg)
        p.draw(t.canvas, in: rect)
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name)-\(Int(scale))x.png"), 0)
        }
        return t
    }

    func assertColour(_ t: CairoImageTarget, _ pt: CanvasPoint, scale: Double, _ want: CanvasColor, _ what: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let p = t.pixel(Int(pt.x * scale), Int(pt.y * scale))
        let w = [want.r, want.g, want.b].map { Int($0 * 255 + 0.5) }
        let ok = abs(Int(p.r) - w[0]) <= 6 && abs(Int(p.g) - w[1]) <= 6 && abs(Int(p.b) - w[2]) <= 6
        XCTAssertTrue(ok, "\(what) at \(pt) = rgb(\(p.r),\(p.g),\(p.b)), want \(w)", file: file, line: line)
    }

    func testPanelInDarkAndLightAt1440x900() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            for (layout, rect) in Self.layouts {
                let p = try panel()
                for scale in [1.0, 2.0] {
                    let t = render(p, "keyframe-easing-\(layout)-\(mode)", rect, scale: scale)
                    let graph = try XCTUnwrap(p.hits.rect { $0 == .graph }, "\(layout): no graph")
                    assertColour(t, CanvasPoint(rect.maxX - 3, rect.maxY - 3), scale: scale, PanelTheme.panelBg, "\(layout) \(mode) panel")
                    assertColour(t, CanvasPoint(graph.x + 3, graph.midY), scale: scale, PanelTheme.panelBgInset, "\(layout) \(mode) graph")
                    assertColour(t, CanvasPoint(rect.x - 1 < 0 ? 2 : rect.x - 2, 4), scale: scale, PanelTheme.studioBg, "\(layout) \(mode) window")
                    XCTAssertGreaterThanOrEqual(graph.width, rect.width >= KeyframeEasingPanel.wideLayout ? rect.width * 0.35 : rect.width - 30)
                    XCTAssertLessThanOrEqual(graph.maxY, rect.maxY, "\(layout): the graph fits the panel")
                    for (hit, r) in p.hits.regions.map({ ($0.action, $0.rect) }) {
                        XCTAssertLessThanOrEqual(r.maxY, rect.maxY + 0.5, "\(layout): \(hit) is cut off at the panel's bottom")
                    }
                }
            }
        }
    }

    func testEveryControlFitsTheTabAtItsMinimumWidth() throws {
        let p = try panel(), r = CanvasRect(x: 0, y: 0, width: PanelFit.minRight, height: 900)
        p.draw(PanelMeasureCanvas(), in: r)
        for (rect, hit, _) in p.hits.regions where hit != .graph {
            XCTAssertLessThanOrEqual(rect.maxX, r.maxX + 0.5, "\(hit) leaves the panel")
            XCTAssertGreaterThanOrEqual(rect.x, r.x - 0.5, "\(hit) leaves the panel")
        }
    }
}
#endif
