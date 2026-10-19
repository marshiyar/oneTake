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

/// Pixel snapshots of the side panels at their design sizes, so visual regressions show.
///
/// Every test renders at 1x and 2x and checks colours at geometry that does not depend on the installed fonts
/// (card fills, borders, badges, wheel hues, slider tracks). Set `MPVFX_SNAPSHOT_DIR` to also write the PNGs
/// (`<panel>-1x.png`, `<panel>-2x.png`) for side-by-side review against the recorded reference renders.
final class PanelSnapshotTests: XCTestCase {
    static var outDir: String? { ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] }

    /// Renders `body` into a `w`×`h` point canvas at `scale`, writes it when asked, and returns the target.
    @discardableResult
    func snapshot(_ name: String, w: Double, h: Double, scale: Double, background: CanvasColor = PanelTheme.studioBg,
                  _ body: (CanvasContext) -> Void) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(w * scale), height: Int(h * scale))
        let c = t.canvas
        c.scale(scale, scale)
        c.fillRect(CanvasRect(x: 0, y: 0, width: w, height: h), background)
        body(c)
        if let dir = Self.outDir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name)-\(Int(scale))x.png"), 0)
        }
        return t
    }

    /// Asserts pixel (x, y) in points is within `tol` of `hex` on every channel.
    func assertPixel(_ t: CairoImageTarget, _ x: Double, _ y: Double, scale: Double, _ hex: String, tol: Int = 6,
                     file: StaticString = #filePath, line: UInt = #line) {
        let p = t.pixel(Int(x * scale), Int(y * scale))
        let want = CanvasColor(hex: hex)!
        let w = (Int(want.r * 255 + 0.5), Int(want.g * 255 + 0.5), Int(want.b * 255 + 0.5))
        let ok = abs(Int(p.r) - w.0) <= tol && abs(Int(p.g) - w.1) <= tol && abs(Int(p.b) - w.2) <= tol
        XCTAssertTrue(ok, "pixel (\(x),\(y))@\(scale)x = rgb(\(p.r),\(p.g),\(p.b)), want \(hex)", file: file, line: line)
    }

    /// A 320×180 test frame (light slide with a dark rule), standing in for a decoded thumbnail.
    static func testFrame(dark: Bool) -> CanvasImage {
        let w = 32, h = 18
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let v: UInt8 = dark ? (x > 9 && x < 23 ? 0x35 : 0x16) : (x == 16 ? 0x60 : 0xFA)
            px[i] = v; px[i + 1] = v; px[i + 2] = dark ? min(255, v + 0x20) : v; px[i + 3] = 255
        } }
        return CanvasImage(width: w, height: h, rgba: px)
    }

    static func sidebarFixture() -> LeftSidebarPanel {
        let s = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        s.items = [
            .init(id: "v1", name: "CS146-Assignment6-Watch.mp4", path: "media/CS146-Assignment6-Watch.mp4", category: .video, duration: 336, used: true),
            .init(id: "v2", name: "substitution-short.mp4", path: "media/substitution-short.mp4", category: .video, duration: 92, used: false),
        ]
        s.library.available = true
        s.library.libraries = [.init(id: "L", name: "test", events: [.init(id: "E", name: "Media")], projects: [.init(id: "P", name: "jk", eventId: "E")],
                                     assets: (0..<13).map { .init(id: "A\($0)", name: "clip-\($0).mp4", kind: "video", eventId: "E") },
                                     exports: (0..<14).map { .init(id: "J\($0)", label: "jk", status: "complete") })]
        s.library.currentProjectId = "P"
        s.onLibrary = { _ in }
        let light = testFrame(dark: false), dark = testFrame(dark: true)
        s.thumbnail = { $0 == "v1" ? light : dark }
        return s
    }

    func testLeftSidebar() {
        for scale in [1.0, 2.0] {
            let s = Self.sidebarFixture()
            let t = snapshot("left-sidebar", w: 370, h: 1040, scale: scale) { s.draw($0, size: CanvasSize(370, 1040)) }
            // Positions from the recorded reference layout at 370×1040 (left sidebar, library navigator, media bin).
            assertPixel(t, 150, 1000, scale: scale, "#0a0a0a")       // card body: bg-neutral-950
            assertPixel(t, 100, 50, scale: scale, "#171717")         // library select (13,37 344×28): bg-neutral-900
            assertPixel(t, 220, 258, scale: scale, "#0e0e0e")        // Import media (211.8,253 105×32): bg-panel-input
            assertPixel(t, 100, 297.5, scale: scale, "#181818")      // header border-b at y 297: neutral-800/50 on neutral-950
            assertPixel(t, 300, 320, scale: scale, "#0e0e0e")        // search (17,308 336×26.5): bg-panel-input
            assertPixel(t, 19, 397.5, scale: scale, "#3a3a3a", tol: 10)  // "Added" badge (17,395.5): neutral-950/80 over the frame
            assertPixel(t, 60, 440, scale: scale, "#fafafa", tol: 10)    // first tile (13,391.5 166×93.4) shows the frame
        }
    }

    static func rightFixture(open group: String?, h: Double) throws -> RightPanel {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let r = RightPanel(layout: layout)
        r.jobs = [.init(id: "1", name: "jk_2026-10-13.mp4", status: .complete, detail: "1920×1080")]
        r.inspector.editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        r.inspector.selection = ["clip:a"]
        if let group, r.inspector.openGroupId != group { r.inspector.toggleGroup(group) }   // a header click, as the reference was opened
        return r
    }

    func testRightPanelDesign() throws {
        for scale in [1.0, 2.0] {
            let r = try Self.rightFixture(open: nil, h: 1040)
            let t = snapshot("inspector-layout", w: 409, h: 1040, scale: scale) { r.draw($0, size: CanvasSize(409, 1040)) }
            assertPixel(t, 55, 15, scale: scale, "#262626")          // active "Design" tab (49,9 58×32): bg-neutral-800
            assertPixel(t, 200, 70, scale: scale, "#1d1d1d")         // flat panel bg-panel-bg under the header
        }
    }

    /// Inspector shell + Transform (PropertyPanelFlatHeader, FlatGroupHeader, LayoutGeometryRows, FlatRow,
    /// KeyframeNavigation, FlatSegmentedRow): geometry from the recorded reference layout, checked where no glyph of text lands.
    func testInspectorShellAndTransform() throws {
        for scale in [1.0, 2.0] {
            let r = try Self.rightFixture(open: "layout", h: 1040)
            let t = snapshot("inspector-layout", w: 409, h: 1040, scale: scale) { r.draw($0, size: CanvasSize(409, 1040)) }
            assertPixel(t, 200, 94, scale: scale, "#141414")      // header border-b: 44.5px laid out, painted at 94
            assertPixel(t, 200, 96, scale: scale, "#1d1d1d")      // open Transform header (95…135)
            assertPixel(t, 386, 114, scale: scale, "#71717a")     // open caret M2 4l4 4 4-4z at (380,108.5), text-3
            assertPixel(t, 200, 140, scale: scale, "#191919")     // open body bg-panel-bg-inset from 135
            assertPixel(t, 100, 180, scale: scale, "#1d1d1d")     // Position X field (17,170.5 183.5×30) rounded bg-panel-bg
            assertPixel(t, 204, 180, scale: scale, "#191919")     // gap-2 between the X and Y fields
            assertPixel(t, 100, 194, scale: scale, "#1a1a1d", tol: 8)   // value underline border-panel-border-input/50
        }
        // FlatSegmentedRow: the active option sits on a 2px accent underline; KeyframeNavigation's active diamond.
        for scale in [1.0, 2.0] {
            let insp = InspectorPanel()
            let seg = InspectorRow.Segmented(key: "k", label: "Ease", options: [(key: "a", label: "Linear", active: true), (key: "b", label: "Ease", active: false)], select: { _ in })
            let kf = InspectorRow.Keyframe(state: .onKey, toggle: {}, prev: nil, next: nil)
            let t = snapshot("inspector-controls", w: 240, h: 64, scale: scale, background: PanelTheme.panelBgInset) { c in
                insp.drawSegmented(c, CanvasRect(x: 0, y: 0, width: 240, height: 32), seg)
                insp.drawKeyframeNav(c, right: 240, midY: 48, key: "x", kf)
            }
            // Options laid right to left: "Ease" ends at 240, "Linear" 2px before it; underline = last 2px of 26.5.
            let easeW = t.canvas.measureText("Ease", font: PanelTheme.font(11)).width + 12
            let linearW = t.canvas.measureText("Linear", font: PanelTheme.font(11)).width + 12
            let underlineY = 28.3   // 16 + 26.5/2 - 2 … 29.25
            assertPixel(t, 240 - easeW - 2 - linearW / 2, underlineY, scale: scale, "#4c8df0", tol: 10)
            assertPixel(t, 240 - easeW / 2, underlineY, scale: scale, "#191919")
            assertPixel(t, 240 - 41 + 14 + 6.5, 48 + 0.5, scale: scale, "#5a98f0", tol: 12)   // 9px diamond centre
        }
    }

    /// Grade (PropertyPanelColorGradeRows): the fixture opened to Grade at the reference height 1900, so the whole
    /// body (scopes, presets, wheels, curves, secondaries, LUT, finish) lands on screen. Checked away from text.
    func testInspectorGrade() throws {
        for scale in [1.0, 2.0] {
            let r = try Self.rightFixture(open: "grade", h: 1900)
            let t = snapshot("inspector-grade-tall", w: 409, h: 1900, scale: scale) { r.draw($0, size: CanvasSize(409, 1900)) }
            assertPixel(t, 200, 70, scale: scale, "#1d1d1d")      // flat panel bg-panel-bg under the tab bar
        }
    }

    /// Light mode: every curve tab's line shows on the light graph (the near-white Master and Hue/Luma lines were
    /// invisible). Pixels on the curve differ clearly from the graph background beside it.
    func testGradeCurveLinesShowInLightMode() throws {
        Theme.setMode(.light); defer { Theme.setMode(.dark) }
        for scale in [1.0, 2.0] {
            let r = try Self.rightFixture(open: "grade", h: 1900)
            for tab in InspectorPanel.curveTabs {
                r.inspector.grade.curveTab = tab.key
                let t = snapshot("inspector-grade-curve-light-\(tab.key)", w: 409, h: 1900, scale: scale) { r.draw($0, size: CanvasSize(409, 1900)) }
                let box = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:curve", 0) }).insetBy(6)
                // Default curves: Master/R/G/B the identity diagonal, hue curves flat at 0 (mid-height).
                let lineY = tab.hue ? box.midY : box.maxY - 0.375 * box.height
                let x = box.x + 0.375 * box.width, bgY = tab.hue ? box.maxY - 0.375 * box.height : box.maxY - 0.625 * box.height
                let on = t.pixel(Int(x * scale), Int(lineY * scale)), off = t.pixel(Int(x * scale), Int(bgY * scale))
                let lum = { (p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) in 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b) }
                XCTAssertGreaterThan(lum(off) - lum(on), 60, "\(tab.key)@\(scale)x line rgb(\(on.r),\(on.g),\(on.b)) vs bg rgb(\(off.r),\(off.g),\(off.b))")
            }
        }
    }

    /// Grade preset tiles draw the host's look frame for each preset, aspect-fit in the 16:9 frame, asking for the
    /// tile's device pixels; tiles still rendering keep the empty frame.
    func testGradePresetTilesShowLookFrames() throws {
        for scale in [1.0, 2.0] {
            let r = try Self.rightFixture(open: "grade", h: 900)
            var asked: [PresetPreviewRequest] = []
            r.inspector.presetPreview = { req in
                asked.append(req)
                if req.presetId == "warm-daylight" { return .rendering }
                let red = req.presetId == "neutral"
                var px = [UInt8](repeating: 255, count: 32 * 18 * 4)
                for i in stride(from: 0, to: px.count, by: 4) { px[i] = red ? 230 : 20; px[i + 1] = 20; px[i + 2] = red ? 20 : 230 }
                return .ready(CanvasImage(width: 32, height: 18, rgba: px))
            }
            let t = snapshot("inspector-grade-previews", w: 409, h: 900, scale: scale) { r.draw($0, size: CanvasSize(409, 900)) }
            let tile0 = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:presets", 0) })
            let tile1 = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:presets", 1) })
            let tile2 = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:presets", 2) })
            let frameH = (tile0.width - 2) * 9 / 16
            assertPixel(t, tile0.midX, tile0.y + 1 + frameH / 2, scale: scale, "#e61414", tol: 6)   // neutral: the host's frame
            assertPixel(t, tile2.midX, tile2.y + 1 + frameH / 2, scale: scale, "#1414e6", tol: 6)   // another preset, its own frame
            assertPixel(t, tile1.midX, tile1.y + 1 + frameH / 2, scale: scale, "#1d1d1d", tol: 8)   // still rendering: empty frame
            XCTAssertEqual(Set(asked.map(\.presetId)).count, ColorGrading.gradePresets.count, "every tile asks for its preset")
            let req = try XCTUnwrap(asked.first)
            XCTAssertEqual(req.clipId, "clip:a")
            XCTAssertEqual(Double(req.pixelWidth), ((tile0.width - 2) * scale).rounded(), accuracy: 1)
            XCTAssertEqual(Double(req.pixelHeight), (frameH * scale).rounded(), accuracy: 1)
        }
    }

    /// Grade opens on the Scopes row (35pt, "Off") and, while look frames are unavailable, the Retry link, so the
    /// preset grid starts where the reference's does: 123 below the Grade header's top (the reference's header sits at
    /// 95.5 because its scroll came out at 79, ours at 94.5 with the header scrolled exactly to the body's top).
    func testGradeScopesRowAndRetryPlaceTheGrid() throws {
        let r = try Self.rightFixture(open: "grade", h: 1900)
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 1900))
        XCTAssertTrue(c.drawnStrings.contains("Scopes")); XCTAssertTrue(c.drawnStrings.contains("Off"))
        XCTAssertTrue(c.drawnStrings.contains("Retry look previews"))
        let tile = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:presets", 0) })
        XCTAssertEqual(tile.y, 94.5 + 123, accuracy: 0.5)
        XCTAssertEqual(tile.x, 17, accuracy: 0.5)
        // With look frames available the link goes and the grid moves up by its 18 + 6.
        r.inspector.presetPreview = { _ in .rendering }
        c.reset(); r.draw(c, size: CanvasSize(409, 1900))
        XCTAssertFalse(c.drawnStrings.contains("Retry look previews"))
        XCTAssertEqual(try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:presets", 0) }).y, 94.5 + 123 - 24, accuracy: 0.5)
    }

    /// Opening Scopes shows the status, the mode tabs and the scope of the host's graded frame; tabs switch mode.
    func testGradeScopesOpen() throws {
        let r = try Self.rightFixture(open: "grade", h: 1900)
        var px = [UInt8](repeating: 255, count: 64 * 36 * 4)
        for i in 0..<(64 * 36) { let v = UInt8((i % 64) * 4); px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v }
        let frame = CanvasImage(width: 64, height: 36, rgba: px)
        var asked = 0
        r.inspector.scopeFrame = { id, w, _ in asked += 1; XCTAssertEqual(id, "clip:a"); XCTAssertEqual(w, 320); return .ready(frame) }
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 1900))
        XCTAssertEqual(asked, 0, "closed scopes capture nothing")
        let toggle = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:scopes", 0) })
        XCTAssertTrue(r.inspector.pointerDown(CanvasPoint(toggle.midX, toggle.midY))); r.inspector.pointerUp(CanvasPoint(toggle.midX, toggle.midY))
        XCTAssertTrue(r.inspector.grade.scopesOpen)
        c.reset(); r.draw(c, size: CanvasSize(409, 1900))
        XCTAssertGreaterThan(asked, 0)
        for s in ["ready", "Histogram", "Waveform", "RGB Parade", "Vectorscope"] { XCTAssertTrue(c.drawnStrings.contains(s), s) }
        let tile = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:presets", 0) })
        XCTAssertEqual(tile.y, 94.5 + 123 + 234.35 - 35, accuracy: 1, "the open scopes push the grid down")
        let parade = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:scopes", 4) })
        XCTAssertTrue(r.inspector.pointerDown(CanvasPoint(parade.midX, parade.midY))); r.inspector.pointerUp(CanvasPoint(parade.midX, parade.midY))
        XCTAssertEqual(r.inspector.grade.scopeMode, .parade)
        for scale in [1.0, 2.0] {
            let t = snapshot("inspector-grade-scopes", w: 409, h: 700, scale: scale) { r.draw($0, size: CanvasSize(409, 700)) }
            _ = t
        }
    }

    /// Scope analysis and drawing: a horizontal grey ramp fills the waveform diagonally, the histogram evenly, and
    /// sits on the vectorscope's centre.
    func testColorScopesAnalysis() {
        var px = [UInt8](repeating: 255, count: 256 * 4 * 4)
        for y in 0..<4 { for x in 0..<256 { let i = (y * 256 + x) * 4; px[i] = UInt8(x); px[i + 1] = UInt8(x); px[i + 2] = UInt8(x) } }
        let a = ColorScopes.analyze(CanvasImage(width: 256, height: 4, rgba: px))
        XCTAssertEqual(a.histogram.reduce(0, +), 256 * 4 * 255)
        XCTAssertEqual(a.waveform[10 * 256 + 245], 4 * 255, "column 10 is luma 10, drawn 10 up from the bottom")
        XCTAssertEqual(a.vectorscope[127 * 256 + 128] + a.vectorscope[128 * 256 + 128] + a.vectorscope[127 * 256 + 127] + a.vectorscope[128 * 256 + 127], 256 * 4 * 255, "greys have no chroma")
        let empty = ColorScopes.render(.waveform, nil)
        XCTAssertEqual(empty.width, 320); XCTAssertEqual(empty.height, 144)
        XCTAssertEqual(Array(empty.rgba[0..<3]), [9, 11, 14], "the #090b0e grid")
        for m in ColorScopes.Mode.allCases {
            let img = ColorScopes.render(m, a)
            XCTAssertNotEqual(img.rgba, empty.rgba, "\(m) draws the frame")
        }
    }

    /// Effects with nothing active: "Add effect", the family tabs (Essentials
    /// open) and the Blur / Pixelate / Bloom tiles; then an added effect's active row and editor rail.
    func testInspectorEffects() throws {
        for scale in [1.0, 2.0] {
            let r = try Self.rightFixture(open: "effects", h: 1040)
            let t = snapshot("inspector-effects", w: 409, h: 1040, scale: scale) { r.draw($0, size: CanvasSize(409, 1040)) }
            let tabs = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("fx:tabs", 1) })
            assertPixel(t, tabs.midX, tabs.y + 2, scale: scale, "#1d1d1d")              // tab bg-panel-bg
            assertPixel(t, tabs.x - 0.5, tabs.midY, scale: scale, "#141414", tol: 8)    // gap-px hairline between tabs
        }
        let r = try Self.rightFixture(open: "effects", h: 1040)
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(409, 1040))
        let blur = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("fx:tiles", 0) })
        XCTAssertTrue(r.inspector.pointerDown(CanvasPoint(blur.midX, blur.midY))); r.inspector.pointerUp(CanvasPoint(blur.midX, blur.midY))
        XCTAssertEqual(r.inspector.editor?.colorGrading(clipId: "clip:a")?.effects["blur"], 0.45)
        c.reset(); r.draw(c, size: CanvasSize(409, 1040))
        XCTAssertTrue(c.drawnStrings.contains("Editing")); XCTAssertTrue(c.drawnStrings.contains("Radius"))
        XCTAssertNil(r.inspector.hits.rect { $0 == .custom("fx:tabs", 0) }, "adding closes the catalog")
    }

    /// Renders tab at 409×600, the reference's variants: one finished render;
    /// finished + failed + cancelled + rendering; empty; bundled tools missing with an action error.
    static func rendersFixture(_ variant: String) -> RightPanel {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        let r = RightPanel(layout: layout)
        let now = 1_800_000_000.0
        r.now = { now }
        let done = RenderJobView(id: "1", name: "jk_2026-10-13.mp4", status: .complete, progress: 1, thumbnail: testFrame(dark: false),
                                 createdAt: now - 3600, sizeBytes: 48_200_000, durationMs: 42_000)
        switch variant {
        case "mixed":
            r.jobs = [done,
                      .init(id: "2", name: "jk_2026-10-13_2.mp4", status: .failed, error: "Encoder exited with code 1", createdAt: now - 120),
                      .init(id: "3", name: "jk_2026-10-13_3.mp4", status: .cancelled, createdAt: now - 60),
                      .init(id: "4", name: "jk_2026-10-13_4.mp4", status: .rendering, stage: "Encoding frames", progress: 0.375, createdAt: now - 5)]
        case "empty": r.jobs = []
        default: r.jobs = [done]
        }
        if variant != "mixed" && variant != "empty" { r.lastRenderSeconds = 42 }
        if variant == "error" { r.actionError = "Could not delete jk_2026-10-13.mp4: permission denied" }
        return r
    }

    func testRendersPanel() {
        for scale in [1.0, 2.0] {
            for v in ["done", "mixed", "empty", "error"] {
                let r = Self.rendersFixture(v)
                let t = snapshot("renders-\(v)", w: 409, h: 600, scale: scale) { r.draw($0, size: CanvasSize(409, 600)) }
                switch v {
                case "done":
                    assertPixel(t, 100, 95, scale: scale, "#0e0e0e")     // Format select (13,81 187.5×28) bg-panel-input
                    assertPixel(t, 30, 180, scale: scale, "#ffffff")     // Export (13,176 383×32) bg-white
                    assertPixel(t, 200, 240, scale: scale, "#161616", tol: 10)  // settings border-b straddling 240 (239.5…240.5)
                    assertPixel(t, 20, 290, scale: scale, "#fafafa", tol: 12)   // the 16:9 poster frame fills the 80×45 well at (13,280)
                case "mixed":
                    assertPixel(t, 30, 180, scale: scale, "#858585", tol: 10)   // Rendering… (white/50 over neutral-950)
                    assertPixel(t, 53, 353, scale: scale, "#f87171", tol: 20)   // failed status dot at (49,349)
                    assertPixel(t, 140, 519.5, scale: scale, "#4c8df0", tol: 12) // progress fill (103,517.5 83.9×4)
                    assertPixel(t, 250, 519.5, scale: scale, "#000000", tol: 8)  // progress track
                case "error":
                    assertPixel(t, 30, 180, scale: scale, "#ffffff")             // Export enabled (13,176 383×32) bg-white
                    assertPixel(t, 300, 256, scale: scale, "#1d0e0e", tol: 10)   // error strip bg-red-500/10
                default:
                    assertPixel(t, 100, 400, scale: scale, "#0a0a0a")
                }
            }
        }
    }

    /// The accordion entrance in pixels: at its start the reopened Transform body is the panel background (opacity 0),
    /// mid-way a blend, at the end the inset body; the keyboard focus ring is the 2px accent.
    func testAccordionEntranceAndFocusRingPixels() throws {
        for scale in [1.0, 2.0] {
            let r = try Self.rightFixture(open: "layout", h: 1040)
            r.inspector.onAnimate = {}
            r.inspector.toggleGroup("layout"); r.inspector.toggleGroup("layout")
            var t = snapshot("inspector-enter-0", w: 409, h: 1040, scale: scale) { r.draw($0, size: CanvasSize(409, 1040)) }
            assertPixel(t, 200, 140, scale: scale, "#1d1d1d", tol: 2)    // body at opacity 0: bg-panel-bg
            r.inspector.tick(0.03)
            t = snapshot("inspector-enter-mid", w: 409, h: 1040, scale: scale) { r.draw($0, size: CanvasSize(409, 1040)) }
            let mid = t.pixel(Int(200 * scale), Int(140 * scale))
            XCTAssertGreaterThan(Int(mid.r), 0x0c); XCTAssertLessThan(Int(mid.r), 0x12)
            r.inspector.tick(0.2)
            t = snapshot("inspector-enter-1", w: 409, h: 1040, scale: scale) { r.draw($0, size: CanvasSize(409, 1040)) }
            assertPixel(t, 200, 140, scale: scale, "#191919")            // settled: bg-panel-bg-inset
            // Focus ring on the Transform header (95…135): 2px accent just outside it, clipped to the scrolling body
            // (so its top edge under the clip header is hidden, as the overflow-y-auto body clips the outline).
            r.inspector.focus.current = .group("layout"); r.inspector.focus.visible = true
            t = snapshot("inspector-focus", w: 409, h: 1040, scale: scale) { r.draw($0, size: CanvasSize(409, 1040)) }
            assertPixel(t, 200, 136, scale: scale, "#4c8df0", tol: 30)
        }
    }
}
#endif
