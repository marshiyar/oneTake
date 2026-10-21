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
#if os(Linux)   // Cairo is the Linux canvas; these draw real pixels.
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxTheme
import MpvfxTimeline
@testable import MpvfxPlayer

/// Pixel snapshots of the transform box at 1440×900 in dark and light: the eight handles and the anchor at rest,
/// a resize with its snap guide and readout, and a rotate with the rotate glyph. The checks read pixels at
/// geometry that does not depend on fonts; set `MPVFX_SNAPSHOT_DIR` to also write the PNGs
/// (`transform-box-<state>-<mode>-<scale>x.png`) for review.
final class TransformBoxSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    static let size = CanvasSize(1440, 900)

    /// A light picture behind the box, so the contrast ring is what keeps the white handles visible.
    final class LightFrame: FrameSource {
        func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement]) {
            c.fillRect(rect, CanvasColor(hex: "#2b2f36") ?? CanvasColor(r: 0, g: 0, b: 0))
            for e in elements { c.fillRect(e.rect, CanvasColor(hex: "#f2f2f2") ?? CanvasColor(r: 1, g: 1, b: 1)) }
        }
    }

    func rig() -> (PlayerView, PlayerController) {
        let v = PlayerView(playback: PlaybackState(duration: 10))
        v.canvasSize = CanvasSize(1920, 1080)
        v.frameSource = LightFrame()
        v.theme = TimelineTheme.default
        v.now = { 100 }
        let c = PlayerController(view: v)
        c.size = Self.size
        v.elements = [StageElement(id: "a", name: "A", rect: CanvasRect(x: 560, y: 240, width: 800, height: 600), kind: .video)]
        v.selectedIds = ["a"]
        return (v, c)
    }

    func render(_ v: PlayerView, _ name: String, scale: Double) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(Self.size.width * scale), height: Int(Self.size.height * scale))
        t.canvas.scale(scale, scale)
        v.draw(t.canvas, size: Self.size)
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/transform-box-\(name)-\(Int(scale))x.png"), 0)
        }
        return t
    }

    func pixel(_ t: CairoImageTarget, _ p: CanvasPoint, scale: Double) -> (r: Int, g: Int, b: Int) {
        let q = t.pixel(Int((p.x * scale).rounded(.down)), Int((p.y * scale).rounded(.down)))
        return (Int(q.r), Int(q.g), Int(q.b))
    }

    func assertWhite(_ t: CairoImageTarget, _ p: CanvasPoint, scale: Double, _ msg: String, above floor: Int = 235, line: UInt = #line) {
        let q = pixel(t, p, scale: scale)
        XCTAssertTrue(q.r > floor && q.g > floor && q.b > floor, "\(msg): rgb\(q) at \(p)", line: line)
    }

    func assertDarkerThanPicture(_ t: CairoImageTarget, _ p: CanvasPoint, scale: Double, _ msg: String, line: UInt = #line) {
        let q = pixel(t, p, scale: scale)
        XCTAssertTrue(q.r < 200 && q.g < 200 && q.b < 200, "\(msg): rgb\(q) at \(p)", line: line)
    }

    func testRestingBoxShowsEightHandlesAndTheAnchorInDarkAndLight() {
        for mode in [ThemeMode.dark, .light] { Theme.setMode(mode); for scale in [1.0, 2.0] {
            let (v, c) = rig()
            let t = render(v, "rest-\(mode.rawValue)", scale: scale)
            let ve = v.chromeElement(v.elements[0], in: c.size)
            for h in TransformHandle.allCases {
                let p = TransformBox.screenPoint(ve, unit: h.unit)
                assertWhite(t, CanvasPoint(p.x - 0.5, p.y - 0.5), scale: scale, "\(h) handle centre (\(mode) \(scale)x)")
            }
            // Just outside the se dot, inside the box over the light picture: the dark contrast ring (6–7 px out).
            let se = TransformBox.screenPoint(ve, unit: TransformHandle.se.unit)
            assertDarkerThanPicture(t, CanvasPoint(se.x - 4.7, se.y - 4.7), scale: scale, "contrast ring (\(mode) \(scale)x)")
            // The anchor's right arm (5–9 px out, 1.5 px white over 3 px dark): white on it, dark just beside it.
            let a = ve.centre
            assertWhite(t, CanvasPoint(a.x + 7.5, a.y), scale: scale, "anchor arm (\(mode) \(scale)x)", above: 200)
            assertDarkerThanPicture(t, CanvasPoint(a.x + 7.5, a.y + 1.2), scale: scale, "anchor arm outline (\(mode) \(scale)x)")
        } }
    }

    func testResizeShowsTheSnapGuideAndTheReadoutInDarkAndLight() throws {
        for mode in [ThemeMode.dark, .light] { Theme.setMode(mode); for scale in [1.0, 2.0] {
            let (v, c) = rig()
            v.toolbar.snapEnabled = true
            let ve = v.chromeElement(v.elements[0], in: c.size)
            let e = TransformBox.screenPoint(ve, unit: TransformHandle.e.unit), f = v.frameRect(in: c.size)
            c.pointerDown(x: e.x, y: e.y)
            c.pointerMove(x: f.maxX - 3, y: e.y)   // 3 px from the frame's right edge: snaps onto it
            let t = render(v, "resize-\(mode.rawValue)", scale: scale)
            XCTAssertEqual(v.transformChrome.readout?.text, "W 1360 × H 600")
            let guide = try XCTUnwrap(v.snapGuides.first)
            XCTAssertEqual(guide.position, f.maxX, accuracy: 1e-6)
            // The readout pill (stage scrim) sits right of and below the cursor.
            let pill = pixel(t, CanvasPoint(min(f.maxX - 3 + 18, v.viewportRect(in: c.size).maxX - 10), e.y + 22), scale: scale)
            XCTAssertTrue(pill.r < 40 && pill.g < 40 && pill.b < 40, "readout pill is dark: rgb\(pill) (\(mode) \(scale)x)")
            c.pointerUp(x: f.maxX - 3, y: e.y)
        } }
    }

    func testRotateShowsTheGlyphAndTheAngleInDarkAndLight() {
        for mode in [ThemeMode.dark, .light] { Theme.setMode(mode); for scale in [1.0, 2.0] {
            let (v, c) = rig()
            let ve = v.chromeElement(v.elements[0], in: c.size)
            let ne = TransformBox.screenPoint(ve, unit: TransformHandle.ne.unit)
            let zone = CanvasPoint(ne.x + 18, ne.y - 18)
            c.pointerMove(x: zone.x, y: zone.y)
            c.pointerDown(x: zone.x, y: zone.y)
            let to = PlayerView.rotate(zone, about: ve.centre, 20)
            c.pointerMove(x: to.x, y: to.y)
            _ = render(v, "rotate-\(mode.rawValue)", scale: scale)
            XCTAssertEqual(v.transformChrome.cursor, .rotate)
            XCTAssertEqual(v.transformChrome.readout?.text, "20.0°")
            c.pointerUp(x: to.x, y: to.y)
        } }
    }
}
#endif
