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
import XCTest
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MpvfxTheme
#endif

final class SecondaryQualifierTests: XCTestCase {
    func setup() throws -> (InspectorPanel, TimelineEditor, ColorGrading) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        var g = ColorGrading(); var s = ColorGrading.Secondary()
        s.hueCenter = 120; s.hueRange = 30
        s.satMin = 0.2; s.satMax = 0.8; s.lumaMin = 0.2; s.lumaMax = 0.8
        g.secondaries = [s]
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.openGroupId = "grade"
        draw(p)
        return (p, editor, g)
    }
    func draw(_ p: InspectorPanel) {
        for _ in 0..<2 { p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 6000)) }
    }
    func testEveryHandleIsReachableAndDraggingCommitsOneUndo() throws {
        for channel in SecondaryQualifier.allCases { for part in 0...1 {
            let (p, e, before) = try setup()
            let id = "sec:qualifier:\(channel.rawValue)"
            let hit = InspectorPanel.Hit.custom(id, part)
            let rect = try XCTUnwrap(p.hits.rect { $0 == hit })
            XCTAssertGreaterThanOrEqual(rect.width, 24); XCTAssertGreaterThanOrEqual(rect.height, 24)
            XCTAssertTrue(PanelFocus<InspectorPanel.Hit>.order(p.hits, InspectorPanel.focusable).contains(hit))
            let start = CanvasPoint(rect.midX, rect.midY)
            XCTAssertTrue(p.pointerDown(start))
            for offset in [5.0, 10, 20] {
                _ = p.pointerMove(CanvasPoint(start.x + offset, start.y)); draw(p)
                XCTAssertEqual(e.colorGrading(clipId: "clip:a"), before, "a drag does not add history entries")
            }
            p.pointerUp(CanvasPoint(start.x + 20, start.y))
            XCTAssertNotEqual(e.colorGrading(clipId: "clip:a"), before)
            e.undo(); XCTAssertEqual(e.colorGrading(clipId: "clip:a"), before)
        } }
    }
    func testClickAndDragBackToStartPreserveTheFullHueRange() throws {
        let (p, e, original) = try setup()
        var g = original; g.secondaries[0].hueRange = 180
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g)); draw(p)
        let rect = try XCTUnwrap(p.hits.rect { $0 == .custom("sec:qualifier:hue", 0) })
        let start = CanvasPoint(rect.midX, rect.midY)
        XCTAssertTrue(p.pointerDown(start)); p.pointerUp(start)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a"), g)
        XCTAssertTrue(p.pointerDown(start))
        _ = p.pointerMove(CanvasPoint(start.x + 20, start.y)); draw(p)
        _ = p.pointerMove(start); draw(p); p.pointerUp(start)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a"), g)
    }
    func testKeyboardAdjustsEveryEndpointAndSaturationCannotCross() throws {
        let (p, e, _) = try setup()
        for channel in SecondaryQualifier.allCases { for part in 0...1 {
            draw(p)
            let id = "sec:qualifier:\(channel.rawValue)"
            let before = try XCTUnwrap(e.colorGrading(clipId: "clip:a")?.secondaries.first)
            p.focus.current = .custom(id, part); p.focus.visible = true
            XCTAssertTrue(p.keyDown(EditorKey(.right)))
            let after = try XCTUnwrap(e.colorGrading(clipId: "clip:a")?.secondaries.first)
            XCTAssertNotEqual(channel.bounds(before).0 + channel.bounds(before).1, channel.bounds(after).0 + channel.bounds(after).1)
        } }
        var s = ColorGrading.Secondary(); s.satMin = 0.2; s.satMax = 0.8
        s = SecondaryQualifier.saturation.editing(s, part: 0, value: 2)
        XCTAssertEqual(s.satMin, 0.8); XCTAssertEqual(s.satMax, 0.8)
        s = SecondaryQualifier.saturation.editing(s, part: 1, value: -1)
        XCTAssertEqual(s.satMin, s.satMax)
        XCTAssertEqual(SecondaryQualifier.luma.editing(s, part: 0, value: .nan), s)
    }
    func testHueWrapsAcrossRedAndLumaBoundariesStayOrdered() {
        var s = ColorGrading.Secondary(); s.hueCenter = 0; s.hueRange = 30
        let next = SecondaryQualifier.hue.editing(s, part: 0, value: 320)
        XCTAssertEqual(next.hueCenter, 355); XCTAssertEqual(next.hueRange, 35)
        XCTAssertEqual(SecondaryQualifier.hue.bounds(next).0, 320)
        XCTAssertEqual(SecondaryQualifier.hue.bounds(next).1, 30)
        var full = ColorGrading.Secondary(); full.hueCenter = 180; full.hueRange = 170
        full = SecondaryQualifier.hue.editing(full, part: 0, value: 0)
        full = SecondaryQualifier.hue.editing(full, part: 1, value: 360)
        XCTAssertEqual(full.hueRange, 180)
        XCTAssertEqual(SecondaryQualifier.hue.bounds(full).1, 360)
        s.lumaMin = 0.3; s.lumaMax = 0.7
        XCTAssertEqual(SecondaryQualifier.luma.editing(s, part: 0, value: 1).lumaMin, 0.7)
        XCTAssertEqual(SecondaryQualifier.luma.editing(s, part: 1, value: 0).lumaMax, 0.3)
    }
    func testEyedropperRangesAppearAndMatteRejectsOutsideLuma() throws {
        let (p, e, _) = try setup()
        let image = CanvasImage(width: 1, height: 1, rgba: [128, 128, 128, 255])
        var s = ColorGrading.Secondary()
        XCTAssertTrue(SecondaryColorKey.sample(image, x: 0, y: 0, into: &s))
        XCTAssertEqual(s.lumaMin, 128.0 / 255 - 0.2, accuracy: 1e-9)
        XCTAssertEqual(s.lumaMax, 128.0 / 255 + 0.2, accuracy: 1e-9)
        var g = ColorGrading(); g.secondaries = [s]
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g)); draw(p)
        let track = try XCTUnwrap(p.grade.qualifierTracks["sec:qualifier:luma"])
        for (part, value) in [s.lumaMin, s.lumaMax].enumerated() {
            let handle = try XCTUnwrap(p.hits.rect { $0 == .custom("sec:qualifier:luma", part) })
            XCTAssertEqual(handle.midX, track.x + track.width * value, accuracy: 0.001)
        }
        XCTAssertEqual(SecondaryColorKey.matte(CanvasImage(width: 1, height: 1, rgba: [255, 255, 255, 255]), s).rgba, [0, 0, 0, 255])
        p.grade.sampleFrame = image; p.grade.showMatte = true
        s.lumaMin = 0.8; p.grade.qualifierDraft = s; draw(p)
        XCTAssertEqual(p.grade.matteMemo?.image.rgba, [0, 0, 0, 255], "matte follows the in-progress range")
    }
    func testProjectRoundTripPreservesAuthoredValuesAndOldDefaults() {
        let old = ColorGrading(json: ["secondaries": .array([.object([:])])])
        XCTAssertEqual(old.secondaries[0].satMin, 0); XCTAssertEqual(old.secondaries[0].satMax, 1)
        XCTAssertEqual(old.secondaries[0].lumaMin, 0); XCTAssertEqual(old.secondaries[0].lumaMax, 1)
        var g = ColorGrading(); var s = ColorGrading.Secondary()
        s.satMin = 0.123456789; s.satMax = 0.987654321; s.satSoftness = 0.17
        s.lumaMin = 0.22; s.lumaMax = 0.77; s.lumaSoftness = 0.03
        g.secondaries = [s]
        XCTAssertEqual(ColorGrading(json: g.json), g)
        s.satMin = -0.1; s.lumaMax = 1.1; g.secondaries = [s]
        XCTAssertEqual(ColorGrading(json: g.json), g, "loading retains stored values rather than silently clamping")
    }
