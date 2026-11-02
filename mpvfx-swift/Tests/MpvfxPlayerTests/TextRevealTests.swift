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
/// Text reveals: units arrive on the frames the timing gives them, a frame that shows everything is the plain text,
/// and preview and export draw the same pixels.
final class TextRevealTests: XCTestCase {
    static let width = 640, height = 120
    static let content = "one two three four five"

    func layer(_ reveal: NativeTextReveal?, unreveal: NativeTextReveal? = nil, frame: Double? = nil, clipFrames: Double = 120,
               look: NativeTextLook? = nil, content: String = TextRevealTests.content) -> PreviewLayer {
        var l = PreviewLayer(clipId: "t", source: "", kind: .text, start: 0, end: 4, sourceIn: 0,
                             box: CanvasRect(x: 10, y: 10, width: Double(Self.width - 20), height: Double(Self.height - 20)))
        l.text = NativeClipText(content: content, fontSize: 40, fontWeight: 700, color: "#ffffff", look: look, reveal: reveal, unreveal: unreveal)
        l.textFrame = frame.map { TextRevealFrame(frame: $0, clipFrames: clipFrames, fps: 30) }
        return l
    }

    func render(_ l: PreviewLayer) throws -> CanvasImage {
        let c = try RasterCanvas(width: Self.width, height: Self.height)
        c.clear(.transparent)
        PreviewPainter.drawText(l, on: c, frame: CanvasRect(x: 0, y: 0, width: Double(Self.width), height: Double(Self.height)), scale: 1)
        XCTAssertNil(c.drawError)
        return c.image()
    }

    /// The word boxes, in canvas px.
    func wordBoxes(_ l: PreviewLayer) throws -> [CanvasRect] {
        let text = try XCTUnwrap(l.text)
        let units = try XCTUnwrap(TextRevealRenderer.layout(NativeTextRendering.block(text, scale: 1), width: l.box.width))
        return units.words.map { CanvasRect(x: l.box.x + $0.rect.x, y: l.box.y + $0.rect.y, width: $0.rect.width, height: $0.rect.height) }
    }

    /// Summed alpha (0…255 per pixel) inside `rect`.
    func coverage(_ image: CanvasImage, _ rect: CanvasRect) -> Int {
        var sum = 0
        for y in max(0, Int(rect.y.rounded(.down)))..<min(image.height, Int(rect.maxY.rounded(.up))) {
            for x in max(0, Int(rect.x.rounded(.down)))..<min(image.width, Int(rect.maxX.rounded(.up))) { sum += Int(image.rgba[(y * image.width + x) * 4 + 3]) }
        }
        return sum
    }

    func total(_ image: CanvasImage) -> Int { stride(from: 3, to: image.rgba.count, by: 4).reduce(0) { $0 + Int(image.rgba[$1]) } }

    // MARK: acceptance

    func testA1WordThreeStartsAtFrameTenAndIsFullyShownAtFrameTwenty() throws {
        let reveal = NativeTextReveal(unit: "words", style: "fade", staggerFrames: 5, unitFrames: 10)
        let plain = try render(layer(nil))
        let boxes = try wordBoxes(layer(reveal))
        XCTAssertEqual(boxes.count, 5)
        let full = boxes.map { coverage(plain, $0) }
        XCTAssertTrue(full.allSatisfy { $0 > 1000 })
        let at10 = try render(layer(reveal, frame: 10)), at15 = try render(layer(reveal, frame: 15)), at20 = try render(layer(reveal, frame: 20))
        XCTAssertEqual(coverage(at10, boxes[2]), 0, "word 3 has not begun at frame 10")
        XCTAssertGreaterThan(coverage(at15, boxes[2]), 0)
        XCTAssertEqual(Double(coverage(at15, boxes[2])), Double(full[2]) / 2, accuracy: Double(full[2]) * 0.1, "half way through a fade")
        XCTAssertEqual(Double(coverage(at20, boxes[2])), Double(full[2]), accuracy: Double(full[2]) * 0.02, "fully shown at frame 20")
        XCTAssertEqual(Double(coverage(at10, boxes[0])), Double(full[0]), accuracy: Double(full[0]) * 0.02, "word 1 finished at frame 10")
        XCTAssertEqual(coverage(at10, boxes[4]), 0, "the last word starts at frame 20")
    }

