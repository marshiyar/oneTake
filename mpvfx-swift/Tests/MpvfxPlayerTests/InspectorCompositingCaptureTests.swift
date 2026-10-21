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
import Foundation
import MpvfxCanvas
import MpvfxPanels
import MpvfxTimeline
import MpvfxTheme
import MpvfxShared
import OneTakeKeyframes
#if os(macOS)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
@testable import MpvfxPlayer

final class InspectorCompositingCaptureTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func save(_ image: CanvasImage, name: String) throws {
        #if os(macOS)
        guard let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(image.rgba) as CFData))
        let cg = try XCTUnwrap(CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
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
                for size in [CanvasSize(1440, 900), CanvasSize(1280, 800)] {
                    let c = try RasterCanvas(width: Int(size.width), height: Int(size.height))
                    c.clear(PanelTheme.studioBg)
                    for (i, group) in ["layout", "style", "media"].enumerated() {
                        let panel = InspectorPanel(); panel.editor = editor; panel.selection = ["clip:a"]; panel.openGroupId = group
                        panel.draw(c, in: CanvasRect(x: Double(i) * 409, y: 36, width: 409, height: size.height - 36))
                    }
                    let toolbar = PreviewToolbar(); toolbar.onToggleRecording = {}
                    toolbar.draw(c, width: size.width, cropAvailable: true, cropActive: false)
                    XCTAssertNil(c.drawError)
                    try save(c.image(), name: "design-\(Int(size.width))x\(Int(size.height))-\(light ? "light" : "dark")-\(keyed ? "keyed" : "static")")
                }
            }
        }
    }

    func testRecordLabelAndDotUseTheSameLineAtBothScales() throws {
        for scale in [1.0, 2.0] {
            let c = try RasterCanvas(width: Int(180 * scale), height: Int(36 * scale))
            c.clear(.opaqueBlack); c.scale(scale, scale)
            let toolbar = PreviewToolbar(); toolbar.onToggleRecording = {}
            let rect = toolbar.recordRect(c)
            toolbar.drawRecord(c, rect)
            XCTAssertNil(c.drawError)
            let image = c.image()
            // Read actual text ink separately from the red dot and neutral button fill.
            var dotYs: [Int] = [], textYs: [Int] = []
            for y in 0..<image.height { for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                let r = Int(image.rgba[i]), g = Int(image.rgba[i + 1]), b = Int(image.rgba[i + 2])
                if Double(x) < 25 * scale && r > 150 && r > g * 2 { dotYs.append(y) }
                // The lower-case e/c/o run measures the x-height, omitting R and the d ascender.
                if Double(x) >= 38 * scale && Double(x) < 58 * scale && min(r, min(g, b)) > 140 { textYs.append(y) }
            } }
            let dotMin = try XCTUnwrap(dotYs.min()), dotMax = try XCTUnwrap(dotYs.max())
            let textMin = try XCTUnwrap(textYs.min()), textMax = try XCTUnwrap(textYs.max())
            XCTAssertEqual(Double(dotMin + dotMax) / (2 * scale), Double(textMin + textMax) / (2 * scale), accuracy: 0.5)
            try save(image, name: "record-\(Int(scale))x")
        }
    }
}