#if canImport(CoreGraphics)
    func testQualifierCapturesAtBothViewportSizesAndAppearances() throws {
        defer { Theme.setMode(.dark) }
        for mode in [ThemeMode.dark, .light] { for size in [(1440, 900), (1280, 800)] {
            Theme.setMode(mode)
            let (p, _, _) = try setup()
            let width = 409.0, height = Double(size.1)
            let first = try XCTUnwrap(p.hits.rect { $0 == .custom("sec:qualifier:hue", 0) })
            p.bodyScroll = first.y - 240
            let canvas = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: Int(width), height: size.1))
            canvas.fillRect(CanvasRect(x: 0, y: 0, width: width, height: height), PanelTheme.studioBg)
            p.draw(canvas, in: CanvasRect(x: 0, y: 0, width: width, height: height))
            for channel in SecondaryQualifier.allCases {
                let rect = try XCTUnwrap(p.hits.rect { $0 == .custom("sec:qualifier:\(channel.rawValue)", 1) })
                XCTAssertGreaterThan(rect.y, 0); XCTAssertLessThan(rect.maxY, height)
            }
            if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let path = "\(dir)/secondary-qualifier-\(mode == .dark ? "dark" : "light")-\(size.0)x\(size.1).png"
                let image = try XCTUnwrap(canvas.ctx.makeImage())
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        } }
    }
#endif
}