    func testAFrameThatShowsEverythingIsThePlainTextExactly() throws {
        let plain = try render(layer(nil))
        for style in NativeTextReveal.styles {
            let reveal = NativeTextReveal(style: style, staggerFrames: 5, unitFrames: 10)
            XCTAssertEqual(try render(layer(reveal, frame: 30)), plain, "\(style): word 5 is shown whole at frame 30")
            XCTAssertEqual(try render(layer(reveal, frame: 119)), plain, "\(style): the text rests as plain text")
            XCTAssertNotEqual(try render(layer(reveal, frame: 12)), plain, style)
        }
    }

    func testA2ASeededRandomOrderIsTheSameInEveryDrawAndDiffersBetweenSeeds() throws {
        let a = NativeTextReveal(unit: "characters", staggerFrames: 2, unitFrames: 4, order: "random", seed: 3)
        let first = try render(layer(a, frame: 14)), again = try render(layer(a, frame: 14))
        XCTAssertEqual(first, again)
        let other = try render(layer(NativeTextReveal(unit: "characters", staggerFrames: 2, unitFrames: 4, order: "random", seed: 4), frame: 14))
        XCTAssertNotEqual(first, other)
        let forward = try render(layer(NativeTextReveal(unit: "characters", staggerFrames: 2, unitFrames: 4), frame: 14))
        XCTAssertNotEqual(first, forward)
    }

    func testOrdersChangeWhichWordsShowFirst() throws {
        let boxes = try wordBoxes(layer(nil))
        func shown(_ order: String) throws -> [Bool] {
            let image = try render(layer(NativeTextReveal(staggerFrames: 6, unitFrames: 6, order: order), frame: 7))
            return boxes.map { coverage(image, $0) > 500 }
        }
        XCTAssertEqual(try shown("forward"), [true, true, false, false, false])
        XCTAssertEqual(try shown("backward"), [false, false, false, true, true])
        XCTAssertEqual(try shown("center"), [false, true, true, false, false], "the middle word and the one before it")
    }

    func testEachStyleMovesOrScalesTheUnitAsDocumented() {
        let rise = TextRevealRenderer.look("rise", amount: 0.5, fontSize: 40)
        XCTAssertEqual(rise.opacity, 0.5); XCTAssertGreaterThan(rise.dy, 0); XCTAssertEqual(rise.scale, 1)
        let grow = TextRevealRenderer.look("grow", amount: 0.5, fontSize: 40)
        XCTAssertEqual(grow.dy, 0); XCTAssertLessThan(grow.scale, 1); XCTAssertGreaterThan(grow.scale, TextRevealRenderer.growFrom)
        XCTAssertEqual(TextRevealRenderer.look("typeOn", amount: 0, fontSize: 40).opacity, 0)
        XCTAssertEqual(TextRevealRenderer.look("typeOn", amount: 0.01, fontSize: 40).opacity, 1)
        for style in NativeTextReveal.styles {
            let done = TextRevealRenderer.look(style, amount: 1, fontSize: 40)
            XCTAssertEqual(done.opacity, 1); XCTAssertEqual(done.dy, 0); XCTAssertEqual(done.scale, 1, style)
        }
    }

    func testAnUnrevealTakesTheTextAwayByTheEndOfTheClip() throws {
        let leave = NativeTextReveal(staggerFrames: 4, unitFrames: 6)
        let plain = try render(layer(nil))
        XCTAssertEqual(try render(layer(nil, unreveal: leave, frame: 40)), plain, "before the unreveal begins")
        let late = try render(layer(nil, unreveal: leave, frame: 119))
        XCTAssertLessThan(total(late), total(plain) / 10, "almost nothing is left on the last frame")
        XCTAssertLessThan(total(try render(layer(nil, unreveal: leave, frame: 110))), total(plain))
    }

    func testARevealAndUnrevealOnDifferentUnitsStillDrawEveryLetterOnce() throws {
        let words = NativeTextReveal(unit: "words", staggerFrames: 4, unitFrames: 8)
        let chars = NativeTextReveal(unit: "characters", style: "rise", staggerFrames: 1, unitFrames: 2)
        let alone = try render(layer(words, frame: 10)), both = try render(layer(words, unreveal: chars, frame: 10))
        XCTAssertGreaterThan(total(alone), 0)
        XCTAssertEqual(Double(total(both)), Double(total(alone)), accuracy: Double(total(alone)) / 100,
                       "letters that the unreveal groups differently are still drawn once, at the reveal's opacity")
    }

