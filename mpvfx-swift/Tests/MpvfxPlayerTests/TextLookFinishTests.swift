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
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxPlayer

#if os(Linux) || os(Windows) || os(macOS)
/// Text look, second half: glow, background plate and gradient fill.
final class TextLookFinishTests: XCTestCase {
    static let width = 420, height = 340

    func layer(_ look: NativeTextLook?, content: String = "H", size: Double = 200, box: CanvasRect = CanvasRect(x: 60, y: 40, width: 300, height: 260),
               align: String = "center") -> PreviewLayer {
        var l = PreviewLayer(clipId: "t", source: "", kind: .text, start: 0, end: 1, sourceIn: 0, box: box)
        l.text = NativeClipText(content: content, fontSize: size, fontWeight: 700, color: "#ffffff", align: align, look: look)
        return l
    }

    func render(_ l: PreviewLayer) throws -> CanvasImage {
        let c = try RasterCanvas(width: Self.width, height: Self.height)
        c.clear(.transparent)
        PreviewPainter.drawText(l, on: c, frame: CanvasRect(x: 0, y: 0, width: Double(Self.width), height: Double(Self.height)), scale: 1)
        XCTAssertNil(c.drawError)
        return c.image()
    }

    func pixel(_ i: CanvasImage, _ x: Int, _ y: Int) -> [UInt8] { Array(i.rgba[(y * i.width + x) * 4..<(y * i.width + x) * 4 + 4]) }
    func total(_ i: CanvasImage) -> Int { stride(from: 3, to: i.rgba.count, by: 4).reduce(0) { $0 + Int(i.rgba[$1]) } }

    // MARK: plate

    func twoLines(_ plate: NativeTextLook.Plate, content: String = "Line one\nLine two") -> PreviewLayer {
        layer(NativeTextLook(plate: plate), content: content, size: 40, box: CanvasRect(x: 60, y: 40, width: 300, height: 200), align: "left")
    }

    func testA1PlatesOfNeighbouringLinesJoinWithNoBackgroundBetweenThem() throws {
        let plate = NativeTextLook.Plate(paddingX: 14, paddingY: 6, radius: 20, color: "#ff0000")
        let image = try render(twoLines(plate))
        let red: [UInt8] = [255, 0, 0, 255]
        XCTAssertEqual(pixel(image, 50, 33)[3], 0, "above the first plate")
        // Two lines of 48 px start at y 40; the plates grow 6 px past them. A column 3 px inside the left edge sits in the
        // rounded corners of both plates, which alone would leave a notch where the lines meet.
        for y in 50..<126 { XCTAssertEqual(pixel(image, 49, y), red, "row \(y) at x 49") }
        XCTAssertEqual(pixel(image, 46, 34)[3], 0, "the outer corner stays round")
        XCTAssertEqual(pixel(image, 49, 142)[3], 0, "below the last plate")
    }

    func testALineWithNoTextGetsNoPlateAndFarLinesStaySeparate() throws {
        let plate = NativeTextLook.Plate(paddingX: 10, paddingY: 4, color: "#ff0000")
        let image = try render(twoLines(plate, content: "Line one\n\nLine two"))
        XCTAssertEqual(pixel(image, 52, 40 + 24)[3], 255, "the first line has its plate")
        XCTAssertEqual(pixel(image, 52, 40 + 72)[3], 0, "the empty line has none")
        XCTAssertEqual(pixel(image, 52, 40 + 120)[3], 255, "the last line has its plate")
    }

    func testBlockModeDrawsOneRectangleBehindAllLines() throws {
        let long = "A longer line\nShort"
        let line = try render(twoLines(.init(mode: "line", paddingX: 10, paddingY: 0, color: "#ff0000"), content: long))
        let block = try render(twoLines(.init(mode: "block", paddingX: 10, paddingY: 0, color: "#ff0000"), content: long))
        // Right of "Short", still inside the first line's width, on the second line.
        XCTAssertEqual(pixel(line, 250, 40 + 72)[3], 0)
        XCTAssertEqual(pixel(block, 250, 40 + 72), [255, 0, 0, 255])
    }

