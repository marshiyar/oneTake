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
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared

/// Text look: outlines and a drop shadow built from the letters' coverage, drawn by the preview painter (and so by export).
final class TextLookTests: XCTestCase {
    func square(_ n: Int, _ size: Int, at origin: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: n * n)
        for y in origin..<origin + size { for x in origin..<origin + size { c[y * n + x] = 255 } }
        return c
    }

    func pixel(_ rgba: [UInt8], _ n: Int, _ x: Int, _ y: Int) -> [UInt8] { Array(rgba[(y * n + x) * 4..<(y * n + x) * 4 + 4]) }

    func testAnOutlineIsExactlyItsWidthOutsideTheLetterEdgeAndRoundAtCorners() {
        let n = 100
        let out = TextLookCompositor.compose(coverage: square(n, 20, at: 40), width: n, height: n, fill: CanvasColor(r: 1, g: 1, b: 1),
                                             bands: [.init(reach: 10, color: CanvasColor(r: 0, g: 0, b: 0))], shadow: nil)
        let row = (0..<n).map { pixel(out, n, $0, 50) }
        let black = row.filter { ($0[3] > 250) && $0[0] < 5 }.count, white = row.filter { $0[0] > 250 && $0[3] > 250 }.count
        XCTAssertEqual(white, 20)
        XCTAssertEqual(black, 20, accuracy: 2, "10 px each side")
        XCTAssertEqual(pixel(out, n, 30, 50)[3], 255, "the tenth pixel out from the edge")
        XCTAssertEqual(pixel(out, n, 29, 50)[3], 0, "past the band")
        XCTAssertEqual(pixel(out, n, 31, 31)[3], 0, "the corner is round: the diagonal reaches 10 px only along a quarter circle")
        XCTAssertEqual(pixel(out, n, 33, 33)[3], 255, "inside the arc")
    }

    func testTwoOutlinesStackAndAShadowSitsUnderTheLetters() {
        let n = 120
        let out = TextLookCompositor.compose(coverage: square(n, 20, at: 40), width: n, height: n, fill: CanvasColor(r: 1, g: 1, b: 1),
                                             bands: [.init(reach: 4, color: CanvasColor(r: 1, g: 0, b: 0)), .init(reach: 8, color: CanvasColor(r: 0, g: 0, b: 1))],
                                             shadow: .init(dx: 12, dy: 12, blur: 0, color: CanvasColor(r: 0, g: 1, b: 0)))
        XCTAssertEqual(pixel(out, n, 50, 50), [255, 255, 255, 255])
        XCTAssertEqual(pixel(out, n, 38, 50), [255, 0, 0, 255], "inner outline next to the letter")
        XCTAssertEqual(pixel(out, n, 33, 50), [0, 0, 255, 255], "outer outline beyond it")
        XCTAssertEqual(pixel(out, n, 70, 70), [0, 255, 0, 255], "shadow offset 12, past the outlines")
        XCTAssertEqual(pixel(out, n, 20, 20)[3], 0)
    }

    func testShadowBlurSpreadsAndKeepsTheTotalAlpha() {
        let n = 100
        let hard = TextLookCompositor.compose(coverage: square(n, 20, at: 40), width: n, height: n, fill: CanvasColor(r: 1, g: 1, b: 1, a: 0), bands: [],
                                              shadow: .init(dx: 0, dy: 0, blur: 12, color: CanvasColor(r: 0, g: 0, b: 0)))
        let total = stride(from: 3, to: hard.count, by: 4).reduce(0) { $0 + Int(hard[$1]) }
        XCTAssertEqual(Double(total) / 255, 400, accuracy: 8, "blur moves alpha, it does not create or lose it")
        XCTAssertGreaterThan(pixel(hard, n, 36, 50)[3], 0, "alpha reaches outside the letter")
        XCTAssertLessThan(pixel(hard, n, 50, 50)[3], 255)
    }

    #if os(Linux) || os(Windows) || os(macOS)
    func layer(look: NativeTextLook?, size: Double = 200) -> PreviewLayer {
        var l = PreviewLayer(clipId: "t", source: "", kind: .text, start: 0, end: 1, sourceIn: 0, box: CanvasRect(x: 60, y: 40, width: 300, height: 260))
        l.text = NativeClipText(content: "H", fontSize: size, fontWeight: 700, color: "#ffffff", align: "center", look: look)
        return l
    }

    func rasterized(_ l: PreviewLayer) throws -> CanvasImage {
        let c = try RasterCanvas(width: 420, height: 340)
        c.clear(.transparent)
        PreviewPainter.drawText(l, on: c, frame: CanvasRect(x: 0, y: 0, width: 420, height: 340), scale: 1)
        XCTAssertNil(c.drawError)
        return c.image()
    }

    func testATenPixelBlackOutlineAroundAWhiteHReadsTenPixelsEachSideOfTheStem() throws {
        let look = NativeTextLook(outlines: [.init(width: 10, color: "#000000")])
        let img = try rasterized(layer(look: look))
        let plain = try rasterized(layer(look: nil))
        let y = 170
        func run(_ i: CanvasImage, _ test: (ArraySlice<UInt8>) -> Bool) -> [Int] {
            (0..<i.width).filter { test(i.rgba[(y * i.width + $0) * 4..<(y * i.width + $0) * 4 + 4]) }
        }
        let white = run(plain) { $0[$0.startIndex] > 200 && $0[$0.startIndex + 3] > 200 }
        let stemStart = try XCTUnwrap(white.first)
        var stemEnd = stemStart
        while white.contains(stemEnd + 1) { stemEnd += 1 }
        let blackLeft = run(img) { $0[$0.startIndex] < 60 && $0[$0.startIndex + 3] > 200 }.filter { $0 < stemStart }.count
        let blackRight = run(img) { $0[$0.startIndex] < 60 && $0[$0.startIndex + 3] > 200 }.filter { $0 > stemEnd && $0 < stemEnd + 30 }.count
        XCTAssertEqual(blackLeft, 10, accuracy: 1)
        XCTAssertEqual(blackRight, 10, accuracy: 1)
    }

    func testALayerWithoutALookIsDrawnExactlyAsBefore() throws {
        let a = try rasterized(layer(look: nil))
        let b = try rasterized(layer(look: NativeTextLook()))
        XCTAssertEqual(a, b, "an empty look draws the plain fill")
        let c = try RasterCanvas(width: 420, height: 340); c.clear(.transparent)
        let l = layer(look: nil)
        TextLayout.draw(NativeTextRendering.block(try XCTUnwrap(l.text), scale: 1), in: l.box, on: c)
        XCTAssertEqual(c.image(), a)
    }

    func testAShadowAndAnUnsupportedLook() throws {
        let shadowed = try rasterized(layer(look: NativeTextLook(shadow: .init(x: 30, y: 30, blur: 0, color: "#ff0000"))))
        let plain = try rasterized(layer(look: nil))
        let red = stride(from: 0, to: shadowed.rgba.count, by: 4).filter { shadowed.rgba[$0] > 200 && shadowed.rgba[$0 + 1] < 60 && shadowed.rgba[$0 + 3] > 200 }.count
        XCTAssertGreaterThan(red, 500)
        let future = try JSONDecoder().decode(NativeTextLook.self, from: Data(##"{"v":9,"outlines":[]}"##.utf8))
        XCTAssertEqual(try rasterized(layer(look: future)), plain, "a look from a newer version is not drawn")
    }

    func testPreviewCanvasAndExportCanvasAgreeWithinOneLevel() throws {
        let look = NativeTextLook(outlines: [.init(width: 6, color: "#102030")], shadow: .init(x: 5, y: 7, blur: 6, color: "#000000c0"))
        let l = layer(look: look, size: 120)
        let exported = try rasterized(l)
        #if os(Linux)
        let target = CairoImageTarget(width: 420, height: 340)
        PreviewPainter.drawText(l, on: target.canvas, frame: CanvasRect(x: 0, y: 0, width: 420, height: 340), scale: 1)
        let previewed = target.straightRGBA()
        // Compared premultiplied: Cairo stores premultiplied pixels, so its straight readback of a faint pixel is
        // off by up to 255 / alpha / 2 in colour while the picture is the same.
        var worst = 0
        var at = (0, 0, 0, 0)
        for i in 0..<previewed.count {
            let a = Int(previewed[i - i % 4 + 3])
            let d = i % 4 == 3 ? abs(Int(previewed[i]) - Int(exported.rgba[i]))
                : abs(Int(previewed[i]) * a - Int(exported.rgba[i]) * Int(exported.rgba[i - i % 4 + 3])) / 255
            if d > worst { worst = d; at = (i / 4 % 420, i / 4 / 420, i % 4, a) }
        }
        XCTAssertLessThanOrEqual(worst, 1, "\(at)")
        #endif
        XCTAssertGreaterThan(exported.rgba.count, 0)
    }
    #endif
}
