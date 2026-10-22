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
import MpvfxCanvas
@testable import MpvfxPanels
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import MpvfxTheme
import UniformTypeIdentifiers
#endif

internal final class SecondaryQualifierTests: XCTestCase {
    private struct Fixture {
        let panel: InspectorPanel
        let editor: TimelineEditor
        let grade: ColorGrading
    }

    private func setup() throws -> Fixture {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        var grade = ColorGrading(); var secondary = ColorGrading.Secondary()
        secondary.hueCenter = 120; secondary.hueRange = 30
        secondary.satMin = 0.2; secondary.satMax = 0.8; secondary.lumaMin = 0.2; secondary.lumaMax = 0.8
        grade.secondaries = [secondary]
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade))
        let panel = InspectorPanel(); panel.editor = editor; panel.selection = ["clip:a"]; panel.openGroupId = "grade"
        draw(panel)
        return Fixture(panel: panel, editor: editor, grade: grade)
    }
    private func draw(_ panel: InspectorPanel) {
        for _ in 0..<2 { panel.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 6_000)) }
    }
    internal func testEveryHandleIsReachableAndDraggingCommitsOneUndo() throws {
        for channel in SecondaryQualifier.allCases { for part in 0...1 {
            let fixture = try setup()
            let panel = fixture.panel, editor = fixture.editor, before = fixture.grade
            let id = "sec:qualifier:\(channel.rawValue)"
            let hit = InspectorPanel.Hit.custom(id, part)
            let rect = try XCTUnwrap(panel.hits.rect { $0 == hit })
            XCTAssertGreaterThanOrEqual(rect.width, 24); XCTAssertGreaterThanOrEqual(rect.height, 24)
            XCTAssertTrue(PanelFocus<InspectorPanel.Hit>.order(panel.hits, InspectorPanel.focusable).contains(hit))
            let start = CanvasPoint(rect.midX, rect.midY)
            XCTAssertTrue(panel.pointerDown(start))
            for offset in [5.0, 10, 20] {
                _ = panel.pointerMove(CanvasPoint(start.x + offset, start.y)); draw(panel)
                XCTAssertEqual(editor.colorGrading(clipId: "clip:a"), before, "a drag does not add history entries")
            }
            panel.pointerUp(CanvasPoint(start.x + 20, start.y))
            XCTAssertNotEqual(editor.colorGrading(clipId: "clip:a"), before)
            editor.undo(); XCTAssertEqual(editor.colorGrading(clipId: "clip:a"), before)
        } }
    }
    internal func testClickAndDragBackToStartPreserveTheFullHueRange() throws {
        let fixture = try setup()
        let panel = fixture.panel, editor = fixture.editor, original = fixture.grade
        var grade = original; grade.secondaries[0].hueRange = 180
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade)); draw(panel)
        let rect = try XCTUnwrap(panel.hits.rect { $0 == .custom("sec:qualifier:hue", 0) })
        let start = CanvasPoint(rect.midX, rect.midY)
        XCTAssertTrue(panel.pointerDown(start)); panel.pointerUp(start)
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a"), grade)
        XCTAssertTrue(panel.pointerDown(start))
        _ = panel.pointerMove(CanvasPoint(start.x + 20, start.y)); draw(panel)
        _ = panel.pointerMove(start); draw(panel); panel.pointerUp(start)
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a"), grade)
    }
    internal func testKeyboardAdjustsEveryEndpointAndSaturationCannotCross() throws {
        let fixture = try setup()
        let panel = fixture.panel, editor = fixture.editor
        for channel in SecondaryQualifier.allCases { for part in 0...1 {
            draw(panel)
            let id = "sec:qualifier:\(channel.rawValue)"
            let before = try XCTUnwrap(editor.colorGrading(clipId: "clip:a")?.secondaries.first)
            panel.focus.current = .custom(id, part); panel.focus.visible = true
            XCTAssertTrue(panel.keyDown(EditorKey(.right)))
            let after = try XCTUnwrap(editor.colorGrading(clipId: "clip:a")?.secondaries.first)
            XCTAssertNotEqual(channel.bounds(before).0 + channel.bounds(before).1, channel.bounds(after).0 + channel.bounds(after).1)
        } }
        var secondary = ColorGrading.Secondary(); secondary.satMin = 0.2; secondary.satMax = 0.8
        secondary = SecondaryQualifier.saturation.editing(secondary, part: 0, value: 2)
        XCTAssertEqual(secondary.satMin, 0.8); XCTAssertEqual(secondary.satMax, 0.8)
        secondary = SecondaryQualifier.saturation.editing(secondary, part: 1, value: -1)
        XCTAssertEqual(secondary.satMin, secondary.satMax)
        XCTAssertEqual(SecondaryQualifier.luma.editing(secondary, part: 0, value: .nan), secondary)
    }
    internal func testHueWrapsAcrossRedAndLumaBoundariesStayOrdered() {
        var secondary = ColorGrading.Secondary(); secondary.hueCenter = 0; secondary.hueRange = 30
        let next = SecondaryQualifier.hue.editing(secondary, part: 0, value: 320)
        XCTAssertEqual(next.hueCenter, 355); XCTAssertEqual(next.hueRange, 35)
        XCTAssertEqual(SecondaryQualifier.hue.bounds(next).0, 320)
        XCTAssertEqual(SecondaryQualifier.hue.bounds(next).1, 30)
        var full = ColorGrading.Secondary(); full.hueCenter = 180; full.hueRange = 170
        full = SecondaryQualifier.hue.editing(full, part: 0, value: 0)
        full = SecondaryQualifier.hue.editing(full, part: 1, value: 360)
        XCTAssertEqual(full.hueRange, 180)
        XCTAssertEqual(SecondaryQualifier.hue.bounds(full).1, 360)
        secondary.lumaMin = 0.3; secondary.lumaMax = 0.7
        XCTAssertEqual(SecondaryQualifier.luma.editing(secondary, part: 0, value: 1).lumaMin, 0.7)
        XCTAssertEqual(SecondaryQualifier.luma.editing(secondary, part: 1, value: 0).lumaMax, 0.3)
    }
    internal func testEyedropperRangesAppearAndMatteRejectsOutsideLuma() throws {
        let fixture = try setup()
        let panel = fixture.panel, editor = fixture.editor
        let image = CanvasImage(width: 1, height: 1, rgba: [128, 128, 128, 255])
        var secondary = ColorGrading.Secondary()
        XCTAssertTrue(SecondaryColorKey.sample(image, x: 0, y: 0, into: &secondary))
        XCTAssertEqual(secondary.lumaMin, 128.0 / 255 - 0.2, accuracy: 1e-9)
        XCTAssertEqual(secondary.lumaMax, 128.0 / 255 + 0.2, accuracy: 1e-9)
        var grade = ColorGrading(); grade.secondaries = [secondary]
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade)); draw(panel)
        let track = try XCTUnwrap(panel.grade.qualifierTracks["sec:qualifier:luma"])
        for (part, value) in [secondary.lumaMin, secondary.lumaMax].enumerated() {
            let handle = try XCTUnwrap(panel.hits.rect { $0 == .custom("sec:qualifier:luma", part) })
            XCTAssertEqual(handle.midX, track.x + track.width * value, accuracy: 0.001)
        }
        XCTAssertEqual(SecondaryColorKey.matte(CanvasImage(width: 1, height: 1, rgba: [255, 255, 255, 255]), secondary).rgba, [0, 0, 0, 255])
        panel.grade.sampleFrame = image; panel.grade.showMatte = true
        secondary.lumaMin = 0.8; panel.grade.qualifierDraft = secondary; draw(panel)
        XCTAssertEqual(panel.grade.matteMemo?.image.rgba, [0, 0, 0, 255], "matte follows the in-progress range")
    }
    internal func testProjectRoundTripPreservesAuthoredValuesAndOldDefaults() {
        let old = ColorGrading(json: ["secondaries": .array([.object([:])])])
        XCTAssertEqual(old.secondaries[0].satMin, 0); XCTAssertEqual(old.secondaries[0].satMax, 1)
        XCTAssertEqual(old.secondaries[0].lumaMin, 0); XCTAssertEqual(old.secondaries[0].lumaMax, 1)
        var grade = ColorGrading(); var secondary = ColorGrading.Secondary()
        secondary.satMin = 0.123456789; secondary.satMax = 0.987654321; secondary.satSoftness = 0.17
        secondary.lumaMin = 0.22; secondary.lumaMax = 0.77; secondary.lumaSoftness = 0.03
        grade.secondaries = [secondary]
        XCTAssertEqual(ColorGrading(json: grade.json), grade)
        secondary.satMin = -0.1; secondary.lumaMax = 1.1; grade.secondaries = [secondary]
        XCTAssertEqual(ColorGrading(json: grade.json), grade, "loading retains stored values rather than silently clamping")
    }
#if canImport(CoreGraphics)
    internal func testQualifierCapturesAtBothViewportSizesAndAppearances() throws {
        defer { Theme.setMode(.dark) }
        for mode in [ThemeMode.dark, .light] { for size in [(1440, 900), (1280, 800)] {
            Theme.setMode(mode)
            let panel = try setup().panel
            let width = 409.0, height = Double(size.1)
            let first = try XCTUnwrap(panel.hits.rect { $0 == .custom("sec:qualifier:hue", 0) })
            panel.bodyScroll = first.y - 240
            let canvas = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: Int(width), height: size.1))
            canvas.fillRect(CanvasRect(x: 0, y: 0, width: width, height: height), PanelTheme.studioBg)
            panel.draw(canvas, in: CanvasRect(x: 0, y: 0, width: width, height: height))
            for channel in SecondaryQualifier.allCases {
                let rect = try XCTUnwrap(panel.hits.rect { $0 == .custom("sec:qualifier:\(channel.rawValue)", 1) })
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