    func testAPlateGrowsWithPaddingAndKeepsItsAlpha() throws {
        let image = try render(twoLines(.init(paddingX: 20, paddingY: 10, color: "#0000ff80")))
        let p = pixel(image, 45, 60)
        XCTAssertEqual(p[3], 128, accuracy: 1)
        XCTAssertEqual(p[2], 255)
        XCTAssertEqual(pixel(image, 35, 60)[3], 0, "past the 20 px of padding")
    }

    // MARK: gradient

    func gradientLayer(angle: Double) -> PreviewLayer {
        layer(NativeTextLook(fill: .init(from: "#ff0000", to: "#0000ff", angle: angle)), content: "HHHH", size: 100,
              box: CanvasRect(x: 10, y: 20, width: 400, height: 140), align: "left")
    }

    func testA2AZeroDegreeGradientReadsRedAtTheLeftEdgeAndBlueAtTheRightEdge() throws {
        let image = try render(gradientLayer(angle: 0))
        var left: [UInt8]?, right: [UInt8]?
        outer: for x in 0..<image.width { for y in 0..<image.height where pixel(image, x, y)[3] >= 250 { left = pixel(image, x, y); break outer } }
        outer: for x in stride(from: image.width - 1, through: 0, by: -1) { for y in 0..<image.height where pixel(image, x, y)[3] >= 250 { right = pixel(image, x, y); break outer } }
        let l = try XCTUnwrap(left), r = try XCTUnwrap(right)
        XCTAssertGreaterThanOrEqual(Int(l[0]), 253); XCTAssertLessThanOrEqual(Int(l[2]), 2)
        XCTAssertGreaterThanOrEqual(Int(r[2]), 253); XCTAssertLessThanOrEqual(Int(r[0]), 2)
    }

    func testAnAngleOfNinetyDegreesRunsTopToBottom() throws {
        let image = try render(gradientLayer(angle: 90))
        var top: [UInt8]?, bottom: [UInt8]?
        outer: for y in 0..<image.height { for x in 0..<image.width where pixel(image, x, y)[3] >= 250 { top = pixel(image, x, y); break outer } }
        outer: for y in stride(from: image.height - 1, through: 0, by: -1) { for x in 0..<image.width where pixel(image, x, y)[3] >= 250 { bottom = pixel(image, x, y); break outer } }
        XCTAssertGreaterThanOrEqual(Int(try XCTUnwrap(top)[0]), 245, "the letters are about 70 px tall, so the first opaque row is a few levels in")
        XCTAssertGreaterThanOrEqual(Int(try XCTUnwrap(bottom)[2]), 245)
    }

    func testAGradientKeepsItsColoursWhileTheTextRevealsLeftToRight() throws {
        let look = NativeTextLook(fill: .init(from: "#ff0000", to: "#0000ff"))
        var whole = gradientLayer(angle: 0)
        let still = try render(whole)
        whole.text?.reveal = NativeTextReveal(unit: "characters", staggerFrames: 10, unitFrames: 4)
        whole.textFrame = TextRevealFrame(frame: 12, clipFrames: 120, fps: 30)
        whole.text?.look = look
        let part = try render(whole)
        // The first letter is shown in both; the colour of its pixels does not change as the others arrive.
        var compared = 0
        for y in 0..<still.height { for x in 0..<120 where pixel(part, x, y)[3] == 255 && pixel(still, x, y)[3] == 255 {
            XCTAssertEqual(Int(pixel(part, x, y)[0]), Int(pixel(still, x, y)[0]), accuracy: 1); compared += 1
        } }
        XCTAssertGreaterThan(compared, 100)
    }

    // MARK: glow

    func testA3AGlowOfStrengthZeroRendersIdenticalToNoGlow() throws {
        let outline = NativeTextLook.Outline(width: 4, color: "#000000")
        let none = try render(layer(NativeTextLook(outlines: [outline])))
        let zero = try render(layer(NativeTextLook(outlines: [outline], glow: .init(radius: 20, strength: 0, color: "#ff00ff"))))
        XCTAssertEqual(none, zero)
        let plain = try render(layer(nil))
        XCTAssertEqual(try render(layer(NativeTextLook(glow: .init(radius: 20, strength: 0, color: "#ff00ff")))), plain, "a lone idle glow is no look at all")
    }