    func testTheTypeOnCursorBlinksAfterTheLastLetter() throws {
        let reveal = NativeTextReveal(unit: "characters", style: "typeOn", staggerFrames: 2, unitFrames: 1, cursor: true)
        let plain = try render(layer(nil))
        let on = try render(layer(reveal, frame: 70)), off = try render(layer(reveal, frame: 80))
        XCTAssertEqual(off, plain, "the off half of the blink is the plain text")
        XCTAssertGreaterThan(total(on), total(plain), "the bar adds ink")
        let words = try wordBoxes(layer(nil))
        let end = Int(words[4].maxX.rounded(.up))
        var beyond = 0
        for y in 0..<Self.height { for x in end + 1..<min(Self.width, end + 12) { beyond += Int(on.rgba[(y * Self.width + x) * 4 + 3]) } }
        XCTAssertGreaterThan(beyond, 0, "the bar stands after the last letter")
        let noCursor = NativeTextReveal(unit: "characters", style: "typeOn", staggerFrames: 2, unitFrames: 1)
        XCTAssertEqual(try render(layer(noCursor, frame: 70)), plain)
    }

    func testARevealOverALookGrowsTheLookWithTheLetters() throws {
        let look = NativeTextLook(outlines: [.init(width: 3, color: "#ff0000")], shadow: .init(x: 4, y: 4, blur: 0, color: "#0000ff"))
        let reveal = NativeTextReveal(staggerFrames: 5, unitFrames: 10)
        let staticLook = try render(layer(nil, look: look))
        let part = try render(layer(reveal, frame: 12, look: look))
        XCTAssertGreaterThan(total(part), 0)
        XCTAssertLessThan(total(part), total(staticLook))
        XCTAssertEqual(try render(layer(reveal, frame: 100, look: look)), staticLook, "when everything shows, the look is the plain look")
        XCTAssertLessThan(total(try render(layer(reveal, frame: 6, look: look))), total(part))
    }

    func testAReadingOrderForRightToLeftTextRevealsFromTheRight() throws {
        let content = "\u{0633}\u{0644}\u{0627}\u{0645} \u{062F}\u{0646}\u{06CC}\u{0627}"
        let boxes = try wordBoxes(layer(nil, content: content))
        XCTAssertEqual(boxes.count, 2)
        XCTAssertGreaterThan(boxes[0].x, boxes[1].x, "the first word of Persian text stands on the right")
        let image = try render(layer(NativeTextReveal(staggerFrames: 10, unitFrames: 4), frame: 8, content: content))
        XCTAssertGreaterThan(coverage(image, boxes[0]), 0)
        XCTAssertEqual(coverage(image, boxes[1]), 0)
    }

    func testPunctuationArrivesWithItsWord() throws {
        let content = "\u{201C}Hi,\u{201D} she said!"
        let plain = try render(layer(nil, content: content))
        let reveal = NativeTextReveal(staggerFrames: 4, unitFrames: 4)
        XCTAssertEqual(try render(layer(reveal, frame: 40, content: content)), plain)
        XCTAssertGreaterThan(total(try render(layer(reveal, frame: 3, content: content))), 0)
    }

    // MARK: preview = export

    func document(_ text: String) throws -> NativeProjectDocument {
        let raw = try NativeJSONValue.parse(
            """
            {"schemaVersion":1,"mediaEngine":"native","id":"project:reveal","revision":0,
            "frameRate":{"numerator":30,"denominator":1},"canvas":{"width":320,"height":180,"background":"#000000"},
            "assets":[{"id":"asset:title","kind":"element","name":"Title","durationFrames":60}],
            "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:1","kind":"video","clips":[
            {"id":"clip:title","assetId":"asset:title","startFrame":0,"durationFrames":60,"sourceInFrame":0,
            "staticParameters":{"layout.left":10,"layout.top":10,"layout.width":300,"layout.height":160},
            "text":\(text),"effects":[],"parameterTracks":[]}]}]}}
            """
        )
        return try parseNativeProjectDocument(raw, engine: try KeyframeRuntime())
    }

