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
import OneTakeKeyframes
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import MpvfxPanels
@testable import MpvfxPlayer

#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Issue #284, A3: each starter style painted by the export painter over a white, a black and a mid-grey frame.
final class TextStarterStylesRenderingTests: XCTestCase {
    private func frame(_ style: NativeTextStyle, background: String) throws -> (rgba: [UInt8], width: Int, height: Int) {
        let engine = try KeyframeRuntime()
        let base = try TimelineEditor(json: TimelineEditor.demoJSON, engine: engine)
        var document = base.document
        document.assets = []; document.sequence.tracks = []
        document.canvas.width = 640; document.canvas.height = 360; document.canvas.background = background
        let editor = try TimelineEditor(json: serializeNativeProjectDocument(document, engine: engine), engine: engine)
        let id = try XCTUnwrap(editor.addTextClip(at: 0, content: "Sample", seconds: 2))
        XCTAssertTrue(editor.applyLibraryTextStyle(style, clipIds: [id]), style.name)
        let composition = PreviewComposition(document: editor.document, projectDir: nil, engine: editor.engine)
        let painter = try ExportFramePainter(composition: composition, width: 640, height: 360, pad: CanvasColor(r: 0, g: 0, b: 0))
        let image = try painter.paint(time: 0.5) { _, _, _, _ in nil }
        return (image.rgba, 640, 360)
    }

    func testEveryStyleIsPaintedOnThreeBackgrounds() throws {
        let backgrounds = [("white", "#ffffff", 255), ("black", "#000000", 0), ("grey", "#808080", 128)]
        for style in TextStarterStyles.styles {
            for (name, hex, level) in backgrounds {
                let out = try frame(style, background: hex)
                var changed = 0, strong = 0
                for i in stride(from: 0, to: out.rgba.count, by: 4) {
                    let d = abs(Int(out.rgba[i]) - level) + abs(Int(out.rgba[i + 1]) - level) + abs(Int(out.rgba[i + 2]) - level)
                    if d > 30 { changed += 1 }
                    if d > 300 { strong += 1 }
                }
                XCTAssertGreaterThan(changed, 200, "\(style.name) draws on the \(name) frame")
                // The text or its outline or plate stands well apart from the frame: no style vanishes into it.
                XCTAssertGreaterThan(strong, 50, "\(style.name) stands out on the \(name) frame")
                #if canImport(CoreGraphics)
                if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
                    var bytes = out.rgba
                    let image: CGImage? = bytes.withUnsafeMutableBytes {
                        CGContext(data: $0.baseAddress, width: out.width, height: out.height, bitsPerComponent: 8, bytesPerRow: out.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
                    }
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let slug = style.name.lowercased().replacingOccurrences(of: " ", with: "-")
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("starter-\(slug)-\(name).png")
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, try XCTUnwrap(image), nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                }
                #endif
            }
        }
    }
}
