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
import MpvfxCanvas
@testable import MpvfxPanels
import MpvfxTheme
import MpvfxTimeline
import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

internal final class InspectorLegibilityTests: XCTestCase {
    private var previousMode: ThemeMode = .dark
    private static let panelsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MpvfxPanels")

    internal override func setUp() {
        super.setUp()
        previousMode = Theme.mode
    }

    internal override func tearDown() {
        Theme.setMode(previousMode)
        super.tearDown()
    }

    internal func testDesignFontFloorAndHierarchy() throws {
        let dir = Self.panelsDirectory
        let pattern = try NSRegularExpression(pattern: #"PanelTheme\.(?:font|mono)\((\d+(?:\.\d+)?)"#)
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("InspectorPanel") && url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: source))
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(Double(source[range])), 11, url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(PanelTheme.inspectorSectionSize, PanelTheme.inspectorHintSize)
        XCTAssertLessThan(PanelTheme.inspectorSectionSize, 12, "group titles remain larger")
    }

    internal func testDesignGroupsAtBothWindowSizesAndAppearances() throws {
        for mode in ThemeMode.allCases {
            Theme.setMode(mode)
            for (windowWidth, windowHeight) in [(1_440.0, 900.0), (1_280.0, 800.0)] {
                let width = PanelFit.fit(windowWidth, PanelFit.defaults(windowWidth)).right
                for (name, group, scroll) in [("grade", "grade", 0.0), ("grade-primary", "grade", 650.0),
                    ("grade-wheels", "grade", 1_100.0), ("grade-curves", "grade", 1_550.0),
                    ("grade-detail", "grade", 2_100.0), ("grade-scopes", "grade", 0.0), ("effects", "effects", 0.0),
                    ("effects-active", "effects", 0.0), ("layout", "layout", 0.0), ("media", "media", 0.0)] {
                    let panel = InspectorPanel()
                    panel.editor = try TimelineEditor(json: TimelineEditor.demoJSON)
                    panel.selection = ["clip:a"]
                    panel.openGroupId = group
                    panel.bodyScroll = scroll
                    panel.grade.scopesOpen = name == "grade-scopes"
                    if name == "effects-active", let editor = panel.editor {
                        var grade = editor.gradeShown(clipId: "clip:a", time: 0)
                        grade.effects["blur"] = 0.2
                        editor.setColorGrading(clipId: "clip:a", grade)
                    }
                    let canvas = PanelMeasureCanvas()
                    panel.draw(canvas, in: CanvasRect(x: 0, y: 0, width: width, height: windowHeight))
                    XCTAssertFalse(canvas.texts.isEmpty)
                    if name == "grade-primary" || name == "grade-wheels" {
                        let drawsControlEdge = canvas.fills.contains { $0.1 == PanelTheme.inspectorControl }
                        XCTAssertTrue(drawsControlEdge, "sliders draw the essential edge token")
                    }
                    for (text, _, font, _) in canvas.texts {
                        XCTAssertGreaterThanOrEqual(font.size, 11, "\(group): \(text)")
                    }
                    #if canImport(CoreGraphics)
                    if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                        let rendered = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: Int(width), height: Int(windowHeight)))
                        panel.draw(rendered, in: CanvasRect(x: 0, y: 0, width: width, height: windowHeight))
                        let image = try XCTUnwrap(rendered.ctx.makeImage())
                        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        let path = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode)-\(Int(windowWidth))x\(Int(windowHeight)).png")
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