    func testAGlowSpreadsPastTheLettersAndScalesWithItsStrength() throws {
        let plain = try render(layer(nil))
        let full = try render(layer(NativeTextLook(glow: .init(radius: 24, strength: 1, color: "#00ff00"))))
        let half = try render(layer(NativeTextLook(glow: .init(radius: 24, strength: 0.5, color: "#00ff00"))))
        XCTAssertGreaterThan(total(full), total(plain) + 5000)
        XCTAssertGreaterThan(total(full), total(half))
        XCTAssertGreaterThan(total(half), total(plain))
        // Just past the left stem of the H, away from its crossbar, the halo is green and the letters stay white.
        var edge = 0
        for x in 0..<Self.width where pixel(plain, x, 100)[3] > 250 { edge = x; break }
        let beside = pixel(full, edge - 3, 100)
        XCTAssertGreaterThan(beside[3], 60); XCTAssertGreaterThan(beside[1], beside[0])
        XCTAssertEqual(pixel(full, edge + 4, 100), [255, 255, 255, 255])
    }

    // MARK: compositor

    func testTheCompositorJoinsPlateRectanglesWithoutSeamsAndRoundsTheirCorners() {
        let rects = [TextLookCompositor.PlateRect(rect: CanvasRect(x: 10, y: 10, width: 40, height: 20), radius: 8),
                     TextLookCompositor.PlateRect(rect: CanvasRect(x: 10, y: 30, width: 40, height: 20), radius: 8)]
        let c = TextLookCompositor.plateCoverage(rects, width: 60, height: 60)
        XCTAssertEqual(c[20 * 60 + 30], 1); XCTAssertEqual(c[40 * 60 + 30], 1)
        XCTAssertEqual(c[10 * 60 + 10], 0, "the outer corner of a rounded plate is empty")
        XCTAssertEqual(c[0], 0)
    }

    // MARK: preview = export

    func testA4PreviewAndExportAgreeWithinOneLevelForGlowPlateAndGradient() throws {
        let engine = try KeyframeRuntime()
        let look = ##"{"v":1,"glow":{"radius":6,"strength":0.8,"color":"#00ffffcc"},"plate":{"paddingX":8,"paddingY":4,"radius":6,"color":"#102030c0"},"fill":{"from":"#ff8800","to":"#0044ff","angle":30},"outlines":[{"width":2,"color":"#000000"}]}"##

        let raw = try NativeJSONValue.parse(
            """
            {"schemaVersion":1,"mediaEngine":"native","id":"project:look","revision":0,
            "frameRate":{"numerator":30,"denominator":1},"canvas":{"width":320,"height":180,"background":"#202020"},
            "assets":[{"id":"asset:title","kind":"element","name":"Title","durationFrames":60}],
            "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:1","kind":"video","clips":[
            {"id":"clip:title","assetId":"asset:title","startFrame":0,"durationFrames":60,"sourceInFrame":0,
            "staticParameters":{"layout.left":10,"layout.top":10,"layout.width":300,"layout.height":160},
            "text":{"content":"Look\\nfinish","fontSize":44,"color":"#ffffff","align":"center","look":\(look),
            "reveal":{"v":1,"unit":"characters","staggerFrames":2,"unitFrames":6}},"effects":[],"parameterTracks":[]}]}]}}
            """)
        let composition = PreviewComposition(document: try parseNativeProjectDocument(raw, engine: engine), projectDir: nil, engine: engine)
        let painter = try ExportFramePainter(composition: composition, width: 320, height: 180, pad: .transparent)
        for frame in [0, 9, 25, 50] {
            let time = Double(frame) / 30
            let exported = try painter.paint(time: time) { _, _, _, _ in nil }
            let canvas = try RasterCanvas(width: 320, height: 180)
            canvas.clear(CanvasColor(hex: "#202020") ?? .transparent)
            for l in composition.layers(at: time) where l.kind == .text {
                PreviewPainter.drawText(l, on: canvas, frame: CanvasRect(x: 0, y: 0, width: 320, height: 180), scale: 1)
            }
            let worst = zip(canvas.image().rgba, exported.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1, "frame \(frame)")
        }
        XCTAssertTrue(try XCTUnwrap(composition.layers(at: 0).first { $0.kind == .text }?.text?.look?.isSupported))
    }
}
#endif
