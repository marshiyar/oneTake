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
import MpvfxPanels
import MpvfxShared
import MpvfxTheme
import MpvfxTimeline
import OneTakeKeyframes
import XCTest

@testable import MpvfxPlayer



#if os(macOS)
    import CoreGraphics
    import ImageIO
    import UniformTypeIdentifiers
#endif

internal final class InspectorCompositingCaptureTests: XCTestCase {
    private var initialTheme: ThemeMode = .dark

    internal override func setUp() {
        super.setUp()
        initialTheme = Theme.mode
    }

    internal override func tearDown() {
        Theme.setMode(initialTheme)
        super.tearDown()
    }

    private func save(_ image: CanvasImage, name: String) throws {
        #if os(macOS)
            guard let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] else {
                return
            }
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let provider = try XCTUnwrap(CGDataProvider(data: Data(image.rgba) as CFData))
            let graphicsImage = try XCTUnwrap(
                CGImage(
                    width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
            let dest = try XCTUnwrap(
                CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, graphicsImage, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        #endif
    }

    func testDesignCapturesWithAndWithoutKeysInBothAppearances() throws {
        for light in [false, true] {
            Theme.setMode(light ? .light : .dark)
            for keyed in [false, true] {
                let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
                if keyed {
                    XCTAssertTrue(editor.keyProperties(clipIds: ["clip:a"], time: 0, animatedOnly: false))
                }
                for size in [CanvasSize(1_440, 900), CanvasSize(1_280, 800)] {
                    let canvas = try RasterCanvas(width: Int(size.width), height: Int(size.height))
                    canvas.clear(PanelTheme.studioBg)
                    for (index, group) in ["layout", "style", "media"].enumerated() {
                        let panel = InspectorPanel()
                        panel.editor = editor
                        panel.selection = ["clip:a"]
                        panel.openGroupId = group
                        panel.draw(
                            canvas, in: CanvasRect(x: Double(index) * 409, y: 36, width: 409, height: size.height - 36))
                    }
                    let toolbar = PreviewToolbar()
                    toolbar.onToggleRecording = { /* Captures require no recording side effect. */  }
                    toolbar.draw(canvas, width: size.width, cropAvailable: true, cropActive: false)
                    XCTAssertNil(canvas.drawError)
                    try save(
                        canvas.image(),
                        name:
                            "design-\(Int(size.width))x\(Int(size.height))-\(light ? "light" : "dark")-\(keyed ? "keyed" : "static")"
                    )
                }
            }
        }
    }

    func testRecordLabelAndDotUseTheSameLineAtBothScales() throws {
        for scale in [1.0, 2.0] {
            let canvas = try RasterCanvas(width: Int(180 * scale), height: Int(36 * scale))
            canvas.clear(.opaqueBlack)
            canvas.scale(scale, scale)
            let toolbar = PreviewToolbar()
            toolbar.onToggleRecording = { /* Captures require no recording side effect. */  }
            let rect = toolbar.recordRect(canvas)
            toolbar.drawRecord(canvas, rect)
            XCTAssertNil(canvas.drawError)
            let image = canvas.image()
            // Read actual text ink separately from the red dot and neutral button fill.
            var dotYs: [Int] = []
            var textYs: [Int] = []
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let i = (y * image.width + x) * 4
                    let r = Int(image.rgba[i])
                    let g = Int(image.rgba[i + 1])
                    let b = Int(image.rgba[i + 2])
                    if Double(x) < 25 * scale && r > 150 && r > g * 2 { dotYs.append(y) }
                    // The lower-case e/c/o run measures the x-height, omitting R and the d ascender.
                    if Double(x) >= 38 * scale && Double(x) < 58 * scale && min(r, min(g, b)) > 140 { textYs.append(y) }
                }
            }
            let dotMin = try XCTUnwrap(dotYs.min())
            let dotMax = try XCTUnwrap(dotYs.max())
            let textMin = try XCTUnwrap(textYs.min())
            let textMax = try XCTUnwrap(textYs.max())
            XCTAssertEqual(
                Double(dotMin + dotMax) / (2 * scale), Double(textMin + textMax) / (2 * scale), accuracy: 0.5)
            try save(image, name: "record-\(Int(scale))x")
        }
    }
}
