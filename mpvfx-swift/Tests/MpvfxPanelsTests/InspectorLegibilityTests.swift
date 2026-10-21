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
import MpvfxTimeline
@testable import MpvfxPanels
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

final class InspectorLegibilityTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func testDesignFontFloorAndHierarchy() throws {
        let dir = ThemeTokensTestsPath.panels
        let pattern = try NSRegularExpression(pattern: #"PanelTheme\.(?:font|mono)\((\d+(?:\.\d+)?)"#)
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("InspectorPanel") && url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for m in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(m.range(at: 1), in: source))
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(Double(source[range])), 11, url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(PanelTheme.inspectorSectionSize, PanelTheme.inspectorHintSize)
        XCTAssertLessThan(PanelTheme.inspectorSectionSize, 12, "group titles remain larger")
    }

    func testDesignGroupsAtBothWindowSizesAndAppearances() throws {
        for mode in ThemeMode.allCases {
            Theme.setMode(mode)
            for (w, h) in [(1440.0, 900.0), (1280.0, 800.0)] {
                let width = PanelFit.fit(w, PanelFit.defaults(w)).right
                for (name, group, scroll) in [("grade", "grade", 0.0), ("grade-primary", "grade", 650.0),
                    ("grade-wheels", "grade", 1100.0), ("grade-curves", "grade", 1550.0),
                    ("grade-detail", "grade", 2100.0), ("grade-scopes", "grade", 0.0), ("effects", "effects", 0.0),
                    ("effects-active", "effects", 0.0), ("layout", "layout", 0.0), ("media", "media", 0.0)] {
                    let p = InspectorPanel()
                    p.editor = try TimelineEditor(json: TimelineEditor.demoJSON)
                    p.selection = ["clip:a"]
                    p.openGroupId = group
                    p.bodyScroll = scroll
                    p.grade.scopesOpen = name == "grade-scopes"
                    if name == "effects-active", let editor = p.editor {
                        var grade = editor.gradeShown(clipId: "clip:a", time: 0)
                        grade.effects["blur"] = 0.2
                        editor.setColorGrading(clipId: "clip:a", grade)
                    }
                    let canvas = PanelMeasureCanvas()
                    p.draw(canvas, in: CanvasRect(x: 0, y: 0, width: width, height: h))
                    XCTAssertFalse(canvas.texts.isEmpty)
                    if name == "grade-primary" || name == "grade-wheels" {
                        XCTAssertTrue(canvas.fills.contains { $0.1 == PanelTheme.inspectorControl }, "sliders draw the essential edge token")
                    }
                    for (text, _, font, _) in canvas.texts {
                        XCTAssertGreaterThanOrEqual(font.size, 11, "\(group): \(text)")
                    }
                    #if canImport(CoreGraphics)
                    if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                        let rendered = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: Int(width), height: Int(h)))
                        p.draw(rendered, in: CanvasRect(x: 0, y: 0, width: width, height: h))
                        let image = try XCTUnwrap(rendered.ctx.makeImage())
                        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        let path = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode)-\(Int(w))x\(Int(h)).png")
                        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil))
                        CGImageDestinationAddImage(destination, image, nil)
                        XCTAssertTrue(CGImageDestinationFinalize(destination))
                    }
                    #endif
                }
            }
        }
    }
}

private enum ThemeTokensTestsPath {
    static let panels = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MpvfxPanels")
}