    func testA3PreviewAndExportMatchWithinOneLevelAtFiveTimesForEachStyle() throws {
        let engine = try KeyframeRuntime()
        for style in NativeTextReveal.styles {
            let text = ##"{"content":"one two three four","fontSize":40,"color":"#ffffff","reveal":{"v":1,"style":"\##(style)","staggerFrames":6,"unitFrames":10,"cursor":true},"unreveal":{"v":1,"style":"\##(style)","staggerFrames":3,"unitFrames":6}}"##
            let composition = PreviewComposition(document: try document(text), projectDir: nil, engine: engine)
            let painter = try ExportFramePainter(composition: composition, width: 320, height: 180, pad: .transparent)
            for frame in [0, 7, 19, 30, 58] {
                let time = Double(frame) / 30
                let exported = try painter.paint(time: time) { _, _, _, _ in nil }
                let canvas = try RasterCanvas(width: 320, height: 180)
                canvas.clear(CanvasColor(r: 0, g: 0, b: 0))
                for l in composition.layers(at: time) where l.kind == .text {
                    XCTAssertNotNil(l.textFrame)
                    PreviewPainter.drawText(l, on: canvas, frame: CanvasRect(x: 0, y: 0, width: 320, height: 180), scale: 1)
                }
                let shown = canvas.image()
                let worst = zip(shown.rgba, exported.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(worst, 1, "\(style) at frame \(frame)")
            }
        }
    }

    func testARevealFromANewerVersionDrawsTheTextInFull() throws {
        let engine = try KeyframeRuntime()
        let future = try document(##"{"content":"one two","fontSize":40,"color":"#ffffff","reveal":{"v":2,"unit":"syllables"}}"##)
        let plain = try document(##"{"content":"one two","fontSize":40,"color":"#ffffff"}"##)
        func frame(_ d: NativeProjectDocument) throws -> [UInt8] {
            let c = PreviewComposition(document: d, projectDir: nil, engine: engine)
            return try ExportFramePainter(composition: c, width: 320, height: 180, pad: .transparent).paint(time: 0) { _, _, _, _ in nil }.rgba
        }
        XCTAssertEqual(try frame(future), try frame(plain))
        XCTAssertNil(PreviewComposition(document: future, projectDir: nil, engine: engine).layers(at: 0)[0].textFrame)
    }

    func testALayerWithoutARevealCarriesNoRevealFrame() throws {
        let engine = try KeyframeRuntime()
        let composition = PreviewComposition(document: try document(##"{"content":"x","fontSize":40}"##), projectDir: nil, engine: engine)
        XCTAssertNil(composition.layers(at: 0)[0].textFrame)
    }

    // MARK: speed

    func testABenchOfATwoHundredCharacterTitleInsideAReveal() throws {
        let content = String(repeating: "Lorem ipsum dolor sit amet ", count: 8).prefix(200).description
        var l = layer(NativeTextReveal(unit: "characters", style: "rise", staggerFrames: 1, unitFrames: 12), frame: 60, content: content)
        l.box = CanvasRect(x: 60, y: 60, width: 1800, height: 900)
        l.text?.fontSize = 56
        let canvas = try RasterCanvas(width: 1920, height: 1080)
        let frame = CanvasRect(x: 0, y: 0, width: 1920, height: 1080)
        PreviewPainter.drawText(l, on: canvas, frame: frame, scale: 1)  // warms the unit cache and the fonts
        var worst = 0.0, sum = 0.0
        let runs = 30
        for i in 0..<runs {
            l.textFrame?.frame = 50 + Double(i % 10)
            canvas.clear(.transparent)
            let start = DispatchTime.now().uptimeNanoseconds
            PreviewPainter.drawText(l, on: canvas, frame: frame, scale: 1)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            worst = max(worst, ms); sum += ms
        }
        l.textFrame = nil; l.text?.reveal = nil
        var plain = 0.0
        for _ in 0..<5 {
            canvas.clear(.transparent)
            let start = DispatchTime.now().uptimeNanoseconds
            PreviewPainter.drawText(l, on: canvas, frame: frame, scale: 1)
            plain += Double(DispatchTime.now().uptimeNanoseconds - start) / 5_000_000
        }
        print("[bench] 200-character reveal at 1080p (debug build): mean \(sum / Double(runs)) ms, worst \(worst) ms; the same text unrevealed: \(plain) ms")
        XCTAssertLessThan(sum / Double(runs), plain * 1.5, "a frame of the reveal costs about what drawing the same text costs (milliseconds)")
    }
}
#endif
