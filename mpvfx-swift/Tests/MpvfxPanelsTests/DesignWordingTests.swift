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
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxTheme
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

final class DesignWordingTests: XCTestCase {
    func inspector(text: Bool = false) throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        let panel = InspectorPanel()
        panel.editor = editor
        panel.selection = [text ? try XCTUnwrap(editor.addTextClip(at: 1)) : "clip:a"]
        panel.time = 1
        return (panel, editor)
    }

    func testHumanSummariesAndTemperatureKeepDocumentKeys() {
        XCTAssertEqual(InspectorPanel.styleSummary(nil, opacityPercent: 100), "Fill none · 100%")
        var grade = ColorGrading()
        grade.preset = "warm-daylight"
        XCTAssertEqual(InspectorPanel.gradeSummary(grade), "Warm Daylight · 100%")
        grade.intensity = 0.5
        XCTAssertEqual(InspectorPanel.gradeSummary(grade), "Warm Daylight · 50%")
        grade.enabled = false
        XCTAssertEqual(InspectorPanel.gradeSummary(grade), "Off")
        XCTAssertEqual(ColorGrading.adjustSliders.first { $0.key == "temperature" }?.label, "Temperature")
    }

    func testRotationIsShownOnlyOnceAndSummariesAreNamed() throws {
        let (panel, _) = try inspector()
        panel.transform3DOpen = true
        let canvas = PanelMeasureCanvas()
        panel.draw(canvas, in: CanvasRect(x: 0, y: 0, width: 409, height: 1800))
        XCTAssertEqual(canvas.drawnStrings.filter { $0 == "Rotation" }.count, 1)
        XCTAssertFalse(canvas.drawnStrings.contains("Roll"))
        XCTAssertTrue(canvas.drawnStrings.contains("3D transform"))
        XCTAssertTrue(panel.groups.first { $0.id == "layout" }?.summary.hasPrefix("X ") == true)
    }

    func testTextIconsExposeNamesTooltipsAndExistingCommands() throws {
        let (panel, editor) = try inspector(text: true)
        panel.openGroupId = "text"
        let canvas = PanelMeasureCanvas()
        let rect = CanvasRect(x: 0, y: 0, width: 409, height: 1600)
        panel.draw(canvas, in: rect)
        for name in ["Align left", "Align center", "Align right", "Justify", "Original case", "Uppercase", "Lowercase", "Capitalize", "Regular", "Italic"] {
            let control = try XCTUnwrap(panel.accessibilityControls.first { $0.label == name }, name)
            XCTAssertGreaterThan(control.frame.width, 0)
        }
        let upper = try XCTUnwrap(panel.namedIconControls.first { $0.label == "Uppercase" })
        panel.hovered = upper.hit
        canvas.reset(); panel.draw(canvas, in: rect)
        XCTAssertTrue(canvas.drawnStrings.contains("Uppercase"), "hover tooltip names the icon")
        upper.press()
        XCTAssertEqual(editor.clip(try XCTUnwrap(panel.selection.first))?.clip.text?.resolvedTransform, "uppercase")
    }

    func testCropResetHasNamedIconAndRestoresCrop() throws {
        let (panel, editor) = try inspector()
        panel.openGroupId = "media"
        panel.cropActive = "clip:a"
        _ = editor.setCrop(clipId: "clip:a", NativeClipCrop(top: 12))
        panel.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 1800))
        let reset = try XCTUnwrap(panel.accessibilityControls.first { $0.label == "Reset crop" })
        reset.press()
        XCTAssertTrue(editor.crop(clipId: "clip:a")?.isZero ?? true)
    }

    /// Offscreen native panel captures, at the panel widths used by both requested window sizes.
    func testCaptureDesignWording() throws {
        #if canImport(CoreGraphics)
        guard let directory = ProcessInfo.processInfo.environment["MPVFX_WORDING_CAPTURES"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { Theme.setMode(.dark) }
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            for (width, height) in [(1440, 900), (1280, 800)] {
                for group in ["text", "layout", "grade", "media", "effects"] {
                    let (panel, editor) = try inspector(text: group == "text")
                    panel.openGroupId = group
                    panel.transform3DOpen = true
                    if group == "media" { panel.cropActive = "clip:a" }
                    var grade = ColorGrading(); grade.preset = "warm-daylight"
                    _ = editor.setColorGrading(clipId: "clip:a", grade)
                    let canvas = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: width, height: height))
                    canvas.fillRect(CanvasRect(x: 0, y: 0, width: Double(width), height: Double(height)), PanelTheme.studioBg)
                    if group == "grade" {
                        panel.draw(PanelMeasureCanvas(), in: CanvasRect(x: Double(width - 409), y: 0, width: 409, height: 5000))
                        let primary = try XCTUnwrap(panel.hits.rect { $0 == .slider("grade:adj:exposure") })
                        panel.bodyScroll = max(0, primary.y - 220)
                    }
                    panel.draw(canvas, in: CanvasRect(x: Double(width - 409), y: 0, width: 409, height: Double(height)))
                    let name = "\(group)-\(mode == .dark ? "dark" : "light")-\(width)x\(height).png"
                    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, try XCTUnwrap(canvas.ctx.makeImage()), nil)
                    XCTAssertTrue(CGImageDestinationFinalize(dest))
                }
            }
        }
        #endif
    }
}
