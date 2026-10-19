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
import MpvfxTimeline

/// A tall or square composition previews at its own aspect: the stage frame is letterboxed in the viewport (bars
/// left and right, not a stretched 16:9 frame) and a square picture stays square inside it.
final class PortraitPreviewTests: XCTestCase {
    static func document(width: Int, height: Int) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"project:tall","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":\#(width),"height":\#(height),"background":"#102030"},
         "assets":[{"id":"i","kind":"image","name":"i.png","source":"i.png","durationFrames":100,"width":1080,"height":1080}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"t1","kind":"video","clips":[
           {"id":"img","assetId":"i","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    func assertFrame(_ w: Double, _ h: Double, file: StaticString = #filePath, line: UInt = #line) {
        let v = PlayerView(playback: PlaybackState(duration: 1))
        let size = CanvasSize(900, 700)
        v.canvasSize = CanvasSize(w, h)
        let f = v.frameRect(in: size), vp = v.viewportRect(in: size)
        XCTAssertEqual(f.width / f.height, w / h, accuracy: 0.01, "\(w)×\(h)", file: file, line: line)
        XCTAssertTrue(f.maxY <= vp.maxY && f.y >= vp.y, "inside the viewport", file: file, line: line)
        XCTAssertEqual(f.midX, size.width / 2, accuracy: 1, "centred", file: file, line: line)
    }

    func testStageFrameFollowsTheCompositionAspect() {
        assertFrame(1080, 1920); assertFrame(1080, 1080); assertFrame(1080, 1350); assertFrame(1920, 1080)
    }

    #if os(Linux)   // Cairo draws real pixels; the macOS (Core Graphics) drawing is not checked here.
    /// The preview of a `w`×`h` composition holding one untouched 1080×1080 red still, drawn by PlayerView through
    /// the compositor at 900×700: the pixels, the stage frame, and the red square's extent through the frame's centre.
    func preview(_ w: Int, _ h: Int) throws -> (t: CairoImageTarget, frame: CanvasRect, redW: Int, redH: Int) {
        let doc = try Self.document(width: w, height: h)
        let comp = PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil, fileExists: { _ in true })
        let cx = PreviewCompositor(decodesMedia: false)
        cx.composition = comp
        let layer = try XCTUnwrap(comp.layers(at: 0.05).first)
        cx.cache.store(PreviewCompositorTests.solid(255, 0, 0, w: 8, h: 8), lane: layer.laneKey, frame: PreviewDecodeLane.stillFrame)
        let v = PlayerView(playback: PlaybackState(duration: 1))
        v.canvasSize = CanvasSize(Double(w), Double(h))
        v.frameSource = cx
        let size = CanvasSize(900, 700)
        let t = CairoImageTarget(width: 900, height: 700)
        v.draw(t.canvas, size: size)
        func isRed(_ x: Int, _ y: Int) -> Bool { let p = t.pixel(x, y); return p.r > 200 && p.g < 40 && p.b < 40 }
        let f = v.frameRect(in: size)
        let xs = (Int(f.x) - 2...Int(f.maxX) + 2).filter { isRed($0, Int(f.midY)) }
        let ys = (Int(f.y) - 2...Int(f.maxY) + 2).filter { isRed(Int(f.midX), $0) }
        return (t, f, (xs.last ?? 0) - (xs.first ?? 0) + 1, (ys.last ?? 0) - (ys.first ?? 0) + 1)
    }
    func rgb(_ t: CairoImageTarget, _ x: Double, _ y: Double) -> [Int] { let p = t.pixel(Int(x), Int(y)); return [Int(p.r), Int(p.g), Int(p.b)] }

    func testPortraitPreviewIsLetterboxedAndNotSquashed() throws {
        let p = try preview(1080, 1920)
        XCTAssertEqual(p.frame.width / p.frame.height, 1080.0 / 1920, accuracy: 0.01)
        XCTAssertLessThan(p.frame.width, 900 - 100, "a tall frame leaves bars left and right")
        XCTAssertEqual(Double(p.redW), p.frame.width, accuracy: 2, "the 1080 px square spans the frame's width")
        XCTAssertEqual(Double(p.redW), Double(p.redH), accuracy: 2, "the square stays square on screen (no squash)")
        XCTAssertNotEqual(rgb(p.t, p.frame.x - 4, p.frame.midY), [16, 32, 48], "outside the frame is the viewport")
        XCTAssertEqual(rgb(p.t, p.frame.midX, p.frame.y + 4), [16, 32, 48], "composition background above the square")
        XCTAssertEqual(rgb(p.t, p.frame.midX, p.frame.maxY - 4), [16, 32, 48], "and below it")
    }

    func testSquarePreviewIsNotSquashed() throws {
        let p = try preview(1080, 1080)
        XCTAssertEqual(p.frame.width, p.frame.height, accuracy: 1)
        XCTAssertEqual(Double(p.redW), p.frame.width, accuracy: 2)
        XCTAssertEqual(Double(p.redW), Double(p.redH), accuracy: 2, "the square stays square on screen")
        XCTAssertNotEqual(rgb(p.t, p.frame.x - 4, p.frame.midY), [16, 32, 48], "outside the frame is the viewport")
    }
    #endif
}
